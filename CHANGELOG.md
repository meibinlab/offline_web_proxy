## 0.15.0

### 機能追加

- **オフライン代替ページが、上流へ到達できる状態に戻ると自分で再読込するようにした**: オフライン時にキャッシュの無い画面へ遷移すると返る代替ページは `200` のため、WebView にはエラーとして届かず、接続が戻っても利用者が戻る操作をするまで代替ページのままでした。既定の代替ページは同じ origin の `statusPath` を読み、上流へ到達できる状態に戻ると再読込します
  - 判定は `isUpstreamReachable` で行います。`true` を 2 回続けて読んだら、`queueLength` が 0 になるまで（最長 `autoReloadQueueWaitTimeout`）待ってから再読込します
  - 自動再読込の結果として `504` ページが表示された場合は、10 秒待った後に `isUpstreamReachable: true` を読めば、再び再読込します（継続復帰）。proxy のページに着いた自動再読込が 3 回続くと止まります
  - 状態を取得できない間は再読込しません。スクリプトは `document.readyState` が `loading` のときだけ動き、HTML 断片として挿入された場合や、同じページで 2 回目に実行された場合は動きません
  - `beforeunload` を受け取ってから `requestTimeout` に 30 秒を足した時間は、画面から始まった遷移を打ち消さないよう再読込を見送ります。ページが置き換わらない遷移（`204` の応答やダウンロードなど）の後も、この時間だけ再読込が遅れます。iOS の WKWebView で `beforeunload` が発火するかは未確認です
  - 自動再読込の連続回数を、Web アプリの origin の `sessionStorage` に `__offline_web_proxy_recovery:` で始まるキーで保存し、10 分以上更新の無いキーは消します
- **既定の代替ページと `504` ページに再試行ボタンを追加**
- **自動復帰の設定を追加**: `ProxyConfig.enableOfflinePageAutoReload`（既定 `true`）、`enableAutoReloadContinuation`（既定 `true`）、`enableGatewayTimeoutAutoReload`（既定 `false`）、`autoReloadPollInterval`（既定 3 秒）、`autoReloadQueueWaitTimeout`（既定 10 秒）。監視間隔が 100 ミリ秒未満または 24 時間超、待ち時間が負の場合は `start()` が `ProxyStartException` を投げます
- **差し替え HTML へ自動復帰のスクリプトを入れる目印を追加**: `offlineFallbackHtml` / `gatewayTimeoutHtml` に `ProxyConfig.recoveryScriptPlaceholder`（`<!--offline-web-proxy:recovery-->`）を書くと、最初の目印の位置へスクリプトを入れ、残りの目印は取り除きます。入れる条件を満たさない場合は空文字に置き換え、目印が無い HTML はそのまま返します
- **キュー・隔離・ドロップ履歴を暗号化して保存するようにした**: キューと隔離は、要求のヘッダ（認証情報を含み得る）と本文をそのまま端末に保持します。Cookie と同じ secure storage の鍵で、AES-256 の暗号化 Box（`proxy_queue_secure`、`proxy_quarantined_requests_secure`、`proxy_dropped_requests_secure`）に保存します。暗号化されるのは値だけで、Box のキー（保存した時刻から採番した ID）は平文です
  - 0.14.0 以前の平文の Box は自動で移行し、`X-Offline-Queue-Id` と隔離の ID は変わりません。その proxy インスタンスで鍵を生成した場合は、プラットフォームを問わず、移行を鍵の生成から 30 秒後へ遅らせます。Android の secure storage はディスクへ非同期に書き込み、iOS などで書き込みがその場で確定するかも実機では未確認です。書き込みの確定を確かめる手段が無いため待ち時間を置きますが、待っても確定は保証されません
  - 移行を待つ間は、旧キューの項目が後回しになります。件数と一覧には旧 Box の分を含め、その項目の `pendingMigration` を `true` にします。旧 Box の隔離は再送も破棄もできず（`false`、管理 API は `409`）、確認済みへの変更と全削除は旧 Box にも適用します
