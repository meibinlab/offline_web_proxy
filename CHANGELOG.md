## 0.12.0

### 機能追加

- **`assets/static/` の静的リソースを配信**: 起動時に一覧化したアセットを実際に返すように実装。`GET` と `HEAD` に対応し、内容から算出した `ETag` と `Cache-Control: no-cache` を付与します。CDN 依存の資材をアプリへ同梱して配信できます
- **`no-store` を無視して保存するパスを指定可能に**: `ProxyConfig.forceCachePaths` を追加。全応答へ `no-store` を付与するサーバでもオフライン応答を用意できます。既定は空で、全体を一括で無効化する設定は用意していません。一致した場合でも、応答に `Set-Cookie` か `Vary` がある場合、リクエストに `Authorization` がある場合は保存しません。また、一致したパスでは上流の `max-age` や `Expires` を使わず `cacheTtl` を有効期限に使います（`no-store` と `max-age=0` の併記で保存直後に stale になるのを避けるため）。**応答キャッシュは暗号化していないため、指定したパスの本文は端末内に平文で残ります**
- **イベントを追加**: `ProxyEventType.cacheSkipped` を追加。`forceCachePaths` に一致しても安全のため保存しなかった場合に、理由（`set-cookie` / `vary` / `authorization`）を伝えます
- **キューへ入れない更新系を指定可能に**: `ProxyConfig.queueExcludePaths` と `QueueExcludeRule` を追加。レジ認証やログアウトのように後から送っても意味が無い更新系を、キューへ保存せず規則ごとの応答で返します。`202 Accepted` を成功と誤認する問題を避けられます。オフライン時、上流へ到達できなかった場合、上流が 5xx を返した場合のすべてに適用します（5xx は上流の応答をそのまま返し、保存だけを行いません）。応答には `X-Offline-Queued: 0` と `X-Offline-Excluded: 1` を付与します。既定は空です
- **受け付けた時刻を上流へ通知**: `ProxyConfig.enableAcceptedAtHeader`（既定 `true`）と `acceptedAtHeaderName`（既定 `X-Offline-Accepted-At`）を追加。proxy が最初にリクエストを受け付けた時刻を、初回転送と以降の再送で同じ値（UTC の ISO 8601）として送ります。オフラインで積んだ更新系が復帰時刻で記録され、日別集計がずれる問題を上流側の 1 箇所で解消できます。隔離からの再送でも値は変わりません
- **再送結果を通知**: `ProxyEventType.queueResendAttempted` と `QueueResendResult` を追加。再送 1 件ごとの URL、ステータス、成否、べき等性キー、再試行の有無を通知します。本文は含みません。`recentResendResults` で直近 20 件を後から参照できます
- **モデルへ受付時刻を追加**: `QueuedRequest.acceptedAt` と `QuarantinedRequest.acceptedAt` を追加
- **状態通知エンドポイントを追加**: `ProxyConfig.statusPath`（既定 `/__offline_web_proxy/status`、空文字列で無効）を追加。オンライン状態、上流到達性、未送信件数、隔離件数、未確認のドロップ件数、直近の再送結果を JSON で返します。`healthCheckPath` と同じく上流へ転送せず統計にも計上しません。「未送信があるときは精算させない」といった判断を Web 側だけで完結できます
- **管理エンドポイントを実装**: `ProxyConfig.enableAdminApi`（既定 `false`）に実体を追加し、隔離キューの一覧・再送・破棄を `/__offline_web_proxy/admin/quarantine` 配下で公開します。フィールドだけが存在して実装が無い状態を解消しました
- **内部エンドポイントの origin 制御**: 状態通知と管理の各エンドポイントは proxy 自身の origin からの要求だけを受け付け、CORS ミドルウェアの対象外としました。別 origin の `Origin` を伴う要求には `403` を返します
- **ウォームアップの参照資源を連鎖取得**: `warmupCache(followReferences: true)` を追加。取得した HTML が参照する同一 origin の `<script src>`、`<link href>`、`<img src>` も続けて取得します。`<link>` は `stylesheet` など資源を指す `rel` だけを対象とし、`canonical` や `alternate` は取得しません。1 段のみ辿り、既定は従来どおり無効です。`WarmupEntry.referencedFrom` で参照元を辿れます

