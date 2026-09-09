# offline_web_proxy

[![CI/CDパイプライン](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml)
[![Pubバージョン](https://img.shields.io/pub/v/offline_web_proxy.svg)](https://pub.dev/packages/offline_web_proxy)
[![ライセンス](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![カバレッジ](https://codecov.io/gh/meibinlab/offline_web_proxy/branch/main/graph/badge.svg)](https://codecov.io/gh/meibinlab/offline_web_proxy)

offline_web_proxy は Flutter WebView 向けのローカル HTTP プロキシです。既存の Web アプリをモバイルアプリ内で扱う際に、接続が不安定な場合や一時的に利用できない場合でも動作を継続しやすくすることを目的にしています。

127.0.0.1 上で動作し、オンライン時は設定済みの上流 origin へ転送します。proxy キャッシュはオフライン時または上流到達不能時（接続失敗・リクエストタイムアウト）の代替応答に限定して利用し、更新系リクエストはキューに保持します。加えて、WebView の遷移判定、Cookie 再利用、統計取得、イベント監視の API を提供します。

## 主な機能

- Flutter WebView 向けローカルプロキシサーバ
- `assets/static/` に同梱した静的リソースの配信（CDN 依存の資材をアプリへ取り込める）
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
  offline_web_proxy: ^0.12.0
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
    'text/javascript': 86400,
    'image/*': 604800,
    'default': 86400,
  },
  cacheStale: {
    'text/html': 86400,
    'text/css': 604800,
    'image/*': 2592000,
    'default': 259200,
  },
  forceCachePaths: ['/app/**'],
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
  dropPolicy: DropPolicy.quarantine,
  enableIdempotencyKey: true,
  idempotencyHeaderName: 'Idempotency-Key',
  idempotencyRetention: Duration(hours: 24),
  queueExcludePaths: [
    QueueExcludeRule(
      path: '/api/registers/auth.json',
      response: ProxyResponseConfig(
        statusCode: 503,
        contentType: 'application/json; charset=utf-8',
        body: '{"message":"オフラインのためレジ認証できません"}',
      ),
    ),
  ],
  enableAcceptedAtHeader: true,
  acceptedAtHeaderName: 'X-Offline-Accepted-At',
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
  statusPath: '/__offline_web_proxy/status',
  healthCheckInterval: Duration.zero,
  serverIdleTimeout: Duration(seconds: 120),
  maxRestartAttemptsPerMinute: 5,
);
```

補足:

- `origin` は必須で、絶対 HTTP URL または HTTPS URL である必要があります。
- パスを指定する設定（`forceCachePaths` など）は共通の glob 記法で照合します。`*` は `/` を含まない 1 セグメント、`**` は `/` を含む任意の文字列に一致し、メタ文字が無い場合は完全一致です。クエリ文字列は照合対象に含みません。
- `port: 0` を指定すると、OS が空きポートを自動割り当てします。
- `preferredPort` を指定すると、まずそのポートを試し、使えない場合は自動割り当てへフォールバックします。直前に成功したポートも次回起動時に再利用されるため、WebView の origin をより安定させやすくなります。
- `startupPaths` は `warmupCache()` で、オフライン時または上流到達不能時の代替応答を事前準備したいパスに使います。
  - ウォームアップは転送経路と同じく Cookie Jar の内容を送ります。認証後に呼び出せば、認証が必要な API も取得できます。
  - `warmupCache(followReferences: true)` を指定すると、取得した HTML が参照する同一 origin の資源（`<script src>`、`<link href>`、`<img src>`）も続けて取得します。1 段だけ辿り、実行時に JavaScript が組み立てる URL には届きません。`<link>` は `stylesheet` など資源を指す `rel` だけを対象とします。
- `healthCheckPath` は稼働確認専用のパスです。この URL は上流へ転送されず、統計にも計上されません。Web アプリのルートと衝突する場合に変更します。
- `statusPath` は proxy の状態を JSON で返すパスです。`healthCheckPath` と同じ扱いで、上流へ転送されず統計にも計上されません。空文字列を指定すると無効になります。
- `enableAdminApi` を `true` にすると、隔離キューの一覧・再送・破棄を HTTP から操作できます。既定は無効です。
- `healthCheckInterval` に 0 より大きい値を指定すると定期的に稼働確認を行います。既定は無効で、復帰時の確認（`ProxyLifecycleGuard`）を主経路とします。
- `offlineFallbackHtml` と `gatewayTimeoutHtml` を指定すると、オフライン応答とタイムアウト応答の HTML をアプリ側の文言へ差し替えられます。
- `upstreamFailureThreshold` は、上流へ到達できない状態が連続した場合に転送を止めるまでの回数です。リンク層は接続済みでも上流が落ちている環境で、リクエストが毎回タイムアウトまで待たされるのを防ぎます。0 を指定すると無効になります。
- `upstreamProbePath`、`upstreamProbeMethod`、`upstreamProbeTimeout`、`upstreamProbeBackoffSeconds` は、転送を止めている間の復帰確認に使います。応答が返れば到達可能と判定するため、ステータスコードは問いません。
- `queuedResponse` と `offlineMissResponse` は、proxy が自分で生成する応答の内容です。既定はどちらも JSON で、Web アプリ側の `response.json()` が成功します。
- `dropPolicy` は、上流が 4xx で拒否した更新系リクエストの扱いです。既定の `quarantine` では本文を保持したまま隔離し、`getQuarantinedRequests()` で確認して再送または破棄を判断できます。`drop` を指定すると従来どおり破棄し、履歴のみ残します。
- `enableIdempotencyKey` は更新系リクエストへのべき等性キー付与です。最初の転送と再送で同じキーを送るため、応答を受け取れなかったリクエストが再送で二重に適用されることを上流側で防げます。**重複の排除自体は上流サーバでの実装が必要です。**
- `forceCachePaths` は `Cache-Control: no-store` を無視して保存するパスです。全応答に `no-store` を付与するサーバでは、既定のままだとオフラインで返せる応答が残りません。既定は空で、指定が無い限り従来どおり保存しません。全体を一括で無効化する設定は用意していません。
  - 一致しても、応答に `Set-Cookie` がある場合、応答に `Vary` がある場合（`Accept-Encoding` だけを指す場合を除く）、またはリクエストに `Authorization` がある場合は保存しません。除外したときは `ProxyEventType.cacheSkipped` を理由付きで発行するため、オフラインで使えない原因を追跡できます。
  - `Vary` が `Accept-Encoding` だけを指す場合に保存するのは、proxy が上流へ `Accept-Encoding: identity` を固定で送るため応答が割れないからです。Tomcat、nginx、Apache は圧縮を有効にするとこの `Vary` を既定で付けるため、除外すると画面の HTML、JS、CSS がまとめて対象外になります。`*` や他のヘッダ名を含む場合は除外します。
  - 一致したパスでは上流の `max-age` や `Expires` を使わず、`cacheTtl` の値を有効期限に使います。`no-store` は `max-age=0` と併記されることが多く、そのまま採用すると保存直後に stale になるためです。
  - **応答キャッシュは暗号化していません。** 指定したパスの応答本文は端末内に平文で残るため、画面が含む情報を踏まえて指定してください。
- `queueExcludePaths` は、後から送っても意味が無い更新系をキューへ入れないための規則です。レジ認証やログアウトのように、復帰後に送っても業務上の意味が無く、`202 Accepted` が成功と誤認される要求に使います。規則ごとに応答を設定できるため、画面ごとの文言を Web 側の改修なしに返せます。既定は空です。
  - オフライン時、上流へ到達できなかった場合、上流が 5xx を返した場合のすべてに適用します。ただし 5xx は上流が実際に応答しているため、応答をそのまま返してキューへの保存だけを行いません。
  - 応答には `X-Offline-Queued: 0` と `X-Offline-Excluded: 1` を付与します。
- `enableAcceptedAtHeader` と `acceptedAtHeaderName` は、proxy が最初にリクエストを受け付けた時刻を上流へ伝える設定です。初回転送と以降の再送で同じ値（UTC の ISO 8601）を送るため、上流は「業務日時が未指定ならこのヘッダを使う」と 1 箇所で実装できます。オフラインで積んだ会計が復帰時刻で記録される問題を避けられます。既定で有効です。
  - 隔離からの再送でも値は変わりません。`queuedAt` は再送のたびに更新されるため流用できません。
  - **値は端末の時計に依存します。** オフライン中に時計がずれた端末は、ずれた時刻を報告します。
- `cacheTtl` と `cacheStale` は、指定すると既定のマップとマージされず**丸ごと置き換わります**。未掲載の Content-Type が `default` へ落ちるよう、`default` は必ず含めてください。
- `text/html` の既定は TTL 1 時間、stale 1 日です。最後にオンラインで取得してから約 25 時間でフォールバック対象から外れるため、**長期のオフライン運用では `cacheTtl` と `cacheStale` の設定が必要です**。`cacheStale` には JavaScript のキーが無く、スクリプトは `default`（3 日）になります。

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

リンク層は接続済みでも上流へ到達できない場合も同じ内容を返します。この応答には `X-Offline-Source: none` が付くため、上流自身が返した `504` と判別できます。
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

一覧に一致した URL には、同梱アセットの内容をそのまま返します。CDN から読み込んでいた資材をアプリへ同梱し、`/js/haori.iife.js` のような同一 origin の URL で配信できます。

```
assets/static/js/haori.iife.js  →  http://127.0.0.1:<port>/js/haori.iife.js
```

- 対象は `GET` と `HEAD` です。同名パスへの更新系は静的扱いにせず上流へ転送します
- 内容から算出した `ETag` と `Cache-Control: no-cache` を付与し、`If-None-Match` が一致した場合は `304` を返します
- 一覧に載っていてもアセットの実体を読み込めない場合は `404` を返さず、上流への転送へ委ねます
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

### 再送結果の取得

キュー再送は画面の裏側で行われるため、結果が要求元へ返りません。上流が実際に記録した内容と突き合わせたい場合は、イベントか `recentResendResults` を参照します。

```dart
proxy.events
    .where((event) => event.type == ProxyEventType.queueResendAttempted)
    .listen((event) {
  debugPrint('再送: ${event.data['statusCode']} ${event.url}');
});

// 直近 20 件を後から確認する（本文は含みません）
for (final result in proxy.recentResendResults) {
  debugPrint('${result.method} ${result.url} -> ${result.statusCode}');
}
```

結果は監視用にメモリ上へ保持するだけで、永続化しません。アプリのプロセスが終了すると失われます。

## Web アプリから proxy の状態を見る

未送信件数やオンライン状態は Dart の API でも取得できますが、表示も判断も画面側で行いたい場合は、状態エンドポイントを使うとアプリへ橋渡しを実装せずに済みます。

```js
const res = await fetch('/__offline_web_proxy/status');
const status = await res.json();

if (status.queueLength > 0) {
  // 未送信があるうちは精算させない
  disableSettlement(`未送信が ${status.queueLength} 件あります`);
}
if (!status.isOnline) {
  // オフラインならレジ認証を出さない
  hideRegisterAuth();
}
```

応答は次の形です。

```json
{
  "isOnline": true,
  "onlineDecisionSource": "connectivity",
  "isUpstreamReachable": true,
  "upstreamCircuitState": "closed",
  "queueLength": 0,
  "quarantinedCount": 0,
  "unacknowledgedDroppedCount": 0,
  "recentResendResults": []
}
```

- `GET` のみで、上流へは転送されず、統計にも計上されません。
- proxy 自身の origin からの要求だけを受け付けます。別 origin の `Origin` を伴う要求には `403` を返し、`Access-Control-Allow-Origin: *` も付与しません。
- `statusPath` に空文字列を指定すると無効になります。

### 隔離キューを画面から操作する

4xx で隔離された会計は、原因（棚卸の締めなど）を解いてから再送します。操作するのが店舗の人であれば、`enableAdminApi: true` で HTTP からも操作できます。

| メソッド | パス | 用途 |
| --- | --- | --- |
| `GET` | `/__offline_web_proxy/admin/quarantine` | 隔離の一覧（本文は返しません） |
| `POST` | `/__offline_web_proxy/admin/quarantine/<id>/retry` | キューへ戻して再送 |
| `DELETE` | `/__offline_web_proxy/admin/quarantine/<id>` | 破棄 |

```js
const res = await fetch('/__offline_web_proxy/admin/quarantine');
const { requests } = await res.json();

for (const request of requests) {
  // 原因を解消したものから再送する
  await fetch(`/__offline_web_proxy/admin/quarantine/${request.id}/retry`, {
    method: 'POST',
  });
}
```

**注意**: 既定は無効です。同一 origin 限定とはいえ、これは「同じ origin で動くスクリプトすべてに操作を許す」ことでもあります。CDN など第三者のスクリプトを読み込んだままで有効にすると、そのスクリプトから隔離の破棄まで到達し得ます。`assets/static/` への同梱へ切り替えてから有効にしてください。

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

// 上流に拒否されて再送を打ち切ったリクエスト
final quarantined = await proxy.getQuarantinedRequests();
for (final request in quarantined) {
  // 原因を解消したら再送、送らないと判断したら破棄する
  await proxy.retryQuarantinedRequest(request.id);
}

final stats = await proxy.getStats();
print('requests=${stats.totalRequests} hitRate=${stats.cacheHitRate}');
print('quarantined=${stats.quarantinedCount} '
    'unacknowledged=${stats.unacknowledgedDroppedCount}');

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
- `warmupCache()` は通常時の高速化ではなく、フォールバック用レスポンスの事前取得が目的です。上流断を検知している間は待たずに失敗を返し、取得の成否は上流到達性の判定に反映します。

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
- `assets/static/` から配信できるのは `GET` と `HEAD` だけです。同名パスへの更新系は静的扱いにせず上流へ転送します。Range 要求には対応していません。
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