- **暗号化 Box を開く前に、secure storage の鍵と照合するようにした**: Hive は鍵が合わない Box を開くと中身を切り詰めるためです。Box を開かずにファイルを読んで照合し、先頭の記録が合わない Box は別の isolate で全体を走査して、先頭側が壊れた Box と別の鍵で書かれた Box を区別します（走査の時間の上限は Box ごとに 10 秒）。鍵を一時的に読めない状態（iOS / macOS の端末のロック中など）、読み取り不能、鍵なし、形式不正を区別し、中身のある暗号化 Box があり、鍵なしか読み取り不能の場合は、鍵を 3 回まで読み直します。照合は Hive 2.2.3 の内部形式に依存します
- **隔離とドロップ履歴に保持上限を追加**: `ProxyConfig.quarantineMaxCount`（既定 1000）、`quarantineRetention`（既定 30 日）、`quarantineMaxBytes`（既定 20 MB）、`droppedRequestMaxCount`（既定 1000）、`droppedRequestRetention`（既定 30 日）。`0` は上限なし、負の値は `start()` が `ProxyStartException` を投げます
  - 隔離の上限を超えた分は、保存した時刻の古いものからドロップ履歴へ記録してから削除します。`dropReason` は件数と合計バイト数による場合が `quarantine_limit`、期間による場合が `quarantine_expired` で、`requestDropped` に `quarantineId` を含めます
  - 1 件で `quarantineMaxBytes` を超える要求は、隔離せず、既存の隔離も追い出しません。本文を捨ててドロップ履歴へ `quarantine_too_large` で記録してから、キューから取り除きます
  - ドロップ履歴は、件数を超えた分を確認済みの古いものから削除し、未確認は期間でのみ削除します
  - 判定は起動時、追加時、遅らせた移行の後、1 時間ごとに行います。削除は論理削除で、フラッシュストレージ上の完全消去は保証しません
- **暗号化した保存領域の復旧 API `recoverEncryptedStorage()` を追加**: 起動失敗が再試行しても続く場合に、利用者の確認を経て呼び出します。結果は `EncryptedStorageRecoveryResult`、処理しなかった理由は `StorageRecoveryRejection`、予期しない失敗は `StorageRecoveryException` です
  - 鍵があり、キュー・隔離・ドロップ履歴の Box のどれかに問題があれば、鍵を残し、鍵と合わない Box を削除します。問題の無い Box は残します
  - 先頭側が壊れた Box は、鍵と合う最初の記録から作り直します。先頭側の記録は件数不明のまま失われます
  - 照合が時間の上限を超えた Box は、Box を閉じた後に時間の上限なしで照合し直し、その結果で扱います。鍵と合わなければ削除し、先頭側が壊れていれば作り直します。先頭の記録が書きかけで鍵と合う記録も無ければ、0 バイトに切り詰めます（開けば Hive も同じく切り詰めるため、失うものはありません）
  - 鍵の形式不正、または鍵なし・読み取り不能の場合（中身のある暗号化 Box があれば、読み直しても続く場合）は、キュー・隔離・ドロップ履歴の Box のどれかに中身があれば、暗号化 Box をすべて削除してから鍵を削除します（Cookie も消えます）。キュー・隔離・ドロップ履歴の Box のどれにも中身が無ければ（中身があるのが Cookie Box だけの場合や、どの Box にも中身が無い場合）何も消さず、`startWillSucceed` を返します（`keyWriteFailed` で起動に失敗した場合も同じです）
- **Cookie の保存領域を破棄したことを知らせる手段を追加**: `ProxyEventType.cookieStorageDiscarded`（`data['reason']` に理由）と、`ProxyDiagnostics.lastCookieStorageDiscardedAt` / `lastCookieStorageDiscardReason`。破棄は `start()` や、起動前・停止後に呼んだ Cookie API の中で起きるため、後から購読したアプリは診断情報で確認します。復旧 API による削除では、このイベントを発行せず、診断情報も変えません
- **照合結果を表す公開型を追加**: `ProxyStorageBox`、`StorageBoxCheckResult`、`StorageIntegrityFailure`
- **一覧のモデルに `pendingMigration` を追加**: `QueuedRequest`、`QuarantinedRequest`、`DroppedRequest`（既定 `false`）。管理 API の隔離の一覧にも含めます

### 変更