### 修正

- **静的リソースのパスが上流へ届かなくなる問題を修正**: 一覧に一致した URL へ 404 プレースホルダを返していたため、`assets/static/` にファイルを置いた時点で同名パスの上流応答が受け取れなくなっていました。実配信へ切り替えたうえで、アセットを読み込めない場合は 404 とせず上流へ転送します
- **解釈できない `Expires` で成功応答が失われる問題を修正**: `Expires: 0` のように日時として解析できない値を受け取ると、キャッシュ有効期限の算出で例外が発生し、上流が返した 200 が転送失敗として扱われていました。504 を返すうえに上流到達性の失敗としても計上され、繰り返すと転送が遮断されます。解析できない値は無視し、既定 TTL を適用します
- **ウォームアップが Cookie を送っていなかった問題を修正**: 転送経路とキュー再送経路は Cookie Jar を送るのに、`warmupCache()` だけが送っていませんでした。認証が必要な資源はウォームアップでは常に取得できず、`200` 以外は保存しないため何も貯まらない状態でした
- **キャッシュ保存の失敗で成功応答が失われる問題を修正**: 保存領域へ書き込めない場合（容量不足、停止処理との競合など）に例外が転送処理へ伝播し、上流が 200 を返していても 500 を返していました。保存の失敗は `ProxyEventType.errorOccurred` で通知し、応答はそのまま返します

### 改善

- **既定 TTL に `text/javascript` を追加**: JavaScript を `text/javascript` で返すサーバでも、`application/javascript` と同じ TTL が適用されます
- **静的リソース判定の対象メソッドを限定**: `GET` と `HEAD` だけを静的扱いとし、同名パスへの更新系は上流へ転送するように変更
- **`queueDrained` の内容を拡充**: `statusCode` と `idempotencyKey` を追加（キーの追加のみで後方互換）
- **静的リソースの `ETag` 算出を軽量化**: 同梱アセットはプロセス実行中に変化しないため、asset key ごとに算出結果を保持し、要求のたびに全バイトをハッシュし直さないように改善

### ドキュメント

- **パスパターン記法を明記**: 設定でパスを指定する項目が共通で使う glob 記法（`*` / `**` / 完全一致）を仕様書と README に記載
- **キャッシュ設定の注意点を追記**: `cacheTtl` と `cacheStale` は指定すると既定マップを丸ごと置き換えること、`text/html` は約 25 時間でフォールバック対象から外れるため長期のオフライン運用には設定が必要であることを README に明記
- **API リファレンスを更新**: 仕様書【20】の `ProxyConfig`、`ProxyEventType`、`QueuedRequest`、`QuarantinedRequest` へ追加項目を反映し、`QueueExcludeRule`、`QueueResendResult`、`recentResendResults` を追記

### テスト

