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
- CDN など別 origin の資源の proxy 経由での取得とキャッシュ（`mirroredOrigins`）
- オフライン時と上流到達不能時（接続失敗・リクエストタイムアウト）に限定したフォールバックキャッシュ
- 上流へ到達できる状態に戻ると自分で再読込するオフライン代替ページ（再試行ボタン付き）
- POST、PUT、DELETE のオフラインキューイング
- AES-256 による Cookie、キュー、隔離、ドロップ履歴の暗号化保存と、Cookie の復元 API
- 暗号化鍵と保存データの照合と、鍵を失った場合の復旧 API
- 隔離とドロップ履歴の保持上限（件数、期間、合計バイト数）
- 端末を共用する場合に、別の利用者の送信待ちをログインし直した利用者のセッションで送らない設定（`queueOwnerResolver`）
- same-origin、外部委譲、新規 window 判定のための WebView 補助 API
- 起動ごとの秘密値で proxy への到達を既定で WebView に限る（`requireAccessToken`）。CORS ヘッダは origin を挙げた場合だけ付ける（`corsAllowedOrigins`）
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
  offline_web_proxy: ^0.25.0
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

    // requireAccessToken は既定で有効。WebView が最初のページを読み込む前に、
    // 起動ごとの秘密値を proxy の origin へ Cookie として置く。
    // 置かないと、稼働確認を除く全ての要求が 403 になる
    await WebViewCookieManager().setCookie(
      WebViewCookie(
        name: OfflineWebProxy.accessTokenCookieName,
        value: _proxy.accessToken!,
        domain: _proxy.baseUri!.host,
      ),
    );

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

