import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 上流サーバが返すページ本文の目印。
const String _upstreamMarker = 'hello-from-upstream';

/// 既定の代替ページの見出し。
const String _offlineHeading = 'オフライン中です';

/// 既定の 504 ページの見出し。
const String _gatewayTimeoutHeading = '上流サーバがタイムアウトしました';

/// 上流が応答するまでの遅延。`requestTimeout` を超えさせて 504 を返させる。
const Duration _slowResponse = Duration(seconds: 5);

/// 画面として読み込むパスの接頭辞。上流が数える `GET` はこの接頭辞のものに限る。
const String _pagePathPrefix = '/uncached';

/// 同じポートで停止と再起動を繰り返せ、応答の遅延と更新系のステータスを
/// 切り替えられる上流サーバ。
class _ControllableUpstream {
  _ControllableUpstream._(this.port);

  /// 待ち受けるポート番号。再起動しても変わらない。
  final int port;

  /// 稼働中のサーバ。停止中は `null`。
  HttpServer? _server;

  /// 画面の `GET` への応答を遅らせる時間。`null` の場合は遅らせない。
  Duration? getDelay;

  /// 更新系の要求へ返すステータスコード。
  int updateStatusCode = HttpStatus.ok;

  /// 受信した画面の `GET`（[_pagePathPrefix] で始まるもの）の件数。
  ///
  /// favicon などの付随する要求で件数がずれないよう、画面のパスだけを数える。
  int getCount = 0;

  /// 空きポートで上流サーバを起動する。
  ///
  /// Returns: 起動した上流サーバ。
  static Future<_ControllableUpstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _ControllableUpstream._(server.port);
    upstream._listen(server);
    return upstream;
  }

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:$port';

  /// 同じポートで上流サーバを再起動する。
  ///
  /// Returns: 再起動の完了を表す Future。
  Future<void> restart() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _listen(server);
  }

  /// 上流サーバを停止する。
  ///
  /// Returns: 停止の完了を表す Future。
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// 受信した要求へ並行して応答する。
  ///
  /// 遅延中の `GET` が復帰確認の `HEAD` を待たせないよう、要求ごとに応答する。
  ///
  /// [server] は応答に使うサーバです。
  void _listen(HttpServer server) {
    _server = server;
    unawaited(() async {
      await for (final HttpRequest request in server) {
        unawaited(_respond(request));
      }
    }());
  }

  /// 1 件の要求へ応答する。
  ///
  /// [request] は受信した要求です。
  ///
  /// Returns: 応答の完了を表す Future。
  Future<void> _respond(HttpRequest request) async {
    try {
      await request.drain<void>();
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = updateStatusCode;
        await request.response.close();
        return;
      }

      final isPage = request.method == 'GET' &&
          request.uri.path.startsWith(_pagePathPrefix);
      if (isPage) {
        getCount += 1;
        final delay = getDelay;
        if (delay != null) {
          await Future<void>.delayed(delay);
        }
      }

      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
        ..headers.set('cache-control', 'no-store');
      if (request.method == 'GET') {
        request.response.write('''
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>upstream</title></head>
  <body><div id="msg">$_upstreamMarker</div></body>
</html>
''');
      }
      await request.response.close();
    } catch (_) {
      // 停止処理と重なった場合は無視する
    }
  }
}

/// WebView の読み込み完了を待つ操作と、表示中の本文の取得をまとめたクラス。
class _WebViewHarness {
  _WebViewHarness(this.controller);

  /// テスト対象の WebView コントローラ。
  final WebViewController controller;

  /// 読み込み完了の通知先。読み込みごとに作り直す。
  Completer<void>? _pageFinished;