- **パスパターンのテストを追加**: `test/path_pattern_test.dart` を追加し、セグメント境界、メタ文字の扱い、先頭スラッシュの正規化を検証
- **`forceCachePaths` のテストを追加**: `test/force_cache_test.dart` を追加し、保存とオフライン配信、`Set-Cookie` / `Vary` / `Authorization` による除外と通知、対象外パスでの無通知、`no-store, max-age=0` を伴う応答が設定 TTL で保存されること、再起動で前回のパターンが残らないことを検証
- **静的リソース配信のテストを追加**: 実配信、`ETag` による 304、`HEAD`、更新系の上流転送、アセットを読めない場合の上流フォールバックを検証
- **キャッシュ有効期限と保存失敗のテストを追加**: 解釈できない `Expires` の無視、解析できる `Expires` の反映、保存に失敗した場合でも上流応答を返すことを検証
- **キュー除外のテストを追加**: `test/queue_exclusion_test.dart` を追加し、オフライン・上流 5xx・応答なしの 3 経路、メソッド指定、パターン指定、対象外パスの従来動作を検証
- **受付時刻のテストを追加**: `test/accepted_at_test.dart` を追加し、初回転送への付与、read 系での不付与、応答を受け取れなかった転送と再送での一致、隔離再送での保持、無効化、ヘッダ名変更、旧データの補完を検証
- **再送結果のテストを追加**: `test/resend_result_test.dart` を追加し、成功・4xx 隔離・5xx 再試行の通知内容、保持件数の上限、`recentResendResults` を検証
- **状態通知エンドポイントのテストを追加**: `test/status_endpoint_test.dart` を追加し、応答内容、上流へ転送しないこと、統計に計上しないこと、origin 制御、CORS ヘッダを付けないこと、無効化とパス変更、不正な指定の拒否を検証
- **管理エンドポイントのテストを追加**: `test/admin_api_test.dart` を追加し、既定で無効なこと、一覧・再送・破棄、該当なしの 404、origin 制御を検証
- **ウォームアップのテストを追加**: `test/warmup_reference_test.dart` を追加し、Cookie の付与、参照資源の連鎖取得、別 origin の除外、重複取得の抑止、HTML 以外を走査しないことを検証

---

## 0.11.1

### 修正

- **ドロップ履歴が残らない場合があった問題を修正**: 破棄方針が `DropPolicy.drop` の場合に、ドロップ履歴を書き込む前にキューから取り除いていたため、履歴が残らないまま消える瞬間がありました。履歴を残してから取り除くよう順序を入れ替えています

### ドキュメント

- **`Semaphore` の位置づけを明記**: ライブラリ本体に定義しているため参照できますが、内部実装を目的としたクラスであることを仕様書とコードコメントに記載
- **README の導入例を更新**: 依存指定が `^0.8.0` のままで 0.9.0 以降が取得できなかったため、最新版へ更新

### テスト

- **隔離に失敗した場合のテストを追加**: 隔離領域へ退避できない状況で、キューから取り除かずバックオフを適用することを検証
- **応答を受け取れなかった転送のテストを追加**: 転送が締め切りで打ち切られた場合も、キュー再送で最初の転送と同じべき等性キーを送ることを検証

### CI

- **GitHub Actions を更新**: Node.js 20 非推奨の警告を解消するため、`actions/checkout` を v5、`actions/github-script` を v8、`codecov/codecov-action` を v5、`peaceiris/actions-gh-pages` を v4 へ更新。`softprops/action-gh-release` は v2 へ更新（上流が Node.js 20 のため警告は残ります）

---

## 0.11.0

### 機能追加

- **隔離キューを追加**: 上流が 4xx で拒否した更新系リクエストを破棄せず、本文を保持したまま隔離領域へ退避する `ProxyConfig.dropPolicy`（既定 `DropPolicy.quarantine`）を追加。`getQuarantinedRequests()`、`retryQuarantinedRequest()`、`discardQuarantinedRequest()`、`clearQuarantinedRequests()` で確認・再送・破棄を操作できます
- **未確認のドロップ履歴を検知可能に**: `DroppedRequest.acknowledged` と `acknowledgeDroppedRequests()` を追加し、監視していない間に破棄されたリクエストへ起動時に気付けるように改善
- **統計項目を追加**: `ProxyStats.quarantinedCount` と `ProxyStats.unacknowledgedDroppedCount` を追加
- **べき等性キーを実装**: 更新系リクエストへ 1 つのキーを割り当て、最初の転送とキュー再送の両方で同じ値を送るように改善。応答を受け取れなかったリクエストが再送で二重に適用されることを上流側で判別できます。`ProxyConfig.enableIdempotencyKey`（既定 `true`）、`idempotencyHeaderName`（既定 `Idempotency-Key`）、`idempotencyRetention`（既定 24 時間）で制御します
- **イベントを追加**: `ProxyEventType.requestQuarantined` を追加