**読み込む前に秘密値の Cookie を置いてください。** 0.26.0 から、起動ごとの秘密値を持たない要求は `403` で拒否します（`requireAccessToken` の既定が `true`）。`start()` のたびに、WebView がページを読み込む前に `accessToken` を proxy の origin へ Cookie として置きます。`webview_flutter` の `WebViewCookieManager` は HttpOnly を指定できないため、ページのスクリプトから値を読めます。HttpOnly で置く方法は [WebView 以外からの到達を防ぐ](#webview-以外からの到達を防ぐ) を参照してください。

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
  cacheUserScopedResponses: true,
  mirroredOrigins: ['https://cdn.example.com'],
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
  quarantineMaxCount: 1000,
  quarantineRetention: Duration(days: 30),
  quarantineMaxBytes: 20 * 1024 * 1024,
  quarantineResponseBodyMaxBytes: 0,
  droppedRequestMaxCount: 1000,
  droppedRequestRetention: Duration(days: 30),
  maxRequestBodyBytes: 10 * 1024 * 1024,
  queueMaxCount: 1000,
  queueMaxBytes: 50 * 1024 * 1024,
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
  authRequiredStatusCodes: {401},
  authResumePaths: ['/api/login.json'],
  enableAcceptedAtHeader: true,
  acceptedAtHeaderName: 'X-Offline-Accepted-At',
  enableReplayHeader: true,
  replayHeaderName: 'X-Offline-Replay',
  enableUpstreamCompression: true,
  encryptResponseCache: true,
  offlineMissResponse: ProxyResponseConfig(
    statusCode: 504,
    contentType: 'application/json; charset=utf-8',
    body: '{"offline":true}',
  ),
  retryBackoffSeconds: [1, 2, 5, 10, 20, 30],
  enableAdminApi: false,
  requireAccessToken: true,
  addCorsHeaders: false,
  corsAllowedOrigins: [],
  forwardWebViewCookieNames: {},
  logLevel: 'info',
  includeQueryInEvents: false,
  startupPaths: ['/app/config'],
  preferredPort: 8787,
  healthCheckPath: '/__offline_web_proxy/health',
  statusPath: '/__offline_web_proxy/status',
  healthCheckInterval: Duration.zero,
  serverIdleTimeout: Duration(seconds: 120),
  maxRestartAttemptsPerMinute: 5,
  enableOfflinePageAutoReload: true,
  enableAutoReloadContinuation: true,
  enableGatewayTimeoutAutoReload: false,
  autoReloadPollInterval: Duration(seconds: 3),
  autoReloadQueueWaitTimeout: Duration(seconds: 10),
);
```

補足:

- `origin` は必須で、絶対 HTTP URL または HTTPS URL である必要があります。
- パスを指定する設定（`forceCachePaths`、`authResumePaths`、`queueExcludePaths`）は共通の glob 記法で照合します。`*` は `/` を含まない 1 セグメント、`**` は `/` を含む任意の文字列に一致し、メタ文字が無い場合は完全一致です。クエリ文字列は照合対象に含みません。
  - 0.26.0 から、パターンとパスの双方を同じ形にそろえてから比較します。各セグメントの `;` 以降（`;jsessionid=...`）を除き、非予約文字の `%XX`（`%6C` など）だけを復号し、`/` の重複をまとめ、末尾の `/` を除きます。このため `/api/login` は `/api/login;jsessionid=1`、`/api/login/`、`/api/%6Cogin` にも一致します。末尾の `/*` と `/**` は手前のパスそのもの（`/js/*` に対する `/js`）にも一致します。詳しくは [doc/specs.ja.md](doc/specs.ja.md) の【1】「設定のパスパターン記法」を参照してください。
- `host` はループバック（`127.0.0.1` などの `127.0.0.0/8`、`::1`、`localhost`）だけを指定できます。`0.0.0.0` や端末のアドレスを指定すると、`start()` が `ProxyStartException` を投げます（0.26.0 から）。
- `port: 0` を指定すると、OS が空きポートを自動割り当てします。
- `preferredPort` を指定すると、まずそのポートを試し、使えない場合は自動割り当てへフォールバックします。直前に成功したポートも次回起動時に再利用されるため、WebView の origin をより安定させやすくなります。
- `startupPaths` は `warmupCache()` で `paths` を省略したときに取得するパスです。オフライン時または上流到達不能時の代替応答を事前準備したいパスに使います。
  - **`start()` は `startupPaths` を自動では取得しません。** 起動後の必要な時点で `warmupCache()` を呼んでください。
  - ウォームアップは転送経路と同じく Cookie Jar の内容を送ります。認証後に呼び出せば、認証が必要な API も取得できます。
  - `warmupCache(followReferences: true)` を指定すると、取得した HTML と CSS が参照する資源も続けて取得します。対象は同一 origin と `mirroredOrigins` に列挙した origin です。実行時に JavaScript が組み立てる URL には届きません。
    - HTML からは `<script src>`、`<link href>`、`<img src>` と `<style>` 要素内の `url()` / `@import` を、`paths` に指定した HTML の 1 段だけ辿ります。`<link>` は `stylesheet` など資源を指す `rel` だけを対象とします。
    - CSS からは `url()` と `@import` を続けて辿ります（HTML → CSS → フォントのように、指定したパスから数えて最大 4 段）。
- `healthCheckPath` は稼働確認専用のパスです。この URL は上流へ転送されず、統計にも計上されません。`GET` と `HEAD` は要求ログにも出力しません。Web アプリのルートと衝突する場合に変更します。
- `statusPath` は proxy の状態を JSON で返すパスです。`healthCheckPath` と同じ扱いで、上流へ転送されず、統計にも計上されず、`GET` は要求ログにも出力しません。空文字列を指定すると無効になり、代替ページと `504` ページの自動復帰も止まります。
- `enableAdminApi` を `true` にすると、隔離キューの一覧・再送・破棄を HTTP から操作できます。既定は無効です。
- `requireAccessToken` は、起動ごとの秘密値（`accessToken`）を持たない要求を `403` で拒否します。**0.26.0 から既定で有効**です（0.25.0 までは無効）。`false` にするのは、端末内の別アプリやページから到達されない環境（テストなど）に限ってください。[WebView 以外からの到達を防ぐ](#webview-以外からの到達を防ぐ) を参照してください。
- `addCorsHeaders` を `true` にすると、内部エンドポイントを除く応答へ、`corsAllowedOrigins` に挙げた origin 向けにだけ CORS ヘッダを付けます。**0.26.0 から既定で無効**です（0.25.0 までは有効で、全 origin へ `Access-Control-Allow-Origin: *` を付けていました）。WebView のページは同一 origin のため、CORS ヘッダを必要としません。`requireAccessToken` が有効な間（既定）、別 origin のページは通常は秘密値を送れず（同じ WebView 内で `credentials: 'include'` により秘密値の Cookie を送れる場合は除く）、preflight も CORS ヘッダなしの `403` になるため、CORS ヘッダは実質 `requireAccessToken: false` の場合にだけ意味を持ちます。無効にする危険は [WebView 以外からの到達を防ぐ](#webview-以外からの到達を防ぐ) を参照してください。上流自身が返す CORS ヘッダは、これらの設定にかかわらずそのまま返します。
- `corsAllowedOrigins` は、`addCorsHeaders` が `true` のときに proxy の応答を読ませる `http(s)` の origin（パス・クエリ・フラグメント・ユーザー情報なし。末尾の `/` だけは許可）の一覧です。要求の `Origin` が一致した場合だけ `Access-Control-Allow-Origin` にその origin を返し、応答には `Vary: Origin` を付けます。一致しない要求には CORS ヘッダを付けません。`['*']` 単独なら全 origin へ `*` を返します。`Access-Control-Allow-Credentials` は付けません。`addCorsHeaders` が `true` で一覧が空の場合、origin として解釈できない値がある場合、`'*'` と他の値が混在する場合は、`start()` が `ProxyStartException` を投げます。
- `forwardWebViewCookieNames` は、WebView が送った Cookie のうち上流へ渡す名前の一覧です。**0.26.0 から既定は空で、WebView の Cookie は上流へ渡しません**（0.25.0 までは、秘密値以外をすべて渡していました）。上流のセッションは proxy の Cookie Jar が持ち、設定にかかわらず送ります。WebView が proxy の origin に持つ Cookie は、proxy を通るどのページのスクリプトからも `document.cookie` で置けるため、上流が信頼する Cookie を差し込まれないようにしています。詳しくは [Cookie API](#cookie-api) を参照してください。
  - 挙げた名前の Cookie だけを、Cookie Jar に同じ名前が無い場合に渡します（同じ名前は Cookie Jar の値を優先）。名前は大小文字を区別します。キューへ保存する要求の `Cookie` と、キューからの再送も同じ規則で絞ります。
  - `{'*'}` 単独で、秘密値以外の全件を渡します（0.25.0 と同じ動作）。
  - RFC 6265 の token でない名前（空白、`=`、`;`、`,`、引用符などを含む名前や空文字）、`OfflineWebProxy.accessTokenCookieName`、`'*'` と他の名前の混在は、`start()` が `ProxyStartException` を投げます。
- `includeQueryInEvents` を `true` にすると、イベントの URL（`ProxyEvent.url` と、`requestReceived`・`redirectHandled`・`queueResendAttempted` の URL の項目）にクエリとフラグメントを残します。**0.26.0 から既定で無効**です（0.25.0 までは常に完全な URL を載せていました）。クエリには検索語や一度きりの符号、セッション識別子が入ることが多く、イベントはログ収集へ送られやすいためです。`redirectHandled` の `externalUrl` は、アプリが外部起動に使う値のため、この設定によらず完全な URL です。上流への転送、WebView へ返す `Location`、Dart API の `recentResendResults` は影響を受けません。
- `healthCheckInterval` に 0 より大きい値を指定すると定期的に稼働確認を行います。既定は無効で、復帰時の確認（`ProxyLifecycleGuard`）を主経路とします。
- `offlineFallbackHtml` と `gatewayTimeoutHtml` を指定すると、オフライン応答とタイムアウト応答の HTML をアプリ側の文言へ差し替えられます。
  - 既定のページも差し替えた HTML も、`Content-Type: text/html; charset=utf-8` と `Cache-Control: no-store` で返します。既定のページは再試行ボタンを持ちます。
  - 差し替えた HTML には、`ProxyConfig.recoveryScriptPlaceholder`（`<!--offline-web-proxy:recovery-->`）を書いた位置にだけ自動復帰のスクリプトが入ります。`<script>` 要素を置ける位置（`body` 内など）に書いてください。目印を複数書いた場合は、最初の目印にだけ入れ、残りは取り除きます。再試行ボタンも自分で置いてください。
  - スクリプトを入れるのは、`statusPath` が空でなく、代替ページでは `enableOfflinePageAutoReload` が、`504` ページでは `enableOfflinePageAutoReload`、`enableAutoReloadContinuation`、`enableGatewayTimeoutAutoReload` のいずれかが有効な場合です。条件を満たさない場合、目印は空文字に置き換わります。
  - `Content-Security-Policy` の meta でインラインスクリプトを禁止していると、スクリプトは動きません。
- `enableOfflinePageAutoReload`、`enableAutoReloadContinuation`、`enableGatewayTimeoutAutoReload`、`autoReloadPollInterval`、`autoReloadQueueWaitTimeout` は、proxy が返すページの自動復帰の設定です。`autoReloadPollInterval` は 100 ミリ秒以上 24 時間以下、`autoReloadQueueWaitTimeout` は 0 以上で指定します。「オフライン代替ページの自動復帰」を参照してください。
- `upstreamFailureThreshold` は、上流へ到達できない状態が連続した場合に転送を止めるまでの回数です。リンク層は接続済みでも上流が落ちている環境で、リクエストが毎回タイムアウトまで待たされるのを防ぎます。0 を指定すると無効になります。
- `upstreamProbePath`、`upstreamProbeMethod`、`upstreamProbeTimeout`、`upstreamProbeBackoffSeconds` は、転送を止めている間の復帰確認に使います。応答が返れば到達可能と判定するため、ステータスコードは問いません。
- `queuedResponse` と `offlineMissResponse` は、proxy が自分で生成する応答の内容です。既定はどちらも JSON で、Web アプリ側の `response.json()` が成功します。
- `dropPolicy` は、上流が 4xx で拒否した更新系リクエストの扱いです（`authRequiredStatusCodes` に指定した状態コードを除く）。408 と 429 は一時的な状態のため取り除かず、5xx と同じく再試行します。`Retry-After` があれば（1 時間を上限に）その時刻まで待ち、429 の間はキュー全体の送信を控えます。303 は届いたものとみなします。既定の `quarantine` では本文を保持したまま隔離し、`getQuarantinedRequests()` で確認して再送または破棄を判断できます（1 件で `quarantineMaxBytes` を超える要求は隔離せず、本文を捨ててドロップ履歴へ `quarantine_too_large` で記録します）。`drop` を指定すると従来どおり破棄し、履歴のみ残します。
- `quarantineMaxCount`（既定 1000 件）、`quarantineRetention`（既定 30 日）、`quarantineMaxBytes`（既定 20 MB）、`droppedRequestMaxCount`（既定 1000 件）、`droppedRequestRetention`（既定 30 日）は、隔離とドロップ履歴の保持上限です。`0`（`Duration.zero`）を指定するとその上限は無くなり、負の値を指定すると `start()` が `ProxyStartException` を投げます。「隔離とドロップ履歴の保持上限」を参照してください。
- `maxRequestBodyBytes`（既定 10 MiB）は受け付ける要求本文の上限、`queueMaxCount`（既定 1000 件）と `queueMaxBytes`（既定 50 MiB）はキューの上限です（0.26.0 から）。本文が上限を超える要求は転送もキュー保存もせず `413` を返し、キューが上限を超える要求は保存せず `503` と `{"queued":false,"error":"queue_full"}` を返します。範囲（`maxRequestBodyBytes` は 1024〜256 MiB、`queueMaxCount` は 1〜100000、`queueMaxBytes` は 1 MiB〜1 GiB）の外は `start()` が `ProxyStartException` を投げます。「キューと要求本文の上限」を参照してください。
- `quarantineResponseBodyMaxBytes` を 0 より大きくすると、キューからの再送が 4xx で隔離されたときに、断られた応答の本文の先頭を `QuarantinedRequest.responseBodyPreview` に残します。上流が拒否した理由を確かめるために使います。既定は `0`（残さない）で、0〜65536 の範囲外は `start()` が `ProxyStartException` を投げます。
  - 対象は `Content-Type` が `text/*`、`application/json`、`+json` の種類で、文字コードが UTF-8・US-ASCII・指定なしの本文です。gzip は 256 KB までなら解凍してから先頭を取り、それ以外の `Content-Encoding` は残しません。UTF-8 の文字の途中では切らないため、上限より数バイト短くなることがあります。
  - 隔離と一緒に暗号化して保存し、`quarantineMaxBytes` の合計に含めます（古い隔離が早く追い出されやすくなります）。先頭を含めると 1 件で `quarantineMaxBytes` を超える場合は、先頭を外して隔離します。
  - 読めるのは `getQuarantinedRequests()` だけで、管理 API の一覧、イベント、状態通知、ドロップ履歴には出しません。`retryQuarantinedRequest()` で送り直すときに消します。
  - **個人情報（利用者が入力した値など）が入り得ます。** 必要なときだけ有効にし、要求を送った本人にだけ見せてください。
- `enableIdempotencyKey` は更新系リクエストへのべき等性キー付与です。最初の転送と再送で同じキーを送るため、応答を受け取れなかったリクエストが再送で二重に適用されることを上流側で防げます。**重複の排除自体は上流サーバでの実装が必要です。** 画面が付けたキーの要求がキューにある場合、同じ持ち主の同じ内容（メソッド、URL、本文）ならその要求の ID を返し、持ち主か内容が違えば保存せず `422` と `{"queued":false,"error":"idempotency_key_conflict"}` を返します（0.26.0 から）。
- `forceCachePaths` は `Cache-Control: no-store` を無視して保存するパスです。全応答に `no-store` を付与するサーバでは、既定のままだとオフラインで返せる応答が残りません。既定は空で、指定が無い限り従来どおり保存しません。全体を一括で無効化する設定は用意していません。
  - 一致しても、応答に `Set-Cookie` がある場合、応答に `Vary` がある場合（`Accept-Encoding` だけを指す場合を除く）、またはリクエストに `Authorization` がある場合は保存しません。除外したときは `ProxyEventType.cacheSkipped` を理由付きで発行するため、オフラインで使えない原因を追跡できます。
  - `Vary` が `Accept-Encoding` だけを指す場合に保存するのは、proxy が上流へ送る `Accept-Encoding` をすべての経路で揃え、gzip は解凍してから保存するため応答が割れないからです。Tomcat、nginx、Apache は圧縮を有効にするとこの `Vary` を既定で付けるため、除外すると画面の HTML、JS、CSS がまとめて対象外になります。`*` や他のヘッダ名を含む場合は除外します。
  - 一致したパスでは上流の `max-age` や `Expires` を使わず、`cacheTtl` の値を有効期限に使います。`no-store` は `max-age=0` と併記されることが多く、そのまま採用すると保存直後に stale になるためです。
  - 応答キャッシュは既定で暗号化して保存します。`encryptResponseCache` を無効にすると、指定したパスの応答本文が端末内に平文で残ります。暗号化しても Box のキー（URL の SHA-256）は平文のため、画面が含む情報を踏まえて指定してください。
- `cacheUserScopedResponses` は、利用者ごとの応答を応答キャッシュへ保存するかどうかです。既定は `true` です（0.26.0 から）。
  - 応答に `Set-Cookie` がある応答と `Cache-Control: private` の応答は、常に利用者ごとです。上流へ `Authorization` か Cookie を送った応答も利用者ごとですが、応答の `Cache-Control` に `public` があれば、上流が共有を許しているため利用者ごとにしません（RFC 9111 3.5 を参考に `public` だけを印にします。`s-maxage` と `must-revalidate` は再検証が前提で、オフラインでは再検証しないため印にしません）。`public` でも `Vary` に `Cookie`、`Authorization`、`*` のいずれかがあれば利用者ごとです。
  - **セッションを Cookie で持つ上流では、Cookie が 1 つでもあればほぼすべての要求で Cookie を送るため、上流が `public` を付けない限り、静的資源を含むほぼすべての応答が該当します。** `false` にするとログインした後は事実上キャッシュされません。持ち主ごとに扱う場合も、利用者を切り替えた後は、該当する静的資源も取り直すまでオフラインで返せません。
  - `false` にすると保存せず、`ProxyEventType.cacheSkipped`（`reason: userScoped`）を発行します。
  - `true` で `queueOwnerResolver` を指定した場合は、保存した時点の持ち主と結び付け、その持ち主がログインしている間だけキャッシュから返します（「端末を共用する場合」）。指定しない場合は 0.25.0 と同じく誰にでも返します。
  - どちらの場合も、保存するヘッダから `Set-Cookie` と `Set-Cookie2` を除きます。WebView へ返す応答からは除きません。0.25.0 以前に保存した記録は書き換えないため、その `Set-Cookie` は有効期限を過ぎるか `clearCache()` を呼ぶまで端末に残ります（キャッシュから返すことはありません）。
- `mirroredOrigins` は、proxy 経由で取得する別 origin の一覧です。CDN から UI ライブラリを読み込む画面では、HTML 内の絶対 URL が 127.0.0.1 を経由せず、キャッシュもフォールバックもウォームアップも効きません。列挙した origin は proxy が中継し、通常のキャッシュとオフライン代替の対象になります。既定は空です。
  - proxy が返す `text/html` の `<script src>`、`<link href>`、`<img src>` と `<style>` 要素内、および `text/css` の `url()` と `@import` のうち、一致する絶対 URL を `/__offline_web_proxy/ext/<scheme>/<host>[:port]/<元のパス>` へ書き換えます。`<link>` は `stylesheet` など資源を指す `rel` だけが対象です。
  - Google Fonts のように CSS が別 origin のフォント本体を参照する場合は、CSS とフォント本体の両方の origin（例: `https://fonts.googleapis.com` と `https://fonts.gstatic.com`）を列挙します。
  - 列挙した origin を指す絶対 URL、または中継した CSS 内の `/` で始まるルート相対 URL を含む CSS は、書き換えで本文が変わるため、`integrity` 属性を付けた `<link>` では検証に失敗します。`../x` のようなパス相対 URL は書き換えません。
  - 書き換えの判定はウォームアップの参照抽出と同じです。**書き換えた資源は必ず `warmupCache(followReferences: true)` の対象になります**。
  - 書き換えは保存時ではなく応答時に行うため、オフラインでキャッシュから返す HTML と CSS にも同じ変換がかかります。設定から origin を外せば元の URL に戻ります。
  - 中継するのは `GET` と `HEAD` だけです。ほかのメソッドは `405` を返し、キューにも載せません。許可していない origin を指すパスは `404` を返し、設定済み origin へ素通ししません。
  - 一致判定はスキーム、ホスト、ポートの完全一致です。パスやクエリを含む値を指定すると起動時に `ProxyStartException` になります。
  - **中継先へは `Authorization`、`Origin`、`Referer` とクライアントの `Cookie` を送りません。** Cookie Jar のうち中継先のドメインに一致するものだけを送ります。
  - 中継先が返す `Set-Cookie` のうち、設定済み origin のホストへも送られる範囲の Cookie（親ドメインの `Domain` や、ポートだけが違う同じホスト）は Cookie Jar へ保存しません（[Cookie API](#cookie-api) の受け入れ規則）。
  - **中継先が返す `Set-Cookie` は WebView へ返しません。** Cookie Jar にだけ保存し、以後の中継で中継先へ送ります。WebView へ返すと proxy の origin の Cookie として保存され、設定済み origin への要求でも送られるためです。中継先の Cookie をページのスクリプトから読む画面は、更新後に読めなくなります。
  - 実行時に JavaScript が組み立てる URL には届きません。`Content-Security-Policy` を返す画面では、書き換え後の URL が proxy と same-origin になるため `'self'` の許可が必要です。`assets/static/` から配信する同梱 HTML は書き換えの対象外です。
- `queueExcludePaths` は、後から送っても意味が無い更新系をキューへ入れないための規則です。レジ認証やログアウトのように、復帰後に送っても業務上の意味が無く、`202 Accepted` が成功と誤認される要求に使います。規則ごとに応答を設定できるため、画面ごとの文言を Web 側の改修なしに返せます。既定は空です。
  - オフライン時、上流へ到達できなかった場合、上流が 5xx を返した場合のすべてに適用します。ただし 5xx は上流が実際に応答しているため、応答をそのまま返してキューへの保存だけを行いません。
  - 応答には `X-Offline-Queued: 0` と `X-Offline-Excluded: 1` を付与します。
- `authRequiredStatusCodes` と `authResumePaths` は、オフラインの間に上流のセッションが切れた場合に、キューの要求を隔離せずに再ログインまで待たせる設定です。既定はどちらも空で、従来どおり 4xx はすべて `dropPolicy` に従って取り除きます。
  - キューから送った要求が `authRequiredStatusCodes`（例 `{401}`）の状態コードを返すと、その要求をキューに残し（再試行回数は増やしません）、キューの送信を一時停止します。順序を保つため、後続の要求も送りません。
  - 一時停止すると `ProxyEventType.authenticationRequired` を 1 回発行し、`getStats()` と状態通知の `queuePausedReason` が `authenticationRequired` になります。キーで照会した状態は `queued` のままです。
  - 再開するのは、`resumeQueue()` を呼んだときと、`authResumePaths` に一致する要求（ログイン）が proxy を通って 2xx か 3xx を返したときです。3xx を含めるのは、フォームのログインが成功後にリダイレクトすることが多いためです。再開後に同じ要求がまた同じ状態コードを返した場合は、再び一時停止します。
  - ログインし直しても通らない要求は、`skipPausedRequest()` で `dropPolicy` に従って隔離またはドロップ履歴へ移し（理由は `authentication_required`）、残りを送ります。
  - 指定できるのは 300〜499 です。ログイン画面へのリダイレクト（`302` など）も指定できます。指定しない場合、`303` は届いたものとみなすため、セッション切れを `303` で返す上流では `303` を指定してください。**権限不足でも返る `403` のような状態コードを指定すると、ログインで解決しない要求でキューが止まります。** 古いセッションの CSRF トークンを含む要求も同じです。
  - 一時停止の状態は保存しません。proxy を停止すると解除し、次の起動では先頭から送り直します。
- `queueOwnerResolver` は、ログインした利用者を判定して、別の利用者の送信待ちを送らないための設定です。既定は `null`（0.24.0 と同じ動き）で、指定する場合は `authResumePaths` が必要です。「端末を共用する場合」を参照してください。
- `enableAcceptedAtHeader` と `acceptedAtHeaderName` は、proxy が最初にリクエストを受け付けた時刻を上流へ伝える設定です。初回転送と以降の再送で同じ値（UTC の ISO 8601）を送るため、上流は「業務日時が未指定ならこのヘッダを使う」と 1 箇所で実装できます。オフラインで積んだ会計が復帰時刻で記録される問題を避けられます。既定で有効です。
  - 隔離からの再送でも値は変わりません。`queuedAt` は再送のたびに更新されるため流用できません。
  - **値は端末の時計に依存します。** オフライン中に時計がずれた端末は、ずれた時刻を報告します。
- `enableReplayHeader` と `replayHeaderName` は、キューから送る更新系に `X-Offline-Replay: 1` を付ける設定です。上流は、画面から受けてすぐ転送した要求と、キューから後で送った要求とを見分けられます。たとえば、内容が現在の登録と食い違うとき、最初の転送では拒否して画面で確認し直してもらい、キューからの送信では受け付ける、という扱いができます。既定で有効です。
  - 最初の転送を拒否する場合は 4xx を返してください。5xx を返すとキューへ入り、このヘッダを付けて送り直されます。4xx でも、タイムアウトなどで応答が proxy へ届かなければ同じく送り直されるため、同じべき等性キーで一度拒否した要求には、キューからの送信でも同じ判定を返してください。
  - 画面が送った同名のヘッダは、画面から受けて上流へ転送する要求（read 系を含む）からは取り除き、キューからの送信では proxy の値で上書きします。
  - **認証の代わりにはなりません。** 上流へ直接届く要求は、proxy を通らずにこのヘッダを付けられます。
- `enableUpstreamCompression` を有効にすると（既定）、上流へ `Accept-Encoding: gzip` を送り、gzip の本文を proxy で解凍してから WebView へ返します。上流との通信量が減ります。
  - 転送、キューからの送信、ウォームアップ、別 origin の中継のすべてで同じ値を送ります。キャッシュ・HTML と CSS の書き換え・WebView への応答は、解凍後の本文で扱います。
  - 解凍できない本文（壊れている、途中で切れている、解凍後に 64 MB を超える）は、そのまま返して保存しません。br など gzip 以外の方式は、従来どおりそのまま返します。`Range` を付けた要求には `identity` を送ります。
  - `false` にすると、0.19.0 以前と同じく `Accept-Encoding: identity` を送ります。
- `cacheMaxSize` は、応答キャッシュの本文の合計の上限です（既定 200 MB、`0` で上限なし）。超えた場合は、保存した日時の古いものから、上限の 9 割に収まるまで削除し、`ProxyEventType.cacheEvicted` を発行します。本文だけで上限を超える応答は保存しません。
- `encryptResponseCache` が有効な間は（既定）、応答キャッシュを Cookie・キュー・隔離と同じ鍵で暗号化して保存します。
  - 本文は返すときに 1 件ずつ読むため、全件を復号せず、キャッシュ全体をメモリに載せません。ただし開くときにファイル全体を読むため、開く時間は大きさに比例します（パソコンで 200 MB に約 0.75 秒、Android エミュレータで約 30 ms/MB）。暗号化の有無ではほとんど変わりません。
  - 0.21.0 以前から更新すると、古い形式のキャッシュ（平文の `proxy_cache` など）を暗号化した組へ移してから、古いファイルを削除します（パソコンで 200 MB に約 7.5 秒。エミュレータでは 40 秒を超える見込み）。削除は通常のファイル削除で、ストレージ上の領域の消去は保証しません。
  - 応答キャッシュは、`start()` の後に裏で開きます（移行も含む）。`start()` は待たずに返り、開き終わるまではオンラインの GET の応答を保存しません。キャッシュから返す要求は `requestTimeout` を上限に待ちます。起動直後にオフラインで画面を出す前に待つ場合は `await proxy.cacheReady;` を使います。開けない場合はキャッシュを使わずに動作を続けます（`ProxyEventType.errorOccurred`、`phase: cacheOpen`）。
  - `false` にすると平文で保存し、暗号化したキャッシュは平文へ戻さずに削除します。鍵と合わない場合は、起動を失敗させずにキャッシュを空にします。
  - Box のキー（正規化した URL の SHA-256）は平文のままです。
- `cacheTtl` と `cacheStale` は、指定すると既定のマップとマージされず**丸ごと置き換わります**。未掲載の Content-Type が `default` へ落ちるよう、`default` は必ず含めてください。
- `text/html` の既定は TTL 1 時間、stale 1 日です。最後にオンラインで取得してから約 25 時間でフォールバック対象から外れるため、**長期のオフライン運用では `cacheTtl` と `cacheStale` の設定が必要です**。`cacheStale` には JavaScript のキーが無く、スクリプトは `default`（3 日）になります。

### 端末を共用する場合

複数の利用者が同じ端末を使う業務アプリでは、利用者 A の送信待ちが残ったまま、利用者 B がログインし直すことがあります。再送は送る時点の Cookie を使うため、そのままでは A の更新が B のセッションで送られます。`queueOwnerResolver` を指定すると、ログインの要求と応答から利用者を判定し、持ち主が違う送信待ちを送らずに取り除きます。

```dart
final config = ProxyConfig(
  origin: 'https://api.example.com',
  authRequiredStatusCodes: {401},
  authResumePaths: ['/api/login.json'],
  // ログインの要求の本文 {"account": "..."} から利用者を判定する
  queueOwnerResolver: (context) => switch (context.requestJson) {
    {'account': final String account} => account,
    _ => null, // 判定できない場合（ログインの失敗など）は持ち主を変えない
  },
);
```

- 判定関数は、`authResumePaths` に一致する要求に上流が 2xx か 3xx を返したときに、同期で呼ばれます。`QueueOwnerContext` で要求と応答（解凍済みの本文）を受け取り、`requestJson`、`responseJson`、`requestFormFields`、`requestHeader()`、`responseHeader()` などで読めます。
- 空でない文字列を返すと、現在の持ち主になります。`null` か空文字列を返すと、現在の持ち主を変えません。ログインの失敗を `200` で返すサーバでは `null` を返してください。
- proxy が要求を受け付けた時点の持ち主を記録し（上流が応答を待たせている間に別の利用者がログインしても変わりません）、再送の直前に現在の持ち主と比べます。違う場合は送らずに `dropPolicy` に従って隔離またはドロップ履歴へ移し、理由は `owner_changed`、状態コードは `0` です。`requestQuarantined` / `requestDropped` と `recentResendResults` で気付けます。持ち主がログインし直した後に `retryQuarantinedRequest()` で送り直せます。
- どちらかの持ち主が分からない要求（この設定を使う前や、誰もログインしていない間に入れた要求）は、従来どおり送ります。
- ログインを転送している間は、キューから送りません。複数のログインを並行して転送しても、応答が届いた順に Cookie と持ち主をそろえて確定します。
- ログイン以外でセッションを変える場合も持ち主を扱います（0.26.0 から）。`restoreCookies()` には、復元するセッションの利用者を `queueOwnerId` で渡してください。渡すとその利用者が持ち主になり、渡さないとキューを `ownerUnresolved` で止めます。`clearCookies()` で全件か設定済み origin のホストへ送られるドメインを消した場合も `ownerUnresolved` で止めます。どちらも前の持ち主の要求は捨てません。一度も起動していない間は判定関数の有無が分からないため、`queueOwnerId` を使いません。`start()` の後に呼んでください。
- 判定関数が例外を投げた場合と、持ち主を決められない・保存できない場合は、`errorOccurred`（`phase: queueOwnerResolve` / `queueOwnerPersist`）を出し、ログインした利用者を正体の分からない持ち主とみなして、キューを `ownerUnresolved` で止めます。`resumeQueue()` か、持ち主が決まる次のログインで再開します。持ち主が分からないまま起動し直した場合も `ownerUnresolved` で止めたままにし、前の持ち主の要求を移しません（`clearCookies()`、`queueOwnerId` の無い `restoreCookies()`、ログインの転送中の終了の後も同じです）。
- 識別子はそのまま保存せず、HMAC-SHA256 だけを持ちます。イベント、状態通知、管理 API には出しません。現在の持ち主は起動し直しても引き継ぎます。暗号化しないポート設定の Box に保存するため、記録には書き換えを検出するタグを付けます。起動時にタグが合わない場合と、持ち主のある要求があるのに記録が無い場合は、`errorOccurred`（`phase: queueOwnerLoad`）を出してキューを `ownerUnresolved` で止めます。0.25.0 の記録（タグなし）は 1 回だけ受け入れ、タグを付けて保存し直します。
- **この設定を使う前にログインしたセッションで溜まった送信待ちは、次のログインまで保護されません。** 上流側の本人確認も残してください。
- `enableWebStorageInheritance` を有効にした場合、Web ストレージのスナップショットは持ち主と関係なく端末に残ります。利用者のサインアウトや端末の引き渡しの際は `clearWebStorageSnapshot()` を呼んでください（「Web ストレージのスナップショット」）。
- 応答キャッシュも持ち主ごとに扱います（0.26.0 から）。キャッシュのキーは URL だけのため、利用者ごとの応答（上流へ Cookie を送った応答など）には、保存したときの持ち主を付けます。オフラインや上流へ到達できないときは、現在の持ち主と一致する場合だけ返し、別の利用者の間や、持ち主が変わった後はミス（`ProxyEventType.cacheMiss`、`reason: ownerMismatch`）にします。持ち主が分からないまま（`ownerUnresolved`）保存した応答は、持ち主が変わるまでだけ返します。取得している間にログインや `restoreCookies()` が始まった応答は保存しません（`cacheSkipped`、`reason: ownerChanged`）。誰もログインしていない間の応答は「持ち主なし」の印を付けて保存し、持ち主が無い間だけ返します。誰かがログインした後や `clearCookies()` の後は返しません。端末を共用する場合に利用者ごとの応答を一切残したくなければ、`cacheUserScopedResponses: false` にしてください。

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

キャッシュが無い状態のオフライン read には、既定で `504` と `{"offline":true}` を返します。`response.ok` が false になるため、通常のエラー処理で扱えます。ページ遷移（`Sec-Fetch-Mode: navigate`）だけは、人が読める HTML のフォールバックページ（`200`）を返します。

リンク層は接続済みでも上流へ到達できない場合、ページ遷移以外には同じ内容を返します。ページ遷移には、再試行ボタンを持つ HTML の `504` ページ（`gatewayTimeoutHtml` で差し替え可能）を返します。サーキットブレーカが遮断した後はオフライン時と同じ経路になり、ページ遷移にはフォールバックページを返します。上流へ到達できずに proxy が返す `504` には `X-Offline-Source: none` が付くため、上流自身が返した `504` と判別できます。
- 現在サポートされる設定入口は `ProxyConfig` です。外部 YAML の自動読込は実装されていません。

### オフライン代替ページの自動復帰

オフライン時にキャッシュの無い画面へ遷移すると、proxy は `200` の代替ページ（フォールバックページ）を返します。WebView にはエラーとして届かないため、何もしなければ接続が戻っても代替ページのままになります。既定の代替ページは、同じ origin の `statusPath` を一定間隔で読み、上流へ到達できる状態に戻ると自分で再読込します。

- `isUpstreamReachable` を 2 回続けて `true` で読んだら、`queueLength` が 0 になるまで（最長 `autoReloadQueueWaitTimeout`）待ってから再読込します。再送前の画面を見た利用者が、同じ操作を入れ直すのを防ぐためです。
- `isOnline` ではなく `isUpstreamReachable` で判定します。`isOnline` はリンク層だけの判定で、Wi-Fi に接続したまま上流が止まっている間も `true` になるためです。
- 「到達できる」は proxy の判定が変わったことを表し、上流の応答を確かめた結果ではありません。機内モードを解除した直後の再読込は、経路が整う前で `504` になることがあります。
- 自動再読込の結果として `504` ページが表示された場合は、10 秒待った後に `isUpstreamReachable: true` を読めば、もう一度再読込します（`enableAutoReloadContinuation`、既定で有効）。proxy のページに着いた自動再読込が 3 回続くと止まり、再試行ボタンだけが残ります。
- 表示した時点から `504` ページを監視して再読込する機能（`enableGatewayTimeoutAutoReload`）は既定で無効です。有効にしても、proxy が到達不能を検知した（サーキットブレーカの遮断やリンク層の切断）あとで到達できる状態に戻った場合だけ働きます。
- 状態を取得できない間（proxy の停止やポートの変更）は再読込せず、間隔を最長 30 秒まで延ばして読み続けます。proxy 自体の復旧は `ProxyLifecycleGuard` が担います。
- `beforeunload` を受け取ってから `requestTimeout` に 30 秒を足した時間は、画面から始まった遷移を打ち消さないよう再読込を見送ります。ページが置き換わらない遷移（`204` の応答、ダウンロード、アプリが止めた遷移、外部スキーム）の後も、この時間だけ再読込が遅れます。これより長くかかる遷移は打ち消すことがあります。iOS の WKWebView で `beforeunload` が発火するかは未確認です。
- JavaScript が無効な WebView では動きません。iframe で表示した場合は枠ごとに動きます。
- 自動再読込の連続回数は、Web アプリの origin の `sessionStorage` に `__offline_web_proxy_recovery:` で始まるキーで保存し、10 分以上更新の無いキーは消します。`sessionStorage` を使えない WebView では、連続回数の上限と継続復帰が働きません。
- 自動再読込の途中でリダイレクトを挟んで別の URL に着いた場合、その 1 回は継続復帰が働きません。着いた先の `504` ページは、`enableGatewayTimeoutAutoReload` が無効なら再試行ボタンだけを残します。
- `statusPath` を空文字列にすると、スクリプトを入れず、再試行ボタンだけのページになります。
- 状態通知の `GET` と稼働確認の `GET` / `HEAD` は、要求ログに出力しません。要求ログにはクエリを出さず、クエリのある要求は `/path?…` と出力します。

HTTP エラーの通知（webview_flutter の `NavigationDelegate.onHttpError`、flutter_inappwebview の `onReceivedHttpError`）でアプリのエラー画面を出している場合、自動再読込が `504` に着くたびに通知が届きます（連続 3 回まで）。proxy が生成した `504` には `X-Offline-Source: none` が付きます。

- 既定の `504` ページ、または再試行ボタンを置いた差し替え HTML を使っている場合は、主フレームの `504` に `X-Offline-Source: none` が付いていれば、アプリのエラー画面を出さずに済みます（WebView で JavaScript が有効な場合）。
- ヘッダ名は大文字小文字を区別せずに照合してください。
- それでもエラー画面を出す場合は、閉じる契機に注意してください。`504` ページ自身の読み込み完了で閉じると、表示した直後に消えるおそれがあります。HTTP エラーの通知と読み込み完了の通知の順序は WebView の実装によるため、実機で確かめてから実装してください。
- 競合する場合は `enableAutoReloadContinuation: false` を指定してください。

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

オフライン代替ページは、状態通知を読んで自分で再読込します。`504` ページが再読込するのは、自動再読込の結果として表示された場合（`enableAutoReloadContinuation`）と、`enableGatewayTimeoutAutoReload` を有効にした場合です（「オフライン代替ページの自動復帰」）。`ProxyLifecycleGuard` が担うのは、proxy のソケット自体が応答しなくなった場合の復旧です。

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
- `lastCookieStorageDiscardedAt` と `lastCookieStorageDiscardReason` で、このインスタンスが Cookie の保存領域を破棄した日時と理由を確認できます（「暗号化鍵を失った場合」）。

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

`statusCode` が `0` になるのは、上流へ到達できなかった場合と、持ち主が違うため送らなかった場合（`dropReason` が `owner_changed`）、`origin` の設定を変えた後で保存した送信先が設定済み origin と違うため送らなかった場合（`mirroredOrigins` に含まれていても同じ）（`dropReason` が `origin_changed`）です。結果は監視用にメモリ上へ保持するだけで、永続化しません。アプリのプロセスが終了すると失われます。`recentResendResults` はクエリを含む完全な URL を保持しますが、イベントの `url` は `includeQueryInEvents` が `true` でない限りクエリとフラグメントを除きます。

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
  "queuePausedReason": null,
  "queuePausedUntil": null,
  "recentResendResults": []
}
```

- `queuePausedReason` は、キューの送信を止めている理由です。止めていなければ `null`、認証待ち（`authRequiredStatusCodes`）なら `"authenticationRequired"`、上流が 429 を返して控えているなら `"rateLimited"`、`queueOwnerResolver` が利用者を判定できずに止めているなら `"ownerUnresolved"` です。`"authenticationRequired"` は、画面にログインを促す表示を出す判断に使えます。
- `queuePausedUntil` は、`"rateLimited"` の場合に送信を再開する時刻（UTC の ISO 8601）です。それ以外は `null` です。
- `recentResendResults` は直近の再送結果です。画面から読めるため、`includeQueryInEvents` の設定にかかわらず `url` にクエリとフラグメントを含めません。
- `GET` のみで、上流へは転送されず、統計にも計上されず、要求ログにも出力されません。
- proxy 自身の origin からの要求だけを受け付けます。別 origin の `Origin` を伴う要求には `403` を返し、`corsAllowedOrigins` の設定にかかわらず `Access-Control-Allow-Origin` を付与しません。
- `Origin` の無い要求は許可するため、`requireAccessToken` を無効にすると、端末内の別アプリからも到達できます（「WebView 以外からの到達を防ぐ」）。
- `statusPath` に空文字列を指定すると無効になります。代替ページと `504` ページの自動復帰も止まります。
- `queueLength`、`quarantinedCount`、`unacknowledgedDroppedCount` には、0.14.0 以前の保存領域から移行を待っている分も含みます（「0.14.0 以前からの移行」）。

#### 送った要求の状態をキーで照会する

画面が `Idempotency-Key`（`idempotencyHeaderName` で変えた場合はそのヘッダ）に自分で決めたキーを付けて送った更新系は、`idempotencyKey` を指定して、いまどうなっているかを照会できます。画面を開き直した後も送信待ちを表示し続ける、上流に拒否されたことに気付いて取り直してもらう、といった用途に使います。

```javascript
const query = requestIds
  .map((id) => `idempotencyKey=${encodeURIComponent(id)}`)
  .join("&");
const response = await fetch(`/__offline_web_proxy/status?${query}`, {
  cache: "no-store",
});
if (!response.ok) {
  // 503 は保存領域を読めない状態。残したキーは消さず、次の照会を待つ
  return;
}
for (const item of (await response.json()).requests) {
  // item.state は queued / quarantined / delivered / dropped / unknown
}
```

- `state` は、`queued`（送信待ち。認証待ちで一時停止している場合を含む）、`quarantined`（4xx で隔離）、`delivered`（送信待ちから送り、上流が 2xx か 303 を返した。`idempotencyRetention` の間だけ）、`dropped`（ドロップ履歴にある）、`unknown`（どこにも無い）のいずれかです。`quarantined` と `dropped` には `statusCode` が付きます。
- 同じキーが複数の場所にある場合は、`delivered` → `queued` → `quarantined` → `dropped` の順で先に当てはまるものを返します。
- 最初の転送で上流が 5xx 以外を返した要求は `unknown` です。画面はその応答を直接受け取るためです。5xx を返した場合や上流へ到達できなかった場合は送信待ちへ入るため、`queued` です（`queueExcludePaths` に一致する要求は送信待ちへ入らないため、`unknown` です）。
- キーは 50 件まで、長さは 200 文字までです。超えると `400` を返します。保存領域を読めない場合は、`unknown` ではなく `503` を返します。
- 端末内の別アプリも、キーを知っていれば照会できます。キーは推測できない乱数（UUID 第 4 版など）にしてください。
- Dart からは `getRequestStatuses()` で同じ判定を行えます。

### 隔離キューを画面から操作する

4xx で隔離された会計は、原因（棚卸の締めなど）を解いてから再送します。操作するのが店舗の人であれば、`enableAdminApi: true` で HTTP からも操作できます。

| メソッド | パス | 用途 |
| --- | --- | --- |
| `GET` | `/__offline_web_proxy/admin/quarantine` | 隔離の一覧（本文は返しません） |
| `POST` | `/__offline_web_proxy/admin/quarantine/<id>/retry` | キューへ戻して再送 |
| `DELETE` | `/__offline_web_proxy/admin/quarantine/<id>` | 破棄 |

- 一覧は隔離した日時（`quarantinedAt`）の古い順に並び、各項目は `pendingMigration` を持ちます。`quarantineResponseBodyMaxBytes` で残した応答本文の先頭は含みません。
- 再送と破棄の応答は次のとおりです。
  - 成功: `200`（`{"retried": true}` または `{"discarded": true}`）
  - 該当が無い: `404`
  - 0.14.0 以前の保存領域から移行を待っている項目（`pendingMigration: true`）: `409`。移行が終わるまで操作できません
  - `404` と `409` では、`retried` / `discarded` が `false` になり、`error` に理由が入ります
  - 隔離のロックを 30 秒以内に取得できない場合: `500`（`text/plain`）

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

**注意**: 既定は無効です。同一 origin 限定とはいえ、これは「同じ origin で動くスクリプトすべてに操作を許す」ことでもあります。CDN など第三者のスクリプトを読み込んだままで有効にすると、そのスクリプトから隔離の破棄まで到達し得ます。`assets/static/` への同梱へ切り替えてから有効にしてください。また、`Origin` の無い要求は許可するため、`requireAccessToken` を無効にすると、端末内の別アプリからも到達できます。既定の有効のまま使ってください（「WebView 以外からの到達を防ぐ」）。

## WebView 以外からの到達を防ぐ

proxy はループバックで待ち受けますが、要求がどのプロセスから来たかは区別できません。検査が無いと、端末内の別アプリやブラウザのページも proxy へ要求を送れ、転送経路では proxy の Cookie Jar にある認証セッションを付けて上流へ送られます。このため proxy は、WebView が知る起動ごとの秘密値を持つ要求だけを受け付けます（`requireAccessToken`、0.26.0 から既定で有効）。アプリは、WebView が最初のページを読み込む前に秘密値を Cookie として置く必要があります。

```dart
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

final proxy = OfflineWebProxy();
await proxy.start(
  config: const ProxyConfig(
    origin: 'https://api.example.com',
    // requireAccessToken: true（既定）で、秘密値を持たない要求を 403 で拒否する。
    // addCorsHeaders: false（既定）で、WebView のページに不要な CORS ヘッダを付けない
  ),
);

// WebView が最初のページを読み込む前に、HttpOnly の Cookie として置く
await CookieManager.instance().setCookie(
  url: WebUri(proxy.baseUri!.toString()),
  name: OfflineWebProxy.accessTokenCookieName,
  value: proxy.accessToken!,
  isHttpOnly: true,
);
```

- `accessToken` は `start()` のたびに変わり、HTTP では返しません。`start()` し直した後は、新しい値を置き直してから読み込みます。自動復旧の再バインドでは変わりません。
- `webview_flutter` の `WebViewCookieManager` は HttpOnly を指定できないため、これで置いた Cookie（クイックスタートの例）はページのスクリプトから読めます。スクリプトから隠す場合は、HttpOnly で置けるネイティブの Cookie 管理（Android の `CookieManager` など）か、`flutter_inappwebview` を使ってください。
- アプリから `HttpClient` で送る要求など、WebView 以外からの要求にも秘密値が必要です。下記のヘッダで渡してください。
- `fetch` などヘッダを付けられる呼び出しでは、`X-Offline-Web-Proxy-Token`（`OfflineWebProxy.accessTokenHeaderName`）でも受け付けます。
- 拒否しないのは `GET` / `HEAD` の `healthCheckPath` だけです。転送経路、同梱アセット、別 origin の中継、状態通知、管理エンドポイント、WebStorage の橋渡しはすべて対象です。
- Cookie はホストごとに保持され、ポートは区別しません。`127.0.0.1` と `localhost` の両方を使う場合は、それぞれに置きます。同じホストの別ポートのサーバへも秘密値が送られます。
- `SameSite=Strict` にすると、別サイトのページから proxy への遷移では Cookie が送られません。ただし、外部ログインから戻る遷移も `403` になります。
- `credentials: "omit"` の `fetch` は Cookie を送らないため `403` になります。`same-origin`（既定）で呼んでください。
- 秘密値の Cookie とヘッダは、設定にかかわらず上流へは転送せず、キューにも保存しません。上流が同じ名前の `Set-Cookie` を返しても、WebView へは返しません。
- WebView 内で動くスクリプトは、同一 origin の要求として秘密値付きで到達できます。第三者のスクリプトへの対策にはなりません。
- 別のサイトのページが DNS rebinding で自分のホスト名をループバックへ向けても届かないよう、`Host` ヘッダが proxy 自身（`ProxyConfig.host`、`127.0.0.1`、`localhost`、`[::1]` と稼働中のポート）を指さない要求は、稼働確認を含めて秘密値の検査より前に `403` で拒否します。WebView には `baseUri` などこれらのホスト名の URL を読み込ませてください。
- `..%2F` や `%5C..` のように、符号化などで `.` と `..` を隠したパスの要求は、上流で別の資源を指さないよう `400` で拒否します（`errorOccurred` の `phase: requestPath`）。パスの検証は秘密値の検査の後に行うため、秘密値を持たない要求は `403` になり、このイベントは出ません。
- `X-Forwarded-Host` か `X-Forwarded-Proto` を持つ要求は、値にかかわらず `403` で拒否します。dart:io がこれらの値から要求の URL を組み立て、パスや userinfo まで書き換えられるためです。WebView はこれらのヘッダを送りません。
- `X-Forwarded-For`、`Forwarded`、`X-Real-IP`、`X-Original-URL` など、ほかの要求元や元の URL を名乗るヘッダは、上流への転送、中継、キューへの保存、再送のいずれでも渡しません。一覧は [doc/specs.ja.md](doc/specs.ja.md) の【14】「要求元を名乗るヘッダ」を参照してください。

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

- 上流の応答の `Set-Cookie` は、Cookie Jar へ保存する前に RFC 6265 / RFC 6265bis の受け入れ規則で確かめ、外れたものは保存しません。WebView へ返す応答はこの規則の影響を受けません。
  - 要求先ホストに domain-match しない `Domain`（`domainMismatch`）、IP アドレスのホストでホストと異なる `Domain`（`ipDomain`）、`.` の無い `Domain`（`singleLabelDomain`。ホストと等しい `localhost` などはホスト限定として受け入れます）
  - 中継先（`mirroredOrigins`）の応答で、設定済み origin のホストへも送られる範囲の Cookie（`mirroredOriginDomain`）
  - `https` 以外の応答の `Secure`（`insecureSecure`）、条件を満たさない `__Secure-` / `__Host-` の名前（`securePrefix` / `hostPrefix`）、`https` 以外の応答による `Secure` の Cookie の上書き・削除と、親ドメインやパスの重なりで覆うこと（`secureOverwrite`）
  - 保存しなかった Cookie は `errorOccurred`（`operation: cookieSave`）の `reason` と `cookieName` で知らせます。値は載せません。公開サフィックスリストは使わない簡易判定です。詳しくは仕様書【4】の「上流の Set-Cookie の受け入れ規則」を参照してください。
  - `Expires` は RFC 6265 の手順で解釈し、`Wed, 21-Oct-2026 07:28:00 GMT`、2 桁の年、asctime も受け付けます。`Max-Age` は `^-?\d+$` に合う値だけを採り、不正な値は無視します。有効期限は受信から 400 日後を上限に丸めます。`Path` が空か `/` で始まらない場合は要求先のパスから求めた default-path を使います。
- `restoreCookies()` に渡す Cookie はアプリが渡す値のため、上記の受け入れ規則を適用しません。
- `queueOwnerResolver` を指定している場合は、`restoreCookies(entries, queueOwnerId: '...')` で復元するセッションの利用者を渡してください。渡さない場合と、`clearCookies()` で全件か設定済み origin のホストへ送られるドメインを消した場合は、送信待ちの持ち主が分からなくなるため、キューを `ownerUnresolved` で止めます（「端末を共用する場合」）。
- WebView が proxy へ送る Cookie は、`forwardWebViewCookieNames` に挙げた名前だけを上流へ渡します（既定は空）。上流の `Set-Cookie` は従来どおり WebView へも返し、Cookie Jar へも保存するため、上流が置いたセッションの Cookie は設定しなくても Cookie Jar から送られます。中継先（`mirroredOrigins`）の `Set-Cookie` は WebView へ返しません。
  - **0.25.0 からの移行**: ページのスクリプト（`document.cookie`）や `WebViewCookieManager` で置いた Cookie を上流へ送っていた場合は、その名前を指定します。

    ```dart
    const ProxyConfig(
      origin: 'https://api.example.com',
      // 画面のスクリプトが置く言語設定と同意の Cookie を上流へ送る
      forwardWebViewCookieNames: {'locale', 'consent'},
    )
    ```

  - どの Cookie を送っているか分からない場合は、`{'*'}` で 0.25.0 と同じ動作に戻せます。ページのスクリプトが置いた任意の Cookie を上流へ渡すため、必要な名前が分かったら一覧に置き換えてください。
  - キューに残っている 0.25.0 以前の要求も、再送の時点で同じ設定により絞ります。
  - 受け入れ規則で Cookie Jar に保存されなかった Cookie（例: `http` の上流が返す `Secure` の Cookie）は、0.25.0 までは WebView 経由で上流へ届いていましたが、0.26.0 からは上流へ送られません。保存されなかったことは `errorOccurred`（`operation: cookieSave`）の `reason` と `cookieName` で確かめられます。
- `getCookies()` の値は確認用にマスクされます。
- `getCookieHeaderForUrl()` は設定済み origin と同一 origin の URL のみ受け付けます。
- 暗号化鍵と保存データの照合は、`start()` と、起動前や停止後に呼んだ Cookie API の中で行います。詳しくは「暗号化鍵を失った場合」を参照してください。
  - 鍵を使えず（なし・読み取り不能・形式不正）中身があるのが Cookie Box だけの場合や、ほかの Box に問題が無く Cookie Box だけが鍵と合わない・先頭側が壊れている・照合を打ち切った場合は、Cookie を破棄して起動を続けます（再ログインが必要になります）。
  - キュー・隔離・ドロップ履歴の Box のどれかが鍵と合わない・先頭側が壊れている・照合を打ち切った場合と、鍵を使えず（なし・読み取り不能・形式不正）それらの Box のどれかに中身がある場合は、何も消さずに起動に失敗します。
  - 起動前や停止後に呼んだ Cookie API で照合に失敗すると、`CookieOperationException`（`cause` に `StorageIntegrityException`）を投げます。

## キャッシュ、キュー、監視 API

```dart
await proxy.clearCache();
await proxy.clearExpiredCache();
await proxy.clearCacheForUrl('https://api.example.com/app/dashboard');
// Web ストレージのスナップショットを削除する（enableWebStorageInheritance）
await proxy.clearWebStorageSnapshot();

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

// 画面が付けたべき等性キーで、要求がいまどうなっているかを調べる
final statuses = await proxy.getRequestStatuses(['3f0c...']);
print(statuses.single.state); // RequestState.queued など

// 上流に拒否されて再送を打ち切ったリクエスト
final quarantined = await proxy.getQuarantinedRequests();
for (final request in quarantined) {
  // 原因を解消したら再送、送らないと判断したら破棄する
  await proxy.retryQuarantinedRequest(request.id);
}

// 認証待ちで一時停止したキュー（authRequiredStatusCodes）は、
// ログインし直した後に再開する。通らない要求は取り除いて先へ進める
await proxy.resumeQueue();
await proxy.skipPausedRequest();

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
    // 常にクエリを含む完全な URL。起動に使い、ログへは出さない
    launchUrl(Uri.parse(event.data['externalUrl'] as String)); // url_launcher
  }
});
```

補足:

- オンライン時の GET/HEAD は upstream へ転送し、proxy キャッシュで応答を省略しません。
- proxy キャッシュはオフライン時、または上流へ到達できない GET/HEAD の代替応答に使います。接続拒否や接続切断、request timeout の超過が対象で、upstream が応答した 4xx / 5xx はそのまま返します。代替キャッシュが無い場合は 504 を返します。
- `warmupCache()` は通常時の高速化ではなく、フォールバック用レスポンスの事前取得が目的です。上流断を検知している間は待たずに失敗を返し、取得の成否は上流到達性の判定に反映します。
- `getQueuedRequests()`、`getQuarantinedRequests()`、`getDroppedRequests()` は、保存した日時（`queuedAt`、`quarantinedAt`、`droppedAt`）の古い順に並びます。
- `getQuarantinedRequests()` と `getDroppedRequests()` の `limit` は、並べた後の先頭からの件数です。
- `getQueuedRequests()` のヘッダは、機密情報を含み得るものの値を `***` に置き換えます。
  - 対象: 名前を小文字にし `_` を `-` とみなして、`cookie`、`authorization`、`proxy-authorization` と一致するもの、または `auth`、`token`、`secret`、`session`、`csrf`、`xsrf`、`key`、`pass`、`credential`、`signature`、`jwt`、`cookie` のいずれかを含むもの
  - 対象外: `idempotencyHeaderName` のヘッダ
  - 保存されるのはクライアントが送ったヘッダだけで、proxy が付けるヘッダは送信時に加えます
  - **URL のクエリは置き換えません**
  - 再送には保存した値をそのまま使います
- 一覧の項目のうち `pendingMigration` が `true` のものは、0.14.0 以前の保存領域から移行を待っている項目です（「0.14.0 以前からの移行」）。

イベントストリームでは、キャッシュヒット、キュー処理、URL 解決メタ情報に加え、redirect 処理結果も監視できます。`redirectHandled` では `redirectStatusCode`、`locationHeader`、`redirectAction`、`resolvedProxyUrl`、`externalUrl` などを参照できます。
既定では、イベントの URL（`event.url` と、`locationHeader` などの URL の項目）からクエリとフラグメントを除きます。完全な URL が必要な場合は `includeQueryInEvents: true` を指定します。ただし `redirectHandled` の `externalUrl` は、外部起動では WebView へ `204` だけが返るため、常にクエリを含む完全な URL です（地図の検索語、`mailto:` の `?subject=`、`geo:` の `?q=` など）。**`externalUrl` はアプリが実行するための値でクエリを含むため、ログへ出さないでください。** 応答をキャッシュへ保存できなかった場合の `errorOccurred`（`phase: cacheResponse`）も、例外の型名と `reason: storageFailure` だけを載せます。上流の Cookie を保存しなかった場合の `errorOccurred`（`operation: cookieSave`）は、受け入れ規則に外れた場合は `reason` に拒否理由と `cookieName` に Cookie 名を、それ以外の失敗は `error` に例外の型名と `reason` に `invalidSetCookie` か `storageFailure` だけを載せ、`Set-Cookie` の値は載せません。
接続復旧では `serverRecovered` と `serverUnavailable` が発行され、`cause`、`previousPort`、`newPort`、`downtimeMs`、`restartCount`、`probeError` を参照できます。

## 端末に保存するデータ

### 保存するデータの一覧

proxy は Hive の Box と secure storage にデータを保存します。暗号化 Box で暗号化されるのは値だけで、Box のキー（キューなどの ID、Cookie のドメイン・パス・名前）は平文のまま保存されます。**キューと隔離は、要求のヘッダと本文をそのまま保持します。**

| 保存先 | 内容 | 暗号化 | 保持期間 |
| --- | --- | --- | --- |
| `proxy_cookies_secure` | Cookie（名前、値、ドメイン、パス、有効期限、属性）。キーはドメイン、パス、名前など（UTF-8 で 255 バイトを超える場合は SHA-256） | 値のみ（AES-256） | 有効期限を過ぎたものは、送信する Cookie を探すときに削除。`clearCookies()` で削除 |
| `proxy_queue_secure` | 未送信の更新系要求（クエリを含む URL、メソッド、ヘッダ、本文、受け付けた日時、べき等性キーなど。`queueOwnerResolver` を指定した場合は持ち主の HMAC）。キーは保存した時刻から採番した ID | 値のみ（AES-256） | 送信に成功するか、隔離またはドロップ履歴へ移すまで。既定では 1000 件、50 MiB が上限で、超える要求は保存しない（「キューと要求本文の上限」） |
| `proxy_quarantined_requests_secure` | 上流が 4xx で拒否した要求。キューの内容（ヘッダと本文を含む）に、隔離した日時、ステータスコード、理由を加えたもの。`quarantineResponseBodyMaxBytes` を指定した場合は、断られた応答の本文の先頭も加える | 値のみ（AES-256） | 再送または破棄するまで。既定では 30 日、1000 件、20 MB が上限 |
| `proxy_dropped_requests_secure` | キューまたは隔離から外した要求の履歴（クエリを含む URL、メソッド、日時、理由、ステータスコード、エラーメッセージ、確認済みか）。ヘッダと本文は持たない | 値のみ（AES-256） | 既定では 30 日。件数の上限（既定 1000 件）は確認済みの履歴だけに適用 |
| `proxy_cache_index_secure`、`proxy_cache_body_secure` | 応答キャッシュ（既定）。メタデータの Box（`proxy_cache_index_secure`）にステータスコード・保存日時・有効期限・Content-Type・本文の大きさを、本文の Box（`proxy_cache_body_secure`）にヘッダ（`Set-Cookie` と `Set-Cookie2` を除く）と本文を保存する。`queueOwnerResolver` を指定した場合、利用者ごとの応答には持ち主の HMAC も保存する。キーは正規化した URL の SHA-256 | 値のみ（AES-256） | stale 期間を過ぎたものと、`cacheMaxSize` を超えた分を削除。`encryptResponseCache` を無効にすると、平文へ戻さずに削除 |
| `proxy_cache_index`、`proxy_cache_body` | `encryptResponseCache` を `false` にした場合の応答キャッシュ。内容とキーは暗号化した組と同じ | なし | 暗号化した組と同じ。明示的な消去（`clearCache()`、`clearCacheForUrl()`、1 時間ごとにも実行する `clearExpiredCache()`）の後に Box を圧縮。`cacheMaxSize` による追い出しでは圧縮しないため、追い出した記録は Hive の自動圧縮までファイルに残り得る。`encryptResponseCache` を有効にすると、暗号化した組へ移して削除 |
| `proxy_cache`、`proxy_cache_secure` | 0.21.0 以前の応答キャッシュ。1 件の値にメタデータと本文をまとめた形式。`proxy_cache_secure` は 0.21.0 で `encryptResponseCache` を有効にした場合 | `proxy_cache` はなし、`proxy_cache_secure` は値のみ（AES-256） | 起動時に新しい組へ移して削除。`encryptResponseCache` を無効にした場合、`proxy_cache_secure` は移さずに削除 |
| `proxy_web_storage_secure` | `enableWebStorageInheritance` を有効にした場合に、Web ページから受け取った Web ストレージのスナップショット（「Web ストレージのスナップショット」） | 値のみ（AES-256） | 次のスナップショットで上書きされるか、`clearWebStorageSnapshot()` で削除するまで |
| `proxy_web_storage` | 0.25.0 以前の Web ストレージのスナップショット | なし | `enableWebStorageInheritance` が有効なら起動時に `proxy_web_storage_secure` へ移して削除。無効なら移さずに削除 |
| `proxy_idempotency` | 上流へ届いたべき等性キーと、その記録日時。0.26.0 から、Box のキーは `h1:` にべき等性キーの HMAC-SHA256（保存領域の暗号化鍵から導出した鍵）を付けた値で、画面が送ったキーは保存しない。0.25.0 以前の記録（送られたキーそのまま。UTF-8 で 255 バイトを超える場合は SHA-256）も照会する | なし | `idempotencyRetention`（既定 24 時間）を過ぎたものを 1 時間ごとに削除し、削除した後に Box を圧縮。0.25.0 以前の記録も同じく消える |
| `proxy_port_preferences` | ホストごとの、直前にバインドしたポート番号。`queueOwnerResolver` を指定した場合は、現在の持ち主の HMAC、鍵の指紋、ログインを転送中かどうか | なし | ポート番号は次のバインドで上書きされるまで。持ち主は次に保存し直すまでで、鍵の指紋が合わない値は起動時に削除。持ち主の記録を書き換えるたびに Box を圧縮 |
| secure storage の `offline_web_proxy.cookie_box_encryption_key` | 暗号化 Box の鍵。Cookie、キュー、隔離、ドロップ履歴（と、有効にした場合の応答キャッシュ）で共有 | secure storage に保存 | `recoverEncryptedStorage()` が削除するか、使えない鍵（なし・読み取り不能・形式不正）を新しい鍵で上書きするまで。新しい鍵を書き込むのは、キュー・隔離・ドロップ履歴の Box に中身が無い場合（「暗号化鍵を失った場合」） |
| `proxy_queue`、`proxy_quarantined_requests`、`proxy_dropped_requests`、`proxy_cookies` | 0.14.0 以前（Cookie は 0.4.0 より前）が平文で保存した内容 | なし | 暗号化 Box へ移行した後に削除。キュー・隔離・ドロップ履歴の旧 Box は、削除の前に空にする |

### 隔離とドロップ履歴の保持上限

| 設定 | 既定 | 動作 |
| --- | --- | --- |
| `quarantineMaxCount` | 1000 件 | 超えた分を古いものからドロップ履歴へ移す（`dropReason: quarantine_limit`） |
| `quarantineRetention` | 30 日 | `quarantinedAt` から数えて過ぎたものをドロップ履歴へ移す（`quarantine_expired`） |
| `quarantineMaxBytes` | 20 MB | 本文とヘッダ、残した応答本文の先頭の概算の合計。超えた分を古いものからドロップ履歴へ移す（`quarantine_limit`） |
| `droppedRequestMaxCount` | 1000 件 | 超えた分を、確認済みの古いものから削除する。未確認は件数では消さない |
| `droppedRequestRetention` | 30 日 | `droppedAt` から数えて過ぎたものを、確認済みかどうかを問わず削除する |

- `0`（`Duration.zero`）を指定するとその上限は無くなります。負の値を指定すると `start()` が `ProxyStartException` を投げます。
- 隔離から移すときは、ドロップ履歴へ記録してから隔離から削除し、隔離時の `statusCode` と `errorMessage` を引き継ぎます。`requestDropped` に `quarantineId` が入ります。
- 1 件で `quarantineMaxBytes` を超える要求は、既存の隔離を追い出さず、隔離にも入れません。本文を捨ててドロップ履歴へ `quarantine_too_large` で記録し、キューから取り除きます。
- 「古いもの」は保存した日時（`quarantinedAt`、`droppedAt`）の順で決めます。
- 判定は、起動時、隔離やドロップ履歴を追加したとき、遅らせた移行の後、1 時間ごとに行います。
  - 0.14.0 以前から引き継いだ隔離とドロップ履歴にも適用します（「0.14.0 以前からの移行」）。
  - 起動時の判定で出したイベントは、`start()` の後に購読したアプリには届きません。`ProxyStats.unacknowledgedDroppedCount` で気付けます。
- Hive の削除は論理削除です。起動時・遅らせた移行の後・1 時間ごとの判定の後に Box を圧縮しますが、フラッシュストレージ上の完全消去は保証しません。暗号化しない Box（平文の応答キャッシュ、`proxy_idempotency`、`proxy_port_preferences`）の圧縮と、Web ストレージの Box の削除も同じです。
- Hive は Box を開くときに値をすべてメモリに読み込むため、隔離の Box を開く瞬間は `quarantineMaxBytes` の約 2 倍を使い得ます。
- キューの上限は「キューと要求本文の上限」を参照してください。

### キューと要求本文の上限

0.26.0 から、画面の不具合や悪意のある Web ページが大きな要求を送り続けても端末のメモリと保存領域を使い切らないよう、要求本文とキューに上限を設けます（0.25.0 まではどちらも上限なし）。

| 設定 | 既定 | 範囲 | 超えた場合 |
| --- | --- | --- | --- |
| `maxRequestBodyBytes` | 10 MiB | 1024〜268435456（256 MiB） | 本文が上限を超える要求は、転送もキュー保存もせず `413` を返す |
| `queueMaxCount` | 1000 件 | 1〜100000 | 保存せず `503` と `{"queued":false,"error":"queue_full"}` を返す |
| `queueMaxBytes` | 50 MiB | 1 MiB〜1 GiB | 保存せず `503` と `{"queued":false,"error":"queue_full"}` を返す |

- 範囲外の値を指定すると `start()` が `ProxyStartException` を投げます。`0` で上限を無くすことはできません。
- `413` は、オンラインでもオフラインでも同じで、キューへは入れません。`Cache-Control: no-store`、`X-Offline-Queued: 0`、`Connection: close` を付け、本文は `{"queued":false,"error":"request_body_too_large"}` です。`Content-Length` を先に見て、上限を超える本文は保持しません。クライアントが `413` を受け取れるよう、超えた分は 16 MiB まで読み捨ててから応答し、それより大きい場合は読まずに接続を閉じます（この場合、クライアントは送信の途中で接続を閉じられることがあります）。
- `enableWebStorageInheritance` の受け渡しは、`maxRequestBodyBytes` と 5 MiB の小さい方を上限にします。
- キューの大きさは、要求ごとの URL、ヘッダの名前と値の UTF-8 長と本文の長さの和です。保存する前に判定し、超える場合（1 件で `queueMaxBytes` を超える場合を含む）は保存せず、`503` と `{"queued":false,"error":"queue_full"}`、`X-Offline-Queued: 0` を返して（本文で、キューを書けない場合の `{"queued":false}` と区別できます）、`ProxyEventType.errorOccurred`（`phase: queueLimit`、`limit: count` か `bytes`）を発行します。上流が 5xx を返した更新系では、従来どおり上流の応答をそのまま返します。管理用の項目と保存形式の余分は数えないため、メモリと保存領域の使用量は目安として抑えるだけです。
- 上限を理由に既存の要求は消しません。起動時に上限を超えている場合（上限を下げた場合など）も消さず、送信や隔離で下回るまで新しい要求を断ります。隔離から戻す `retryQuarantinedRequest()` は上限で断りません。

### Web ストレージのスナップショット

`enableWebStorageInheritance` を有効にすると、画面は `/__offline_web_proxy/web_storage` を通じて Web ストレージのスナップショットを保存し、再起動の後に読み戻せます。0.26.0 から次のとおりです。

- スナップショットは暗号化 Box `proxy_web_storage_secure` に保存します。0.25.0 以前の平文の Box `proxy_web_storage` は、起動時に移して（暗号化 Box に既にあれば移さず）から、空にして圧縮し、削除します。`enableWebStorageInheritance` が無効な場合は Box を開かず、平文の Box を削除します。
- 受け付けるのは proxy 自身の origin のページからの要求だけです。比べる相手は設定済みの上流 origin ではなく proxy 自身（`http`、要求を受けたポート、`Host` の検査で受け付けるホスト名。`127.0.0.1` と `localhost` は同じとみなす）です。
  - `POST` は `Origin` が必須です。`GET` は `Origin` が無ければ受け付けます。
  - `Sec-Fetch-Site` があり、`same-origin` と `none` 以外の要求は `403` で断ります。
  - `GET` と `POST` 以外のメソッドは `405`（`Allow: GET, POST`）です。
- 応答にはすべて `Cache-Control: no-store` を付けます。内部エンドポイントとして扱い、CORS ヘッダを付けず、統計にも数えません。
- `enableWebStorageInheritance` が無効な場合、このパスは `404` を返し、上流へは転送しません。
- `requireAccessToken: false` にすると、端末内の別アプリが `Origin` の無い `GET` でスナップショットを読めます。`enableWebStorageInheritance` を有効にする場合は、`requireAccessToken` を有効のままにしてください。
- 暗号化 Box が壊れている場合は作り直し、`errorOccurred`（`phase: webStorageRecovery`）で知らせて起動を続けます。
- 平文の Box の移行に失敗した場合と、無効な設定で平文の Box を削除できなかった場合は、起動を止めず、`errorOccurred`（`phase: webStorageMigration`、`error` は例外の型名）で知らせます。平文の Box は残り、次の起動でやり直します。
- `clearWebStorageSnapshot()` でスナップショットを削除できます（サインアウトや端末の引き渡しの前など）。Box を開いている間は空にして圧縮し、開いていなければ新旧の Box のファイルを削除します。稼働中かどうかによらず呼び出せます。失敗した場合は `CacheOperationException`（`operation: clearWebStorageSnapshot`）を投げます。

### 暗号化鍵を失った場合

暗号化 Box は、secure storage に保存した 1 つの鍵を共有します。Hive は鍵が合わない Box を開くと中身を切り詰めるため、proxy は Box を開く前にファイルを読んで鍵と照合し、次のように扱います。照合は `start()` と、起動前や停止後に呼んだ Cookie API の中で行います（`stop()` の後は、次の `start()` か Cookie API で照合し直します）。

| 状況 | 動作 |
| --- | --- |
| 端末のロック中（iOS / macOS）などで、鍵を一時的に読めない | `StorageIntegrityException`（`temporarilyUnavailable`）で起動に失敗する。何も消さない |
| 鍵があり、中身のある暗号化 Box がすべて鍵と合う（0.14.0 からの通常の更新） | そのまま起動する |
| どの暗号化 Box にも中身が無い（0.14.0 からの更新で Cookie Box が空の場合を含む） | 鍵があればそのまま起動する。鍵が無い・読み取り不能・形式不正の場合は、新しい鍵を書き込んで起動する |
| 鍵があり、キュー・隔離・ドロップ履歴の Box に問題が無く、Cookie Box が鍵と合わない・先頭側が壊れている・照合を打ち切った | Cookie Box を破棄して起動を続ける。再ログインが必要になる |
| 鍵を使えず（なし・読み取り不能が続く・形式不正）、中身があるのが Cookie Box だけ | Cookie Box を破棄し、新しい鍵を書き込んで起動を続ける。再ログインが必要になる |
| 鍵があり、キュー・隔離・ドロップ履歴の Box のどれかが鍵と合わない・先頭側が壊れている・照合を打ち切った | `StorageIntegrityException` で起動に失敗する。何も消さない |
| 鍵を使えず、キュー・隔離・ドロップ履歴の Box のどれかに中身がある | `StorageIntegrityException` で起動に失敗する。何も消さない |

- Cookie Box を破棄したときは、`ProxyEventType.cookieStorageDiscarded` を発行し、`data['reason']` に理由を入れます。
  - 破棄は `start()` や、起動前・停止後に呼んだ Cookie API の中で起きるため、後から購読したアプリにはイベントが届きません。
  - 起動後は `getDiagnostics()` の `lastCookieStorageDiscardedAt` と `lastCookieStorageDiscardReason` で確認してください。
  - 復旧 API による削除では、このイベントを発行せず、診断情報も変えません。
- 照合で問題が無くても Hive が開けない、または Cookie として読めない値がある Cookie Box（途中の記録が壊れている）は、`corrupted` として破棄して起動を続けます。0.21.0 以前の版が、UTF-8 で 255 バイトを超えるキーで書いた記録が該当します。べき等性キーの記録（`proxy_idempotency`）が同じ理由で開けない、または記録日時として読めない値がある場合は、作り直して起動を続け、`errorOccurred`（`phase: idempotencyStoreRecovery`）で知らせます。
  - Hive は開けなかった例外を、proxy が捕まえた後もゾーンの未処理の例外として報告します。この起動では、アプリのエラー報告（Crashlytics など）に `HiveError` などが記録されることがあります。
- 起動前や停止後に呼んだ Cookie API（`restoreCookies()` など）で照合に失敗すると、`CookieOperationException` を投げ、その `cause` に `StorageIntegrityException` が入ります。失敗は保持せず、次の呼び出しや `start()` で照合をやり直します。
- `StorageIntegrityException.failure` は次の理由を表します。
  - `temporarilyUnavailable`: iOS / macOS の端末のロック中など、保護データを読めない状態です。読み取りの結果を鍵の有無の判定に使いません
  - `keyUnreadable`: 鍵の読み取りが例外で失敗し続けています
  - `keyMissing`: 鍵がありません
  - `keyInvalid`: 鍵の形式が正しくありません（空文字、Base64 として読めない、または 32 バイトでない）。鍵は末尾の改行などの ASCII の空白を除いてから読み、エラーには鍵の文字列を含めません
  - `keyMismatch`、`corrupted`、`verificationAborted`: 鍵と合わない Box、先頭側が壊れた Box、照合が時間の上限を超えた Box があります
  - `keyWriteFailed`: 新しい鍵を書き込めませんでした
- 中身のある暗号化 Box があり、鍵が無いか読み取り不能の場合は、500 ミリ秒間隔で 3 回まで読み直します。1 回でも読めればその値を使います。結果が `null` と例外で入り混じる場合や、途中で端末がロックされた場合は、一時的に読めないものとして扱います。
- 先頭の記録が鍵と合わない、または書きかけで照合できない Box は、ファイル全体から鍵と合う記録を別の isolate で探します。
  - 後ろに合う記録があれば、先頭側が壊れた Box です。
  - 合う記録が無く、先頭の記録が鍵と合わなければ、鍵と合わない Box です。
  - 合う記録が無く、先頭の記録が書きかけであれば、最初の書き込みの途中で止まった Box とみなして、そのまま開きます。
  - 探す時間は Box ごとに 10 秒までで、4 つの Box を順に照合します。超えた場合は照合を打ち切ります。
  - キュー・隔離・ドロップ履歴の Box が、先頭側が壊れている・鍵と合わない・照合を打ち切ったのどれかに当たると、何も消さずに起動に失敗します（`corrupted`、`keyMismatch`、`verificationAborted`）。Cookie Box だけが当たる場合は、Cookie Box を破棄して起動を続けます。
- 先頭側が壊れたキュー・隔離・ドロップ履歴の Box を起動時に自動で直さないのは、先頭側の記録が失われるためです。利用者の確認を経て `recoverEncryptedStorage()` を呼んでください。
- `temporarilyUnavailable` と `keyWriteFailed` は、復旧 API では直りません。時間をおいて `start()` を再試行してください。

### 暗号化した保存領域の復旧

`recoverEncryptedStorage()` は、`start()` が `StorageIntegrityException` で失敗し、再試行しても続く場合に、失われる内容を利用者へ説明し、同意を得てから呼びます。

```dart
// start() の再試行を済ませても StorageIntegrityException が続く場合の例
try {
  await proxy.start(config: config);
} on StorageIntegrityException catch (error) {
  if (error.failure == StorageIntegrityFailure.temporarilyUnavailable ||
      error.failure == StorageIntegrityFailure.keyWriteFailed) {
    // 復旧 API では直らないため、時間をおいて start() を再試行する
    rethrow;
  }

  // 失われる内容を利用者へ説明し、同意を得られた場合だけ復旧する。
  // askUserToConfirm はアプリで用意する仮の関数
  if (!await askUserToConfirm(error.failure)) {
    rethrow;
  }
  final result = await proxy.recoverEncryptedStorage();
  if (!result.performed &&
      result.rejection != StorageRecoveryRejection.startWillSucceed) {
    // temporarilyUnavailable / proxyActive / verificationTimedOut: 時間をおいて再試行する
    rethrow;
  }
  await proxy.start(config: config);
}
```

- 復旧 API は、削除の直前に、`start()` と同じく鍵を読み直し、同じ時間の上限で照合して、次のように扱います。
  - 鍵があり、キュー・隔離・ドロップ履歴の Box に問題が無い場合は、何もせずに `startWillSucceed` を返します。Cookie Box だけの問題は、`start()` が破棄して続けるためです。
  - 鍵があり、キュー・隔離・ドロップ履歴の Box のどれかに問題がある場合は、鍵を残し、Box ごと（Cookie Box を含む）に次のように扱います。
    - 鍵と合わない Box は削除します（`deletedBoxes`）。
    - 先頭側が壊れた Box は、鍵と合う最初の記録から後ろを残して作り直します（`rebuiltBoxes`）。**先頭側の記録は件数不明のまま失われます。**
    - 照合が時間の上限を超えた Box は、Box を閉じた後に Box ごとに 2 分を上限として照合し直し、その結果で扱います。先頭側が壊れた Box も、作り直す位置を求めるために同じく照合し直します。
      - 鍵と合わなければ削除します（`deletedBoxes`）。
      - 先頭側が壊れていれば作り直します（`rebuiltBoxes`）。
      - 先頭の記録が書きかけで、鍵と合う記録も無ければ、0 バイトに切り詰めます（`rebuiltBoxes`）。開けば Hive も同じく切り詰めるため、失うものはありません。
    - 問題の無い、中身のある Box は残します（`keptBoxes`）。
  - 鍵の形式が正しくない場合、または鍵なし・読み取り不能の場合（中身のある暗号化 Box があれば、読み直しても続く場合）は、次のように扱います。
    - キュー・隔離・ドロップ履歴の Box のどれかに中身があれば、暗号化 Box（Cookie・キュー・隔離・ドロップ履歴）をすべて削除してから鍵を削除します（`keyDeleted`）。**Cookie（ログイン状態）も消えます。**
    - キュー・隔離・ドロップ履歴の Box のどれにも中身が無ければ（中身があるのが Cookie Box だけの場合や、どの Box にも中身が無い場合）、何も消さずに `startWillSucceed` を返します。`start()` が Cookie Box を破棄するか、新しい鍵を書き込んで続けるためです。鍵を書き込めずに起動に失敗した場合（`keyWriteFailed`）も、これに当たります。
  - 鍵を一時的に読めない場合は `temporarilyUnavailable`、この isolate の proxy が稼働中または起動処理中の場合は `proxyActive`、照合し直しが 2 分を超えた場合は `verificationTimedOut`（0.26.0 で追加）を返し、どの場合も何も削除・作り直ししません。
  - 鍵を使えない場合の経路では、削除する鍵で暗号化した応答キャッシュと Web ストレージのスナップショットも削除します（戻り値の一覧には含めません）。
- 暗号化された記録の件数は分からないため、戻り値にも含めません。**`StorageIntegrityException` で起動に失敗した後の `getStats()` は、キュー・隔離・ドロップ履歴の件数に 0 を返すため、確認画面の根拠に使わないでください。**
- 読み取り不能（`keyUnreadable`）や鍵なし（`keyMissing`）は、再試行しても続く場合に復旧します。Android でバックアップから復元した端末は、どちらにも当たり得ます（実機では未確認）。
- 0.14.0 以前の平文の Box は削除しません。
- 復旧の後は、プロセスを再起動せずに `start()` を呼べます。
- Box のファイルや鍵を削除できないなど、予期しない失敗は `StorageRecoveryException` を投げます。
  - 再実行すれば、残りを処理します。前回までに削除や作り直しを済ませた Box は、今回の戻り値の `deletedBoxes` と `rebuiltBoxes` には含まれません。
  - 鍵を使えない場合の経路で、暗号化 Box を消した後に鍵の削除だけが失敗していた場合は、再実行は `startWillSucceed` を返します。使えない鍵は次の `start()` が作り直します。
- ホストアプリが既定の設定の `FlutterSecureStorage().deleteAll()` を呼ぶと、この鍵も消えます。

### 0.14.0 以前からの移行

0.15.0 から、キュー・隔離・ドロップ履歴は別名の暗号化 Box（`proxy_queue_secure`、`proxy_quarantined_requests_secure`、`proxy_dropped_requests_secure`）に保存します。0.14.0 以前の平文の Box（`proxy_queue`、`proxy_quarantined_requests`、`proxy_dropped_requests`）は自動で移行し、キーを保つため `X-Offline-Queue-Id` と隔離の ID は変わりません。

- 鍵が既にある場合（0.14.0 からの通常の更新）は、`start()` の中で再送を始める前に移行します。
- その proxy インスタンスで鍵を生成した場合（起動前の Cookie API の中で生成した場合を含む）は、プラットフォームを問わず、鍵の生成から 30 秒後へ移行を遅らせます。
  - Android の secure storage はディスクへ非同期に書き込むため、同じプロセスで読み直しても書き込みの確認になりません。
  - iOS などで書き込みがその場で確定するかも、実機では未確認です。
  - 書き込みの確定を確かめる手段が無いため、待ち時間を置いています。待っても確定は保証されません（実機では未確認）。
- 移行を待つ間の扱い
  - 暗号化したキューの再送は止めません。旧キューの項目は移行するまで送らないため、後回しになります。移行後は保存した日時の順に送ります。
  - `getStats()`、状態通知の件数、`getQueuedRequests()` などの一覧には旧 Box の分を含め、その項目の `pendingMigration` を `true` にします。
  - 旧 Box の隔離は再送も破棄もできません。`retryQuarantinedRequest()` と `discardQuarantinedRequest()` は `false` を返し、管理 API は `409` を返します。
  - `acknowledgeDroppedRequests()`、`clearQuarantinedRequests()`、`clearDroppedRequests()` は旧 Box にも適用します。
- 旧 Box のファイルを削除できなかった場合は、中身を空にしたうえで処理を続け、`errorOccurred`（`operation: legacyStorageDelete`）を発行します。
  - `start()` の中で旧 Box を削除した場合（鍵が既にある場合の移行と、空のまま残った旧 Box の削除）、このイベントは `start()` の後に購読したアプリには届きません。
  - 空のまま残った旧 Box は、次の `start()` で改めて削除します。
- **保持上限の既定値は、0.14.0 以前から引き継いだ隔離とドロップ履歴にも、更新後の最初の起動で適用されます**（移行を遅らせた場合は移行の後）。
  - 上限を超えた隔離は、本文とヘッダを残さずにドロップ履歴へ移ります。
  - 30 日を過ぎたドロップ履歴は、未確認でも消えます。件数の上限を超えた確認済みの履歴も消えます。
  - 残したい場合は、該当する設定（`quarantineMaxCount`、`quarantineRetention`、`quarantineMaxBytes`、`droppedRequestMaxCount`、`droppedRequestRetention`）に `0`（期間は `Duration.zero`）を指定してください。
- **0.14.0 以前へ戻すと、移行済みのキュー・隔離・ドロップ履歴は見えなくなります。**
  - 戻している間は、移行済みの未送信キューは送られません。
  - 再び 0.15.0 以降へ上げると、戻している間に積んだ分も含めて移行します。
- 旧平文 Cookie Box（`proxy_cookies`）は、`start()` または起動前・停止後の Cookie API で保存領域を初期化するときに移行します（従来どおり）。0.15.0 からは、暗号化 Box に同じ Cookie があれば上書きしません。

### Android の自動バックアップ

Android の自動バックアップ（Auto Backup）の対象には、Hive の保存先と secure storage の保存領域が含まれ得ます（実機では未確認）。バックアップから復元した端末では、復元した暗号化 Box に対して、鍵の読み取り不能（`keyUnreadable`）や鍵なし（`keyMissing`）になるおそれがあります（どちらも実機では未確認）。アプリ側で、これらをバックアップの対象から除外することを推奨します。

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

- Hive は値を AES-256-CBC で暗号化しますが、メッセージ認証コード（MAC）は付けません。CRC で偶発的な破損は検出しますが、暗号化 Box の改ざんは改ざんとして検出できず、細工したファイルで値を読めなくしたり、別の値として読ませたりできます。proxy は鍵を secure storage に置き、ファイルの保護はアプリのサンドボックスに頼ります。

- 1 つの `OfflineWebProxy` インスタンスが業務要求を転送する上流 origin は 1 つです。資源だけを配信する別 origin は `mirroredOrigins` で中継できますが、`GET` と `HEAD` に限られます。
- サポートされる設定経路は `ProxyConfig` です。外部 YAML の自動読込は未実装です。
- `assets/static/` から配信できるのは `GET` と `HEAD` だけです。同名パスへの更新系は静的扱いにせず上流へ転送します。Range 要求には対応していません。
- `AssetManifest.json` または実行環境上の同等 manifest を読み込めない場合は、静的リソースを一覧化せず、通常の upstream 解決へフォールバックします。
- 同じアプリで複数の `OfflineWebProxy` インスタンスを同時に使う構成は想定していません。保存領域の初期化と復旧は、同じ isolate の中ではインスタンスをまたいで直列化しますが、キュー消化・保持上限・移行の排他と、送信待ちの持ち主（`queueOwnerResolver`）はインスタンスごとです。Cookie はインスタンス間で共有するため、あるインスタンスでのログインは別のインスタンスのセッションも変えます。**そのため、別のインスタンスのキューは、前の持ち主の要求を新しいセッションで送ることがあります（`queueOwnerResolver` で保護されません）。** 複数の isolate から同時に使う場合は、保存領域の初期化と復旧も直列化の対象になりません。

## サンプルと参照先

- `example/` に WebView delegate 連携のサンプルがあります。
- API リファレンスは [pub.dev](https://pub.dev/documentation/offline_web_proxy/latest/) で公開しています。
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

### 自動復帰のスクリプトの回帰テスト

オフライン代替ページの自動復帰のスクリプトは、ヘッドレス Chrome で動作を確かめます。Node.js と、Chrome、Chromium、Microsoft Edge のいずれかが必要です（Node.js 24 と Chrome で動作を確認）。CI では `Recovery Script Test` job が同じ手順を実行します。

```bash
dart run tool/offline_recovery_harness/generate_pages.dart build/offline_recovery_harness
node tool/offline_recovery_harness/run.mjs build/offline_recovery_harness
```

- 環境変数 `CHROME_PATH` を指定すると、そのブラウザを使います。指定が無ければ標準のインストール先から探します。
- `run.mjs` に渡すディレクトリの後ろにシナリオ名を並べると、そのシナリオだけを実行します。シナリオ名は `run.mjs` の `buildScenarios` に並んでいます（例: `node tool/offline_recovery_harness/run.mjs build/offline_recovery_harness queue_wait_timeout`）。
- すべてのシナリオの実行には、Windows での実測で約 3 分半かかりました。

### example の e2e

`example/integration_test/` の e2e は CI では実行しません。Android の実機またはエミュレータで、ファイルを指定して実行します（この手順はエミュレータで確認）。

```bash
cd example
flutter test integration_test/offline_web_proxy_offline_page_recovery_e2e_test.dart -d <デバイス ID>
```

デバイス ID は `flutter devices` で確認できます。

`offline_web_proxy_storage_e2e_test.dart` は、テストごとに example アプリの Cookie・キュー・隔離・ドロップ履歴の Box（暗号化前の Box を含む）と暗号化鍵を削除してから始めます。1 件目は旧平文キューの移行の待ち時間（30 秒）を待つため、30 秒以上かかります。

他の e2e は、`requireAccessToken` が既定で有効なため、読み込む前に `WebViewCookieManager` で秘密値の Cookie を置きます（`integration_test/support/access_token.dart`）。

`offline_web_proxy_access_token_e2e_test.dart` は、`requireAccessToken` を有効にした proxy を WebView から使う手順を確かめます。秘密値の Cookie は Android の `CookieManager` で HttpOnly として置きます。最後のテストは `OWP_E2E_EXTERNAL_PROBE_PORT=<ポート>` を出力してから 40 秒待ちます。その間に `adb shell` の `nc` など別プロセスから稼働確認以外のパス（`/page` など）へ要求を送ると、`403` になり上流へ届かないことを確かめられます。要求はテストの外から手動で送ります（送らなくてもテストは通ります）。このテストは HttpOnly を指定するため `webview_flutter_android` の `src/` 配下を直接読み込んでおり、プラグインの更新で動かなくなることがあります。

### 依存関係の更新

依存関係の更新は Dependabot（`.github/dependabot.yml`）が毎週月曜 10:00（UTC）に PR を作ります。対象はパッケージ本体と `example/` の pub、GitHub Actions です。

- pub の minor / patch の更新は、本体と `example/` でそれぞれ 1 本の PR にまとめます。major の更新は依存ごとに個別の PR になります。GitHub Actions は major も含めて 1 本の PR にまとめます
- PR には通常の CI（Flutter 3.22.0 / 3.24.0 のテスト、静的解析、パッケージ検証）が走ります。通ったものだけを取り込みます
- 既知の脆弱性は、リポジトリ設定で有効にした Dependabot alerts が検知し、Dependabot のセキュリティ更新が修正の PR を作ります
- `example/` の e2e（`integration_test/`）は CI で走りません。`example/` の PR で WebView 系（`webview_flutter` など）が更新された場合は、取り込む前にエミュレータで e2e を実行します（「example の e2e」）
- 次の更新は Dependabot の対象外です。手動で上げます
  - `flutter_secure_storage` の major: 暗号化鍵を保存しているため、保存形式の互換性を確かめてから上げます
  - 本体と `example/` で共通の依存（`flutter_secure_storage`、`hive_flutter`、`http`、`flutter_lints`）の major: 片方だけ上がると `example/` の依存解決に失敗するため、`pubspec.yaml` と `example/pubspec.yaml` を同じ PR で同じ版に上げます
  - Flutter 3.22.0（Dart 3.4）で使えない版（`flutter_lints` 5 以降、`webview_flutter` 4.10.0 以降）: サポートする最低 Flutter を上げるときに、`.github/dependabot.yml` の ignore とあわせて見直します

## リリース手順

- 先に `pubspec.yaml` と `CHANGELOG.md` を更新し、その変更を `main` へコミットします。
- リリース時にローカルで `dart pub publish` を直接実行しません。このリポジトリは GitHub Actions の `release` job 経由で公開します。
- `v0.8.0` のようなバージョンタグを作成して push します。`v*` タグ push を契機に GitHub Actions が検証、pub.dev 公開、GitHub Release 作成を実行します。

## ライセンス

MIT License