- **代替ページの自動復帰と継続復帰を既定で有効にした**: 影響するのは、既定の代替ページと `504` ページ、および目印を書いた差し替え HTML です。自動再読込が `504` に着くたびに、WebView の HTTP エラーの通知（webview_flutter の `NavigationDelegate.onHttpError`、flutter_inappwebview の `onReceivedHttpError`）が届きます（連続 3 回まで）。**アプリのエラー画面と競合する場合は、主フレームの `504` に付く `X-Offline-Source: none` で判別するか、`enableAutoReloadContinuation: false` を指定してください**
- **代替ページと `504` ページに `Cache-Control: no-store` を付与**: 差し替え HTML にも付与します。履歴移動で WebView が保存済みのページを再表示しないようにするためです
- **状態通知と稼働確認の `GET` を要求ログから除外**: 表示中の代替ページが一定間隔で状態を読むため、そのまま記録するとログが埋まります。GET / HEAD の `healthCheckPath` と GET の `statusPath` だけを除外し、管理 API と同じパスへの他メソッドの要求は記録します
- **既定の `504` ページを HTML にした**: 従来の本文（上流サーバがタイムアウトしました）を見出しにし、`<title>` と案内文を加えています
- **キュー・隔離・ドロップ履歴の Box 名を変更**: `proxy_queue` → `proxy_queue_secure`、`proxy_quarantined_requests` → `proxy_quarantined_requests_secure`、`proxy_dropped_requests` → `proxy_dropped_requests_secure`。**0.14.0 以前へ戻すと、移行済みのキュー・隔離・ドロップ履歴は見えなくなり、戻している間は移行済みの未送信キューが送られません。** 再び上げると、戻している間に積んだ分も含めて移行します
- **保持上限の既定値を、0.14.0 以前から引き継いだ隔離とドロップ履歴にも適用する**: 更新後の最初の起動で判定します（移行を遅らせた場合は移行の後）。**上限を超えた隔離は、本文とヘッダを残さずにドロップ履歴へ移ります。30 日を過ぎたドロップ履歴は、未確認でも消えます。残したい場合は、該当する設定（`quarantineMaxCount`、`quarantineRetention`、`quarantineMaxBytes`、`droppedRequestMaxCount`、`droppedRequestRetention`）に `0`（期間は `Duration.zero`）を指定してください**
- **暗号化鍵を失っても、中身があるのが Cookie の保存領域だけであれば起動を続けるようにした**: 0.4.0 から、鍵が無く暗号化 Cookie Box が残っている場合は起動に失敗していました（fail-fast）。鍵を使えず中身があるのが Cookie Box だけの場合と、ほかの Box に問題が無く Cookie Box が鍵と合わない・先頭側が壊れている・照合を打ち切った場合は、Cookie Box を破棄して起動を続けます（再ログインが必要です）。**起動失敗を見て再ログインを促しているアプリは、`ProxyEventType.cookieStorageDiscarded` か `ProxyDiagnostics.lastCookieStorageDiscardedAt` で判定するよう変更してください。** キュー・隔離・ドロップ履歴の Box が鍵と合わない・先頭側が壊れている・照合を打ち切った場合と、鍵を使えずそれらの Box に中身がある場合は、何も消さずに起動に失敗します
- **形式不正の鍵を、中身のある暗号化 Box が無ければ作り直すようにした**: Base64 として読めない鍵と、長さが 32 バイトでない鍵は、従来は起動に失敗していました。空文字の鍵は、従来は鍵なしと同じ扱いで、暗号化 Cookie Box が無ければ作り直していました。0.15.0 では空文字の鍵も形式不正として扱います
- **暗号化した保存領域を使えない場合の例外を `StorageIntegrityException` にした**: `ProxyStartException` のサブクラスで、`start()` は包まずに投げます。`failure` で理由、`boxResults` で Box ごとの照合結果を判別できます。従来は、鍵が無く暗号化 Cookie Box が残っている場合と、鍵の長さが不正な場合に、`StateError` を包んだ `ProxyStartException`（`cause` は `null`）を投げていたため、理由を判別できませんでした。Base64 として読めない鍵と、鍵の読み取りで起きた例外では、その例外を `cause` に持つ `ProxyStartException` でした。Cookie API は `CookieOperationException` の `cause` に持ちます。iOS / macOS の端末のロック中などで鍵を一時的に読めない場合も、起動に失敗します（`temporarilyUnavailable`）
- **旧平文 Cookie Box の移行に失敗した場合の例外を `CookieOperationException` にした**: 旧 Box を読めない、書き写せない、または削除できない場合です。従来は `StateError`（削除の失敗は元の例外のまま）でした。`start()` では `ProxyStartException` の `cause` に入ります。あわせて、暗号化 Box に同じ Cookie が既にある場合は、旧 Box の値で上書きしないようにしました
- **`stop()` が再バインドによる復旧（`ensureRunning()` など）との排他を取得できなかった場合の例外を `ProxyStopException` にした**: 上限時間（30 秒）内に取得できなかった場合、`TimeoutException` ではなく `ProxyStopException`（`cause` に `TimeoutException`）を投げます。この場合は停止しません
- **`ProxyEventType` に `cookieStorageDiscarded` を追加**: **この enum に対して網羅的な `switch` を書いている場合はコンパイルエラーになります**
- **`stop()` を呼んだ後、キュー消化が次の要求へ進まないようにした**: 従来は稼働中のフラグを停止処理の最後に下ろしていたため、停止処理の途中でもキュー消化が次の要求の送信へ進むことがありました。送信を終えた 1 件の保存（隔離・ドロップ履歴への記録とキューからの削除）は、終わるのを待ってから Box を閉じます。閉じ始めた後に保存を始めようとした 1 件はキューに残し、次の起動で再送します
- **起動処理中の `start()` を拒否するようにした**: 起動処理が終わる前の 2 回目の呼び出しは `ProxyStartException` を投げます
- **`getQueuedRequests()` のヘッダをマスクするようにした**: `QueuedRequest.headers` の文書（機密情報はマスク済み）に実装を合わせました。名前を小文字にし `_` を `-` とみなして、`cookie`、`authorization`、`proxy-authorization` と一致するか、`auth`、`token`、`secret`、`session`、`csrf`、`xsrf`、`key`、`pass`、`credential`、`signature`、`jwt`、`cookie` を含むヘッダの値を `***` にします。`idempotencyHeaderName` のヘッダは対象外です。URL のクエリはマスクしません。再送には保存した値を使います