  /// delegate を設定する。読み込み完了を通知する。
  void installDelegate() {
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) {
          final pageFinished = _pageFinished;
          if (pageFinished != null && !pageFinished.isCompleted) {
            pageFinished.complete();
          }
        },
      ),
    );
  }

  /// URL を読み込み、読み込み完了まで待つ。
  ///
  /// [uri] は読み込む URL です。
  ///
  /// Returns: 読み込み完了を表す Future。
  Future<void> loadAndWait(Uri uri) async {
    final pageFinished = Completer<void>();
    _pageFinished = pageFinished;
    await controller.loadRequest(uri);
    await pageFinished.future.timeout(const Duration(seconds: 30));
  }

  /// 表示中のページで JavaScript を実行する。
  ///
  /// [source] は実行するスクリプトです。
  ///
  /// Returns: 実行の完了を表す Future。
  Future<void> runScript(String source) {
    return controller.runJavaScript(source).timeout(
          const Duration(seconds: 10),
        );
  }

  /// 表示中のページで式を評価し、結果を文字列で返す。
  ///
  /// [expression] は評価する式です。
  ///
  /// Returns: 評価結果の文字列表現。
  Future<String> evaluate(String expression) async {
    final value = await controller
        .runJavaScriptReturningResult(expression)
        .timeout(const Duration(seconds: 10));
    return value.toString();
  }

  /// 表示中のページの本文テキストを取得する。
  ///
  /// Returns: `document.body.innerText` の値。
  Future<String> readBodyText() => evaluate('document.body.innerText');

  /// 表示中のページのパスとクエリを取得する。
  ///
  /// Returns: `location.pathname + location.search` の値。
  Future<String> readLocation() =>
      evaluate('location.pathname + location.search');

  /// 評価結果に指定の文字列がすべて現れるまで待つ。
  ///
  /// [read] は評価結果の取得です。[texts] は待つ文字列です。
  /// [timeout] は待つ上限です。
  ///
  /// Returns: 文字列が現れた時点で完了する Future。
  Future<void> _waitFor(
    Future<String> Function() read,
    List<String> texts, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final value = await read();
        if (texts.every(value.contains)) {
          return;
        }
      } catch (_) {
        // 再読み込みの途中は取得できないことがあるため、次の確認へ進む
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException('"${texts.join('", "')}" が現れませんでした', timeout);
  }

  /// 本文に指定の文字列が現れるまで待つ。
  ///
  /// [text] は待つ文字列です。[timeout] は待つ上限です。
  ///
  /// Returns: 文字列が現れた時点で完了する Future。
  Future<void> waitForText(String text, {required Duration timeout}) {
    return _waitFor(readBodyText, [text], timeout: timeout);
  }

  /// 表示中のページのパスとクエリに、指定の文字列がすべて現れるまで待つ。
  ///
  /// [texts] は待つ文字列です。[timeout] は待つ上限です。
  ///
  /// Returns: 文字列が現れた時点で完了する Future。
  Future<void> waitForLocation(
    List<String> texts, {
    required Duration timeout,
  }) {
    return _waitFor(readLocation, texts, timeout: timeout);
  }
}

/// 状態通知を読み、JSON を返す。
///
/// [port] は proxy のポート番号です。
///
/// Returns: 状態通知の JSON。
Future<Map<String, dynamic>> _readStatus(int port) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