### 改善

- **キューの重複投入を防止**: クライアントが同じべき等性キーで送り直した場合、キューへ二重に積まないように改善
- **送信済みリクエストの再送を抑止**: 保持期間内に上流へ届いたことが確認できているキーは再送しないように改善
- **統計取得の負荷を軽減**: 未確認件数をキャッシュし、`getStats()` のたびに履歴を全走査しないように改善
- **ウォームアップを上流到達性と連動**: 上流断を検知している間は `warmupCache()` が待たずに失敗を返すように変更。取得の成否も上流到達性の判定に反映します
- **べき等性キーの探索を削減**: クライアントが指定していないキーではキュー全体の探索を行わないように改善。`enableIdempotencyKey: false` の場合はキーを採番しません

### 修正

- **大量のキュー再送が途中で止まる問題を修正**: 再送時に上流の応答本文を読み捨てていなかったため、接続が解放されず同時接続数の上限（50）に達した時点で以降の再送が進まなくなっていました。長時間オフラインだった端末で、復帰後も更新系リクエストが送信されないまま残る場合がありました
- **締め切り超過時に接続が解放されない問題を修正**: 転送時に本文の受信を締め切りで打ち切っても購読を中止していなかったため、受信途中の接続が接続枠を占有し続け、後続のリクエストが空き待ちで滞留する場合がありました
- **キュー再送の接続失敗が上流断の判定に反映されない問題を修正**: 接続拒否や接続タイムアウトで再送が失敗した場合に連続失敗として数えられず、画面操作が無い状況でサーキットブレーカが遮断しませんでした
- **上流到達の記録漏れを修正**: キュー再送が成功した場合と、上流が redirect を返した場合に、到達成功として記録していなかった問題を修正
- **隔離に失敗した場合の再試行間隔を修正**: 隔離領域へ退避できない状況で、バックオフを適用せず同じリクエストを送り続ける場合がありました
- **上流到達不能時の応答にヘッダを追加**: 代替できるキャッシュが無い場合の応答へ `X-Offline-Source: none` を付与し、上流自身が返した 504 と判別できるように修正

### 破壊的変更の注意

- 上流が 4xx で拒否した更新系リクエストは、既定では破棄されず隔離領域へ移ります。ドロップ履歴には記録されないため、履歴だけを使う運用を続ける場合は `dropPolicy: DropPolicy.drop` を指定してください。
- 更新系リクエストへ `Idempotency-Key` ヘッダが付与されます。上流でヘッダ名が衝突する場合は `idempotencyHeaderName` を変更するか、`enableIdempotencyKey: false` を指定してください。
- `ProxyEventType` に値を追加したため、網羅的に `switch` している利用側は分岐の追加が必要です。

### ドキュメント

- **仕様書と README を更新**: 隔離キューの運用、未確認件数の検知、べき等性キーの責務分担を追記
- **べき等性の章を実装に合わせて改訂**: 未実装の記載を削除し、proxy が保証する範囲と上流サーバ側で必要な対応を明記

### テスト

- **隔離キューのテストを追加**: 隔離、再送、破棄、破棄方針の切り替え、統計への反映を検証
- **未確認件数のテストを追加**: 確認前後の件数と履歴の保持を検証
- **不安定なテストを修正**: 起動時の接続状態取得中に変化イベントが届く検証が、実時間に依存して並列実行時に失敗する場合があった問題を修正
- **べき等性のテストを追加**: 再送時のキー付与、同一内容でのキー重複回避、クライアント指定キーの尊重と重複投入の抑止、転送時と再送時のキー一致、無効化設定を検証
- **連続再送のテストを追加**: 同時接続数の上限を超える件数のキューを最後まで送り切れることを検証
- **接続失敗時の遮断テストを追加**: 接続そのものができない再送で遮断されること、リンク層が切断されている間は復帰確認を行わないことを検証
- **接続解放のテストを追加**: 本文の受信を締め切りで打ち切った接続が解放され、後続のリクエストを妨げないことを検証
- **到達成功の記録テストを追加**: 上流が redirect を返した場合とキュー再送が成功した場合に、連続失敗回数が解消されることを検証
- **ウォームアップのテストを追加**: 遮断中は上流へ要求せず、失敗として結果に含めることを検証
- **隔離キューのテストを補完**: `requestQuarantined` イベントの通知、該当しない ID の指定、一括破棄を検証
- **上流到達不能時のテストを補完**: ページ遷移以外への応答内容と `X-Offline-Source` を検証

