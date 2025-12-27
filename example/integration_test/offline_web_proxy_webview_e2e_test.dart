import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('offline_web_proxy + WebView (emulator/device) e2e', () {
    Future<WebViewController> createControllerAndLoad(
      WidgetTester tester,
      Uri initialUrl,
    ) async {
      final pageLoaded = Completer<void>();
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (!pageLoaded.isCompleted) pageLoaded.complete();
            },
          ),
        );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WebViewWidget(controller: controller)),
        ),
      );

      await controller.loadRequest(initialUrl);
      await pageLoaded.future.timeout(const Duration(seconds: 30));

      return controller;
    }

    String normalizeJsString(Object? jsValue) {
      final raw = jsValue?.toString() ?? '';
      // Android WebView は結果を JSON 文字列として返すことがあるため 1回デコード
      if (raw.startsWith('"') && raw.endsWith('"')) {
        try {
          return jsonDecode(raw) as String;
        } catch (_) {
          return raw;
        }
      }
      return raw;
    }

    bool isJsTruthy(Object? value) {
      if (value is bool) return value;
      final s = (value?.toString() ?? '').toLowerCase();
      return s == 'true' || s == '1';
    }

    Future<Map<String, dynamic>> runAsyncJsReturningJsonMap(
      WebViewController controller,
      String asyncFunctionBody,
    ) async {
      final token = DateTime.now().microsecondsSinceEpoch;
      final stateVar = '__owp_it_$token';

      await controller.runJavaScript('''
(() => {
  window.$stateVar = {done:false, value:null, error:null};
  (async () => {
    try {
      const v = await (async () => { $asyncFunctionBody })();
      window.$stateVar.value = JSON.stringify(v);
    } catch (e) {
      window.$stateVar.error = String(e);
    } finally {
      window.$stateVar.done = true;
    }
  })();
})();
''');

      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        final doneRaw = await controller.runJavaScriptReturningResult(
          'window.$stateVar && window.$stateVar.done',
        );
        if (isJsTruthy(doneRaw)) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final errRaw = await controller.runJavaScriptReturningResult(
        'window.$stateVar && window.$stateVar.error',
      );
      final errText = normalizeJsString(errRaw);
      if (errText.isNotEmpty && errText != 'null') {
        fail('JS error: $errText');
      }

      final valRaw = await controller.runJavaScriptReturningResult(
        'window.$stateVar && window.$stateVar.value',
      );
      final valText = normalizeJsString(valRaw);
      if (valText.isEmpty || valText == 'null') {
        fail('JS returned no value');
      }

      final decoded = jsonDecode(valText);
      if (decoded is! Map) {
        fail('Unexpected JS JSON type: ${decoded.runtimeType}');
      }
      return Map<String, dynamic>.from(decoded);
    }

    testWidgets(
      'loads a page through proxy in WebView and still loads from cache after upstream shutdown',
      (tester) async {
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final upstreamClosed = ValueNotifier(false);

        unawaited(() async {
          await for (final HttpRequest req in upstream) {
            try {
              if (req.method == 'GET' && req.uri.path == '/page') {
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'text',
                  'html',
                  charset: 'utf-8',
                );
                req.response.headers.set('cache-control', 'max-age=3600');
                req.response.write('''
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>proxy</title></head>
  <body>
    <div id="msg">hello-from-upstream</div>
  </body>
</html>
''');
                await req.response.close();
                continue;
              }

              req.response.statusCode = 404;
              req.response.write('not found');
              await req.response.close();
            } catch (_) {
              try {
                req.response.statusCode = 500;
                await req.response.close();
              } catch (_) {
                // ignore
              }
            }
          }
        }());

        Future<void> closeUpstream() async {
          if (upstreamClosed.value) return;
          upstreamClosed.value = true;
          await upstream.close(force: true);
        }

        final proxy = OfflineWebProxy();
        final origin = 'http://127.0.0.1:${upstream.port}';
        final proxyPort = await proxy.start(
          config: ProxyConfig(origin: origin),
        );
        final proxyUrl = 'http://127.0.0.1:$proxyPort/page';

        final controller = await createControllerAndLoad(
          tester,
          Uri.parse(proxyUrl),
        );

        final msg1 = await controller
            .runJavaScriptReturningResult(
              'document.getElementById("msg").innerText',
            )
            .timeout(const Duration(seconds: 10));
        expect(msg1.toString(), contains('hello-from-upstream'));

        // Shut down upstream and reload - should be served from proxy cache.
        await closeUpstream();

        final reloadLoaded = Completer<void>();
        controller.setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (!reloadLoaded.isCompleted) reloadLoaded.complete();
            },
          ),
        );

        await controller.loadRequest(Uri.parse(proxyUrl));
        await reloadLoaded.future.timeout(const Duration(seconds: 30));

        final msg2 = await controller
            .runJavaScriptReturningResult(
              'document.getElementById("msg").innerText',
            )
            .timeout(const Duration(seconds: 10));
        expect(msg2.toString(), contains('hello-from-upstream'));

        await proxy.stop();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'POST is queued on upstream 5xx and drained when upstream recovers',
      (tester) async {
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var failPost = true;
        final receivedBodies = <String>[];

        unawaited(() async {
          await for (final HttpRequest req in upstream) {
            try {
              if (req.method == 'POST' && req.uri.path == '/echo') {
                final body = await utf8.decoder.bind(req).join();
                if (failPost) {
                  req.response.statusCode = 503;
                  req.response.write('upstream unavailable');
                  await req.response.close();
                } else {
                  receivedBodies.add(body);
                  req.response.statusCode = 200;
                  req.response.headers.contentType = ContentType(
                    'text',
                    'plain',
                    charset: 'utf-8',
                  );
                  req.response.write(body);
                  await req.response.close();
                }
                continue;
              }

              if (req.method == 'GET' && req.uri.path == '/context') {
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'text',
                  'html',
                  charset: 'utf-8',
                );
                req.response.write(
                  '<!doctype html><html><body><div id="ctx">ok</div></body></html>',
                );
                await req.response.close();
                continue;
              }

              req.response.statusCode = 404;
              await req.response.close();
            } catch (_) {
              try {
                req.response.statusCode = 500;
                await req.response.close();
              } catch (_) {
                // ignore
              }
            }
          }
        }());

        final proxy = OfflineWebProxy();
        final origin = 'http://127.0.0.1:${upstream.port}';
        final proxyPort = await proxy.start(
          config: ProxyConfig(origin: origin),
        );
        final proxyContextUrl = 'http://127.0.0.1:$proxyPort/context';

        final controller = await createControllerAndLoad(
          tester,
          Uri.parse(proxyContextUrl),
        );

        final result = await runAsyncJsReturningJsonMap(controller, '''
const r = await fetch('/echo', {
  method: 'POST',
  headers: {'Content-Type': 'text/plain'},
  body: 'hello-queue'
});
const t = await r.text();
return {status: r.status, body: t};
''');

        expect((result['status'] as num).toInt(), greaterThanOrEqualTo(500));

        // 5xxでもキューに保存されていること
        final queued1 = await proxy.getQueuedRequests();
        expect(queued1.length, greaterThanOrEqualTo(1));

        // upstream復旧
        failPost = false;

        // drain(5秒周期)で消化されるまで待つ
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(deadline)) {
          final queued = await proxy.getQueuedRequests();
          if (queued.isEmpty && receivedBodies.isNotEmpty) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }

        expect(receivedBodies, contains('hello-queue'));
        final queued2 = await proxy.getQueuedRequests();
        expect(queued2, isEmpty);

        await proxy.stop();
        await upstream.close(force: true);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'video-like binary is fetched via WebView (Range supported) and is served from cache when upstream is down',
      (tester) async {
        const totalSize = 512 * 1024; // 512KB
        final videoBytes = List<int>.generate(totalSize, (i) => i % 256);

        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        unawaited(() async {
          await for (final HttpRequest req in upstream) {
            try {
              if (req.method == 'GET' && req.uri.path == '/video') {
                req.response.headers.contentType = ContentType('video', 'mp4');
                req.response.headers.set('accept-ranges', 'bytes');

                final range = req.headers.value('range');
                if (range != null && range.startsWith('bytes=')) {
                  final parts = range.substring('bytes='.length).split('-');
                  final start = int.tryParse(parts.first) ?? 0;
                  final end =
                      int.tryParse(parts.length > 1 ? parts[1] : '') ??
                      (totalSize - 1);
                  final safeStart = start.clamp(0, totalSize - 1);
                  final safeEnd = end.clamp(safeStart, totalSize - 1);
                  final slice = videoBytes.sublist(safeStart, safeEnd + 1);

                  req.response.statusCode = 206;
                  req.response.headers.set(
                    'content-range',
                    'bytes $safeStart-$safeEnd/$totalSize',
                  );
                  req.response.headers.set('content-length', '${slice.length}');
                  req.response.add(slice);
                  await req.response.close();
                } else {
                  req.response.statusCode = 200;
                  req.response.headers.set('content-length', '$totalSize');
                  req.response.add(videoBytes);
                  await req.response.close();
                }
                continue;
              }

              if (req.method == 'GET' && req.uri.path == '/context') {
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'text',
                  'html',
                  charset: 'utf-8',
                );
                req.response.write(
                  '<!doctype html><html><body><div id="ctx">ok</div></body></html>',
                );
                await req.response.close();
                continue;
              }

              req.response.statusCode = 404;
              await req.response.close();
            } catch (_) {
              try {
                req.response.statusCode = 500;
                await req.response.close();
              } catch (_) {
                // ignore
              }
            }
          }
        }());

        final proxy = OfflineWebProxy();
        final origin = 'http://127.0.0.1:${upstream.port}';
        final proxyPort = await proxy.start(
          config: ProxyConfig(origin: origin),
        );
        final proxyContextUrl = 'http://127.0.0.1:$proxyPort/context';

        final controller = await createControllerAndLoad(
          tester,
          Uri.parse(proxyContextUrl),
        );

        // Range fetch (streaming-like)
        final rangeResult = await runAsyncJsReturningJsonMap(controller, '''
const r = await fetch('/video', {headers: {'Range': 'bytes=0-1023'}});
const b = await r.arrayBuffer();
return {status: r.status, len: b.byteLength, cr: r.headers.get('content-range')};
''');
        expect((rangeResult['status'] as num).toInt(), 206);
        expect((rangeResult['len'] as num).toInt(), 1024);
        expect((rangeResult['cr'] as String?) ?? '', contains('bytes 0-1023/'));

        // Full fetch to warm cache
        final full1 = await runAsyncJsReturningJsonMap(controller, '''
const r = await fetch('/video');
const b = await r.arrayBuffer();
const u = new Uint8Array(b);
return {status: r.status, len: b.byteLength, first: u[0], last: u[u.length-1]};
''');
        expect((full1['status'] as num).toInt(), 200);
        expect((full1['len'] as num).toInt(), totalSize);
        expect((full1['first'] as num).toInt(), 0);
        expect((full1['last'] as num).toInt(), 255);

        // Stop upstream to force cache usage
        await upstream.close(force: true);

        // Range fetch should be served from cache even when upstream is down
        final cachedRange = await runAsyncJsReturningJsonMap(controller, '''
      const r = await fetch('/video', {headers: {'Range': 'bytes=0-1023'}});
      const b = await r.arrayBuffer();
      return {status: r.status, len: b.byteLength, cr: r.headers.get('content-range')};
      ''');
        expect((cachedRange['status'] as num).toInt(), 206);
        expect((cachedRange['len'] as num).toInt(), 1024);
        expect((cachedRange['cr'] as String?) ?? '', contains('bytes 0-1023/'));

        final full2 = await runAsyncJsReturningJsonMap(controller, '''
      const r = await fetch('/video');
      const b = await r.arrayBuffer();
      const u = new Uint8Array(b);
      return {status: r.status, len: b.byteLength, first: u[0], last: u[u.length-1]};
      ''');
        expect((full2['status'] as num).toInt(), 200);
        expect((full2['len'] as num).toInt(), totalSize);
        expect((full2['first'] as num).toInt(), 0);
        expect((full2['last'] as num).toInt(), 255);

        await proxy.stop();
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    testWidgets(
      'video-like binary can be streamed via multiple sequential Range requests in WebView (playback-like)',
      (tester) async {
        const totalSize = 512 * 1024; // 512KB
        final videoBytes = List<int>.generate(totalSize, (i) => i % 256);

        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        unawaited(() async {
          await for (final HttpRequest req in upstream) {
            try {
              if (req.method == 'GET' && req.uri.path == '/video') {
                req.response.headers.contentType = ContentType('video', 'mp4');
                req.response.headers.set('accept-ranges', 'bytes');

                final range = req.headers.value('range');
                if (range != null && range.startsWith('bytes=')) {
                  final spec = range.substring('bytes='.length);
                  final parts = spec.split('-');
                  final start = int.tryParse(parts[0]) ?? 0;
                  final end =
                      int.tryParse(parts.length > 1 ? parts[1] : '') ??
                      (start + 1023);
                  final safeStart = start.clamp(0, totalSize - 1);
                  final safeEnd = end.clamp(safeStart, totalSize - 1);
                  final body = videoBytes.sublist(safeStart, safeEnd + 1);

                  req.response.statusCode = 206;
                  req.response.headers.set(
                    'content-range',
                    'bytes $safeStart-$safeEnd/$totalSize',
                  );
                  req.response.add(body);
                  await req.response.close();
                  continue;
                }

                req.response.statusCode = 200;
                req.response.add(videoBytes);
                await req.response.close();
                continue;
              }

              if (req.method == 'GET' && req.uri.path == '/context') {
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'text',
                  'html',
                  charset: 'utf-8',
                );
                req.response.write(
                  '<!doctype html><html><body><div id="ctx">ok</div></body></html>',
                );
                await req.response.close();
                continue;
              }

              req.response.statusCode = 404;
              await req.response.close();
            } catch (_) {
              try {
                req.response.statusCode = 500;
                await req.response.close();
              } catch (_) {
                // ignore
              }
            }
          }
        }());

        final proxy = OfflineWebProxy();
        final origin = 'http://127.0.0.1:${upstream.port}';
        final proxyPort = await proxy.start(
          config: ProxyConfig(origin: origin),
        );
        final proxyContextUrl = 'http://127.0.0.1:$proxyPort/context';

        final controller = await createControllerAndLoad(
          tester,
          Uri.parse(proxyContextUrl),
        );

        Future<void> expectRange(int start, int end) async {
          final result = await runAsyncJsReturningJsonMap(controller, '''
const r = await fetch('/video', {headers: {'Range': 'bytes=$start-$end'}});
const b = await r.arrayBuffer();
const u = new Uint8Array(b);
return {
  status: r.status,
  len: b.byteLength,
  cr: r.headers.get('content-range'),
  first: u[0],
  last: u[u.length-1]
};
''');

          expect((result['status'] as num).toInt(), 206);
          expect((result['len'] as num).toInt(), end - start + 1);
          expect(
            (result['cr'] as String?) ?? '',
            contains('bytes $start-$end/$totalSize'),
          );
          expect((result['first'] as num).toInt(), start % 256);
          expect((result['last'] as num).toInt(), end % 256);
        }

        // 動画プレイヤーっぽく少しずつRange取得
        await expectRange(1, 1024);
        await expectRange(1025, 2048);
        await expectRange(2049, 3072);

        await proxy.stop();
        await upstream.close(force: true);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'loads a typical website with parallel HTML/CSS/JS/images requests (and JS fetches)',
      (tester) async {
        // 1x1 transparent PNG
        final pngBytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/6X3mS4AAAAASUVORK5CYII=',
        );

        final requested = <String>[];

        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        unawaited(() async {
          await for (final HttpRequest req in upstream) {
            try {
              requested.add('${req.method} ${req.uri.path}');

              void setCache() {
                req.response.headers.set('cache-control', 'max-age=3600');
              }

              if (req.method == 'GET' && req.uri.path == '/site') {
                setCache();
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'text',
                  'html',
                  charset: 'utf-8',
                );
                req.response.write('''
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>parallel</title>
    <link rel="stylesheet" href="/style.css" />
  </head>
  <body>
    <h1 id="title">parallel-load</h1>
    <img id="img1" src="/img1.png" />
    <img id="img2" src="/img2.png" />
    <script src="/app.js"></script>
  </body>
</html>
''');
                await req.response.close();
                continue;
              }

              if (req.method == 'GET' && req.uri.path == '/style.css') {
                setCache();
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'text',
                  'css',
                  charset: 'utf-8',
                );
                req.response.write('body{background:#fff;}');
                await req.response.close();
                continue;
              }

              if (req.method == 'GET' && req.uri.path == '/app.js') {
                setCache();
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'application',
                  'javascript',
                  charset: 'utf-8',
                );
                // JS側で並列に fetch と Image ロードを走らせ、結果を window に保存
                req.response.write('''
(function(){
  window.__owpParallel = {done:false, ok:false, details:null};

  function loadImg(url){
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve({url});
      img.onerror = (e) => reject(e);
      img.src = url;
    });
  }

  async function run(){
    const t0 = Date.now();
    const p1 = fetch('/api/data1.json').then(r => r.json()).then(v => ({k:'data1', ok:true, v}));
    const p2 = fetch('/api/data2.json').then(r => r.json()).then(v => ({k:'data2', ok:true, v}));
    const p3 = loadImg('/img3.png').then(() => ({k:'img3', ok:true}));
    const p4 = loadImg('/img4.png').then(() => ({k:'img4', ok:true}));

    const results = await Promise.all([p1,p2,p3,p4]);
    const dt = Date.now() - t0;
    window.__owpParallel.details = {results, ms: dt};
    window.__owpParallel.ok = results.every(x => x.ok) && dt < 20000;
    window.__owpParallel.done = true;
  }

  run().catch((e) => {
    window.__owpParallel.details = {error: String(e)};
    window.__owpParallel.ok = false;
    window.__owpParallel.done = true;
  });
})();
''');
                await req.response.close();
                continue;
              }

              if (req.method == 'GET' &&
                  (req.uri.path == '/img1.png' ||
                      req.uri.path == '/img2.png' ||
                      req.uri.path == '/img3.png' ||
                      req.uri.path == '/img4.png')) {
                setCache();
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType('image', 'png');
                req.response.add(pngBytes);
                await req.response.close();
                continue;
              }

              if (req.method == 'GET' && req.uri.path == '/api/data1.json') {
                setCache();
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'application',
                  'json',
                  charset: 'utf-8',
                );
                req.response.write('{"name":"data1","ok":true}');
                await req.response.close();
                continue;
              }

              if (req.method == 'GET' && req.uri.path == '/api/data2.json') {
                setCache();
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'application',
                  'json',
                  charset: 'utf-8',
                );
                req.response.write('{"name":"data2","ok":true}');
                await req.response.close();
                continue;
              }

              if (req.method == 'GET' && req.uri.path == '/context') {
                req.response.statusCode = 200;
                req.response.headers.contentType = ContentType(
                  'text',
                  'html',
                  charset: 'utf-8',
                );
                req.response.write(
                  '<!doctype html><html><body><div id="ctx">ok</div></body></html>',
                );
                await req.response.close();
                continue;
              }

              req.response.statusCode = 404;
              await req.response.close();
            } catch (_) {
              try {
                req.response.statusCode = 500;
                await req.response.close();
              } catch (_) {
                // ignore
              }
            }
          }
        }());

        final proxy = OfflineWebProxy();
        final origin = 'http://127.0.0.1:${upstream.port}';
        final proxyPort = await proxy.start(
          config: ProxyConfig(origin: origin),
        );
        final siteUrl = 'http://127.0.0.1:$proxyPort/site';

        final controller = await createControllerAndLoad(
          tester,
          Uri.parse(siteUrl),
        );

        final pageResult = await runAsyncJsReturningJsonMap(controller, '''
while (!window.__owpParallel || !window.__owpParallel.done) {
  await new Promise(r => setTimeout(r, 50));
}
return window.__owpParallel;
''');

        expect(
          (pageResult['ok'] as bool?) ?? false,
          isTrue,
          reason: 'details=${pageResult['details']}',
        );

        // 上流が「サイト一式」を受信していること（HTML/CSS/JS/画像/JSON）
        final expectedPaths = <String>{
          'GET /site',
          'GET /style.css',
          'GET /app.js',
          'GET /img1.png',
          'GET /img2.png',
          'GET /img3.png',
          'GET /img4.png',
          'GET /api/data1.json',
          'GET /api/data2.json',
        };
        // WebViewの内部挙動で重複要求が来る場合があるので「含まれているか」だけ見る
        final requestedSet = requested.toSet();
        for (final p in expectedPaths) {
          expect(
            requestedSet.contains(p),
            isTrue,
            reason: 'missing=$p got=$requestedSet',
          );
        }

        final requestedCountBeforeOffline = requested.length;

        // 上流停止後も、サイト一式がプロキシキャッシュで成立すること
        await upstream.close(force: true);

        final pageReloaded = Completer<void>();
        controller.setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (!pageReloaded.isCompleted) pageReloaded.complete();
            },
          ),
        );
        await controller.loadRequest(Uri.parse(siteUrl));
        await pageReloaded.future.timeout(const Duration(seconds: 30));

        final pageResult2 = await runAsyncJsReturningJsonMap(controller, '''
while (!window.__owpParallel || !window.__owpParallel.done) {
  await new Promise(r => setTimeout(r, 50));
}
return window.__owpParallel;
''');
        expect(
          (pageResult2['ok'] as bool?) ?? false,
          isTrue,
          reason: 'details=${pageResult2['details']}',
        );

        // 上流は停止しているので、これ以上 upstream 側のログが増えていないこと
        expect(requested.length, requestedCountBeforeOffline);

        await proxy.stop();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
