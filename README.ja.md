# offline_web_proxy

[![CI/CDパイプライン](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml)
[![Pubバージョン](https://img.shields.io/pub/v/offline_web_proxy.svg)](https://pub.dev/packages/offline_web_proxy)
[![ライセンス](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![カバレッジ](https://codecov.io/gh/meibinlab/offline_web_proxy/branch/main/graph/badge.svg)](https://codecov.io/gh/meibinlab/offline_web_proxy)

Flutter WebView内で動作するオフライン対応ローカルプロキシサーバ。既存のWebシステムをアプリ化する際に、オンライン／オフラインを意識せずに動作させることを目的とします。

## 特徴

### 主要機能
- WebViewからのHTTPリクエストをローカルプロキシサーバで中継
- オンライン時は上流サーバへ転送、オフライン時はキャッシュからレスポンス
- 更新系リクエスト（POST/PUT/DELETE）のオフライン時キューイング
- オンライン復帰時の自動送信によるシームレスなオフライン対応
- 静的リソースのローカル配信機能

### オフライン対応
- RFC準拠のキャッシュ制御とオフライン対応の両立
- Cache-Control、Expiresヘッダに基づくインテリジェントなキャッシュ管理
- オフライン時のno-cache無視とstaleキャッシュ利用
- べき等性保証による重複実行防止

### キューイングシステム
- FIFO（先入先出）によるリクエスト順序保証
- 指数バックオフによる自動再試行
- 永続化による再起動後の継続処理

### Cookie管理
- RFC準拠のCookie評価・管理
- AES-256による暗号化永続化
- メモリキャッシュによる高速アクセス

## インストール

`pubspec.yaml`に以下を追加してください：

```yaml
dependencies:
  offline_web_proxy: ^0.2.0
  # WebViewを使用する場合は以下も追加
  # webview_flutter: ^4.4.2
```

## 使用方法

### 基本セットアップ

```dart
import 'package:offline_web_proxy/offline_web_proxy.dart';
// 注意: WebViewを使用する場合は以下の依存関係を追加してください
// import 'package:webview_flutter/webview_flutter.dart';

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late OfflineWebProxy proxy;
  int? proxyPort;
  
  @override
  void initState() {
    super.initState();
    _startProxy();
  }
  
  Future<void> _startProxy() async {
    proxy = OfflineWebProxy();
    
    // 設定オブジェクト（オプション）
    final config = ProxyConfig(
      origin: 'https://api.example.com', // 上流サーバのURL
      cacheMaxSize: 200 * 1024 * 1024,   // キャッシュ最大容量（200MB）
    );
    
    // プロキシサーバ開始
    proxyPort = await proxy.start(config: config);
    print('プロキシサーバが起動しました：http://127.0.0.1:$proxyPort');
    
    setState(() {});
  }
  
  @override
  void dispose() {
    proxy.stop();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    if (proxyPort == null) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    
    return Scaffold(
      appBar: AppBar(title: Text('オフライン対応WebView')),
      body: WebView(
        initialUrl: 'http://127.0.0.1:$proxyPort/app',
        javascriptMode: JavascriptMode.unrestricted,
      ), // 注意: webview_flutter依存関係が必要です
    );
  }
}
```

### 設定ファイルによる詳細設定

`assets/config/config.yaml` を作成して詳細設定が可能です：

```yaml
proxy:
  server:
    origin: "https://api.example.com"
    
  cache:
    maxSizeBytes: 209715200 # 200MB
    ttl:
      "text/html": 3600      # HTML: 1時間
      "text/css": 86400      # CSS: 24時間
      "image/*": 604800      # 画像: 7日間
      "default": 86400       # その他: 24時間
    
    # 起動時キャッシュ更新
    startup:
      enabled: true
      paths:
        - "/config"
        - "/user/profile"
        - "/assets/app.css"
      
  queue:
    drainIntervalSeconds: 3  # キュー処理間隔
    retryBackoffSeconds: [1, 2, 5, 10, 20, 30] # 再試行間隔
    
  timeouts:
    connect: 10   # 接続タイムアウト
    request: 60   # リクエストタイムアウト
```

### 静的リソースの配信

アプリの `assets/static/` フォルダにファイルを配置することで、ローカル配信が可能：

```
assets/
├── static/
│   ├── app.css      # http://127.0.0.1:port/app.css で配信
│   ├── app.js       # http://127.0.0.1:port/app.js で配信
│   └── images/
│       └── logo.png # http://127.0.0.1:port/images/logo.png で配信
└── config/
    └── config.yaml
```

### キャッシュ管理

```dart
// 全キャッシュクリア
await proxy.clearCache();

// 期限切れキャッシュのみクリア
await proxy.clearExpiredCache();

// 特定URLのキャッシュクリア
await proxy.clearCacheForUrl('https://api.example.com/data');

// キャッシュ統計取得
final stats = await proxy.getCacheStats();
print('キャッシュヒット率: ${stats.hitRate}%');

// キャッシュ一覧取得
final cacheList = await proxy.getCacheList();
for (final entry in cacheList) {
  print('URL: ${entry.url}, ステータス: ${entry.status}');
}

// キャッシュの事前更新
final result = await proxy.warmupCache(
  paths: ['/config', '/user/profile'],
  onProgress: (completed, total) {
    print('進捗: $completed/$total');
  },
);
```

### Cookie管理

```dart
// Cookie一覧取得（値はマスクされます）
final cookies = await proxy.getCookies();
for (final cookie in cookies) {
  print('${cookie.name}: ${cookie.value} (${cookie.domain})');
}

// 全Cookieクリア
await proxy.clearCookies();

// 特定ドメインのCookieクリア
await proxy.clearCookies(domain: 'example.com');
```

### キュー管理

```dart
// キューに保存されたリクエスト確認
final queued = await proxy.getQueuedRequests();
print('キューイング中: ${queued.length}件');

// ドロップされたリクエスト履歴
final dropped = await proxy.getDroppedRequests();
for (final request in dropped) {
  print('${request.url}: ${request.dropReason}');
}

// ドロップ履歴クリア
await proxy.clearDroppedRequests();
```

### リアルタイム監視

```dart
// プロキシイベントの監視
proxy.events.listen((event) {
  switch (event.type) {
    case ProxyEventType.cacheHit:
      print('キャッシュヒット: ${event.url}');
      break;
    case ProxyEventType.requestQueued:
      print('キューに追加: ${event.url}');
      break;
    case ProxyEventType.queueDrained:
      print('キュー送信完了: ${event.url}');
      break;
  }
});

// 統計情報取得
final stats = await proxy.getStats();
print('総リクエスト数: ${stats.totalRequests}');
print('キャッシュヒット率: ${stats.cacheHitRate}%');
print('アップタイム: ${stats.uptime}');
```

## アーキテクチャ

### 通信フロー

```
WebView → http://127.0.0.1:<port> → OfflineWebProxy
                                           ↓
                                    [オンライン判定]
                                           ↓
                              ┌──────────────────────┐
                              │                      │
                        [オンライン]              [オフライン]
                              │                      │
                              ↓                      ↓
                      ┌─────────────┐        ┌─────────────┐
                      │上流サーバへ │        │キャッシュ   │
                      │プロキシ転送 │        │から配信     │
                      └─────────────┘        └─────────────┘
                              │                      │
                              ↓                      ↓
                      ┌─────────────┐        ┌─────────────┐
                      │レスポンスを │        │POST/PUT/    │
                      │キャッシュ保存│        │DELETEは     │
                      └─────────────┘        │キューに保存 │
                                             └─────────────┘
```

### キャッシュ戦略

1. **Fresh（新鮮）**: TTL期限内 → そのまま使用
2. **Stale（期限切れ）**: TTL期限切れだがStale期間内
   - オンライン時：条件付きリクエストで検証
   - オフライン時：Staleキャッシュを使用
3. **Expired（完全期限切れ）**: Stale期間も超過 → 削除対象

### セキュリティ

- **ローカルバインド**: 127.0.0.1のみにバインドし外部アクセスを防止
- **Cookie暗号化**: AES-256による暗号化でCookieを永続化
- **パストラバーサル防止**: `assets/static/`配下への制限を徹底
- **ログマスキング**: Authorization、Cookie等の機密情報をマスク

## プラットフォーム対応

### iOS設定

`ios/Runner/Info.plist`にATS例外を追加：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

### Android設定

`android/app/src/main/res/xml/network_security_config.xml`を作成：

```xml
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
```

`android/app/src/main/AndroidManifest.xml`に追加：

```xml
<application
    android:networkSecurityConfig="@xml/network_security_config">
```

## ライセンス

MIT License

## 依存関係

このプラグインは以下のパッケージを使用しています：

- [shelf](https://pub.dev/packages/shelf) - HTTP サーバフレームワーク
- [shelf_proxy](https://pub.dev/packages/shelf_proxy) - プロキシ機能
- [shelf_router](https://pub.dev/packages/shelf_router) - ルーティング
- [connectivity_plus](https://pub.dev/packages/connectivity_plus) - ネットワーク状態監視
- [hive](https://pub.dev/packages/hive) - データベース（SQLite代替）
- [path_provider](https://pub.dev/packages/path_provider) - ファイルパス取得

## サポート

バグ報告や機能要求は [GitHub Issues](https://github.com/meibinlab/offline_web_proxy/issues) までお願いします。

## 開発者向け

### デバッグ機能

開発時に利用可能なデバッグ機能：

```yaml
debug:
  enableAdminApi: true        # 管理API有効化
  cacheInspection: true       # キャッシュ内容確認
  detailedHeaders: true       # 詳細ヘッダ情報
```

**注意**: 本番環境では必ず`false`に設定してください。

### ログレベル

```yaml
logging:
  level: "debug"                    # debug/info/warn/error
  maskSensitiveHeaders: true        # 機密情報マスク
```

### パフォーマンス監視

```dart
// 統計情報の定期取得
Timer.periodic(Duration(minutes: 5), (timer) async {
  final stats = await proxy.getStats();
  print('キャッシュヒット率: ${stats.cacheHitRate}%');
  print('キュー長: ${stats.queueLength}');
});
```
