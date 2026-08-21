import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 上流サーバが返すページ本文の目印。
const String _upstreamMarker = 'hello-from-upstream';

/// WebView の読み込み完了とリソースエラーを受け取るための操作をまとめたクラス。
class _WebViewHarness {
  _WebViewHarness(this.controller);

  /// テスト対象の WebView コントローラ。
  final WebViewController controller;

  /// 読み込み完了の通知先。読み込みごとに作り直す。
  Completer<void>? _pageFinished;

  /// メインフレームのリソースエラーの通知先。読み込みごとに作り直す。
  Completer<WebResourceError>? _mainFrameError;

  /// delegate を設定する。読み込み完了とエラーを完了させる。
  void installDelegate() {
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) {
          final pageFinished = _pageFinished;
          if (pageFinished != null && !pageFinished.isCompleted) {
            pageFinished.complete();
          }
        },
        onWebResourceError: (WebResourceError error) {
          if (!(error.isForMainFrame ?? true)) {
            return;
          }
          final mainFrameError = _mainFrameError;
          if (mainFrameError != null && !mainFrameError.isCompleted) {
            mainFrameError.complete(error);
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

  /// URL を読み込み、メインフレームのリソースエラーを受け取るまで待つ。
  ///
  /// [uri] は読み込む URL です。
  ///
  /// Returns: WebView が報告したリソースエラー。
  Future<WebResourceError> loadAndWaitForError(Uri uri) async {
    final mainFrameError = Completer<WebResourceError>();
    _mainFrameError = mainFrameError;
    _pageFinished = Completer<void>();
    await controller.loadRequest(uri);
    return mainFrameError.future.timeout(const Duration(seconds: 30));
  }

  /// 表示中ページの目印テキストを取得する。
  ///
  /// Returns: `#msg` 要素のテキスト。
  Future<String> readMarker() async {
    final value = await controller
        .runJavaScriptReturningResult(
          'document.getElementById("msg").innerText',
        )
        .timeout(const Duration(seconds: 10));
    return value.toString();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('offline_web_proxy 接続復旧 (emulator/device) e2e', () {
    /// `/page` を返す上流サーバを起動する。
    ///
    /// Returns: 起動した上流サーバ。
    Future<HttpServer> startUpstream() async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(() async {
        await for (final HttpRequest request in upstream) {
          try {
            if (request.method == 'GET' && request.uri.path == '/page') {
              request.response
                ..statusCode = HttpStatus.ok
                ..headers.contentType =
                    ContentType('text', 'html', charset: 'utf-8')
                ..headers.set('cache-control', 'no-store')
                ..write('''
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>recovery</title></head>
  <body><div id="msg">$_upstreamMarker</div></body>
</html>
''');
              await request.response.close();
              continue;
            }

            request.response
              ..statusCode = HttpStatus.notFound
              ..write('not found');
            await request.response.close();
          } catch (_) {
            try {
              request.response.statusCode = HttpStatus.internalServerError;
              await request.response.close();
            } catch (_) {
              // ignore
            }
          }
        }
      }());
      return upstream;
    }

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

    /// 空きポート番号を 1 つ取得する。
    ///
    /// Returns: 使用されていないポート番号。
    Future<int> findFreePort() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);
      return port;
    }

    /// アプリのライフサイクル状態変化を発生させる。
    ///
    /// [tester] はウィジェットテスターです。
    /// [state] は通知するライフサイクル状態です。
    ///
    /// Returns: 通知完了を表す Future。
    Future<void> sendLifecycleState(
      WidgetTester tester,
      AppLifecycleState state,
    ) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/lifecycle',
        const StringCodec().encodeMessage(state.toString()),
        (_) {},
      );
    }

