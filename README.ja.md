# offline_web_proxy

[![CI/CDパイプライン](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml)
[![Pubバージョン](https://img.shields.io/pub/v/offline_web_proxy.svg)](https://pub.dev/packages/offline_web_proxy)
[![ライセンス](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![カバレッジ](https://codecov.io/gh/meibinlab/offline_web_proxy/branch/main/graph/badge.svg)](https://codecov.io/gh/meibinlab/offline_web_proxy)

offline_web_proxy は Flutter WebView 向けのローカル HTTP プロキシです。既存の Web アプリをモバイルアプリ内で扱う際に、接続が不安定な場合や一時的に利用できない場合でも動作を継続しやすくすることを目的にしています。

127.0.0.1 上で動作し、オンライン時は設定済みの上流 origin へ転送します。proxy キャッシュはオフライン時または上流到達不能時（接続失敗・リクエストタイムアウト）の代替応答に限定して利用し、更新系リクエストはキューに保持します。加えて、WebView の遷移判定、Cookie 再利用、統計取得、イベント監視の API を提供します。

## 主な機能

- Flutter WebView 向けローカルプロキシサーバ
- オフライン時と上流到達不能時（接続失敗・リクエストタイムアウト）に限定したフォールバックキャッシュ
- POST、PUT、DELETE のオフラインキューイング
- AES-256 による Cookie 永続化と復元 API
- same-origin、外部委譲、新規 window 判定のための WebView 補助 API
- サスペンド復帰時の稼働確認と自動再バインドによる接続復旧
- 統計情報とイベントストリームによる監視とデバッグ

## 動作要件

- Flutter 3.22.0 以降
- Dart 3.4.0 以降
- 1 つの proxy インスタンスにつき 1 つの上流 origin

## インストール

アプリ側の `pubspec.yaml` に追加します。

```yaml
dependencies:
  offline_web_proxy: ^0.8.0
  # example アプリと CI ではこの WebView 系を使用しています。
  webview_flutter: ^4.8.0
```

その後に以下を実行します。

```bash
flutter pub get
```

proxy に同梱静的ファイルを認識させたい場合は、アプリ側の `pubspec.yaml` にアセットを宣言し、`AssetManifest.json` に載る状態にしてください。ファイルを置いただけで Flutter アセットとして登録していないものは、proxy ローカル静的リソースとして分類されません。

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
  connectTimeout: Duration(seconds: 5),
  requestTimeout: Duration(seconds: 20),
  upstreamFailureThreshold: 3,
  upstreamProbePath: '/',
  upstreamProbeMethod: 'HEAD',
  upstreamProbeTimeout: Duration(seconds: 3),
  upstreamProbeBackoffSeconds: [1, 2, 5, 10, 30],
  queuedResponse: ProxyResponseConfig(
    statusCode: 202,
    contentType: 'application/json; charset=utf-8',
    body: '{"queued":true}',
  ),
  offlineMissResponse: ProxyResponseConfig(
    statusCode: 504,
    contentType: 'application/json; charset=utf-8',
    body: '{"offline":true}',
  ),
  retryBackoffSeconds: [1, 2, 5, 10, 20, 30],
  enableAdminApi: false,
  logLevel: 'info',
  startupPaths: ['/app/config'],
  preferredPort: 8787,
  healthCheckPath: '/__offline_web_proxy/health',
  healthCheckInterval: Duration.zero,
  serverIdleTimeout: Duration(seconds: 120),
  maxRestartAttemptsPerMinute: 5,
);
```

補足:

- `origin` は必須で、絶対 HTTP URL または HTTPS URL である必要があります。
- `port: 0` を指定すると、OS が空きポートを自動割り当てします。
- `preferredPort` を指定すると、まずそのポートを試し、使えない場合は自動割り当てへフォールバックします。直前に成功したポートも次回起動時に再利用されるため、WebView の origin をより安定させやすくなります。
- `startupPaths` は `warmupCache()` で、オフライン時または上流到達不能時の代替応答を事前準備したいパスに使います。
- `healthCheckPath` は稼働確認専用のパスです。この URL は上流へ転送されず、統計にも計上されません。Web アプリのルートと衝突する場合に変更します。
- `healthCheckInterval` に 0 より大きい値を指定すると定期的に稼働確認を行います。既定は無効で、復帰時の確認（`ProxyLifecycleGuard`）を主経路とします。
- `offlineFallbackHtml` と `gatewayTimeoutHtml` を指定すると、オフライン応答とタイムアウト応答の HTML をアプリ側の文言へ差し替えられます。
- `upstreamFailureThreshold` は、上流へ到達できない状態が連続した場合に転送を止めるまでの回数です。リンク層は接続済みでも上流が落ちている環境で、リクエストが毎回タイムアウトまで待たされるのを防ぎます。0 を指定すると無効になります。
- `upstreamProbePath`、`upstreamProbeMethod`、`upstreamProbeTimeout`、`upstreamProbeBackoffSeconds` は、転送を止めている間の復帰確認に使います。応答が返れば到達可能と判定するため、ステータスコードは問いません。
- `queuedResponse` と `offlineMissResponse` は、proxy が自分で生成する応答の内容です。既定はどちらも JSON で、Web アプリ側の `response.json()` が成功します。

### Web アプリ側でのオフライン応答の扱い

オフライン時の更新系リクエストは上流へ届いていないため、成功と区別できる必要があります。proxy は既定で `202 Accepted` と `{"queued":true}` を返し、あわせて判別用のヘッダを付与します。

```js
const res = await fetch('/api/sales_histories.json', {
  method: 'POST',
  body: JSON.stringify(sale),
});

if (res.headers.get('X-Offline-Queued') === '1') {
  // 上流には未送信。オンライン復帰時に proxy が再送する
  showPendingBadge(res.headers.get('X-Offline-Queue-Id'));
  return;
}

const saved = await res.json();
```

キャッシュが無い状態のオフライン read には、既定で `504` と `{"offline":true}` を返します。`response.ok` が false になるため、通常のエラー処理で扱えます。ページ遷移（`Sec-Fetch-Mode: navigate`）だけは、人が読める HTML のフォールバックページを返します。
- 現在サポートされる設定入口は `ProxyConfig` です。外部 YAML の自動読込は実装されていません。

### WebView 用途の待ち時間

既定値（`connectTimeout` 5 秒、`requestTimeout` 20 秒）は WebView の前段に置く用途に合わせています。人が画面の前で待つため、上流が応答しない場合の待ち時間を短くしています。ブラウザエンジンは 1 つの origin に対して同時接続数を数本に制限するため、数本のリクエストが滞留すると画面全体が反応しなくなります。

`requestTimeout` は 1 リクエスト全体の締め切りです。空き接続の待ち、接続確立、ヘッダ受信、本文受信をこの 1 つの予算で管理するため、段階ごとに待ち時間が積み上がることはありません。

リンク層が接続済みでも上流へ到達できるとは限りません。ネットワークには接続しているが上流が停止している環境では、上流到達性のサーキットブレーカが遮断するまでの数回は `requestTimeout` の時間だけ待ちます。遮断後は待たずにキャッシュやキューへ切り替わります。最悪の待ち時間は `requestTimeout` × `upstreamFailureThreshold` になるため、この 2 つの値は合わせて調整してください。

WebView 側の接続が滞留しないよう、`serverIdleTimeout`（既定 120 秒）は 30〜60 秒程度への短縮も検討してください。

バックグラウンド同期のように待てる用途では、次のように延ばしてください。

```dart
const config = ProxyConfig(
  origin: 'https://api.example.com',
  connectTimeout: Duration(seconds: 10),
  requestTimeout: Duration(seconds: 60),
);
```

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
起動時に `AssetManifest.json` を走査し、`assets/static/` 配下に存在するファイルだけを proxy ローカル静的リソースとして扱います。たとえば `assets/static/app.css` は proxy URL の `/app.css` に対応し、一覧に無い `/test.css` は upstream 解決を優先します。
実行環境で manifest を読み込めない場合でも、proxy 起動は中断せず、静的リソース一覧を空として通常の upstream 解決へフォールバックします。
WebView へ返す上流レスポンスが `301`、`302`、`303`、`307`、`308` の場合、proxy は `HttpClient` の自動追従に依存せず `Location` を明示解決します。same-origin redirect は proxy URL へ書き換え、relative `Location` は上流リクエスト URL 基準で解決し、外部起動 redirect は `ProxyEventType.redirectHandled` で app 側へ通知できます。

## 接続復旧 API

端末のサスペンドやプロセス再開の後は、内部状態が稼働中のままでもソケットが応答しなくなることがあります。この状態では WebView が端末標準のエラー画面（`127.0.0.1:...` に接続できないという表示）を出してしまうため、復帰時に稼働確認と再バインドを行います。

```dart
// アプリのライフサイクルに連動させる
final guard = ProxyLifecycleGuard(
  proxy: proxy,
  currentUrlProvider: () => currentPageUrl,
  onRecovered: (result) {
    final reloadUri = result.reloadUri;
    if (reloadUri != null) {
      controller.loadRequest(reloadUri);
    } else {
      controller.reload();
    }
  },
  onFailed: (result) => showAppNotice(),
);
WidgetsBinding.instance.addObserver(guard);

// WebView のリソースエラーを復旧へつなぐ
onWebResourceError: (error) async {
  final result = await proxy.recoverFromWebResourceError(
    errorCode: error.errorCode,
    failingUrl: error.url,
    isMainFrame: error.isForMainFrame ?? true,
  );
  if (result.cause == ProxyRecoveryCause.recoveryFailed ||
      result.cause == ProxyRecoveryCause.unrelated) {
    showAppNotice();
    return;
  }
  final reloadUri = result.reloadUri;
  if (reloadUri != null) {
    await controller.loadRequest(reloadUri);
  } else {
    await controller.reload();
  }
}

// 任意のタイミングで確認したい場合
if (!await proxy.probe()) {
  await proxy.ensureRunning();
}

final diagnostics = await proxy.getDiagnostics();
print('port=${diagnostics.port} restarts=${diagnostics.restartCount}');
```

補足:

- `isRunning` は内部フラグのみを返します。実際に応答するかは `probe()` で確認します。
- `ensureRunning()` は応答が無い場合のみ再バインドし、キャッシュ、キュー、Cookie は保持します。例外は投げず、結果は `ProxyRecoveryResult` で返します。
- 再バインド時は WebView が保持しているポートの維持を最優先にします。ポートが変わった場合は `portChanged` と `port` を参照してください。
- ポートのみが異なる旧 URL は `resolveReloadUri()` で現行ポートへ読み替えられます。遷移判定 API でも `ProxyNavigationReason.stalePortUrl` として扱い、現行ポートの読み込みを推奨します。
- 復旧の暴走を防ぐため、連続失敗時は待機時間を挟み、1 分あたりの再バインド回数は `maxRestartAttemptsPerMinute` で制限します。
- 利用者向けの文言は本パッケージでは持ちません。`onFailed` や `recoverFromWebResourceError()` の結果を使って、アプリ側で表示内容を決めてください。
- 実装例は `example/lib/main.dart` にあります。

### 上流到達性の診断

`getDiagnostics()` は proxy 自身の状態に加えて、上流へ到達できているかを返します。現地での切り分けに使います。

```dart
final diagnostics = await proxy.getDiagnostics();

print('link=${diagnostics.isOnline} (${diagnostics.onlineDecisionSource})');
print('upstream=${diagnostics.isUpstreamReachable} '
    '(${diagnostics.upstreamCircuitState})');
print('failures=${diagnostics.consecutiveUpstreamFailures} '
    'lastSuccess=${diagnostics.lastUpstreamSuccessAt}');
```

- `isOnline` はリンク層の判定、`onlineDecisionSource` はその根拠（起動時の取得か、変化イベントか）です。
- `isUpstreamReachable` は実際に転送できる状態かどうかで、リンク層とサーキットブレーカの両方を反映します。
- `consecutiveUpstreamFailures` と `lastUpstreamSuccessAt` で、いつから到達できていないかを確認できます。

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
  if (event.type == ProxyEventType.redirectHandled &&
      event.data['redirectAction'] ==
          ProxyWebViewNavigationAction.launchExternal.name) {
    print(event.data['externalUrl']);
  }
});
```

補足:

- オンライン時の GET/HEAD は upstream へ転送し、proxy キャッシュで応答を省略しません。
- proxy キャッシュはオフライン時、または上流へ到達できない GET/HEAD の代替応答に使います。接続拒否や接続切断、request timeout の超過が対象で、upstream が応答した 4xx / 5xx はそのまま返します。代替キャッシュが無い場合は 504 を返します。
- `warmupCache()` は通常時の高速化ではなく、フォールバック用レスポンスの事前取得が目的です。

イベントストリームでは、キャッシュヒット、キュー処理、URL 解決メタ情報に加え、redirect 処理結果も監視できます。`redirectHandled` では `redirectStatusCode`、`locationHeader`、`redirectAction`、`resolvedProxyUrl`、`externalUrl` などを参照できます。
接続復旧では `serverRecovered` と `serverUnavailable` が発行され、`cause`、`previousPort`、`newPort`、`downtimeMs`、`restartCount`、`probeError` を参照できます。

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
- `assets/static/` からの静的リソース実配信は未実装です。起動時に `AssetManifest.json` から検出した `assets/static/` 配下のファイルだけを静的リソースとして分類し、現在のサーバ応答は 404 プレースホルダです。
- `AssetManifest.json` または実行環境上の同等 manifest を読み込めない場合は、静的リソースを一覧化せず、通常の upstream 解決へフォールバックします。

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

## リリース手順

- 先に `pubspec.yaml` と `CHANGELOG.md` を更新し、その変更を `main` へコミットします。
- リリース時にローカルで `dart pub publish` を直接実行しません。このリポジトリは GitHub Actions の `release` job 経由で公開します。
- `v0.8.0` のようなバージョンタグを作成して push します。`v*` タグ push を契機に GitHub Actions が検証、pub.dev 公開、GitHub Release 作成を実行します。

## ライセンス

MIT License