### 修正

- **既定の `504` 応答に `Content-Type` が無かった**: 本文を文字列だけで返しており、shelf が `application/octet-stream; charset=utf-8` を付けていました。WebView が画面として扱えない場合があります
- **暗号化鍵がまだ無い状態で Cookie API を同時に呼ぶと、次回の起動で Cookie が消えることがあった**: `getCookies()` と `restoreCookies()` など（`start()` を含む）が同時に鍵を生成し、secure storage には後から書いた鍵が残る一方、暗号化 Cookie Box は先に開いた側の鍵で書かれていました。次回の起動で鍵が合わず、Hive が Box を切り詰めていました。保存領域の初期化を直列化し、同時に呼ばれても鍵の生成と Box のオープンが重ならないようにしました（同じ isolate 内で proxy のインスタンスが複数ある場合を含みます）。初期化に失敗した場合は結果を共有し続けず、次の呼び出しで再試行します
- **キュー・隔離・ドロップ履歴の一覧が、保存した順に並ばないことがあった**: `getQueuedRequests()`、`getQuarantinedRequests()`、`getDroppedRequests()` は Hive のキーの辞書順で並んでいました。v0.11.0 より前の形式（13 桁・16 桁）のキーと現在の形式（19 桁と連番）のキーが混ざった端末では、新しい記録が古い記録より前に来ていました。保存した時刻（`queuedAt` / `quarantinedAt` / `droppedAt`）の順に並べ、`limit` は並べた後の先頭からの件数にしました
- **`dropPolicy: drop` で履歴を記録できない場合も、キューから取り除いていた**: ドロップ履歴の保存領域が閉じていると、履歴を残さないままキューから取り除いていました。記録できない場合はキューに残し、バックオフしてから再試行します（`quarantine` で隔離できない場合と同じ扱いです）

### ドキュメント

- **README を更新**: 主な機能、設定例、差し替え HTML の目印とスクリプトを入れる条件、「オフライン代替ページの自動復帰」、HTTP エラーの通知でエラー画面を出すアプリ向けの扱い、上流到達不能時のページ遷移への応答、状態通知と稼働確認の要求ログ、`ProxyLifecycleGuard` との関係、開発者向けセットアップ（自動復帰のスクリプトの回帰テストと example の e2e の実行方法）を日本語版と英語版の双方で同期
- **仕様書を更新**: 【1】のオフライン応答の概要、【8】の上流到達不能かつ代替キャッシュ無しの応答、状態通知エンドポイントの説明、【10】の代替ページと `504` ページのヘッダと「代替ページの自動復帰」（スクリプトを入れる条件、起動と監視の規則、状態遷移、自動再読込の連続回数と目印、要求ログ）、【18】の要求ログ、【20】の設定と `ProxyLifecycleGuard` の説明を更新
- **README に暗号化と保持上限を追記**: 節「端末に保存するデータ」を新しく追加し、その下に「保存するデータの一覧」「隔離とドロップ履歴の保持上限」「暗号化鍵を失った場合」「暗号化した保存領域の復旧」「0.14.0 以前からの移行」「Android の自動バックアップ」を置きました。あわせて、主な機能、設定例と保持上限の設定の補足、「上流到達性の診断」の診断情報、「Web アプリから proxy の状態を見る」の件数、「隔離キューを画面から操作する」の応答（`409` など）と `pendingMigration`、「Cookie API」の補足、「キャッシュ、キュー、監視 API」の一覧の並びとヘッダのマスク、「現在の制約」（複数のインスタンスの同時使用）、「example の e2e」（保存領域の e2e が消すデータと所要時間）を更新し、日本語版と英語版の双方で同期
- **仕様書に暗号化と保持上限を追記**: 【1】に端末に保存するデータ、【4】に暗号化鍵の管理と照合（初期化の直列化、鍵の状態の区分、読み直し、照合、判定表、Cookie Box の破棄、起動失敗、復旧 API、Hive の内部形式への依存）、【5】に保存領域の暗号化、旧平文 Box からの移行、保持上限、一覧と上限による削除の順を追加し、`quarantine` の説明、二重記録の回避、履歴管理、状態通知と管理エンドポイントを更新。【17】にインスタンスと isolate、【19】に Android の自動バックアップを追加。【20】に復旧 API、`start()` などの例外、診断情報、イベント、設定、一覧のモデル、照合結果と復旧の型、例外クラスを追加し、`getDroppedRequests()` と `getQuarantinedRequests()` の `limit` の既定値の誤記（100 件）を修正

