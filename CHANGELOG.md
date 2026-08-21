## 未リリース

### 機能追加

- **接続復旧 API を追加**: `probe()`、`ensureRunning()`、`recoverFromWebResourceError()`、`resolveReloadUri()`、`getDiagnostics()`、`port`、`baseUri` を追加し、サスペンド復帰後にソケットが応答しない状態を検知して同一ポート優先で再バインドできるように改善
- **ライフサイクル連動を追加**: `ProxyLifecycleGuard` を追加し、アプリ復帰時の稼働確認と自動復旧、再読込先 URL の通知を行えるように改善
- **ヘルスチェックを追加**: `ProxyConfig.healthCheckPath` の稼働確認エンドポイント（GET / HEAD のみ、204 応答、上流転送なし、統計対象外）と `ProxyConfig.healthCheckInterval` の定期確認を追加。パスは起動時に検証し、`/` 始まりでない値やパスパラメータ記法を含む値は `ProxyStartException` で拒否
- **旧ポート URL の救済を追加**: ポートのみが異なる loopback URL を現行ポートへ読み替え、遷移判定でも `ProxyNavigationReason.stalePortUrl` として扱うように改善。読み替え対象は自インスタンスがバインドしたポート、永続化された直前のポート、`preferredPort` に限定し、別ポートで動作する他のローカルサーバへの遷移は従来どおり扱う
- **復旧イベントを追加**: `ProxyEventType.serverRecovered` と `ProxyEventType.serverUnavailable` を追加
- **応答本文の差し替えを追加**: `ProxyConfig.offlineFallbackHtml` と `ProxyConfig.gatewayTimeoutHtml` により、オフライン応答とタイムアウト応答の文言をアプリ側で指定できるように改善
- **アイドルタイムアウト設定を追加**: `ProxyConfig.serverIdleTimeout` を追加
- **診断情報の精度を改善**: 復旧結果の `downtimeMs` は呼び出し時に渡された停止推定時間のみを反映し、定期ヘルスチェックの稼働確認タイムアウトは確認間隔に連動（500 ミリ秒〜2 秒）するように改善

### 改善

- **上流到達不能時のフォールバックを拡張**: 接続拒否、名前解決失敗、接続中の切断、TLS ハンドシェイク失敗も request timeout と同様にキャッシュ代替応答の対象とし、代替キャッシュが無い場合は 504 を返すように改善（従来は接続失敗時に 500 を返し、キャッシュを利用しなかった）
- **復旧の暴走を抑止**: 復旧処理の同時実行を 1 件に集約し、連続失敗時のバックオフと `ProxyConfig.maxRestartAttemptsPerMinute` による上限を追加
- **停止処理の状態整合を改善**: `stop()` が途中で失敗した場合でも稼働中フラグを残さないように修正。停止時は復旧の実行制御状態のみを初期化し、再バインド回数などの診断値は次回起動まで保持

### 破壊的変更の注意

- `ProxyEventType` と `ProxyNavigationReason` に値を追加したため、これらを網羅的に `switch` している利用側は分岐の追加が必要です。
- 上流へ接続できない GET / HEAD の応答が変わります。保存済みキャッシュがあれば 200 で代替応答を返し、キャッシュが無い場合は従来の 500 ではなく 504 を返します。

### ドキュメント

- **仕様書と README を更新**: 死活監視、自動復旧、旧ポート URL 読み替え、ライフサイクル連動、新設定項目を追記
- **フォールバック仕様を改訂**: キャッシュ代替応答の条件を「オフライン時またはタイムアウト時」から「オフライン時または上流到達不能時（接続失敗・タイムアウト）」へ改訂

### テスト

- **上流到達不能時のフォールバックテストを追加**: 接続失敗時のキャッシュ代替応答、キャッシュ無し時の 504、HEAD の応答、upstream 4xx / 5xx の透過、更新系リクエストのキュー保存を検証
- **カバレッジ計測範囲を修正**: codecov の除外設定から実装本体（`lib/offline_web_proxy.dart`）を外し、計測が実態を反映するように修正
- **接続復旧テストを追加**: ヘルスチェック応答、ソケット死亡検知、同一ポート再バインド、復旧試行の抑制、旧ポート URL 読み替え、遷移判定、診断情報、定期ヘルスチェック、アイドルタイムアウト、ライフサイクル連動を検証

---

## 0.8.1

### 機能追加