---

## 0.10.0

### 機能追加

- **上流到達性のサーキットブレーカを追加**: リンク層が接続済みでも上流へ到達できない場合に、連続失敗が `ProxyConfig.upstreamFailureThreshold`（既定 3、0 で無効）に達した時点で転送を停止し、待たせずにキャッシュ代替応答またはキュー保存へ回すように改善。復帰は `upstreamProbePath` への軽量リクエストをバックオフ付きで実行して確認します
- **上流断の判定材料を追加**: 転送したリクエストに加えてキュー再送の失敗も判定に含め、画面操作が無い状況でも上流断を検知できるように改善
- **キュー投入応答と オフライン応答を設定可能化**: `ProxyConfig.queuedResponse` と `ProxyConfig.offlineMissResponse` を追加し、ステータス、Content-Type、本文を指定できるように改善
- **キュー投入の判別ヘッダを追加**: `X-Offline-Queued` と `X-Offline-Queue-Id` を付与し、Web アプリ側が本文に依存せずキュー投入を判別できるように改善。上流が 5xx を返して再送用に保存した場合も同じヘッダを付与します
- **診断情報を追加**: `getDiagnostics()` に `isOnline`、`onlineDecisionSource`、`isUpstreamReachable`、`upstreamCircuitState`、`consecutiveUpstreamFailures`、`lastUpstreamSuccessAt` を追加
- **イベントを追加**: `ProxyEventType.upstreamCircuitOpened` と `ProxyEventType.upstreamCircuitClosed` を追加

### 改善

- **リクエスト全体の締め切りを導入**: 同時接続数の空き待ち、接続確立、ヘッダ受信、本文受信を `requestTimeout` の 1 つの予算で管理するように改善。従来はハードコードされた 30 秒の空き待ちと段階ごとのタイムアウトが積み上がり、1 リクエストが既定値を大きく超えて待たされる可能性がありました
- **キュー再送にも締め切りを適用**: 再送 1 回あたりの待ち時間を同じ予算で制限
- **ウォームアップにも締め切りを適用**: `warmupCache()` の既定タイムアウトを 30 秒固定から `requestTimeout` に変更し、1 パスあたりの待ち時間を同じ方式で制限
- **保存できなかった更新系を成功扱いにしない**: キューへ保存できなかった場合は 503 と `{"queued":false}` を返すように改善

### 破壊的変更の注意

- 既定のタイムアウトを短縮しました。`connectTimeout` は 10 秒から 5 秒、`requestTimeout` は 60 秒から 20 秒になります。また `requestTimeout` は段階ごとの制限時間ではなくリクエスト全体の締め切りとして扱われます。従来の待ち時間が必要な場合は明示的に指定してください。
- キュー投入時の応答が `200 OK` / `text/plain` から `202 Accepted` / `application/json`（`{"queued":true}`）に変わります。
- オフライン時にキャッシュが無い read のうち、ページ遷移以外（`fetch`、画像、スタイルシートなど）の応答が `200 OK` / HTML から `504 Gateway Timeout` / `application/json`（`{"offline":true}`）に変わります。ページ遷移は従来どおり HTML のフォールバックページを返します。上流到達不能時の 504 応答も同様に扱います。
- 上流到達性のサーキットブレーカが既定で有効です。上流へ到達できない状態が続くと転送を停止します。従来の挙動に戻す場合は `upstreamFailureThreshold: 0` を指定してください。
- `ProxyEventType` に値を追加したため、網羅的に `switch` している利用側は分岐の追加が必要です。
- `ProxyDiagnostics` に必須フィールドを追加したため、このクラスを直接生成している利用側は修正が必要です。