### テスト

- **`test/offline_recovery_page_test.dart` を追加**: 既定の代替ページと `504` ページの HTML・ヘッダ・再試行ボタン・スクリプト、設定の組み合わせによるスクリプトの有無、埋め込む値、加工していない要求行（`[]` と小文字の 16 進を含む URL）での埋め込み、差し替え HTML の目印の置き換え（最初の目印だけ）と除去、閉じタグのエスケープ、監視間隔の下限への丸め、既定値と設定値の範囲の検証、状態通知の JSON が変わらないこと、要求ログの除外範囲（状態通知の無効化とパスの変更を含む）を検証（計 26 件）
- **example の e2e に自動復帰のケースを追加**: 上流の停止と再起動で代替ページが本来の画面へ戻ること、状態を取得できない間は代替ページのままであること、`504` ページが HTML として表示され再試行ボタンを持つこと、自動再読込の結果の `504` ページからの継続復帰、連続 3 回での停止と再試行ボタンを数えないこと、継続復帰の無効化、`504` ページの監視中からの自動再読込、キューが空にならない場合の上限時間、再送待ち中に状態を取得できない場合、`[]` と `~` を含む URL での復帰、`requestTimeout` が目印の判定時間より長い場合の継続復帰、成功した復帰を連続回数に数えないことを検証（計 12 件、Android エミュレータで成功を確認）
- **自動復帰のスクリプトの回帰テストを追加**: `tool/offline_recovery_harness/` に、実装が生成する代替ページと `504` ページをヘッドレス Chrome で開き、状態通知の応答を切り替えて、再読込の有無と、再読込までに読んだ状態通知の件数を確かめるハーネスを追加（16 シナリオ）。判定に使う件数と時間は、ページに埋め込まれた設定値から計算します。pub.dev の配布物には含めません
- **`test/storage_initialization_test.dart` を追加**: 鍵がまだ無い状態で、Cookie API を同時に呼んだ場合、`start()` と Cookie API を同時に呼んだ場合、2 つのインスタンスから同時に呼んだ場合に、鍵が 1 つに決まり再起動後も Cookie が残ること、鍵を一時的に読めない状態や旧平文 Cookie Box の移行の失敗の後に同じインスタンスで再試行でき、開いた Cookie Box を残さないこと、キューなどを開く段階の失敗後も Cookie API が使え `start()` を再試行できること、Box が閉じられた後に同じインスタンスで開き直すこと、キューなどを開く段階の失敗時はその呼び出しで開いた Box だけを閉じること、共有中の初期化の失敗が別の error zone から待つ呼び出しにも届くこと、起動処理中に `start()` を続けて呼ぶと 2 回目を拒否し 1 回目の起動は続くことを検証（計 14 件）
- **`test/async_lock_test.dart` を追加**: 初期化の直列化に使う内部のロックが、待ち始めた順に 1 つずつ実行すること、例外で終わっても解放すること、上限時間を過ぎた場合は処理を実行しないことを検証（計 3 件）
- **`test/storage_integrity_policy_test.dart` を追加**: 判定表の各行（中身のある暗号化 Box が無い場合とある場合）を検証（計 9 件）
- **`test/encryption_key_reader_test.dart` を追加**: 鍵の状態の区分（空文字と形式不正、端末のロック中、読み取り中のロック、ロックの状態が不明な場合）と、読み直し（中身が無い場合は読み直さないこと、すべて同じ結果の場合だけ続くとみなすこと、一時的な失敗の後に読めた値を使うこと、結果が入り混じる場合と途中でロックされた場合は一時的とすること）を検証（計 12 件）
- **`test/hive_frame_inspector_test.dart` を追加**: Hive と同じ CRC32 と鍵の CRC、先頭フレームの照合（正しい鍵、誤った鍵、末尾の書きかけ、先頭の書きかけ）、走査（長さの欄や値が壊れた場合の破損、Cookie のキー、時間の上限による打ち切り）、別の isolate での照合、`.hivec` だけがある場合、切り詰め、過去の形式のキーを含む Box の作り直し、範囲外の位置とファイルが無い場合、先頭フレームが数 MB の大きな Box の照合、乱数で埋めた 32 MB のファイルの走査時間の記録を検証（計 34 件）
- **`test/storage_integrity_test.dart` を追加**: 実際の Box のファイルと差し替えた secure storage で、新規インストール、形式不正の鍵の作り直し、鍵の書き込み失敗で Box を作らないこと、端末のロック中の起動失敗、0.14.0 からの更新で何も消さないこと、Cookie Box だけの不一致と鍵なしでの破棄と通知、一時的な読み取り失敗の後に Cookie Box が残ること、結果が入り混じる場合に何も消さないこと、破棄と同時に復元した Cookie が残ること、業務データの Box の不一致・破損・照合打ち切り・書きかけでの起動失敗、Cookie API への例外の伝え方、鍵の書き込みに失敗した場合に Cookie Box を残すことと直った後の起動、起動前の Cookie API の中での破棄の通知、読み取り不能と形式不正が続く場合の破棄、`.hivec` だけが残った Box の判定を検証（計 25 件）
- **`test/encrypted_storage_migration_test.dart` を追加**: 鍵がある場合の `start()` の中での移行とキーの維持、鍵を生成した場合の移行の遅延（件数と一覧への旧 Box の分の算入、保存時刻の順と `limit`、再送を止めないこと、移行後の保存時刻の順での送信）、途中失敗からの再試行で同じ要求を 1 回だけ送り隔離が増えないこと、書き写したキーの残骸を対象から外すこと、移行を待つ隔離の再送・破棄の拒否と管理 API の `409`、確認済みの維持と全削除、`stop()` 後に次の要求へ進まないことと再起動での再予約、中断した移行からの起動、Cookie の移行で既存を上書きしないこと、暗号化 Box のファイルに本文とヘッダの値の平文が残らないこと、旧 Box のファイルを消せない場合、移行が失敗し続けても暗号化したキューの再送を続けること、移行が終わる瞬間に取った一覧で項目が抜けないこと、隔離の前後で停止しても二重に隔離しないことと停止時に隔離の保存を待ってから Box を閉じることを検証（計 20 件）
- **`test/retention_limits_test.dart` を追加**: キーの形式が混ざった Box での一覧・`limit`・上限による削除の保存順、隔離の件数・期間・合計バイト数（起動時と追加時、ちょうど上限の場合、1 件で上限を超える場合の `quarantine_too_large`）、ドロップ履歴の期間と件数（未確認を件数で消さないこと）、負の設定値の拒否と `0` の上限なし、ロックを取れない場合の `QueueOperationException`、追い出しと確認済みへの変更の同時実行、3000 件の隔離を追い出す時間の記録、停止後の未確認件数が 0 になることを検証（計 26 件）
- **`test/queued_request_masking_test.dart` を追加**: `getQueuedRequests()` のヘッダのマスク（大文字小文字と `_` / `-` の違い、部分一致、対象外のヘッダ、べき等性キーのヘッダ名とその変更、URL のクエリをマスクしないこと、再送に保存した値を使うこと）を検証（計 7 件）
- **`test/storage_order_test.dart` を追加**: キーを時刻として読む規則と、保存時刻・キーの時刻・読めない値の並べ方を検証（計 6 件）
- **`test/storage_location_test.dart` を追加**: アダプタ 0 を登録しサブディレクトリで Hive を初期化した状態でも、実際の保存先にある暗号化 Box を照合し、旧平文 Box を移行することを検証（計 2 件）
- **`test/storage_recovery_test.dart` を追加**: 復旧 API の拒否（稼働中、起動処理中、ロックを待つ間に起動した場合、鍵が一致する場合、一時的な読み取り失敗の後に読めた場合、端末のロック中、結果が入り混じる場合、中身が無い場合、書きかけの Box、Cookie Box だけの不一致・破損・鍵なし）、鍵がある場合の削除・作り直し・残す扱い、鍵を使えない状態が続く場合の全削除と鍵の削除、照合打ち切りの Box の走査し直し（切り詰め・削除・作り直し）、残骸の `.hivec` の削除、作り直しの途中停止からの再実行、2 回目の復旧の拒否、復旧後に同じインスタンスで `start()` できること、別のインスタンスが稼働中の拒否、復旧中と復旧後の `start()` と Cookie API、途中で失敗した復旧の後の段階 1 のやり直し、段階 2 を終えたインスタンスが復旧の後に保存領域を開き直すこと、復旧の間に保存領域を照合し直した同じインスタンスが起動できることを検証（計 38 件）
- **既存のテストを暗号化に合わせて変更**: `test/offline_web_proxy_test.dart` の鍵が無い場合と形式不正の鍵の場合を、Cookie Box の破棄と診断情報、鍵の作り直しの検証に変更。`test/accepted_at_test.dart` の旧データの再現と `test/quarantine_test.dart` の Box 名を暗号化 Box に変更
- **example の e2e に暗号化した保存領域のケースを追加**: `example/integration_test/offline_web_proxy_storage_e2e_test.dart` で、端末の secure storage と Hive のファイルを使い、鍵を生成した起動では 0.14.0 以前の平文キューを待ち時間（30 秒）の後に暗号化 Box へ移すこと、移した後の暗号化 Box のファイルに本文の平文が無いこと、上流を再開すると元の本文のまま 1 回だけ送ること、上流が止まっている間に受け付けた `POST` が `202` を返し、本文の平文を含まない形で暗号化 Box に残り、`stop()` の後に別のインスタンスで `start()` しても残り、上流を再開すると 1 回だけ送ることを検証（計 2 件、Android エミュレータで成功を確認）。同じプロセスの中での確認で、アプリの再起動をまたいだ鍵の保存は確かめていません
- **example の e2e の期待値を修正**: `example/integration_test/offline_web_proxy_device_e2e_test.dart` で、上流を止めた後の `POST` の期待値に `202` を加えました。0.10.0 からキューに入れたときに返す `202` が含まれておらず、失敗していました（修正後、Android エミュレータで成功を確認）