- **ポート安定化を強化**: `preferredPort` を追加し、利用可能ならそのポートを優先してバインドするように改善
- **直前成功ポートの再利用を追加**: 起動ごとに直前に成功したポートを記録・再利用し、WebView origin の変化を抑制
- **WebStorage bridge を追加**: HTML レスポンスへ注入する軽量 bridge と snapshot API を追加し、WebView 側で localStorage / IndexedDB の保存・復元を行えるように改善

### セキュリティ

- **WebStorage bridge の origin 制御を追加**: 設定された upstream origin と一致しない Origin からのアクセスを拒否するように改善

### 改善

- **HTML 注入の堅牢性を改善**: `</body>` がなくても `</html>` があれば挿入し、どちらもない場合は末尾に追記するように改善

### ドキュメント

- **README を更新**: preferred port / persisted port reuse / WebStorage bridge の利用方法を追記

### テスト

- **回帰テストを追加**: preferred port fallback、persisted port reuse、WebStorage snapshot round-trip、origin 制御、HTML 注入 fallback を検証

---

## 0.8.0

### 改善

- **キャッシュ利用条件を見直し**: オンライン時の GET / HEAD は常に upstream を優先し、proxy キャッシュはオフライン時または request timeout 超過時の代替応答に限定
- **エラー時フォールバックを明確化**: upstream の 4xx / 5xx 応答では proxy キャッシュへ切り替えず、そのまま返却する挙動に統一
- **ウォームアップ用途を整理**: `warmupCache()` を通常時の高速化ではなく、フォールバック用レスポンスの事前取得として扱うよう整理

### ドキュメント

- **README / 仕様書を更新**: fallback-only のキャッシュ方針、timeout 時の扱い、4xx / 5xx 応答時の挙動を追記

### テスト

- **回帰テストを強化**: online upstream 優先、timeout fallback、4xx / 5xx non-fallback、warmup のキャッシュ保存を検証するテストを追加
- **テスト表現を整理**: テストコメントとテスト名を実際の検証内容に合わせて見直し

---

## 0.7.0

### 改善

- **上流 redirect の WebView 向け制御を改善**: WebView へ返す `301`、`302`、`303`、`307`、`308` では `HttpClient` の自動追従に依存せず `Location` を明示解決し、same-origin redirect は proxy URL へ書き換えるよう修正
- **外部起動 redirect の通知を追加**: `tel:` や maps URL など外部委譲が必要な redirect を `ProxyEventType.redirectHandled` で app 側へ通知し、WebView エラー化を避けられるよう改善
- **relative Location の解決を統一**: redirect の `Location` が相対 URL の場合でも、上流リクエスト URL 基準で一貫して解決するよう整理

### ドキュメント

- **README / 仕様書を更新**: upstream redirect の明示処理範囲、same-origin rewrite、外部起動通知イベントの扱いを追記

### テスト

- **redirect 回帰テストを追加**: direct URL 判定、same-origin redirect rewrite、relative `Location`、`tel:` / maps への外部委譲 redirect を検証
- **エミュレータ E2E を確認**: `example` アプリの WebView E2E と device E2E を Android エミュレータで実行し、proxy 経由の実機相当動作を確認

---

## 0.6.1

### 修正

- **静的リソース誤判定を修正**: proxy URL の拡張子だけで local-only 扱いせず、`AssetManifest.json` に基づく静的リソース一覧に一致した場合のみ静的リソースとして判定するよう修正
- **manifest 読み込み失敗時の起動継続を改善**: 実行環境で manifest を読み込めない場合でも、静的リソース一覧を空として proxy 起動を継続するよう修正
- **キュー再送時のヘッダ処理を修正**: `Connection` 指定ヘッダや hop-by-hop ヘッダを除外し、Cookie と `accept-encoding` を上流再送向けに正規化するよう修正

### ドキュメント

- **README / 仕様書を更新**: 静的リソース一覧の構築条件、manifest fallback、現在の 404 プレースホルダ応答を明記

### テスト

- **静的リソース一覧と再送ヘッダの回帰テストを追加**: 相対 URL、未登録 CSS、入れ子ディレクトリ、package asset、WebView 由来ヘッダ再送のケースを検証

---

## 0.6.0

### 機能追加

- **WebView delegate 向け推奨アクション API を追加**: `recommendMainFrameNavigation(...)` と `recommendNewWindowNavigation(...)` を追加し、`allow`、`cancel`、`loadProxyUrl`、`launchExternal` の推奨動作を取得可能に
- **delegate 判定モデルを追加**: `ProxyWebViewNavigationRecommendation` と `ProxyWebViewNavigationAction` を公開し、proxy 再読込 URL や外部委譲用の正規化済み URL を参照可能に

### ドキュメント