### ドキュメント

- **仕様書と README を更新**: 上流到達性の判定、リクエスト全体の締め切り、オフライン応答の契約、診断情報を追記
- **Web アプリ側の実装例を追加**: キュー投入をヘッダで判別する `fetch` の例を README に追記

### テスト

- **サーキットブレーカのテストを追加**: 連続失敗による遮断、遮断中の即時フォールバックとキュー保存、復帰確認による解除、上流の 4xx / 5xx では遮断しないこと、キュー再送の失敗による遮断、無効化設定を検証
- **締め切りのテストを追加**: 無反応な上流に対して 1 リクエストの待ち時間が締め切り内に収まることを検証
- **オフライン応答の契約テストを追加**: キュー投入応答とオフライン read 応答が JSON として解釈できること、ページ遷移は HTML を返すこと、設定による差し替え、上流 5xx 時の判別ヘッダを検証
- **診断情報のテストを追加**: オンライン判定とその根拠、転送可否を検証
- **不安定なテストを修正**: ドロップ履歴の検証が、並列実行時に消化タイマーの間隔へ間に合わず失敗する場合があった問題を修正

---

## 0.9.1

### 修正

- **キュー保存の取りこぼしを修正**: 保存キーがミリ秒精度だったため、同一ミリ秒に保存した更新系リクエストが上書きで失われる問題を修正。キーをマイクロ秒精度と同一マイクロ秒内の連番で採番するように変更（ドロップ履歴も同様）
- **起動時のオンライン判定を修正**: 接続状態の変化イベントのみを購読していたため、機内モードや圏外で起動すると初期値のままオンラインと判定していた問題を修正。`start()` で現在の接続状態を取得して初期値を確定するように変更
- **キュー投入時の応答を統一**: オフライン経路のキュー投入応答にも `Connection: close` を付与し、オンライン経路と揃えるように修正
- **停止処理との競合を修正**: キュー消化中に `stop()` が実行された場合に、閉じた保存領域へ読み書きしないように修正

### 改善

- **キュー再送順の保証を強化**: 保存日時の昇順で再送するように変更し、旧バージョンのキー形式が残っている場合でも保存順を維持

### ドキュメント

- **仕様書を実装に合わせて修正**: ドロップ条件（4xx のみ削除し、5xx とネットワークエラーは再試行を継続）、バックオフ（ジッターは未実装）、キュー排出間隔（5 秒）、タイムアウト設定（`sendTimeout` と `receiveTimeout` は未実装）の記述を実装と一致させた
- **べき等性の未実装を明記**: 仕様書【6】に現状は未実装であることと、再送による重複の可能性を追記
- **オンライン / オフライン判定を明文化**: 判定材料、起動時の初期化、変化イベントの優先順位を仕様書へ追記
- **README に WebView 用途の推奨値を追記**: `connectTimeout` 5 秒、`requestTimeout` 20 秒、`serverIdleTimeout` 60 秒と、リンク層の接続状態が上流到達性を保証しない点を明記

### テスト

- **キュー保存の回帰テストを追加**: 同時投入時の保存件数、保存順どおりの再送、ドロップ履歴の保存件数、両経路の `Connection: close` を検証
- **起動時のオンライン判定テストを追加**: 圏外起動時のオフライン応答と 1 秒以内の応答、接続時の上流転送、取得できない場合のフォールバック、起動中に届いた変化イベントの優先を検証

---

## 0.9.0

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
- **停止処理と復旧処理を排他化**: 復旧の再バインドと `stop()` が競合した場合に、停止後もソケットとキュー消化タイマーが残り、閉じた保存領域へアクセスして非同期エラーが発生する問題を修正

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
