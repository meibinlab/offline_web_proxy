import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// offline_web_proxy の WebView delegate API を体験するサンプルアプリです。
void main() {
  runApp(const ProxyExampleApp());
}

/// offline_web_proxy のデモアプリです。
class ProxyExampleApp extends StatelessWidget {
  /// デモアプリを生成します。
  const ProxyExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'offline_web_proxy demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A6C74),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const ProxyExampleHomePage(),
    );
  }
}

/// WebView delegate API と連携例を表示するホーム画面です。
class ProxyExampleHomePage extends StatefulWidget {
  /// ホーム画面を生成します。
  const ProxyExampleHomePage({super.key});

  @override
  State<ProxyExampleHomePage> createState() => _ProxyExampleHomePageState();
}

class _ProxyExampleHomePageState extends State<ProxyExampleHomePage> {
  final OfflineWebProxy _proxy = OfflineWebProxy();
  final List<String> _eventLogs = <String>[];

  StreamSubscription<ProxyEvent>? _eventSubscription;
  HttpServer? _upstreamServer;
  WebViewController? _controller;

  int? _proxyPort;
  String? _upstreamOrigin;
  String? _homeProxyUrl;
  String? _currentPageUrl;
  String? _statusText;
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeDemo());
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    if (_proxy.isRunning) {
      unawaited(_proxy.stop());
    }
    unawaited(_upstreamServer?.close(force: true));
    super.dispose();
  }

  Future<void> _initializeDemo() async {
    try {
      _upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _upstreamOrigin = 'http://127.0.0.1:${_upstreamServer!.port}';
      _startMockUpstream(_upstreamServer!, _upstreamOrigin!);

      _proxyPort = await _proxy.start(
        config: ProxyConfig(origin: _upstreamOrigin!),
      );
      _homeProxyUrl = 'http://127.0.0.1:$_proxyPort/app';
      _currentPageUrl = _homeProxyUrl;

      _eventSubscription = _proxy.events.listen(_handleProxyEvent);
      _controller = _createController();
      await _controller!.loadRequest(Uri.parse(_homeProxyUrl!));

      if (!mounted) {
        return;
      }
      setState(() {
        _isReady = true;
        _statusText = 'proxy 起動完了: $_homeProxyUrl';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusText = '初期化に失敗しました: $error';
      });
    }
  }

  void _startMockUpstream(HttpServer server, String upstreamOrigin) {
    unawaited(() async {
      await for (final HttpRequest request in server) {
        try {
          final html = _buildHtmlResponse(request.uri.path, upstreamOrigin);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write(html);
          await request.response.close();
        } catch (_) {
          try {
            request.response
              ..statusCode = HttpStatus.internalServerError
              ..write('error');
            await request.response.close();
          } catch (_) {
            // ignore
          }
        }
      }
    }());
  }

  WebViewController _createController() {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigationRequest,
          onPageStarted: (String url) {
            if (!mounted) {
              return;
            }
            setState(() {
              _currentPageUrl = url;
              _statusText = '読込中: $url';
            });
          },
          onPageFinished: (String url) {
            if (!mounted) {
              return;
            }
            setState(() {
              _currentPageUrl = url;
              _statusText = '表示中: $url';
            });
          },
          onWebResourceError: (WebResourceError error) {
            if (!mounted) {
              return;
            }
            setState(() {
              _statusText = 'WebView エラー: ${error.description}';
            });
          },
        ),
      );
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final recommendation = _proxy.recommendMainFrameNavigation(
      targetUrl: request.url,
      sourceUrl: _currentPageUrl,
    );
    final targetUri = recommendation.externalUri ??
        recommendation.webViewUri ??
        recommendation.resolution.normalizedTargetUri;
    _appendLog(
      'nav ${recommendation.action.name} ${recommendation.resolution.reason.name} -> $targetUri',
    );

    switch (recommendation.action) {
      case ProxyWebViewNavigationAction.allow:
        return NavigationDecision.navigate;
      case ProxyWebViewNavigationAction.cancel:
        _showMessage('遷移をキャンセル: ${recommendation.resolution.reason.name}');
        return NavigationDecision.prevent;
      case ProxyWebViewNavigationAction.loadProxyUrl:
        final webViewUri = recommendation.webViewUri;
        if (webViewUri != null) {
          unawaited(_controller?.loadRequest(webViewUri));
        }
        return NavigationDecision.prevent;
      case ProxyWebViewNavigationAction.launchExternal:
        _showMessage('外部委譲候補: ${recommendation.externalUri}');
        return NavigationDecision.prevent;
    }
  }

  void _handleProxyEvent(ProxyEvent event) {
    if (event.type != ProxyEventType.requestReceived) {
      return;
    }

    final resolvedUpstreamUrl = event.data['resolvedUpstreamUrl'] as String?;
    final disposition = event.data['navigationDisposition'];
    final reason = event.data['navigationReason'];
    _appendLog(
      'event requestReceived $disposition/$reason upstream=${resolvedUpstreamUrl ?? '-'}',
    );
  }

  Future<void> _reloadHome() async {
    final homeProxyUrl = _homeProxyUrl;
    final controller = _controller;
    if (homeProxyUrl == null || controller == null) {
      return;
    }

    await controller.loadRequest(Uri.parse(homeProxyUrl));
  }

  void _simulateExternalTarget() {
    final recommendation = _proxy.recommendMainFrameNavigation(
      targetUrl: 'tel:+81012345678',
      sourceUrl: _currentPageUrl,
    );
    _appendLog(
      'simulate external ${recommendation.action.name} ${recommendation.resolution.reason.name} ${recommendation.externalUri ?? recommendation.resolution.normalizedTargetUri}',
    );
    _showMessage('外部委譲候補: ${recommendation.externalUri}');
  }

  void _simulateNewWindowTarget() {
    final recommendation = _proxy.recommendNewWindowNavigation(
      targetUrl:
          'https://www.google.com/maps/search/?api=1&query=Tokyo+Station',
      sourceUrl: _currentPageUrl,
    );
    _appendLog(
      'simulate new-window ${recommendation.action.name} ${recommendation.resolution.reason.name} ${recommendation.externalUri ?? recommendation.webViewUri ?? recommendation.resolution.normalizedTargetUri}',
    );
    _showMessage('target=_blank 相当の推奨: ${recommendation.action.name}');
  }

  void _appendLog(String message) {
    if (!mounted) {
      return;
    }

    setState(() {
      _eventLogs.insert(0, message);
      if (_eventLogs.length > 12) {
        _eventLogs.removeRange(12, _eventLogs.length);
      }
    });
  }

  void _showMessage(String text) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  String _buildHtmlResponse(String path, String upstreamOrigin) {
    final title = switch (path) {
      '/app/orders/detail' => 'Order Detail',
      '/app/absolute' => 'Absolute Same-Origin',
      _ => 'Proxy Demo Home',
    };
    final body = switch (path) {
      '/app/orders/detail' => '''
<p>相対リンクと外部委譲の判定を試せます。</p>
<p><a href="../absolute">same-origin absolute page</a></p>
<p><a href="tel:+81012345678">phone link</a></p>
<p><a href="https://www.google.com/maps/search/?api=1&query=Kyoto" target="_blank">maps target blank</a></p>
''',
      '/app/absolute' => '''
<p>絶対 URL を proxy URL に戻す例です。</p>
<p><a href="$upstreamOrigin/app">back home by absolute upstream url</a></p>
''',
      _ => '''
<p>offline_web_proxy の delegate 推奨アクション API を使った WebView サンプルです。</p>
<ul>
  <li><a href="/app/orders/detail">relative same-origin link</a></li>
  <li><a href="$upstreamOrigin/app/absolute">absolute same-origin link</a></li>
  <li><a href="tel:+81012345678">phone link</a></li>
  <li><a href="https://www.google.com/maps/search/?api=1&query=Tokyo+Station">maps link</a></li>
  <li><a href="https://www.google.com/maps/search/?api=1&query=Osaka+Station" target="_blank">maps target blank</a></li>
</ul>
''',
    };

    return '''
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>$title</title>
    <style>
      body { font-family: sans-serif; margin: 0; padding: 24px; background: #f4f8f8; color: #163133; }
      main { max-width: 720px; margin: 0 auto; background: white; border-radius: 16px; padding: 24px; box-shadow: 0 12px 30px rgba(10, 108, 116, 0.12); }
      a { color: #0a6c74; display: inline-block; margin: 8px 0; }
      code { background: #e8f3f4; padding: 2px 6px; border-radius: 6px; }
    </style>
  </head>
  <body>
    <main>
      <h1>$title</h1>
      <p>現在の upstream origin: <code>$upstreamOrigin</code></p>
      $body
    </main>
  </body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text('offline_web_proxy demo'),
      ),
      body: SafeArea(
        child: !_isReady || controller == null
            ? Center(
                child: Text(_statusText ?? 'proxy を起動しています...'),
              )
            : Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'WebView delegate デモ',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(_statusText ?? ''),
                        const SizedBox(height: 8),
                        Text('current: ${_currentPageUrl ?? '-'}'),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: <Widget>[
                            FilledButton(
                              onPressed: _reloadHome,
                              child: const Text('Home を再読込'),
                            ),
                            OutlinedButton(
                              onPressed: _simulateExternalTarget,
                              child: const Text('電話リンク判定'),
                            ),
                            OutlinedButton(
                              onPressed: _simulateNewWindowTarget,
                              child: const Text('target=_blank 判定'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: WebViewWidget(controller: controller),
                  ),
                  Container(
                    color: const Color(0xFFF0F7F8),
                    height: 220,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Proxy event log',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _eventLogs.length,
                            itemBuilder: (BuildContext context, int index) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  _eventLogs[index],
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(fontFamily: 'monospace'),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
