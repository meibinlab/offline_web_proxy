import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:webview_flutter/webview_flutter.dart';
// webview_flutter の WebViewCookieManager は HttpOnly を指定できないため、
// Android の CookieManager を直接使う。利用側がネイティブで置く手順を再現する。
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:webview_flutter_android/src/android_webkit.g.dart'
    as android_webkit;

/// 1x1 の透明な PNG。
final List<int> _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// 受信した要求を記録する上流のモック。
class _Upstream {
  _Upstream(this._server) {
    unawaited(_serve());
  }

  final HttpServer _server;

  /// 受信したパスの一覧。受信順に追加される。
  final List<String> receivedPaths = <String>[];

  /// 受信した `Cookie` ヘッダの一覧（無い場合は空文字列）。
  final List<String> receivedCookies = <String>[];

  /// 受信した秘密値ヘッダの一覧（無い場合は空文字列）。
  final List<String> receivedTokenHeaders = <String>[];

  /// 上流の origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 要求に応答し続ける。
  Future<void> _serve() async {
    await for (final HttpRequest req in _server) {
      try {
        await req.drain<void>();
        receivedPaths.add(req.uri.path);
        receivedCookies.add(req.headers.value('cookie') ?? '');
        receivedTokenHeaders.add(
          req.headers.value(OfflineWebProxy.accessTokenHeaderName) ?? '',
        );

        switch (req.uri.path) {
          case '/page':
            req.response.headers.contentType =
                ContentType('text', 'html', charset: 'utf-8');
            req.response.headers.add('set-cookie', 'e2e_a=1; Path=/');
            req.response.headers.add('set-cookie', 'e2e_b=2; Path=/');
            req.response.write('''
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>token</title></head>
  <body>
    <div id="msg">hello-from-upstream</div>
    <img id="img" src="/img.png">
    <script src="/app.js"></script>
  </body>
</html>
''');
          case '/app.js':
            req.response.headers.contentType =
                ContentType('text', 'javascript', charset: 'utf-8');
            req.response.write('window.__appLoaded = true;');
          case '/img.png':
            req.response.headers.contentType = ContentType('image', 'png');
            req.response.add(_pngBytes);
          case '/api/data':
            req.response.headers.contentType = ContentType.json;
            req.response.write('{"ok":true}');
          default:
            req.response.statusCode = HttpStatus.notFound;
        }
        await req.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    }
  }

  /// 上流を停止する。
  Future<void> close() => _server.close(force: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('requireAccessToken + WebView (emulator/device) e2e', () {
    late _Upstream upstream;
    late OfflineWebProxy proxy;

    setUp(() async {
      upstream =
          _Upstream(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      proxy = OfflineWebProxy();
      // 前のテストの Cookie を残さない
      await WebViewCookieManager().clearCookies();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
      await upstream.close();
      await WebViewCookieManager().clearCookies();
    });

    /// 秘密値を有効にして proxy を起動する。
    ///
    /// Returns: proxy のポート番号。
    Future<int> startProxy() {
      return proxy.start(
        config: ProxyConfig(
          origin: upstream.origin,
          requireAccessToken: true,
          addCorsHeaders: false,
        ),
      );
    }

    /// 利用側の手順どおり、proxy の origin へ HttpOnly の Cookie を置く。
    Future<void> putTokenCookie() async {
      await android_webkit.CookieManager.instance.setCookie(
        proxy.baseUri.toString(),
        '${OfflineWebProxy.accessTokenCookieName}=${proxy.accessToken}; '
        'path=/; HttpOnly',
      );
    }

    /// WebView を表示して [url] を読み込み、読み込みが終わるまで待つ。
    ///
    /// Returns: 読み込んだ WebView のコントローラ。
    Future<WebViewController> loadInWebView(
      WidgetTester tester,
      Uri url,
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
            home: Scaffold(body: WebViewWidget(controller: controller))),
      );
      await controller.loadRequest(url);
      await pageLoaded.future.timeout(const Duration(seconds: 30));
      return controller;
    }

    /// 同じ WebView で [url] を読み込み直し、読み込みが終わるまで待つ。
    Future<void> reload(WebViewController controller, Uri url) async {
      final pageLoaded = Completer<void>();
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!pageLoaded.isCompleted) pageLoaded.complete();
          },
        ),
      );
      await controller.loadRequest(url);
      await pageLoaded.future.timeout(const Duration(seconds: 30));
    }

    /// Android WebView が JSON 文字列で返す結果を 1 回だけ戻す。
    String normalizeJsString(Object? jsValue) {
      final raw = jsValue?.toString() ?? '';
      if (raw.startsWith('"') && raw.endsWith('"')) {
        try {
          return jsonDecode(raw) as String;
        } catch (_) {
          return raw;
        }
      }
      return raw;
    }

    /// ページ上で非同期の JavaScript を実行し、JSON の結果を受け取る。
    ///
    /// [body] は値を return する async 関数の本体です。
    ///
    /// Returns: JavaScript が返した値を JSON で往復させた Map。
    Future<Map<String, dynamic>> runAsyncJs(
      WebViewController controller,
      String body,
    ) async {
      final stateVar = '__owp_token_${DateTime.now().microsecondsSinceEpoch}';
      await controller.runJavaScript('''
(() => {
  window.$stateVar = {done:false, value:null, error:null};
  (async () => {
    try {
      const v = await (async () => { $body })();
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
        final done = normalizeJsString(
          await controller
              .runJavaScriptReturningResult('window.$stateVar.done'),
        );
        if (done == 'true' || done == '1') break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      final error = normalizeJsString(
        await controller.runJavaScriptReturningResult('window.$stateVar.error'),
      );
      if (error.isNotEmpty && error != 'null') {
        fail('JS error: $error');
      }
      final value = normalizeJsString(
        await controller.runJavaScriptReturningResult('window.$stateVar.value'),
      );
      return Map<String, dynamic>.from(jsonDecode(value) as Map);
    }

    /// Dart の HttpClient（WebView 以外のクライアント）で GET を送る。
    ///
    /// Returns: 応答のステータスコード。
    Future<int> getFromOtherClient(
      Uri uri, {
      Map<String, String> headers = const <String, String>{},
    }) async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(uri);
        headers.forEach(request.headers.set);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    testWidgets(
      'WebView with the HttpOnly token cookie loads the page, subresources and fetch',
      (tester) async {
        final port = await startProxy();
        await putTokenCookie();
        final pageUrl = Uri.parse('http://127.0.0.1:$port/page');

        final controller = await loadInWebView(tester, pageUrl);

        final msg = normalizeJsString(
          await controller.runJavaScriptReturningResult(
            'document.getElementById("msg") ? '
            'document.getElementById("msg").innerText : document.body.innerText',
          ),
        );
        expect(msg, contains('hello-from-upstream'));

        final result = await runAsyncJs(controller, '''
const img = document.getElementById("img");
if (!img.complete) {
  await new Promise((resolve) => { img.onload = resolve; img.onerror = resolve; });
}
const data = await fetch("/api/data");
const status = await fetch("/__offline_web_proxy/status");
const omitted = await fetch("/api/data", { credentials: "omit" });
return {
  appLoaded: window.__appLoaded === true,
  imageWidth: img.naturalWidth,
  dataStatus: data.status,
  dataBody: await data.text(),
  dataAllowOrigin: data.headers.get("access-control-allow-origin"),
  statusStatus: status.status,
  omittedStatus: omitted.status,
  documentCookie: document.cookie,
};
''');

        // サブリソース・fetch・状態通知が秘密値の Cookie で通ること
        expect(result['appLoaded'], isTrue);
        expect(result['imageWidth'], equals(1));
        expect(result['dataStatus'], equals(HttpStatus.ok));
        expect(result['dataBody'], equals('{"ok":true}'));
        expect(result['statusStatus'], equals(HttpStatus.ok));
        // addCorsHeaders: false で CORS ヘッダを付けないこと
        expect(result['dataAllowOrigin'], isNull);
        // Cookie を送らない fetch は拒否すること
        expect(result['omittedStatus'], equals(HttpStatus.forbidden));
        // 上流が返した複数の Set-Cookie がどれも WebView に届くこと
        expect(result['documentCookie'] as String, contains('e2e_a=1'));
        expect(result['documentCookie'] as String, contains('e2e_b=2'));
        // HttpOnly のため、ページのスクリプトから秘密値が見えないこと
        expect(
          result['documentCookie'] as String,
          isNot(contains(OfflineWebProxy.accessTokenCookieName)),
        );

        // 上流へ秘密値を渡さないこと
        expect(upstream.receivedPaths,
            containsAll(<String>['/page', '/app.js', '/img.png', '/api/data']));
        expect(
          upstream.receivedCookies.where(
            (cookie) => cookie.contains(OfflineWebProxy.accessTokenCookieName),
          ),
          isEmpty,
        );
        expect(
            upstream.receivedTokenHeaders.where((v) => v.isNotEmpty), isEmpty);

        // WebView 以外のクライアントは、秘密値が無ければ拒否されること
        final requestCountBefore = upstream.receivedPaths.length;
        expect(
          await getFromOtherClient(
              Uri.parse('http://127.0.0.1:$port/api/data')),
          equals(HttpStatus.forbidden),
        );
        expect(upstream.receivedPaths.length, equals(requestCountBefore));
        expect(
          await getFromOtherClient(
            Uri.parse('http://127.0.0.1:$port/api/data'),
            headers: {
              OfflineWebProxy.accessTokenHeaderName: proxy.accessToken!,
            },
          ),
          equals(HttpStatus.ok),
        );
        // 稼働確認は秘密値なしで応答すること
        expect(await proxy.probe(), isTrue);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'WebView without the token cookie is refused',
      (tester) async {
        final port = await startProxy();

        final controller = await loadInWebView(
          tester,
          Uri.parse('http://127.0.0.1:$port/page'),
        );

        final text = normalizeJsString(
          await controller.runJavaScriptReturningResult(
            'document.body ? document.body.innerText : ""',
          ),
        );
        expect(text, contains('access token is required'));
        expect(upstream.receivedPaths, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'the cookie of the previous start is refused until the new token is put',
      (tester) async {
        await startProxy();
        await putTokenCookie();
        await proxy.stop();

        final port = await startProxy();
        final pageUrl = Uri.parse('http://127.0.0.1:$port/page');

        // 前回の値の Cookie が残っていても拒否すること
        final controller = await loadInWebView(tester, pageUrl);
        final refused = normalizeJsString(
          await controller.runJavaScriptReturningResult(
            'document.body ? document.body.innerText : ""',
          ),
        );
        expect(refused, contains('access token is required'));
        expect(upstream.receivedPaths, isEmpty);

        // 新しい値を置き直すと読み込めること
        await putTokenCookie();
        await reload(controller, pageUrl);
        final accepted = normalizeJsString(
          await controller.runJavaScriptReturningResult(
            'document.body ? document.body.innerText : ""',
          ),
        );
        expect(accepted, contains('hello-from-upstream'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'requests from another process never reach the upstream',
      (tester) async {
        final port = await startProxy();
        await putTokenCookie();

        // 端末の別プロセス（adb shell）から要求を送れるよう、ポートを知らせて待つ。
        // 要求はホスト側のスクリプトが送り、応答のステータスはホスト側で確かめる
        const window = Duration(seconds: 40);
        // ignore: avoid_print
        print('OWP_E2E_EXTERNAL_PROBE_PORT=$port');
        await Future<void>.delayed(window);

        // 別プロセスの要求は、秘密値の有無の検査で上流へ届かないこと
        expect(upstream.receivedPaths, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