### CI

- **`Recovery Script Test` ジョブを追加**: 自動復帰のスクリプトの回帰テストを、ubuntu-latest の Chrome と Node.js 24 で実行します。このジョブが失敗した場合は `release` ジョブを実行しません

## 0.14.0

### 機能追加

- **別 origin の資源を proxy 経由で取得する `mirroredOrigins` を追加**: CDN から UI ライブラリを読み込む画面では、HTML 内の絶対 URL が 127.0.0.1 を経由しないため、キャッシュもフォールバックもウォームアップも効きません。HTML と API を保存できても、描画を担うライブラリが読めなければ画面は動きませんでした。列挙した origin を proxy が中継し、通常のキャッシュとオフライン代替の対象にします。既定は空で、指定が無い限り別 origin には一切関与しません
  - proxy が返す `text/html` の `<script src>`、`<link href>`、`<img src>` のうち、一致する絶対 URL を `/__offline_web_proxy/ext/<scheme>/<host>[:port]/<元のパス>` へ書き換えます。元の origin をパスの一部として保つため、その資源が持つ相対 URL も同じ origin 配下へ解決されます
  - 書き換えの判定はウォームアップの参照抽出と同じ正規表現を使います。書き換えた資源は必ず `warmupCache(followReferences: true)` の対象になります
  - 書き換えは保存時ではなく応答時に行います。キャッシュには上流が返したバイト列をそのまま保持するため、オフラインでキャッシュから返す HTML にも同じ変換がかかり、設定から origin を外せば元の URL に戻ります。本文は `latin1` で読み書きし、文字コードによらずバイト列を保ちます
  - 中継するのは `GET` と `HEAD` だけです。ほかのメソッドは `405` を返してキューにも載せず、許可していない origin を指すパスは `404` を返して設定済み origin へ素通ししません
  - **中継先へは `Authorization`、`Origin`、`Referer` とクライアントの `Cookie` を送りません。** Cookie Jar のうち中継先のドメインに一致するものだけを送り、中継先が返す `Set-Cookie` も自身のドメインで保存します
  - 中継先が返す 3xx の `Location` も中継用のパスへ書き換えます。`resolveNavigationTarget()` は一致する URL を `inWebView` と判定します
  - 対象は proxy が返す 200 の `text/html` 応答です。上流から取得した応答とそのキャッシュのほか、`offlineFallbackHtml` で差し替えたオフライン応答も含みます。`assets/static/` から配信する同梱 HTML は対象外です
  - 中継用のパスは要求元が自由に組み立てられるため、`user@host` のように認証情報を含む形と、proxy 自身を指す形は受け付けません

