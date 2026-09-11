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
  offline_web_proxy: ^0.15.0
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
  droppedRequestMaxCount: 1000,
  droppedRequestRetention: Duration(days: 30),
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
  enableOfflinePageAutoReload: true,
  enableAutoReloadContinuation: true,
  enableGatewayTimeoutAutoReload: false,
  autoReloadPollInterval: Duration(seconds: 3),
  autoReloadQueueWaitTimeout: Duration(seconds: 10),
);
```

補足:

- `origin` は必須で、絶対 HTTP URL または HTTPS URL である必要があります。
- パスを指定する設定（`forceCachePaths` など）は共通の glob 記法で照合します。`*` は `/` を含まない 1 セグメント、`**` は `/` を含む任意の文字列に一致し、メタ文字が無い場合は完全一致です。クエリ文字列は照合対象に含みません。
- `port: 0` を指定すると、OS が空きポートを自動割り当てします。
- `preferredPort` を指定すると、まずそのポートを試し、使えない場合は自動割り当てへフォールバックします。直前に成功したポートも次回起動時に再利用されるため、WebView の origin をより安定させやすくなります。
- `startupPaths` は `warmupCache()` で、オフライン時または上流到達不能時の代替応答を事前準備したいパスに使います。
  - ウォームアップは転送経路と同じく Cookie Jar の内容を送ります。認証後に呼び出せば、認証が必要な API も取得できます。
  - `warmupCache(followReferences: true)` を指定すると、取得した HTML が参照する資源（`<script src>`、`<link href>`、`<img src>`）も続けて取得します。対象は同一 origin と `mirroredOrigins` に列挙した origin です。1 段だけ辿り、実行時に JavaScript が組み立てる URL には届きません。`<link>` は `stylesheet` など資源を指す `rel` だけを対象とします。
- `healthCheckPath` は稼働確認専用のパスです。この URL は上流へ転送されず、統計にも計上されません。`GET` と `HEAD` は要求ログにも出力しません。Web アプリのルートと衝突する場合に変更します。
- `statusPath` は proxy の状態を JSON で返すパスです。`healthCheckPath` と同じ扱いで、上流へ転送されず、統計にも計上されず、`GET` は要求ログにも出力しません。空文字列を指定すると無効になり、代替ページと `504` ページの自動復帰も止まります。
- `enableAdminApi` を `true` にすると、隔離キューの一覧・再送・破棄を HTTP から操作できます。既定は無効です。
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
- `dropPolicy` は、上流が 4xx で拒否した更新系リクエストの扱いです。既定の `quarantine` では本文を保持したまま隔離し、`getQuarantinedRequests()` で確認して再送または破棄を判断できます（1 件で `quarantineMaxBytes` を超える要求は隔離せず、本文を捨ててドロップ履歴へ `quarantine_too_large` で記録します）。`drop` を指定すると従来どおり破棄し、履歴のみ残します。
- `quarantineMaxCount`（既定 1000 件）、`quarantineRetention`（既定 30 日）、`quarantineMaxBytes`（既定 20 MB）、`droppedRequestMaxCount`（既定 1000 件）、`droppedRequestRetention`（既定 30 日）は、隔離とドロップ履歴の保持上限です。`0`（`Duration.zero`）を指定するとその上限は無くなり、負の値を指定すると `start()` が `ProxyStartException` を投げます。「隔離とドロップ履歴の保持上限」を参照してください。
- `enableIdempotencyKey` は更新系リクエストへのべき等性キー付与です。最初の転送と再送で同じキーを送るため、応答を受け取れなかったリクエストが再送で二重に適用されることを上流側で防げます。**重複の排除自体は上流サーバでの実装が必要です。**
- `forceCachePaths` は `Cache-Control: no-store` を無視して保存するパスです。全応答に `no-store` を付与するサーバでは、既定のままだとオフラインで返せる応答が残りません。既定は空で、指定が無い限り従来どおり保存しません。全体を一括で無効化する設定は用意していません。
  - 一致しても、応答に `Set-Cookie` がある場合、応答に `Vary` がある場合（`Accept-Encoding` だけを指す場合を除く）、またはリクエストに `Authorization` がある場合は保存しません。除外したときは `ProxyEventType.cacheSkipped` を理由付きで発行するため、オフラインで使えない原因を追跡できます。
  - `Vary` が `Accept-Encoding` だけを指す場合に保存するのは、proxy が上流へ `Accept-Encoding: identity` を固定で送るため応答が割れないからです。Tomcat、nginx、Apache は圧縮を有効にするとこの `Vary` を既定で付けるため、除外すると画面の HTML、JS、CSS がまとめて対象外になります。`*` や他のヘッダ名を含む場合は除外します。
  - 一致したパスでは上流の `max-age` や `Expires` を使わず、`cacheTtl` の値を有効期限に使います。`no-store` は `max-age=0` と併記されることが多く、そのまま採用すると保存直後に stale になるためです。
  - **応答キャッシュは暗号化していません。** 指定したパスの応答本文は端末内に平文で残るため、画面が含む情報を踏まえて指定してください。
- `mirroredOrigins` は、proxy 経由で取得する別 origin の一覧です。CDN から UI ライブラリを読み込む画面では、HTML 内の絶対 URL が 127.0.0.1 を経由せず、キャッシュもフォールバックもウォームアップも効きません。列挙した origin は proxy が中継し、通常のキャッシュとオフライン代替の対象になります。既定は空です。
  - proxy が返す `text/html` の `<script src>`、`<link href>`、`<img src>` のうち、一致する絶対 URL を `/__offline_web_proxy/ext/<scheme>/<host>[:port]/<元のパス>` へ書き換えます。`<link>` は `stylesheet` など資源を指す `rel` だけが対象です。
  - 書き換えの判定はウォームアップの参照抽出と同じです。**書き換えた資源は必ず `warmupCache(followReferences: true)` の対象になります**。
  - 書き換えは保存時ではなく応答時に行うため、オフラインでキャッシュから返す HTML にも同じ変換がかかります。設定から origin を外せば元の URL に戻ります。
  - 中継するのは `GET` と `HEAD` だけです。ほかのメソッドは `405` を返し、キューにも載せません。許可していない origin を指すパスは `404` を返し、設定済み origin へ素通ししません。
  - 一致判定はスキーム、ホスト、ポートの完全一致です。パスやクエリを含む値を指定すると起動時に `ProxyStartException` になります。
  - **中継先へは `Authorization`、`Origin`、`Referer` とクライアントの `Cookie` を送りません。** Cookie Jar のうち中継先のドメインに一致するものだけを送ります。
  - 実行時に JavaScript が組み立てる URL には届きません。`Content-Security-Policy` を返す画面では、書き換え後の URL が proxy と same-origin になるため `'self'` の許可が必要です。`assets/static/` から配信する同梱 HTML は書き換えの対象外です。
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
- 状態通知の `GET` と稼働確認の `GET` / `HEAD` は、要求ログ（`shelf.logRequests`）に出力しません。

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

- `GET` のみで、上流へは転送されず、統計にも計上されず、要求ログにも出力されません。
- proxy 自身の origin からの要求だけを受け付けます。別 origin の `Origin` を伴う要求には `403` を返し、`Access-Control-Allow-Origin: *` も付与しません。
- `statusPath` に空文字列を指定すると無効になります。代替ページと `504` ページの自動復帰も止まります。
- `queueLength`、`quarantinedCount`、`unacknowledgedDroppedCount` には、0.14.0 以前の保存領域から移行を待っている分も含みます（「0.14.0 以前からの移行」）。

### 隔離キューを画面から操作する

4xx で隔離された会計は、原因（棚卸の締めなど）を解いてから再送します。操作するのが店舗の人であれば、`enableAdminApi: true` で HTTP からも操作できます。

| メソッド | パス | 用途 |
| --- | --- | --- |
| `GET` | `/__offline_web_proxy/admin/quarantine` | 隔離の一覧（本文は返しません） |
| `POST` | `/__offline_web_proxy/admin/quarantine/<id>/retry` | キューへ戻して再送 |
| `DELETE` | `/__offline_web_proxy/admin/quarantine/<id>` | 破棄 |

- 一覧は隔離した日時（`quarantinedAt`）の古い順に並び、各項目は `pendingMigration` を持ちます。
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
- 暗号化鍵と保存データの照合は、`start()` と、起動前や停止後に呼んだ Cookie API の中で行います。詳しくは「暗号化鍵を失った場合」を参照してください。
  - 鍵を使えず（なし・読み取り不能・形式不正）中身があるのが Cookie Box だけの場合や、ほかの Box に問題が無く Cookie Box だけが鍵と合わない・先頭側が壊れている・照合を打ち切った場合は、Cookie を破棄して起動を続けます（再ログインが必要になります）。
  - キュー・隔離・ドロップ履歴の Box のどれかが鍵と合わない・先頭側が壊れている・照合を打ち切った場合と、鍵を使えず（なし・読み取り不能・形式不正）それらの Box のどれかに中身がある場合は、何も消さずに起動に失敗します。
  - 起動前や停止後に呼んだ Cookie API で照合に失敗すると、`CookieOperationException`（`cause` に `StorageIntegrityException`）を投げます。

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
接続復旧では `serverRecovered` と `serverUnavailable` が発行され、`cause`、`previousPort`、`newPort`、`downtimeMs`、`restartCount`、`probeError` を参照できます。

## 端末に保存するデータ

### 保存するデータの一覧

proxy は Hive の Box と secure storage にデータを保存します。暗号化 Box で暗号化されるのは値だけで、Box のキー（キューなどの ID、Cookie のドメイン・パス・名前）は平文のまま保存されます。**キューと隔離は、要求のヘッダと本文をそのまま保持します。**

| 保存先 | 内容 | 暗号化 | 保持期間 |
| --- | --- | --- | --- |
| `proxy_cookies_secure` | Cookie（名前、値、ドメイン、パス、有効期限、属性）。キーはドメイン、パス、名前など | 値のみ（AES-256） | 有効期限を過ぎたものは、送信する Cookie を探すときに削除。`clearCookies()` で削除 |
| `proxy_queue_secure` | 未送信の更新系要求（クエリを含む URL、メソッド、ヘッダ、本文、受け付けた日時、べき等性キーなど）。キーは保存した時刻から採番した ID | 値のみ（AES-256） | 送信に成功するか、隔離またはドロップ履歴へ移すまで。上限なし |
| `proxy_quarantined_requests_secure` | 上流が 4xx で拒否した要求。キューの内容（ヘッダと本文を含む）に、隔離した日時、ステータスコード、理由を加えたもの | 値のみ（AES-256） | 再送または破棄するまで。既定では 30 日、1000 件、20 MB が上限 |
| `proxy_dropped_requests_secure` | キューまたは隔離から外した要求の履歴（クエリを含む URL、メソッド、日時、理由、ステータスコード、エラーメッセージ、確認済みか）。ヘッダと本文は持たない | 値のみ（AES-256） | 既定では 30 日。件数の上限（既定 1000 件）は確認済みの履歴だけに適用 |
| `proxy_cache` | 応答キャッシュ（ステータスコード、ヘッダ、本文、有効期限）。キーは正規化した URL の SHA-256 | なし | stale 期間を過ぎたものを 1 時間ごとに削除 |
| `proxy_web_storage` | `enableWebStorageInheritance` を有効にした場合に、Web ページから受け取った Web ストレージのスナップショット | なし | 次のスナップショットで上書きされるまで |
| `proxy_idempotency` | 上流へ届いたべき等性キーと、その記録日時 | なし | `idempotencyRetention`（既定 24 時間）を過ぎたものを 1 時間ごとに削除 |
| `proxy_port_preferences` | ホストごとの、直前にバインドしたポート番号 | なし | 次のバインドで上書きされるまで |
| secure storage の `offline_web_proxy.cookie_box_encryption_key` | 暗号化 Box の鍵。Cookie、キュー、隔離、ドロップ履歴で共有 | secure storage に保存 | `recoverEncryptedStorage()` が削除するか、使えない鍵（なし・読み取り不能・形式不正）を新しい鍵で上書きするまで。新しい鍵を書き込むのは、キュー・隔離・ドロップ履歴の Box に中身が無い場合（「暗号化鍵を失った場合」） |
| `proxy_queue`、`proxy_quarantined_requests`、`proxy_dropped_requests`、`proxy_cookies` | 0.14.0 以前（Cookie は 0.4.0 より前）が平文で保存した内容 | なし | 暗号化 Box へ移行した後に削除。キュー・隔離・ドロップ履歴の旧 Box は、削除の前に空にする |

### 隔離とドロップ履歴の保持上限

| 設定 | 既定 | 動作 |
| --- | --- | --- |
| `quarantineMaxCount` | 1000 件 | 超えた分を古いものからドロップ履歴へ移す（`dropReason: quarantine_limit`） |
| `quarantineRetention` | 30 日 | `quarantinedAt` から数えて過ぎたものをドロップ履歴へ移す（`quarantine_expired`） |
| `quarantineMaxBytes` | 20 MB | 本文とヘッダの概算の合計。超えた分を古いものからドロップ履歴へ移す（`quarantine_limit`） |
| `droppedRequestMaxCount` | 1000 件 | 超えた分を、確認済みの古いものから削除する。未確認は件数では消さない |
| `droppedRequestRetention` | 30 日 | `droppedAt` から数えて過ぎたものを、確認済みかどうかを問わず削除する |

- `0`（`Duration.zero`）を指定するとその上限は無くなります。負の値を指定すると `start()` が `ProxyStartException` を投げます。
- 隔離から移すときは、ドロップ履歴へ記録してから隔離から削除し、隔離時の `statusCode` と `errorMessage` を引き継ぎます。`requestDropped` に `quarantineId` が入ります。
- 1 件で `quarantineMaxBytes` を超える要求は、既存の隔離を追い出さず、隔離にも入れません。本文を捨ててドロップ履歴へ `quarantine_too_large` で記録し、キューから取り除きます。
- 「古いもの」は保存した日時（`quarantinedAt`、`droppedAt`）の順で決めます。
- 判定は、起動時、隔離やドロップ履歴を追加したとき、遅らせた移行の後、1 時間ごとに行います。
  - 0.14.0 以前から引き継いだ隔離とドロップ履歴にも適用します（「0.14.0 以前からの移行」）。
  - 起動時の判定で出したイベントは、`start()` の後に購読したアプリには届きません。`ProxyStats.unacknowledgedDroppedCount` で気付けます。
- Hive の削除は論理削除です。起動時・遅らせた移行の後・1 時間ごとの判定の後に Box を圧縮しますが、フラッシュストレージ上の完全消去は保証しません。
- Hive は Box を開くときに値をすべてメモリに読み込むため、隔離の Box を開く瞬間は `quarantineMaxBytes` の約 2 倍を使い得ます。
- キューには上限を設けません。未送信の業務データを捨てないためです。

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
- 起動前や停止後に呼んだ Cookie API（`restoreCookies()` など）で照合に失敗すると、`CookieOperationException` を投げ、その `cause` に `StorageIntegrityException` が入ります。失敗は保持せず、次の呼び出しや `start()` で照合をやり直します。
- `StorageIntegrityException.failure` は次の理由を表します。
  - `temporarilyUnavailable`: iOS / macOS の端末のロック中など、保護データを読めない状態です。読み取りの結果を鍵の有無の判定に使いません
  - `keyUnreadable`: 鍵の読み取りが例外で失敗し続けています
  - `keyMissing`: 鍵がありません
  - `keyInvalid`: 鍵の形式が正しくありません（空文字、Base64 として読めない、または 32 バイトでない）
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
    // temporarilyUnavailable / proxyActive: 時間をおいて再試行する
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
    - 照合が時間の上限を超えた Box は、Box を閉じた後に時間の上限を設けずに照合し直し、その結果で扱います。
      - 鍵と合わなければ削除します（`deletedBoxes`）。
      - 先頭側が壊れていれば作り直します（`rebuiltBoxes`）。
      - 先頭の記録が書きかけで、鍵と合う記録も無ければ、0 バイトに切り詰めます（`rebuiltBoxes`）。開けば Hive も同じく切り詰めるため、失うものはありません。
    - 問題の無い、中身のある Box は残します（`keptBoxes`）。
  - 鍵の形式が正しくない場合、または鍵なし・読み取り不能の場合（中身のある暗号化 Box があれば、読み直しても続く場合）は、次のように扱います。
    - キュー・隔離・ドロップ履歴の Box のどれかに中身があれば、暗号化 Box（Cookie・キュー・隔離・ドロップ履歴）をすべて削除してから鍵を削除します（`keyDeleted`）。**Cookie（ログイン状態）も消えます。**
    - キュー・隔離・ドロップ履歴の Box のどれにも中身が無ければ（中身があるのが Cookie Box だけの場合や、どの Box にも中身が無い場合）、何も消さずに `startWillSucceed` を返します。`start()` が Cookie Box を破棄するか、新しい鍵を書き込んで続けるためです。鍵を書き込めずに起動に失敗した場合（`keyWriteFailed`）も、これに当たります。
  - 鍵を一時的に読めない場合は `temporarilyUnavailable`、この isolate の proxy が稼働中または起動処理中の場合は `proxyActive` を返し、何もしません。
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

- 1 つの `OfflineWebProxy` インスタンスが業務要求を転送する上流 origin は 1 つです。資源だけを配信する別 origin は `mirroredOrigins` で中継できますが、`GET` と `HEAD` に限られます。
- サポートされる設定経路は `ProxyConfig` です。外部 YAML の自動読込は未実装です。
- `assets/static/` から配信できるのは `GET` と `HEAD` だけです。同名パスへの更新系は静的扱いにせず上流へ転送します。Range 要求には対応していません。
- `AssetManifest.json` または実行環境上の同等 manifest を読み込めない場合は、静的リソースを一覧化せず、通常の upstream 解決へフォールバックします。
- 同じアプリで複数の `OfflineWebProxy` インスタンスを同時に使う構成は想定していません。保存領域の初期化と復旧は、同じ isolate の中ではインスタンスをまたいで直列化しますが、キュー消化・保持上限・移行の排他はインスタンスごとです。複数の isolate から同時に使う場合は、保存領域の初期化と復旧も直列化の対象になりません。

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

## リリース手順

- 先に `pubspec.yaml` と `CHANGELOG.md` を更新し、その変更を `main` へコミットします。
- リリース時にローカルで `dart pub publish` を直接実行しません。このリポジトリは GitHub Actions の `release` job 経由で公開します。
- `v0.8.0` のようなバージョンタグを作成して push します。`v*` タグ push を契機に GitHub Actions が検証、pub.dev 公開、GitHub Release 作成を実行します。

## ライセンス

MIT License