- **README / 仕様書を更新**: WebView delegate 向け推奨アクション API の使い方と main frame / new window の扱いを追記

### テスト

- **delegate 推奨アクションのテストを追加**: main frame と new window の内部遷移、外部委譲、解決不能、静的リソース、不正 URL のケースを検証

---

## 0.5.0

### 機能追加

- **URL 解決 API を追加**: `tryResolveUpstreamUrl(String url)` と `resolveNavigationTarget(...)` を追加し、proxy URL、同一 origin URL、相対 URL を WebView 遷移前に判定可能に
- **遷移判定モデルを追加**: `ProxyNavigationResolution`、`ProxyNavigationDisposition`、`ProxyNavigationReason` を公開し、外部委譲や local-only 判定に必要なメタ情報を取得可能に
- **requestReceived メタ情報を拡張**: `resolvedUpstreamUrl`、`resolvedProxyUrl`、`navigationDisposition` などの URL 解決結果をイベントから参照可能に

### 改善

- **上流 URL 解決の共通化**: proxy 内部の上流転送、キャッシュ更新、キュー再送でも同じ URL 解決ルールを利用するよう整理
- **loopback alias 判定を明確化**: `localhost` と `127.0.0.1` の吸収は proxy URL 判定時の HTTP のみに限定
- **静的リソース URL マッピングを調整**: `/app.css` や `/images/...` を `assets/static/` 配下へ対応付ける前提に統一
- **example アプリを刷新**: `NavigationDelegate` と URL 解決 API を使った WebView 連携サンプルを追加

### ドキュメント

- **README / 仕様書 / example を更新**: URL 解決 API、requestReceived メタ情報、静的リソースのルートパスマッピング例を追記

### テスト

- **URL 解決とイベント通知のテストを追加**: loopback alias、relative URL、outside proxy scope、requestReceived メタ情報、静的リソース判定の検証を追加

---

## 0.4.0

### 機能追加

- **Cookie 復元 API を追加**: `restoreCookies(Iterable<CookieRestoreEntry>)` を追加し、proxy 起動前に native 側で保持している Cookie を復元可能に
- **Cookie 復元モデルを追加**: `CookieRestoreEntry` を追加し、構造化データと `Set-Cookie` 文字列の両方から復元可能に
- **ドロップ履歴 API を強化**: dropped requests の取得、クリア、統計反映を改善

### セキュリティ

- **Cookie 永続化を暗号化**: Cookie ストレージを secure storage の鍵で暗号化し、既存の平文 Cookie ストレージがある場合は 1 回だけ移行
- **鍵喪失時は fail-fast**: secure storage 上の鍵が失われた場合、既存の暗号化 Cookie は復号せず再ログインを要求

### 改善

- **上流転送の Cookie 評価を改善**: 復元 Cookie と Set-Cookie で保存した Cookie を上流リクエストへ正しくマージ
- **queue / dropped requests の挙動を改善**: FIFO 再送、再起動後の永続化、バックオフ、4xx ドロップ履歴を整理
- **開発者向け品質改善**: pre-commit hook に `dart fix --apply`、`dart format .`、`dart analyze --fatal-warnings` を追加

### ドキュメント

- **README / 仕様書更新**: Cookie 復元 API、暗号化鍵管理、鍵喪失時の挙動、開発者向け hook 手順を追記

### テスト

- **Cookie / queue / dropped requests テストを拡充**: 復元 Cookie 転送、Set-Cookie capture、stop/start 回帰、FIFO 再送、バックオフ、ドロップ履歴の検証を追加

### 注意事項

- **Cookie セッション再確立が必要な場合あり**: secure storage 上の鍵が失われている環境では、既存の暗号化 Cookie は再利用できず再ログインが必要

---

## 0.3.0

### 機能追加

- **Cookie ヘッダ取得 API を追加**: `getCookieHeaderForUrl(String url)` を追加し、native HTTP 通信やバックグラウンド通信で同一セッションの Cookie ヘッダ値を再利用可能に

### セキュリティ

- **取得対象を同一 origin に制限**: `getCookieHeaderForUrl` は `start()` で設定した `origin` と同一 origin の URL のみ許可

### 内部改善

- **Set-Cookie の保持を改善**: 複数 `Set-Cookie` を壊さず保持するレスポンスヘッダスナップショットを導入
- **Cookie 評価基盤を追加**: Domain / Path / Expires / Max-Age / Secure を考慮した内部 evaluator を追加
- **Cookie 内部モデルを追加**: 公開用 `CookieInfo` と分離した内部保存モデル `CookieRecord` を導入

### ドキュメント