### 変更

- **`ProxyNavigationReason` に `mirroredOriginUrl` を追加**: ミラー対象 origin の URL を解決した場合の理由です。**この enum に対して網羅的な `switch` を書いている場合はコンパイルエラーになります**
- **`/__offline_web_proxy/ext/` を proxy の予約名前空間にした**: `mirroredOrigins` が空でも上流へは転送せず `404` を返します。稼働確認、状態通知、管理エンドポイントと同じ扱いです

### 修正

- **`ProxyConfig.forceCachePaths` のコメントを実装に合わせた**: 0.13.0 で `Vary: Accept-Encoding` だけの応答を除外対象から外した変更が、公開 API のコメントに反映されていませんでした

### ドキュメント

- **仕様書へ別 origin の中継を追記**: 【1】へ中継用のパス、書き換えの対象と時点、中継の扱い、設定値の検証、制限を追加し、【14】へ `Authorization`、`Cookie`、`Origin`／`Referer`、`Location` の中継時の扱いを追加
- **README を更新**: 主な機能、設定例、`mirroredOrigins` の説明、現在の制約を日本語版と英語版の双方で同期

### テスト

- **`test/mirrored_origin_test.dart` を追加**: 既定では別 origin に触れないこと、書き換えと中継、キャッシュとオフライン復元、許可外 origin の `404`、更新系の `405`、資源タグと `canonical` の区別、相対 URL と HTML 以外の非対象、ウォームアップの連鎖取得と許可外 origin の失敗記録、資格情報を渡さないこと、絶対と相対の redirect 書き換え、遷移解決、設定値の検証を検証。あわせて版指定の `@` とパーセントエンコードを含むパスの往復、プロトコル相対 URL、認証情報を含む形と proxy 自身を指す形の拒否、Shift_JIS 本文のバイト列保持、`Content-Encoding` を持つ応答の非対象、差し替えたオフライン応答の書き換え、接頭辞付き属性と `srcset` の違い、同梱 HTML の非対象を検証（計 28 件）