/// proxy を経由して要求を送り、ステータスコードを返す。
///
/// [uri] は要求先です。[method] は HTTP メソッドです。
///
/// Returns: 応答のステータスコード。
Future<int> _requestThroughProxy(Uri uri, {String method = 'GET'}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    if (method != 'GET') {
      request.write('{"total":1000}');
    }
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// 条件を満たすまで待つ。
///
/// [condition] は判定です。[timeout] は待つ上限です。[message] は失敗時の説明です。
///
/// Returns: 条件を満たした時点で完了する Future。
Future<void> _waitUntil(
  FutureOr<bool> Function() condition, {
  required Duration timeout,
  required String message,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(message, timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('offline_web_proxy オフライン代替ページの自動復帰 (emulator/device) e2e', () {
    /// WebView を画面に配置して操作用のハーネスを返す。
    ///
    /// [tester] はウィジェットテスターです。
    ///
    /// Returns: WebView 操作用のハーネス。
    Future<_WebViewHarness> pumpWebView(WidgetTester tester) async {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted);
      final harness = _WebViewHarness(controller)..installDelegate();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WebViewWidget(controller: controller)),
        ),
      );

      return harness;
    }

    /// 上流を止めて転送の失敗を起こし、到達不能と判定されるまで待つ。
    ///
    /// [upstream] は停止する上流サーバです。[port] は proxy のポート番号です。
    /// [failures] はサーキットを遮断させるために起こす失敗の回数です。
    ///
    /// Returns: 到達不能と判定された時点で完了する Future。
    Future<void> openCircuit(
      _ControllableUpstream upstream,
      int port, {
      required int failures,
    }) async {
      await upstream.stop();
      for (var attempt = 0; attempt < failures; attempt++) {
        await _requestThroughProxy(
          Uri.parse('http://127.0.0.1:$port/warmup$attempt'),
        );
      }

      await _waitUntil(
        () async => (await _readStatus(port))['isUpstreamReachable'] == false,
        timeout: const Duration(seconds: 30),
        message: '上流が到達不能と判定されませんでした',
      );
    }

    /// 遮断中に代替ページを表示する。
    ///
    /// [harness] は WebView 操作用のハーネスです。[port] は proxy のポート番号です。
    ///
    /// Returns: 代替ページを表示した時点で完了する Future。
    Future<void> showOfflinePage(_WebViewHarness harness, int port) async {
      await harness.loadAndWait(
        Uri.parse('http://127.0.0.1:$port$_pagePathPrefix'),
      );
      expect(await harness.readBodyText(), contains(_offlineHeading));
    }

    testWidgets(
      'reloads the offline fallback page once the upstream comes back',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: upstream.origin,
              upstreamFailureThreshold: 1,
              upstreamProbeBackoffSeconds: const [1],
              autoReloadPollInterval: const Duration(milliseconds: 500),
              autoReloadQueueWaitTimeout: const Duration(seconds: 1),
            ),
          );
          final harness = await pumpWebView(tester);

          await openCircuit(upstream, port, failures: 1);
          await showOfflinePage(harness, port);

          // 上流が戻ると、復帰確認で遮断が解け、代替ページが自分で再読み込みすること
          await upstream.restart();
          await harness.waitForText(
            _upstreamMarker,
            timeout: const Duration(seconds: 60),
          );
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'does not count successful recoveries toward the reload limit',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: upstream.origin,
              upstreamFailureThreshold: 1,
              upstreamProbeBackoffSeconds: const [1],
              autoReloadPollInterval: const Duration(milliseconds: 500),
              autoReloadQueueWaitTimeout: const Duration(seconds: 1),
            ),
          );
          final harness = await pumpWebView(tester);

          // 連続回数の上限（3 回）を超える回数だけ、代替ページからの復帰を繰り返す
          for (var cycle = 0; cycle < 4; cycle++) {
            await openCircuit(upstream, port, failures: 1);
            await showOfflinePage(harness, port);

            await upstream.restart();
            // 成功した復帰は数えないため、毎回自動で本来の画面へ戻ること
            await harness.waitForText(
              _upstreamMarker,
              timeout: const Duration(seconds: 60),
            );
          }
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );

    testWidgets(
      'keeps the offline fallback page while the status cannot be read',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: upstream.origin,
              upstreamFailureThreshold: 1,
              autoReloadPollInterval: const Duration(milliseconds: 500),
            ),
          );
          final harness = await pumpWebView(tester);

          await openCircuit(upstream, port, failures: 1);
          await showOfflinePage(harness, port);

          // 状態を取得できない状況を作る
          await proxy.stop();
          await upstream.restart();
          await Future<void>.delayed(const Duration(seconds: 5));

          // 取得に失敗しても再読み込みせず、代替ページのままであること
          expect(await harness.readBodyText(), contains(_offlineHeading));
          expect(upstream.getCount, equals(0));
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'shows the gateway timeout page as html with a retry button',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await proxy.start(
            config: ProxyConfig(origin: upstream.origin),
          );
          final harness = await pumpWebView(tester);

          // 遮断前の転送失敗には 504 ページが返る
          await upstream.stop();
          await harness.loadAndWait(
            Uri.parse('http://127.0.0.1:$port$_pagePathPrefix'),
          );

          // HTML として表示され、再試行ボタンを持つこと
          await harness.waitForText(
            _gatewayTimeoutHeading,
            timeout: const Duration(seconds: 30),
          );
          expect(
            await harness
                .evaluate('document.querySelector("button").innerText'),
            contains('再試行'),
          );
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    /// 504 を返させつつ遮断はさせない設定で proxy を起動する。
    ///
    /// [proxy] は起動する proxy です。[upstream] は上流サーバです。
    /// [requestTimeout] は要求の締め切りです。
    /// [enableAutoReloadContinuation] は継続復帰の有効・無効です。
    ///
    /// Returns: 起動した proxy のポート番号。
    Future<int> startForContinuation(
      OfflineWebProxy proxy,
      _ControllableUpstream upstream, {
      Duration requestTimeout = const Duration(seconds: 2),
      bool enableAutoReloadContinuation = true,
    }) {
      return proxy.start(
        config: ProxyConfig(
          origin: upstream.origin,
          requestTimeout: requestTimeout,
          // 遮断に 5 回の失敗を要するため、自動再読込の 504 では遮断しない
          upstreamFailureThreshold: 5,
          upstreamProbeBackoffSeconds: const [1],
          autoReloadPollInterval: const Duration(milliseconds: 500),
          autoReloadQueueWaitTimeout: const Duration(seconds: 1),
          enableAutoReloadContinuation: enableAutoReloadContinuation,
        ),
      );
    }

    testWidgets(
      'continues from a gateway timeout page reached by an automatic reload',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await startForContinuation(proxy, upstream);
          final harness = await pumpWebView(tester);

          await openCircuit(upstream, port, failures: 5);
          await showOfflinePage(harness, port);

          // 復帰確認は通るが、ページの取得は締め切りを超える状態で戻す
          upstream.getDelay = _slowResponse;
          await upstream.restart();

          // 自動再読込の結果として 504 ページが表示されること
          await harness.waitForText(
            _gatewayTimeoutHeading,
            timeout: const Duration(seconds: 60),
          );

          // 上流が応答するようになると、継続復帰で本来の画面へ戻ること
          upstream.getDelay = null;
          await harness.waitForText(
            _upstreamMarker,
            timeout: const Duration(seconds: 60),
          );
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    testWidgets(
      'continues even when the response takes longer than the marker window',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          // 応答待ちを目印の判定時間（10 秒）より長くし、判定が遷移を始めた時刻
          // （performance.timeOrigin）に基づくことを確かめる
          final port = await startForContinuation(
            proxy,
            upstream,
            requestTimeout: const Duration(seconds: 13),
          );
          final harness = await pumpWebView(tester);

          await openCircuit(upstream, port, failures: 5);
          await showOfflinePage(harness, port);

          upstream.getDelay = const Duration(seconds: 16);
          await upstream.restart();

          await harness.waitForText(
            _gatewayTimeoutHeading,
            timeout: const Duration(seconds: 90),
          );

          upstream.getDelay = null;
          await harness.waitForText(
            _upstreamMarker,
            timeout: const Duration(seconds: 90),
          );
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'stops after three automatic reloads and does not count a manual retry',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await startForContinuation(proxy, upstream);
          final harness = await pumpWebView(tester);

          await openCircuit(upstream, port, failures: 5);
          await showOfflinePage(harness, port);

          upstream.getDelay = _slowResponse;
          await upstream.restart();

          // 自動再読込が 3 回続いたら止まること
          await _waitUntil(
            () => upstream.getCount >= 3,
            timeout: const Duration(seconds: 120),
            message: '自動再読込が 3 回行われませんでした',
          );
          await Future<void>.delayed(const Duration(seconds: 25));
          expect(upstream.getCount, equals(3));
          expect(
            await harness.readBodyText(),
            contains(_gatewayTimeoutHeading),
          );

          // 再試行ボタンによる再読み込みは自動再読込として数えず、続けて再読込しないこと
          await harness.runScript('document.querySelector("button").click()');
          await _waitUntil(
            () => upstream.getCount >= 4,
            timeout: const Duration(seconds: 30),
            message: '再試行ボタンで再読み込みされませんでした',
          );
          await Future<void>.delayed(const Duration(seconds: 25));
          expect(upstream.getCount, equals(4));
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'does not continue when continuation is disabled',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await startForContinuation(
            proxy,
            upstream,
            enableAutoReloadContinuation: false,
          );
          final harness = await pumpWebView(tester);

          await openCircuit(upstream, port, failures: 5);
          await showOfflinePage(harness, port);

          upstream.getDelay = _slowResponse;
          await upstream.restart();
          await harness.waitForText(
            _gatewayTimeoutHeading,
            timeout: const Duration(seconds: 60),
          );

          // 504 ページのまま、再読込しないこと
          final countAfterGatewayTimeout = upstream.getCount;
          await Future<void>.delayed(const Duration(seconds: 25));
          expect(upstream.getCount, equals(countAfterGatewayTimeout));
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    testWidgets(
      'reloads the gateway timeout page after the upstream turns unreachable',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: upstream.origin,
              requestTimeout: const Duration(seconds: 2),
              // 1 回の失敗で遮断し、到達不能への変化を作る
              upstreamFailureThreshold: 1,
              // 遮断をページが確実に観測できるよう、復帰確認を遅らせる
              upstreamProbeBackoffSeconds: const [5],
              autoReloadPollInterval: const Duration(milliseconds: 500),
              autoReloadQueueWaitTimeout: const Duration(seconds: 1),
              enableGatewayTimeoutAutoReload: true,
            ),
          );
          final harness = await pumpWebView(tester);

          upstream.getDelay = _slowResponse;
          await harness.loadAndWait(
            Uri.parse('http://127.0.0.1:$port$_pagePathPrefix'),
          );
          await harness.waitForText(
            _gatewayTimeoutHeading,
            timeout: const Duration(seconds: 30),
          );

          // 復帰確認で遮断が解けると、504 ページが自分で再読み込みすること
          upstream.getDelay = null;
          await harness.waitForText(
            _upstreamMarker,
            timeout: const Duration(seconds: 90),
          );
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'reloads after the queue wait timeout when the queue stays non-empty',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: upstream.origin,
              upstreamFailureThreshold: 1,
              upstreamProbeBackoffSeconds: const [1],
              autoReloadPollInterval: const Duration(milliseconds: 500),
              autoReloadQueueWaitTimeout: const Duration(seconds: 2),
            ),
          );
          final harness = await pumpWebView(tester);

          await openCircuit(upstream, port, failures: 1);
          await showOfflinePage(harness, port);

          // 遮断中の更新系をキューへ入れ、再送が 5xx で残り続ける状態で戻す
          final queuedStatus = await _requestThroughProxy(
            Uri.parse('http://127.0.0.1:$port/api/sales.json'),
            method: 'POST',
          );
          expect(queuedStatus, equals(HttpStatus.accepted));
          upstream.updateStatusCode = HttpStatus.internalServerError;
          await upstream.restart();

          // キューが空にならなくても、上限時間を過ぎれば再読み込みすること
          await harness.waitForText(
            _upstreamMarker,
            timeout: const Duration(seconds: 60),
          );
          expect((await _readStatus(port))['queueLength'], equals(1));
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'does not reload when the status cannot be read while waiting',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: upstream.origin,
              upstreamFailureThreshold: 1,
              upstreamProbeBackoffSeconds: const [1],
              autoReloadPollInterval: const Duration(milliseconds: 500),
              autoReloadQueueWaitTimeout: const Duration(seconds: 60),
            ),
          );
          final harness = await pumpWebView(tester);

          await openCircuit(upstream, port, failures: 1);
          await showOfflinePage(harness, port);

          await _requestThroughProxy(
            Uri.parse('http://127.0.0.1:$port/api/sales.json'),
            method: 'POST',
          );
          upstream.updateStatusCode = HttpStatus.internalServerError;
          await upstream.restart();

          // 到達可能になり、ページが再送待ちに入るまで待つ
          await _waitUntil(
            () async =>
                (await _readStatus(port))['isUpstreamReachable'] == true,
            timeout: const Duration(seconds: 30),
            message: '上流が到達可能と判定されませんでした',
          );
          await Future<void>.delayed(const Duration(seconds: 3));

          // 再送待ちの途中で状態を取得できなくなっても、再読み込みしないこと
          await proxy.stop();
          await Future<void>.delayed(const Duration(seconds: 5));
          expect(await harness.readBodyText(), contains(_offlineHeading));
          expect(upstream.getCount, equals(0));
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'recovers a fallback page whose url contains brackets and a tilde',
      (tester) async {
        final upstream = await _ControllableUpstream.start();
        final proxy = OfflineWebProxy();

        try {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: upstream.origin,
              upstreamFailureThreshold: 1,
              upstreamProbeBackoffSeconds: const [1],
              autoReloadPollInterval: const Duration(milliseconds: 500),
              autoReloadQueueWaitTimeout: const Duration(seconds: 1),
            ),
          );
          final harness = await pumpWebView(tester);

          await openCircuit(upstream, port, failures: 1);
          await showOfflinePage(harness, port);

          // ブラウザが送る URL のまま遷移させる（Uri は [] や ~ を正規化するため）
          await harness.runScript(
            "location.href = '$_pagePathPrefix/~user?q[name]=1&page[number]=2'",
          );

          // 遷移が起きて、[] と ~ を含む URL で代替ページが表示されていること
          await harness.waitForLocation(
            ['~user', 'q[name]=1'],
            timeout: const Duration(seconds: 30),
          );
          await harness.waitForText(
            _offlineHeading,
            timeout: const Duration(seconds: 30),
          );

          await upstream.restart();
          await harness.waitForText(
            _upstreamMarker,
            timeout: const Duration(seconds: 60),
          );
          // 復帰した画面も同じ URL であること
          expect(await harness.readLocation(), contains('~user'));
        } finally {
          await proxy.stop();
          await upstream.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