- **README / 仕様書更新**: 新 API の使い方、戻り値、同一 origin 制約を追記

### テスト

- **Cookie 関連テストを追加**: Cookie matching、ヘッダ生成、URL 制約の検証を追加

---

## 0.2.2

### CI/リリース

- **タグpushで自動公開**: `v*` タグのpushをトリガーに pub.dev publish → GitHub Release 作成まで自動化

---

## 0.2.1

### CI/リリース

- **CI互換性の改善**: Flutter 3.22.x (Dart 3.4.x) を含むマトリクスで依存解決/テストが通るように調整
- **example依存関係の調整**: `flutter_lints` と `webview_flutter` のSDK要件をCIに合わせて更新

---

## 0.2.0

### バグ修正

- **レスポンスヘッダ整合性の修正**: 上流レスポンスの hop-by-hop ヘッダや `content-length` をサニタイズし、端末/エミュレータでの `FormatException (chunked decoding)` を回避
- **更新系リクエストの安定化**: 非GETリクエストのボディを一度だけ読み取り、上流転送とキュー保存で共有（ストリーム二重readを防止）
- **キュー互換性**: 旧データの相対URLを補正して再送できるように改善

### 改善

- **フリーズ要因の軽減**: バイト列処理の効率化（`BytesBuilder` 等）、キャッシュパージの協調的な処理、バックグラウンドタイマーの多重起動/停止漏れ防止
- **キャッシュの信頼性向上**: レスポンスボディを `Uint8List` として保持し、不要なUTF-8変換を削減（バイナリを安全にキャッシュ）
- **Range対応の強化**: `Range`/`206` は保存しない一方、フルキャッシュ(200)から単一Range(206)を生成して返却可能に

### テスト

- **実機相当E2Eの追加**: Flutter `example/` アプリと WebView を用いた統合テストを追加（POSTキュー/復旧、バイナリ、Range、並列サブリソース、オフライン再ロード）

---

## 0.1.1

### バグ修正

- **キャッシュキー生成の修正**: オンライン/オフライン時のキャッシュキー生成を上流サーバURLベースに統一
- **クエリパラメータ対応**: URLのクエリパラメータがキャッシュキーに正しく含まれるように修正
- **テスト環境の改善**: path_providerのモック設定を追加し、テストの安定性を向上

### 改善

- **テストカバレッジ拡充**: クエリパラメータ関連のテストを追加（104テストケース）
- **依存関係の最適化**: Flutter SDK互換性のためtest依存を削除

---

## 0.1.0

### 初回リリース

#### 主要機能
- **オフライン対応プロキシサーバ**: Flutter WebView内で動作するローカルプロキシ
- **インテリジェントキャッシュ**: RFC準拠のCache-Control対応とオフライン戦略の両立
- **リクエストキュー**: POST/PUT/DELETEリクエストのオフライン時キューイング
- **Cookie管理**: AES-256暗号化による安全なCookie永続化
- **静的リソース配信**: assets/static/配下のローカルファイル自動配信

#### API機能
- **サーバ管理**: `start()`、`stop()`、`isRunning`
- **キャッシュ操作**: `clearCache()`、`clearExpiredCache()`、`clearCacheForUrl()`
- **統計情報**: `getStats()`、`getCacheStats()`
- **Cookie管理**: `getCookies()`、`clearCookies()`
- **キュー管理**: `getQueuedRequests()`、`getDroppedRequests()`
- **事前キャッシュ**: `warmupCache()`

#### データモデル
- **CacheEntry**: キャッシュエントリ情報（Fresh/Stale/Expired状態管理）
- **ProxyStats**: プロキシサーバ統計情報
- **CookieInfo**: Cookie情報（値はセキュリティ上マスク）
- **QueuedRequest**: キューイングされたリクエスト
- **WarmupResult**: キャッシュ事前更新結果

#### 例外クラス
- **ProxyStartException**: サーバ起動失敗
- **CacheOperationException**: キャッシュ操作失敗
- **NetworkException**: ネットワークエラー
- **WarmupException**: 事前更新失敗

#### 品質保証
- **包括的テスト**: 85テストケース（基本機能、例外処理、統合テスト）
- **完全カバレッジ**: エッジケース、同時アクセス、設定統合テスト
- **CI/CD**: GitHub Actions による自動テスト・品質チェック
- **セキュリティ**: 依存関係監査、脆弱性チェック

#### ドキュメント
- **詳細仕様書**: specs.md（45KB）による完全な技術仕様
- **多言語対応**: README.md（英語）、README.ja.md（日本語）
- **API リファレンス**: 全メソッド・クラスの詳細説明