    testWidgets(
      'recovers a dead proxy socket from a WebView error and shows the page again',
      (tester) async {
        final upstream = await startUpstream();
        final proxy = OfflineWebProxy();

        try {
          final proxyPort = await proxy.start(
            config: ProxyConfig(origin: 'http://127.0.0.1:${upstream.port}'),
          );
          final pageUri = Uri.parse('http://127.0.0.1:$proxyPort/page');

          final harness = await pumpWebView(tester);
          await harness.loadAndWait(pageUri);

          // 復旧前に proxy 経由で表示できていること
          expect(await harness.readMarker(), contains(_upstreamMarker));

          // 「アプリから proxy への接続が切断される」状態を再現する
          await proxy.closeServerSocketForTesting();

          final error = await harness.loadAndWaitForError(pageUri);

          // 端末標準のエラー画面に頼らず復旧 API へつなぐ
          // 端末によって失敗 URL が省略されるため、アプリが保持する URL を代替に使う
          final result = await proxy.recoverFromWebResourceError(
            errorCode: error.errorCode,
            failingUrl: error.url ?? pageUri.toString(),
            isMainFrame: error.isForMainFrame ?? true,
          );

          // 応答が無いことを検知して再バインドすること
          expect(result.cause, equals(ProxyRecoveryCause.socketDead));
          expect(result.restarted, isTrue);
          // 直前のポートを維持して再バインドすること
          expect(result.portChanged, isFalse);
          expect(result.port, equals(proxyPort));
          // 再読込先が示されること
          expect(result.reloadUri, isNotNull);

          await harness.loadAndWait(result.reloadUri!);

          // 復旧後に同じページを再表示できること
          expect(await harness.readMarker(), contains(_upstreamMarker));
        } finally {
          await proxy.stop();
          await upstream.close(force: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'rewrites a stale port URL and loads it on the current port',
      (tester) async {
        final upstream = await startUpstream();
        final proxy = OfflineWebProxy();

        try {
          final proxyPort = await proxy.start(
            config: ProxyConfig(origin: 'http://127.0.0.1:${upstream.port}'),
          );
          final harness = await pumpWebView(tester);
          await harness.loadAndWait(
            Uri.parse('http://127.0.0.1:$proxyPort/page'),
          );

          // アプリ再起動でポートが変わった直後の URL を再現する
          final stalePort = await findFreePort();
          final staleUri = Uri.parse('http://127.0.0.1:$stalePort/page');

          final error = await harness.loadAndWaitForError(staleUri);

          final result = await proxy.recoverFromWebResourceError(
            errorCode: error.errorCode,
            failingUrl: error.url ?? staleUri.toString(),
          );

          // ポート不一致として扱い、再バインドは行わないこと
          expect(result.cause, equals(ProxyRecoveryCause.stalePort));
          expect(result.restarted, isFalse);
          // 現行ポートへ読み替えた URL を返すこと
          expect(result.reloadUri?.port, equals(proxyPort));
          expect(result.reloadUri?.path, equals('/page'));

          await harness.loadAndWait(result.reloadUri!);

          // 読み替え後の URL で表示できること
          expect(await harness.readMarker(), contains(_upstreamMarker));
        } finally {
          await proxy.stop();
          await upstream.close(force: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'recovers on app resume through ProxyLifecycleGuard',
      (tester) async {
        final upstream = await startUpstream();
        final proxy = OfflineWebProxy();
        ProxyLifecycleGuard? guard;

        try {
          final proxyPort = await proxy.start(
            config: ProxyConfig(origin: 'http://127.0.0.1:${upstream.port}'),
          );
          final pageUri = Uri.parse('http://127.0.0.1:$proxyPort/page');

          final harness = await pumpWebView(tester);
          await harness.loadAndWait(pageUri);

          final recovered = Completer<ProxyRecoveryResult>();
          guard = ProxyLifecycleGuard(
            proxy: proxy,
            probeTimeout: const Duration(seconds: 1),
            currentUrlProvider: () => pageUri.toString(),
            onRecovered: (ProxyRecoveryResult result) {
              if (!recovered.isCompleted) {
                recovered.complete(result);
              }
            },
          );
          tester.binding.addObserver(guard);

          // バックグラウンド中にソケットが無効化された状態を再現する
          await sendLifecycleState(tester, AppLifecycleState.paused);
          await proxy.closeServerSocketForTesting();
          await sendLifecycleState(tester, AppLifecycleState.resumed);

          final result =
              await recovered.future.timeout(const Duration(seconds: 30));

          // 復帰時の稼働確認で再バインドされること
          expect(result.restarted, isTrue);
          // 停止推定時間が記録されること
          expect(result.downtimeMs, isNotNull);
          // 表示中 URL を現行ポートへ読み替えて通知すること
          expect(result.reloadUri?.port, equals(proxy.port));

          await harness.loadAndWait(result.reloadUri!);

          // 自動復旧後に再表示できること
          expect(await harness.readMarker(), contains(_upstreamMarker));
        } finally {
          if (guard != null) {
            tester.binding.removeObserver(guard);
          }
          await proxy.stop();
          await upstream.close(force: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
