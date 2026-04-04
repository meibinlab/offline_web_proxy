# offline_web_proxy

[![CI/CDパイプライン](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml)
[![Pubバージョン](https://img.shields.io/pub/v/offline_web_proxy.svg)](https://pub.dev/packages/offline_web_proxy)
[![ライセンス](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![カバレッジ](https://codecov.io/gh/meibinlab/offline_web_proxy/branch/main/graph/badge.svg)](https://codecov.io/gh/meibinlab/offline_web_proxy)

offline_web_proxy は Flutter WebView 向けのローカル HTTP プロキシです。既存の Web アプリをモバイルアプリ内で扱う際に、接続が不安定でも動作を継続しやすくすることを目的にしています。

127.0.0.1 上で動作し、オンライン時は設定済みの上流 origin へ転送し、オフライン時はキャッシュを返し、更新系リクエストはキューに保持します。加えて、WebView の遷移判定、Cookie 再利用、統計取得、イベント監視の API を提供します。

## 主な機能

- Flutter WebView 向けローカルプロキシサーバ
- RFC を踏まえたキャッシュ制御とオフライン時の stale 利用
- POST、PUT、DELETE のオフラインキューイング
- AES-256 による Cookie 永続化と復元 API
- same-origin、外部委譲、新規 window 判定のための WebView 補助 API
- 統計情報とイベントストリームによる監視

## 動作要件

- Flutter 3.22.0 以降
- Dart 3.4.0 以降
- 1 つの proxy インスタンスにつき 1 つの上流 origin

## インストール

アプリ側の `pubspec.yaml` に追加します。

```yaml
dependencies:
  offline_web_proxy: ^0.6.0
  # example アプリと CI ではこの WebView 系を使用しています。
  webview_flutter: ^4.8.0
```

その後に以下を実行します。

```bash
flutter pub get
```

## クイックスタート

現在の WebView 連携は、`WebViewController`、`WebViewWidget`、および 0.5.0 / 0.6.0 で追加した遷移補助 API を前提にするのが扱いやすいです。

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:webview_flutter/webview_flutter.dart';

class ProxyPage extends StatefulWidget {
  const ProxyPage({super.key});

  @override
  State<ProxyPage> createState() => _ProxyPageState();
}

class _ProxyPageState extends State<ProxyPage> {
  final OfflineWebProxy _proxy = OfflineWebProxy();

  WebViewController? _controller;
  String? _currentUrl;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final port = await _proxy.start(
      config: const ProxyConfig(
        origin: 'https://api.example.com',
        startupPaths: ['/app/config', '/app/bootstrap'],
      ),
    );

    final homeUrl = Uri.parse('http://127.0.0.1:$port/app');
    final controller = WebViewController();

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            _currentUrl = url;
          },
          onNavigationRequest: (NavigationRequest request) {
            final recommendation = _proxy.recommendMainFrameNavigation(
              targetUrl: request.url,
              sourceUrl: _currentUrl,
            );

            switch (recommendation.action) {
              case ProxyWebViewNavigationAction.allow:
                return NavigationDecision.navigate;
              case ProxyWebViewNavigationAction.loadProxyUrl:
                unawaited(controller.loadRequest(recommendation.webViewUri!));
                return NavigationDecision.prevent;
              case ProxyWebViewNavigationAction.launchExternal:
                // recommendation.externalUri を url_launcher などへ渡します。
                return NavigationDecision.prevent;
              case ProxyWebViewNavigationAction.cancel:
                return NavigationDecision.prevent;
            }
          },
        ),
      );

    await controller.loadRequest(homeUrl);

    if (!mounted) {
      return;
    }

    setState(() {
      _controller = controller;
      _currentUrl = homeUrl.toString();
    });
  }

  @override
  void dispose() {
    unawaited(_proxy.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('offline_web_proxy demo')),
      body: WebViewWidget(controller: controller),
    );
  }
}
```

## ProxyConfig による設定

設定は `start()` に渡す `ProxyConfig` で行います。

```dart
const config = ProxyConfig(
  origin: 'https://api.example.com',
  host: '127.0.0.1',
  port: 0,
  cacheMaxSize: 200 * 1024 * 1024,
  cacheTtl: {
    'text/html': 3600,
    'text/css': 86400,
    'application/javascript': 86400,
    'image/*': 604800,
    'default': 86400,
  },
  cacheStale: {
    'text/html': 86400,
    'text/css': 604800,
    'image/*': 2592000,
    'default': 259200,
  },
  connectTimeout: Duration(seconds: 10),
  requestTimeout: Duration(seconds: 60),
  retryBackoffSeconds: [1, 2, 5, 10, 20, 30],
  enableAdminApi: false,
  logLevel: 'info',
  startupPaths: ['/app/config'],
);
```

補足:

- `origin` は必須で、絶対 HTTP URL または HTTPS URL である必要があります。
- `port: 0` を指定すると、OS が空きポートを自動割り当てします。
- `startupPaths` は `warmupCache()` と起動時の事前キャッシュ対象に使われます。
- 現在サポートされる設定入口は `ProxyConfig` です。外部 YAML の自動読込は実装されていません。

## WebView 遷移補助 API

WebView 側で「proxy 内に残すか」「proxy URL に戻すか」「外部へ委譲するか」を判断したい場合は URL 解決 API を使います。

```dart
final resolution = proxy.resolveNavigationTarget(
  targetUrl: 'tel:+81012345678',
  sourceUrl: 'http://127.0.0.1:$port/app/orders/detail',
);

if (resolution.disposition == ProxyNavigationDisposition.external) {
  print('外部起動候補: ${resolution.normalizedTargetUri}');
}

final upstreamUri = proxy.tryResolveUpstreamUrl(
  'http://127.0.0.1:$port/app/orders/42',
);

final newWindowRecommendation = proxy.recommendNewWindowNavigation(
  targetUrl: 'https://www.google.com/maps/search/?api=1&query=Tokyo+Station',
  sourceUrl: 'http://127.0.0.1:$port/app',
);
```

主な使い分け:

- `tryResolveUpstreamUrl(String url)` は proxy URL または同一 origin URL を上流 URL に戻したいときに使います。
- `resolveNavigationTarget(...)` は理由、正規化後 URL、proxy/upstream URL を含む詳細判定向けです。
- `recommendMainFrameNavigation(...)` は通常の WebView main frame delegate 向けです。
- `recommendNewWindowNavigation(...)` は target=_blank 相当の新規 window 判定向けです。

相対 URL や scheme-relative URL の解決には `sourceUrl` が必要です。`sourceUrl` が無い場合、意図的に unresolved になるケースがあります。

## Cookie API

Cookie は暗号化して保存され、proxy 起動前に復元することもできます。

```dart
await proxy.restoreCookies([
  CookieRestoreEntry.fromSetCookieHeader(
    setCookieHeader: 'SESSION=abc123; Path=/app; Secure; HttpOnly',
    requestUrl: 'https://api.example.com/login',
  ),
]);

final cookies = await proxy.getCookies();
final cookieHeader =
    await proxy.getCookieHeaderForUrl('https://api.example.com/app/dashboard');

await proxy.clearCookies();
await proxy.clearCookies(domain: 'example.com');
```

補足:

- `getCookies()` の値は確認用にマスクされます。
- `getCookieHeaderForUrl()` は設定済み origin と同一 origin の URL のみ受け付けます。
- secure storage 上の暗号化鍵を失うと、既存 Cookie は復号できず再ログインが必要になります。

## キャッシュ、キュー、監視 API

```dart
await proxy.clearCache();
await proxy.clearExpiredCache();
await proxy.clearCacheForUrl('https://api.example.com/app/dashboard');

final cacheEntries = await proxy.getCacheList(limit: 20);
final cacheStats = await proxy.getCacheStats();
final warmupResult = await proxy.warmupCache(
  paths: ['/app/config', '/app/bootstrap'],
  onProgress: (completed, total) {
    print('warmup: $completed/$total');
  },
);

final queued = await proxy.getQueuedRequests();
final dropped = await proxy.getDroppedRequests(limit: 50);
await proxy.clearDroppedRequests();

final stats = await proxy.getStats();
print('requests=${stats.totalRequests} hitRate=${stats.cacheHitRate}');

proxy.events.listen((event) {
  if (event.type == ProxyEventType.requestReceived) {
    print(event.data['resolvedUpstreamUrl']);
    print(event.data['navigationDisposition']);
  }
});
```

イベントストリームでは、キャッシュヒット、キュー処理、URL 解決メタ情報などを監視できます。`requestReceived` では `resolvedUpstreamUrl`、`resolvedProxyUrl`、`navigationDisposition`、`navigationReason` などを参照できます。

## プラットフォーム設定

### iOS

`ios/Runner/Info.plist` でローカルネットワークを許可します。

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

### Android

ローカル loopback proxy への cleartext 通信を許可します。

`android/app/src/main/res/xml/network_security_config.xml` を作成します。

```xml
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
```

`android/app/src/main/AndroidManifest.xml` から参照します。

```xml
<application
    android:networkSecurityConfig="@xml/network_security_config">
```

## 現在の制約

- 1 つの `OfflineWebProxy` インスタンスが扱える上流 origin は 1 つです。
- サポートされる設定経路は `ProxyConfig` です。外部 YAML の自動読込は未実装です。
- `assets/static/` からの静的リソース実配信は未実装です。静的リソースらしいパスは遷移判定で分類されますが、現在のサーバ応答は 404 プレースホルダです。

## サンプルと参照先

- `example/` に WebView delegate 連携のサンプルがあります。
- API リファレンスはリポジトリ内の `doc/api/` にあります。
- リリースノートは `CHANGELOG.md` にあります。

## 開発者向けセットアップ

このリポジトリには Git ネイティブの pre-commit hook が含まれています。

```bash
git config core.hooksPath .githooks
```

hook では以下を実行します。

- `dart fix --apply`
- `dart format .`
- `dart analyze --fatal-warnings`

Dart ファイルが自動修正または再整形された場合は、内容確認と再 stage のためにコミットを停止します。

## ライセンス

MIT License