## 0.13.0

### 改善

- **`Vary: Accept-Encoding` だけの応答を `forceCachePaths` の除外対象から外した**: proxy は転送、キュー再送、ウォームアップのいずれでも上流へ `Accept-Encoding: identity` を固定で送るため、受け取る応答は常に 1 種類です。`Accept-Encoding` だけを理由に保存を見送っても守れるものがありません。一方 Tomcat、nginx、Apache はいずれも圧縮を有効にすると `Vary: Accept-Encoding` を既定で付けるため、0.12.0 では圧縮対象の閾値を超えた画面の HTML、JS、CSS、主要な API がまとめて保存対象から外れていました。判定は `,` で分解し、前後の空白と大文字小文字を無視して行います。`*` や他のヘッダ名を 1 つでも含む場合は従来どおり除外し、`Set-Cookie` と `Authorization` による除外も変更していません

### 修正

- **ウォームアップが保存した圧縮応答を復元できない問題を修正**: `warmupCache()` だけが上流へ `Accept-Encoding: gzip, deflate` を送っており、転送経路の `identity` と食い違っていました。本文だけが自動解凍される一方で `Content-Encoding: gzip` は残るため、**ヘッダと本文が矛盾したままキャッシュへ保存され、オフライン時にそのまま返っていました**。クライアント側の復号が失敗します。ウォームアップも `identity` を送るようにそろえました。圧縮を有効にしたサーバへ `warmupCache()` を使う場合、`forceCachePaths` の指定有無にかかわらず該当します
- **共有 HttpClient の自動解凍設定が経路ごとに書き換わる問題を修正**: 転送は無効、ウォームアップとキュー再送は有効を、同じインスタンスに対して呼び出しのたびに設定していました。同時実行時に互いの設定を上書きします。生成時に無効へ固定し、受け取ったバイト列と `Content-Encoding` が常に整合するようにしました。稼働確認と上流疎通確認が使う専用の `HttpClient` も同じ扱いにそろえました（いずれも本文は読み捨てるため挙動は変わりません）

### ドキュメント

- **除外条件の記載を更新**: 仕様書【8】と README の除外条件表へ `Vary: Accept-Encoding` の例外と、それを除外しない理由を追記
- **ウォームアップの仕様を追記**: 上流へ `identity` を送ることを仕様書【8】へ明記

### テスト

- **`Vary` 判定のテストを追加**: `test/force_cache_test.dart` へ、`Accept-Encoding` だけの場合の保存、表記ゆれ（大文字小文字・空白・末尾のカンマ）の吸収、他ヘッダ併記および `*` の除外、複数行に分かれた `Vary` の合流、ヘッダ名を 1 つも挙げない `Vary`、`Set-Cookie` と併存する場合に `set-cookie` を優先することを追加
- **上流への `Accept-Encoding` のテストを追加**: `test/upstream_encoding_test.dart` を追加し、転送経路とウォームアップがどちらも `identity` を送ること、上流が `identity` を無視して圧縮した場合でも保存内容とヘッダが整合しオフラインで復元できることを検証

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
