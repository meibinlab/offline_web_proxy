## Unreleased

### テスト

- 隔離・ドロップ履歴やキューが空になることの一方だけを待ち、直後にキューが空であることや状態の照会・ドロップの通知などを確かめていたテストで、キューからの削除や隔離からの追い出しより先に判定して失敗することがあったため、両方の条件がそろうまで待つようにしました（`test/quarantine_response_preview_test.dart`、`test/request_status_test.dart`、`test/resource_limits_test.dart`、`test/retention_limits_test.dart`、`test/encrypted_storage_migration_test.dart`、`test/integration_test.dart`）

## 0.26.0

### 破壊的変更の注意

- **`ProxyConfig.requireAccessToken` の既定を `true` にしました**（0.25.0 までは `false`）: 起動ごとの秘密値（`OfflineWebProxy.accessToken`）を持たない要求は、稼働確認（`GET` / `HEAD` の `healthCheckPath`）を除き `403` になります。更新後は、`start()` のたびに、WebView がページを読み込む前に `accessToken` を proxy の origin（`baseUri`）へ Cookie `__offline_web_proxy_token`（`OfflineWebProxy.accessTokenCookieName`）として置いてください。WebView 以外からの要求（アプリの `HttpClient` など）は、ヘッダ `X-Offline-Web-Proxy-Token`（`OfflineWebProxy.accessTokenHeaderName`）で渡します。端末内の別アプリやページから到達されない環境（テストなど）に限り、`requireAccessToken: false` で 0.25.0 と同じ動きに戻せます
- **`ProxyConfig.addCorsHeaders` の既定を `false` にしました**（0.25.0 までは `true`）: 既定では CORS ヘッダを付けません。`true` にする場合は、新しい `ProxyConfig.corsAllowedOrigins` に許可する origin を挙げる必要があります。`addCorsHeaders: true` のまま一覧が空だと、`start()` が `ProxyStartException` を投げます。0.25.0 と同じく全 origin へ `Access-Control-Allow-Origin: *` を返すには、`corsAllowedOrigins: ['*']` を指定します
- **イベントの URL から、既定でクエリとフラグメントを除くようにしました**（新しい `ProxyConfig.includeQueryInEvents`、既定 `false`）: `ProxyEvent.url` と、`requestReceived`（`proxyRequestUrl`、`resolvedUpstreamUrl`、`resolvedProxyUrl`）・`redirectHandled`（`proxyRequestUrl`、`sourceUpstreamUrl`、`locationHeader`、`normalizedTargetUrl`、`resolvedUpstreamUrl`、`resolvedProxyUrl`）・`queueResendAttempted`（`url`）の URL の項目が対象です。`includeQueryInEvents: true` で 0.25.0 と同じく完全な URL になります。`redirectHandled` の `externalUrl` は、アプリが外部起動に使う唯一の値のため、設定によらず完全な URL のままです（アプリが実行するための値でクエリを含むため、ログへ出さないでください）
- **要求ログの形式を変えました**: `shelf.logRequests` をやめ、時刻、経過時間、メソッド、ステータス、パスの 1 行を `debugPrint` で出力します。クエリは出さず、クエリのある要求はパスの後ろに `?…` とだけ付けます。処理中の例外は `[ERROR <例外の型名>]` と出します
- **状態通知の `recentResendResults` の `url` からクエリとフラグメントを除くようにしました**（設定によらず）。Dart API の `OfflineWebProxy.recentResendResults` は完全な URL のままです
- **Cookie の保存に失敗したときの `errorOccurred`（`operation: cookieSave`）の `error` を、例外の型名だけにしました**: 失敗の区分は新しい `reason`（`invalidSetCookie` か `storageFailure`）で分かります。応答をキャッシュへ保存できなかったときの `errorOccurred`（`phase: cacheResponse`）も同じく、`error` を例外の型名にし、`reason: storageFailure` を加えました
- **上流の応答の `Set-Cookie` を、受け入れ規則に外れる場合は Cookie Jar へ保存しないようにしました**: 要求先ホストに domain-match しない `Domain`、IP アドレスのホストでホストと異なる `Domain`、`.` の無い `Domain`（ホストと等しい場合を除く）、中継先（`mirroredOrigins`）の応答で設定済み origin のホストへも送られる範囲の Cookie、`https` 以外の応答の `Secure`、条件を満たさない `__Secure-` / `__Host-` の名前、`https` 以外の応答による `Secure` の Cookie の上書き・削除と影での覆い（名前が等しく、ドメインがどちらか向きに domain-match し、新しいパスが既存のパスに path-match する場合。RFC 6265bis 5.7）が対象です。0.25.0 までは保存していたため、これらに頼る上流（`http` の上流が `Secure` を付ける、別ドメインを `Domain` に指定するなど）では、更新後に Cookie が送られなくなります。保存しなかったことは `errorOccurred`（`operation: cookieSave`）の `reason` と `cookieName` で分かります。WebView へ返す応答の `Set-Cookie` と、`restoreCookies()` に渡す Cookie は影響を受けません
- **`Set-Cookie` の `Expires` を RFC 6265 の手順で解釈するようにしました**: `Wed, 21-Oct-2026 07:28:00 GMT` のような形式も有効期限として扱います。0.25.0 までは解釈できずセッション Cookie になっていました。逆に、0.25.0 まで受け付けていた ISO 8601 形式（`2026-10-21T07:28:00Z` など）は解釈できない値として無視し、`Max-Age` が無ければセッション Cookie になります
- **`Set-Cookie` の `Max-Age` と `Path` を RFC 6265 どおりに解釈し、有効期限に 400 日の上限を設けました**: `Max-Age` は `^-?\d+$` に合う値だけを採り、`+5` や `0x10` などは無視して先に採った値を保ちます（0.25.0 までは `+5` を 5 秒として扱い、不正な値は前の値を消していました）。上流から受け取る有効期限は、`Max-Age` と `Expires` のどちらでも受信から 400 日後に丸めます（RFC 6265bis）。`Path` が空か `/` で始まらない場合は、`/` を補うのではなく要求先のパスから求めた default-path を使います（0.25.0 までは `Path=app` を `/app` としていました）。`CookieRestoreEntry.fromSetCookieHeader()` の解釈も同じです
- **WebView が送った Cookie を、既定では上流へ渡さないようにしました**（新しい `ProxyConfig.forwardWebViewCookieNames`、既定 `{}`）: 0.25.0 までは、秘密値以外の WebView の Cookie をすべて上流へ渡していました。上流のセッションは従来どおり Cookie Jar から送ります。ページのスクリプト（`document.cookie`）や `WebViewCookieManager` で置いた Cookie を上流へ送っていた場合は、その名前を `forwardWebViewCookieNames` に指定してください（例 `{'locale', 'consent'}`）。`{'*'}` で 0.25.0 と同じ動作に戻せます。キューへ保存する要求の `Cookie` も挙げた名前だけにし、0.25.0 以前に保存した要求も再送の時点で絞ります。受け入れ規則で Cookie Jar に保存されなかった Cookie（`http` の上流が返す `Secure` の Cookie など）は、0.25.0 までは WebView 経由で上流へ届いていましたが、更新後は送られません（`errorOccurred` の `operation: cookieSave` で確認できます）
- **中継先（`mirroredOrigins`）の応答の `Set-Cookie` を、WebView へ返さないようにしました**: Cookie Jar には従来どおり（受け入れ規則に沿って）保存し、以後の中継で中継先へ送ります。中継先の Cookie をページのスクリプトから読んでいた画面では読めなくなります
- **`ProxyConfig.host` にループバック以外を指定できなくしました**: `localhost`、`127.0.0.0/8` の IPv4 アドレス、`::1` 以外（`0.0.0.0`、`::`、端末のアドレス、他のホスト名、`localhost.` など）では、`start()` が `ProxyStartException` を投げます。制限を外す設定はありません
- **`Host` ヘッダが proxy 自身を指さない要求を `403` で拒否するようにしました**: ホスト名が `ProxyConfig.host`、`127.0.0.1`、`localhost`、`[::1]` のいずれか（大小文字は区別しない）で、ポートが稼働中のポートと一致する必要があります。ポートを書かない `Host` は稼働中のポートが 80 の場合だけ、末尾にドットを付けた名前（`localhost.`）や `[0:0:0:0:0:0:0:1]` のような別の書き方は一致しません。要求行の絶対 URL が別の宛先や userinfo を持つ要求と、`X-Forwarded-Host` か `X-Forwarded-Proto` を持つ要求（値にかかわらず）も拒否します。稼働確認（`healthCheckPath`）も対象です。WebView やアプリから、これら以外のホスト名（端末のアドレスや独自の名前解決など）で proxy を開いていた場合は、`baseUri` などの URL に変えてください
- **符号化などで `.` と `..` を隠したパスの要求を `400` で拒否するようにしました**: `..%2F`、`%2E%2E%2F`、`%5C..`、`..;` などが対象です。`a%2Fb` のように `.` と `..` を伴わない符号化は従来どおり転送します
- **設定のパスパターン（`PathPattern`）の照合で、パターンとパスを正規化するようにしました**: 各セグメントの `;` 以降を除き、非予約文字の `%XX` だけを復号し、`/` の重複をまとめ、末尾の `/` を除いてから比較します。`authResumePaths`、`queueExcludePaths`、`forceCachePaths` が、0.25.0 までは一致しなかった `/api/login;jsessionid=1`、`/api/login/`、`/api/%6Cogin` などにも一致するようになります。末尾の `/*` と `/**` は手前のパスそのもの（`/js/**` に対する `/js`）にも一致します。`PathPattern.normalizePath()` の戻り値も変わります（末尾の `/` を除くなど）
- **`X-Forwarded-For` など、要求元や元の URL を名乗るヘッダを上流へ渡さないようにしました**: `Forwarded`、`X-Forwarded-For` / `-Host` / `-Proto` / `-Port` / `-Prefix`、`X-Real-IP`、`X-Client-IP`、`True-Client-IP`、`CF-Connecting-IP`、`X-Original-URL`、`X-Rewrite-URL` を、転送、中継、キューへの保存、再送のいずれでも落とします。0.25.0 以前にキューへ保存した要求も再送の時点で落とします。このうち `X-Forwarded-Host` と `X-Forwarded-Proto` を付けた要求は、上記のとおり `403` で拒否します。画面からこれらのヘッダで上流へ情報を渡していた場合は、別の名前のヘッダに変えてください
- **`sha256:` で始まる 255 バイト以下の Hive のキーも SHA-256 に置き換えるようにしました**: Cookie などの Box のキーが対象です。べき等性キーは下記のとおり HMAC で記録するようになり、0.25.0 以前の記録も 0.25.0 の規則で照会するため、更新前に送信済みとして記録したキーも保持期間内は引き続き照合されます
- **要求本文に上限を設け、超える要求を `413` で断るようにしました**（新しい `ProxyConfig.maxRequestBodyBytes`、既定 10 MiB）: 0.25.0 までは大きさを問わず読み込んでいました。超える要求は、オンラインでもオフラインでも転送もキュー保存もせず、`413`、`Cache-Control: no-store`、`X-Offline-Queued: 0`、`Connection: close`、本文 `{"queued":false,"error":"request_body_too_large"}` を返します。大きなファイルを送る画面がある場合は、上限を見直してください
- **キューに件数と合計サイズの上限を設けました**（新しい `ProxyConfig.queueMaxCount`、既定 1000 件と `queueMaxBytes`、既定 50 MiB）: 0.25.0 まではキューに上限がありませんでした。超える要求は保存せず、`503` と `{"queued":false,"error":"queue_full"}`、`X-Offline-Queued: 0` を返し（キューを書けない場合の `{"queued":false}` と本文で区別できます）、`errorOccurred`（`phase: queueLimit`、`limit: count` か `bytes`）を発行します。上流が 5xx を返した要求は、従来どおり上流の応答をそのまま返します（キューへは保存しません）。既存の要求は消しません
- **オフラインでキューへ保存できなかった要求に、`requestQueued` を発行しないようにしました**: 0.25.0 までは、保存領域を使えず `503` を返した場合も `queueId: null` の `requestQueued` を発行していました
- **画面が付けたべき等性キーの要求がキューにあり、持ち主か内容が違う場合は `422` で断るようにしました**: 本文は `{"queued":false,"error":"idempotency_key_conflict"}`、`X-Offline-Queued: 0` です。0.25.0 までは、内容を問わずキューにある要求の ID を返していました。同じ持ち主の同じ内容（メソッド、URL、本文）の送り直しは従来どおり既存の ID を返します。0.25.0 以前にキューへ入れた要求は、メソッドと URL で比べます
- **保存した送信先の origin が現在の設定と違う要求を、送らずに取り除くようにしました**: `ProxyConfig.origin` を変えて起動し直すと、0.25.0 までは前の origin へ保存した要求を送っていました。0.26.0 からは、scheme・host・実効ポートが設定済み origin と違う要求を（`mirroredOrigins` に含まれる origin でも）、`dropPolicy` に従い理由 `origin_changed`、ステータスコード `0` で隔離またはドロップ履歴へ移します。`origin` を変える場合は、先にキューを送り切ってください
- **`queueOwnerResolver` を指定している場合、`restoreCookies()` と `clearCookies()` でキューが止まることがあります**: `restoreCookies()` に `queueOwnerId` を渡さない場合と、`clearCookies()` で全件か設定済み origin のホストへ送られるドメインを消した場合は、送信待ちの持ち主が分からなくなるため `ownerUnresolved` で一時停止します。復元するセッションの利用者を `queueOwnerId` で渡してください。`queueOwnerResolver` を指定していない場合は変わりません
- **`queueOwnerResolver` を指定している場合、持ち主の記録に書き換えを検出するタグを付けるようにしました**: 0.25.0 の記録（タグなし）は 1 回だけ受け入れて保存し直します。0.26.0 で起動した後に 0.25.0 へ戻して記録を書き換えると、次の 0.26.0 の起動では書き換えとみなして `ownerUnresolved` で一時停止します。その際は `errorOccurred`（`phase: queueOwnerLoad`）の `reason` で、タグが合わない（`tagMismatch`）か、持ち主を記録した要求があるのに記録が無い（`recordMissing`）かが分かります
- **`queueOwnerResolver` を指定している場合、持ち主が分からないまま起動し直したときに、前の持ち主の要求を移さず一時停止したままにしました**: 0.25.0 では、判定できないログインやログインの転送中の終了の後に起動し直すと、利用者の操作を待たずに持ち主の分かっている要求を `owner_changed` で隔離・ドロップしていました。0.26.0 からは、現在の持ち主が正体の分からない持ち主で、別の持ち主の要求がキューにあれば、起動のたびに `ownerUnresolved` で一時停止します。`resumeQueue()` か、持ち主が決まる次のログインで再開します
- **`queueOwnerResolver` を指定している場合、利用者ごとの応答をキャッシュから持ち主にだけ返すようにしました**: 応答に `Set-Cookie` がある応答、`Cache-Control: private` の応答、上流へ `Authorization` か Cookie を送った応答（応答の `Cache-Control` に `public` があり、`Vary` に `Cookie`・`Authorization`・`*` が無い場合を除く。RFC 9111 3.5 を参考に、印は `public` だけ）は、保存した時点の持ち主と結び付け、現在の持ち主と一致する場合だけオフラインや上流へ到達できないときに返します。別の利用者がログインしている間と、持ち主が変わった後はミスになります（`ProxyEventType.cacheMiss`、`reason: ownerMismatch`）。誰もログインしていない間の応答は「持ち主なし」の印（`none`）を付けて保存し、持ち主が無い間だけ返します。取得している間にログインや `restoreCookies()` が始まった応答は保存しません（`cacheSkipped`、`reason: ownerChanged`）。`queueOwnerResolver` を指定しない場合は 0.25.0 と同じく誰にでも返します。セッションを Cookie で持つ上流では、上流が `public` を付けない限り静的資源を含むほぼすべての応答が該当するため、利用者を切り替えた後は、それらも新しい利用者で取り直すまでオフラインで返せません
- **応答キャッシュへ保存するヘッダから `Set-Cookie` と `Set-Cookie2` を除くようにしました**: WebView へ返す応答は変わりません。キャッシュから返す応答には以前から付けていなかったため、画面から見た動きは変わりません。0.25.0 以前に保存した記録は書き換えないため、その `Set-Cookie` は有効期限を過ぎるか `clearCache()` を呼ぶまで端末に残ります
- **`StorageRecoveryRejection` に `verificationTimedOut` を追加しました**: `recoverEncryptedStorage()` が照合打ち切りや先頭側の破損の Box を照合し直すとき、0.25.0 までは時間の上限が無く、異常に大きなファイルで戻らないことがありました。Box ごとに 2 分を上限とし、超えた場合は何も削除・作り直しせずにこの値を返します。`StorageRecoveryRejection` を網羅する `switch` は、この値の扱いを加える必要があります
- **`enableWebStorageInheritance` の受け渡しの受付条件を厳しくしました**: 比べる相手を設定済みの上流 origin から proxy 自身の origin（`127.0.0.1` と `localhost` は同じとみなす）に変え、`POST` は `Origin` を必須にしました。`Sec-Fetch-Site` が `same-origin` と `none` 以外の要求は `403`、`GET` と `POST` 以外のメソッドは `405` です。0.25.0 までは `Origin` の無い `POST` も受け付けていました。無効な場合も `/__offline_web_proxy/web_storage` を上流へ転送せず `404` を返します
- **Web ストレージのスナップショットを暗号化 Box `proxy_web_storage_secure` へ移しました**: 0.25.0 以前の平文の Box `proxy_web_storage` は、有効な場合は起動時に移して削除し、無効な場合は移さずに削除します。移行に失敗した場合と、無効な設定で旧 Box を削除できなかった場合も起動は止めず、`errorOccurred`（`phase: webStorageMigration`）で知らせて次の起動でやり直します。0.25.0 以前へ戻すと、移したスナップショットは読めません

### セキュリティ修正

- **端末内の別アプリやブラウザのページが、既定の設定のまま proxy へ到達できた**: proxy はループバックで待ち受けますが、要求元のプロセスを区別できないため、既定では別アプリなどの要求も Cookie Jar のセッションを付けて上流へ転送し、状態通知や管理エンドポイントにも到達できました。秘密値の検査を既定で有効にしました（上記）
- **既定で全 origin へ `Access-Control-Allow-Origin: *` を付けていた**: 別 origin のページから、proxy の応答（秘密値の検査を無効にした場合は、Cookie Jar のセッションで得た上流の応答）を読めました。既定では CORS ヘッダを付けず、付ける場合も `corsAllowedOrigins` に挙げた origin の要求にだけ、その origin を `Access-Control-Allow-Origin` に返すようにしました
- **要求ログとイベントに URL のクエリが出ていた**: クエリには検索語や一度きりの符号、セッション識別子が入ることが多く、端末のログやログ収集へ流れていました。要求ログにはクエリを出さず、イベントは既定でクエリとフラグメントを除き、画面から読める状態通知の再送結果は常に除くようにしました（上記）
- **Cookie の保存に失敗したときのイベントに `Set-Cookie` の値が載っていた**: 解釈できない `Set-Cookie` の例外の文言にヘッダの値がそのまま入り、`errorOccurred` の `error` に出ていました。例外の文言から値を外し、イベントには例外の型名と区分だけを載せるようにしました
- **形式の正しくない暗号化鍵の文字列が、例外に含まれていた**: Base64 として読めない鍵では、`StorageIntegrityException` の `error` / `cause` と `toString()` に、`base64Decode` の例外を通じて鍵の文字列と位置が出ていました。位置も値も持たない `FormatException('Invalid encryption key encoding')` に置き換えました。あわせて、末尾の改行など ASCII の空白を除いてから読むようにし、手作業で登録した改行付きの鍵を形式不正と誤って扱わないようにしました
- **上流や中継先が、ほかのホストやセッションの Cookie を Cookie Jar へ置けた**: `Domain` を検証せずに保存していたため、上流の応答が無関係なドメインや `com` のような上位ドメインへ Cookie を置けました。中継先（`mirroredOrigins`）の応答も、設定済み origin へ送られる Cookie（セッション固定など）を置けました。また、`http` の応答が `Secure` の Cookie を置いたり、`https` で得た `Secure` の Cookie を上書き・削除したり、親ドメインやより深いパスの同名の Cookie で覆って先に送らせたりできました。RFC 6265 / RFC 6265bis の受け入れ規則で確かめてから保存するようにしました（上記）。公開サフィックスリストは使わない簡易判定です
- **Cookie の保存領域を使えないとき、上流の応答を返せなかった**: 上流の `Set-Cookie` を保存する前の保存領域の初期化に失敗すると、例外が転送処理へ伝わっていました。`errorOccurred`（`operation: cookieSave`、`reason: storageFailure`）で知らせ、上流の応答をそのまま返すようにしました
- **ページのスクリプトが置いた Cookie が、上流へそのまま届いていた**: WebView の proxy origin の Cookie は、proxy を通るどのページのスクリプトからも置けますが、Cookie Jar に無い名前は上流へ渡していたため、上流が信頼する Cookie（セッション固定など）を差し込めました。キューへ保存した Cookie も再送で送られていました。`forwardWebViewCookieNames` に挙げた名前だけを渡すようにしました（上記）
- **中継先の Cookie が、設定済み origin へ送られていた**: 中継先の `Set-Cookie` を WebView へ返していたため、WebView は proxy の origin の Cookie として保存し、設定済み origin への要求で送っていました（Cookie Jar に無い名前は上流へ渡っていました）。中継先の `Set-Cookie` は Cookie Jar にだけ保存するようにしました（上記）
- **別のサイトのページが DNS rebinding で proxy へ到達できた**: 自分のホスト名をループバックへ向けたページから、`Host` を問わず要求が届き、応答も読めました（秘密値の検査を無効にした場合は Cookie Jar のセッションで上流へ転送されました）。`Host` ヘッダを照合するようにしました（上記）
- **`0.0.0.0` などで待ち受けると、端末の外から proxy へ到達できた**: `ProxyConfig.host` をループバックに限りました（上記）
- **符号化した `..` で、proxy の照合とは別の資源を上流に指させた**: `..%2F` や `%5C..` は proxy では 1 つのセグメントとして照合される一方、上流が復号してから解決すると親のパスを指すため、内部エンドポイント、キューへ入れない規則、ログインのパスなどの照合とずれました。こうした要求を拒否するようにしました（上記）
- **`;jsessionid=...` や末尾の `/`、`%6C` などの書き方で、ログインのパスやキューへ入れない規則の照合をすり抜けられた**: 照合の前に正規化するようにしました（上記）
- **画面が付けた `X-Forwarded-For` などが、上流へそのまま届いていた**: 上流が要求元のアドレスや元の URL として信じると、アクセス制御や URL の組み立てを欺けました。また dart:io は `X-Forwarded-Host` と `X-Forwarded-Proto` の値をそのまま埋め込んで要求の URL を組み立てるため、値にパスや userinfo を含めると、proxy が照合するパスや上流へ渡すパス、イベントの URL まで書き換えられました。これらを上流へ渡さないようにし、`X-Forwarded-Host` か `X-Forwarded-Proto` を持つ要求は `403` で拒否するようにしました（上記）
- **`sha256:<64 桁の 16 進>` の短いキーが、長いキーを置き換えた値と同じ記録を指せた**: 画面が付けたべき等性キーなどで、別の長いキーの記録を送信済みとみなせました。接頭辞で始まるキーは長さによらず SHA-256 に置き換えるようにしました
- **大きな要求や大量の要求で、端末のメモリと保存領域を使い切れた**: 要求本文を大きさを問わずメモリへ読み込み、キューにも上限が無かったため、画面の不具合や悪意のある Web ページが大きな要求を送り続けると、アプリが落ちたり保存領域を使い切ったりしました。要求本文とキューに上限を設けました（上記）
- **上流が応答を待たせている間に別の利用者がログインすると、前の利用者の要求が新しい利用者の要求として記録された**: キューへ入れる時点の持ち主を記録していたため、その要求は新しい利用者のセッションで送られました。proxy が要求を受け付けた時点の持ち主を記録するようにしました
- **並行したログインで、Cookie Jar のセッションと送信待ちの持ち主が別の利用者になることがあった**: ログインの応答の Cookie の保存と持ち主の決定を別々に行っていたため、応答が前後すると、ある利用者のセッションで別の利用者の要求を送り得ました。Cookie の保存から持ち主の保存までを 1 件ずつ行い、応答が届いた順に確定するようにしました。その順番待ちを 30 秒以内に取得できない場合は、Cookie だけを保存して `ownerUnresolved` で一時停止します（順番待ちを持っていた側も、外で Cookie が書かれたことを確かめて持ち主を決めずに止めます）
- **画面が付けたべき等性キーで、別の利用者や別の内容の要求のキュー ID を得られた**: 同じキーの要求がキューにあれば内容を問わずその ID を返していたため、ID を使って照会や操作ができました。持ち主か内容が違う場合は `422` で断るようにしました（上記）
- **`restoreCookies()` と `clearCookies()` でセッションを差し替えると、前の利用者の送信待ちが新しいセッションで送られた**: ログイン以外のセッションの変更では持ち主を変えていませんでした。`restoreCookies()` に `queueOwnerId` を加え、持ち主が分からない場合はキューを一時停止するようにしました（上記）。復元中に送り始めていた再送は、本文を送る直前に中断します
- **`origin` の設定を変えた後に、前の送信先へ要求と Cookie を送っていた**: 再送の直前に保存した URL の origin を確かめるようにしました（上記）
- **暗号化しないポート設定の Box の持ち主の記録を書き換えたり消したりすると、別の利用者の要求を送らせられた**: 記録にタグを付け、タグが合わない場合と、持ち主のある要求があるのに記録が無い場合は、起動時に `ownerUnresolved` で一時停止するようにしました（上記）
- **端末を共用する場合、前の利用者の画面をオフラインで別の利用者へ返していた**: キャッシュのキーは URL だけのため、利用者 A がログインして取得した応答を、利用者 B がログインし直した後もオフラインや上流へ到達できないときにそのまま返していました。`queueOwnerResolver` を指定している場合は持ち主ごとに返すようにし、保存したくない場合のために `cacheUserScopedResponses` を加えました（上記と下記）
- **上流の `Set-Cookie`（セッション識別子など）が応答キャッシュに残っていた**: 保存するヘッダから除くようにしました（上記）。0.25.0 以前の記録の `Set-Cookie2` も、キャッシュから返すときに除くようにしました
- **Web ストレージのスナップショットを平文で保存していた**: 画面の localStorage などをそのまま平文の Box に残していました。暗号化 Box へ移し、旧 Box を削除するようにしました（上記）
- **別のサイトのページから Web ストレージのスナップショットを読み書きできた**: `Origin` の無い `POST` を受け付け、`Origin` を上流の origin と比べていたため、上流の origin のページ（proxy とは別 origin）からも読み書きできました。proxy 自身の origin とだけ比べ、応答に `Cache-Control: no-store` を付け、CORS ヘッダを付けない内部エンドポイントとして扱うようにしました（上記）。`requireAccessToken: false` では端末内の別アプリが `Origin` の無い `GET` で読めるため、`enableWebStorageInheritance` を有効にする場合は `requireAccessToken` を有効のままにしてください
- **画面が送ったべき等性キーを平文の Box のキーにそのまま残していた**: `proxy_idempotency` の Box のキーを、`h1:` に HMAC-SHA256（保存領域の暗号化鍵から用途ごとに導出した鍵。持ち主の HMAC と同じ仕組み）を付けた値にしました。0.25.0 以前の記録も照会し、保持期間（既定 24 時間）を過ぎると削除されます
- **暗号化しない Box で、削除した値がファイルに残っていた**: `encryptResponseCache: false` の応答キャッシュは明示的な消去（`clearCache()`、`clearCacheForUrl()`、1 時間ごとにも実行する `clearExpiredCache()`）の後（`cacheMaxSize` による追い出しでは圧縮せず、Hive の自動圧縮に任せます）、`proxy_port_preferences` は持ち主の記録を書き換えた後、`proxy_idempotency` は期限切れを削除した後に圧縮（`compact()`）するようにしました。フラッシュストレージ上の完全消去は保証しません

### 機能追加

- **`ProxyConfig.corsAllowedOrigins` を追加しました**（既定 `[]`）: `addCorsHeaders: true` のときに CORS ヘッダを返す origin の一覧です
  - 各値はパス・クエリ・フラグメント・ユーザー情報を持たない `http` / `https` の origin（例 `https://app.example.com`）か、`'*'` 単独です。scheme とホストの大小文字は区別せず、既定ポートは書いても書かなくても同じ origin とみなします
  - 要求の `Origin` が一致した場合だけ、`Access-Control-Allow-Origin` にその値を返し、`Access-Control-Allow-Methods` と `Access-Control-Allow-Headers` を付けます。応答が `Origin` によって変わるため、一致しない要求への応答を含めて `Vary: Origin` を付けます（上流の `Vary` には末尾に加えます）。`['*']` の場合だけ全ての要求へ `*` を返し、`Vary` は付けません。`Access-Control-Allow-Credentials` は付けません
  - origin として解釈できない値と、`'*'` と他の値の混在は、`addCorsHeaders` が `false` でも `start()` が `ProxyStartException` を投げます
- **`ProxyConfig.includeQueryInEvents` を追加しました**（既定 `false`）: イベントの URL にクエリとフラグメントを残すかどうかです（上記）
- **`QueueResendResult.toMap()` に `includeQuery` を追加しました**（既定 `true`）: `false` で `url` のクエリとフラグメントを除いた Map を返します
- **`ProxyConfig.forwardWebViewCookieNames` を追加しました**（既定 `{}`）: WebView が送った Cookie のうち、上流へ渡す名前の一覧です（上記）
  - Cookie Jar に同じ名前がある場合は Cookie Jar の値を送ります。名前は大小文字を区別します。秘密値の Cookie は設定にかかわらず渡しません
  - RFC 6265 の token でない名前、`OfflineWebProxy.accessTokenCookieName`、`'*'` と他の名前の混在は、`start()` が `ProxyStartException` を投げます
- **パスの検証で要求を拒否したときに `errorOccurred`（`phase: requestPath`）を発行するようにしました**: `data` の `reason` に `dotSegment` か `malformedPercentEncoding`、`method` に HTTP メソッドが入ります。パスの検証は秘密値の検査の後に行うため、秘密値を持たない要求は `403` になり、このイベントは出ません
- **起動時に持ち主の記録を信頼できず一時停止したときに `errorOccurred`（`phase: queueOwnerLoad`）を発行するようにしました**: `data` の `reason` に、タグが合わない場合は `tagMismatch`、持ち主を記録した要求があるのに記録が無い場合は `recordMissing` が入ります。`ProxyEvent.url` は空文字列です
- **Web ストレージのスナップショットの暗号化 Box を作り直したときに `errorOccurred`（`phase: webStorageRecovery`）を発行するようにしました**: Box を開けないか、保存しない形の値がある場合です。`data` の `error` に例外の型名が入ります
- **Web ストレージのスナップショットの暗号化 Box を削除できなかったときに `errorOccurred`（`phase: webStorageEncryptionCleanup`）を発行するようにしました**: 鍵を作り直す場合と、復旧 API が鍵を削除する場合です。`data` の `error` に例外の型名が入ります
- **`ProxyConfig.maxRequestBodyBytes`、`queueMaxCount`、`queueMaxBytes` を追加しました**: 範囲（`maxRequestBodyBytes` は 1024〜268435456、`queueMaxCount` は 1〜100000、`queueMaxBytes` は 1048576〜1073741824）の外は `start()` が `ProxyStartException` を投げます。`0` で上限を無くすことはできません
  - 本文は `Content-Length` を先に見て、上限を超える場合は保持しません。`Content-Length` の無い（chunked の）要求は、読みながら数えて超えた時点で読んだ分を捨てます。クライアントが `413` を受け取れるよう、超えた分は 16 MiB まで読み捨ててから応答し、それより大きい場合は読まずに接続を閉じます
  - `enableWebStorageInheritance` の受け渡しは、`maxRequestBodyBytes` と 5 MiB の小さい方を上限にします
  - キューの大きさは、要求ごとの URL、ヘッダの名前と値の UTF-8 長と本文の長さの和です。起動時に上限を超えていても既存の要求は消さず、下回るまで新しい要求を断ります。`retryQuarantinedRequest()` は上限で断りません。管理用の項目と保存形式の余分は数えないため、メモリと保存領域の使用量は目安として抑えるだけです。上限の判定から保存までは 1 件ずつ行い、その排他を 30 秒以内に取得できない場合は、保存領域を使えない場合と同じく `{"queued":false}` で `503` を返します
- **`OfflineWebProxy.restoreCookies()` に `queueOwnerId` を追加しました**: 復元するセッションの利用者を渡すと、`queueOwnerResolver` を指定して起動している場合にその利用者を送信待ちの持ち主にします（上記）
- **キューへ保存できなかった場合に `errorOccurred`（`phase: queueSave`）を発行するようにしました**: 保存領域を使えない場合は `reason: storageUnavailable`、キューへの投入のロックを 30 秒以内に取得できない場合は `reason: lockTimeout` です。要求のヘッダと本文は載せません
- **`ProxyConfig.cacheUserScopedResponses` を追加しました**（既定 `true`）: 利用者ごとの応答を応答キャッシュへ保存するかどうかです。`false` にすると保存せず、`ProxyEventType.cacheSkipped` を `reason: userScoped` で発行します。Cookie でセッションを持つ上流では、`false` にするとログインした後は事実上キャッシュされません
- **`ProxyEventType.cacheMiss` を発行するようにしました**: 利用者ごとに保存した応答の持ち主が現在の持ち主と一致しないため、キャッシュから返さなかった場合だけ発行します（`reason: ownerMismatch`）。記録が無いだけのミスでは発行しません
- **`OfflineWebProxy.clearWebStorageSnapshot()` を追加しました**: 保存した Web ストレージのスナップショットを削除します。Box を開いている間は空にして圧縮し、開いていなければ新旧の Box のファイルを削除します。稼働中かどうかと設定によらず呼び出せ、失敗した場合は `CacheOperationException`（`operation: clearWebStorageSnapshot`）を投げます

### 修正

- **キューの再送で、次の送信時刻を保存する前にメモリ上の記録を書き換えていた**: Box から読んだ値をそのまま書き換えていたため、保存する前に他の処理から新しい再試行回数が見え、保存に失敗した場合は失敗時の処理が再試行回数を二重に増やしていました。写しを更新して保存するようにしました。保存に失敗した場合、メモリ上の記録も変わりません

### ドキュメント

- 仕様書【2】の「到達の制限」「CORS ヘッダ」「内部エンドポイントの origin 制御」と【20】の設定一覧を、新しい既定値と `corsAllowedOrigins` に合わせて直しました
- README のクイックスタートに、WebView が読み込む前に秘密値の Cookie を置く手順を加え、設定の説明、「WebView 以外からの到達を防ぐ」、状態通知と管理エンドポイントの注意、example の e2e の説明を直しました
- 仕様書【2】と README に、秘密値の検査が有効な間は別 origin のページが（同じ WebView 内で `credentials: 'include'` により秘密値の Cookie を送れる場合を除き）preflight を含めて `403` になり CORS ヘッダが実質 `requireAccessToken: false` の場合にだけ意味を持つことと、上流自身が返す CORS ヘッダは proxy の制御外でそのまま返ることを書き足しました
- dartdoc（`ProxyConfig.requireAccessToken`、`addCorsHeaders`、`corsAllowedOrigins`、`OfflineWebProxy.accessToken` ほか）を新しい既定値に合わせて直しました
- example アプリが、起動後に `WebViewCookieManager` で秘密値の Cookie を置いてから読み込むようにしました
- 仕様書【4】の「Cookie 評価基準」に `Expires` の解釈と「上流の Set-Cookie の受け入れ規則」を加え、【1】の中継表、【14】の Set-Cookie、【18】の「イベントの URL」、【20】の `restoreCookies()` と `errorOccurred`（`operation: cookieSave`）の説明を合わせて直しました。README の「Cookie API」、中継の注意、イベントの説明にも受け入れ規則を書き足しました
- 仕様書【18】に「イベントの URL」を加え、要求ログの形式・マスキング対象・ログ出力例を実際の形式に合わせて直しました。管理エンドポイントの隔離の一覧は要求を見分けるため完全な URL を返すことも明記しました。【1】【6】の Hive のキー、【4】の鍵の状態の区分、【5】の再送結果の通知と状態通知エンドポイント、【10】の要求ログ、【20】の設定一覧・`ProxyEvent`・`QueueResendResult` を合わせて直しました
- README に `includeQueryInEvents` の説明を加え、要求ログ、再送結果、状態通知、イベント、保存データ、鍵の形式の説明を直しました
- 仕様書【1】の「設定のパスパターン記法」に正規化の手順と 0.26.0 での変更を、【2】に「待ち受けるホストの制限」「Host ヘッダの照合」「パスの検証」を、【14】に「要求元を名乗るヘッダ」を加え、【2】のポート管理とセキュリティ考慮、【18】の要求ログとイベントの URL、【20】の `start()` の例外・設定一覧・`errorOccurred`（`phase: requestPath`）を合わせて直しました。README の設定の説明と「WebView 以外からの到達を防ぐ」にも書き足しました。dartdoc（`PathPattern`、`ProxyConfig.host`）も合わせました
- 仕様書【1】の中継表、【5】の「キュー管理」、【14】の Cookie ヘッダと Set-Cookie ヘッダ、【20】の設定一覧と `start()` の例外に、`forwardWebViewCookieNames` と中継先の `Set-Cookie` の扱いを加えました。README の設定の説明、中継の注意、「Cookie API」に、WebView の Cookie の扱いと 0.25.0 からの移行手順（スクリプトで置いた Cookie を送る場合の設定）を加えました。受け入れ規則で Cookie Jar に保存されなかった Cookie（`http` の上流の `Secure` など）が 0.26.0 からは上流へ送られないこと（`errorOccurred` の `cookieSave` で確認できること）と、複数行の `Cookie` ヘッダを `; ` でまとめてから絞ることも明記しました。dartdoc（`ProxyConfig.forwardWebViewCookieNames`、`mirroredOrigins`）も合わせました
- 仕様書【5】の「保持上限」に「キューと要求本文の上限」を加え、【1】の保存データ表のキューの保持期間（従来「上限なし」）、【5】の「キュー管理」、【10】のキュー投入時と要求本文が大きすぎる場合の応答、【18】の「イベントの URL」、【20】の設定一覧と `errorOccurred` を更新しました
- README に「キューと要求本文の上限」を加え、設定例と設定の説明、保存データ表を更新しました
- 仕様書【5】の「再送打ち切りの条件」に `origin_changed`、「送信待ちの持ち主」に受け付けた時点の記録・並行したログイン・判定関数が `null` を返した場合・「ログイン以外でセッションを変える操作」・記録のタグと 0.25.0 からの移行を、「再送結果の通知」に停止と重なった場合の扱いを加えました。【6】に「キーの衝突」（`422`）を、【10】に `422` と `errorOccurred`（`phase: queueSave`）を加え、【1】の保存データ表、【18】の「イベントの URL」、【20】の `restoreCookies()`・`clearCookies()`・`DroppedRequest`・`QuarantinedRequest`・`QueueResendResult`・`QueuePauseReason.ownerUnresolved`・`errorOccurred`（`phase: queueOwnerLoad` / `queueSave`）を合わせて直しました。README の「端末を共用する場合」「Cookie API」と設定の説明、dartdoc（`ProxyConfig.queueOwnerResolver`、`QueuePauseReason.ownerUnresolved`、`DroppedRequest.dropReason`、`QuarantinedRequest.reason`、`QueueResendResult.statusCode`）も合わせました
- 仕様書【8】の「保存ポリシー」に `Set-Cookie` を保存しないことを、「利用者ごとの応答（cacheUserScopedResponses）」を新設し、「フォールバック利用条件」「ウォームアップ」「保存形式」「キャッシュキー」を合わせて直しました。【1】の保存データ表、【14】の Set-Cookie ヘッダ、【18】の「イベントの URL」、【20】の設定一覧と `cacheSkipped`・`cacheMiss` の説明も更新しました
- README の設定例と設定の説明に `cacheUserScopedResponses` を、「端末を共用する場合」に応答キャッシュの持ち主の扱いを加え、保存データ表を直しました
- 仕様書【1】の保存データ表に `proxy_web_storage_secure` と `proxy_idempotency` の新しいキー、暗号化しない Box の圧縮を、【2】に Web ストレージの受け渡しを常に内部エンドポイントとして扱うことを、【4】に Hive の暗号化に MAC が無いことを「既知の制約」として、復旧 API の照合し直しの上限（2 分）と `verificationTimedOut` を、【5】に「Web ストレージの受け渡し」を、【6】にべき等性キーの記録の形式と 0.25.0 以前の記録の照会を、【20】に `clearWebStorageSnapshot()` と `StorageRecoveryRejection.verificationTimedOut` を加えました
- README の保存データ表、「Web ストレージのスナップショット」（新設）、端末を共用する場合の注意、復旧 API、現在の制約（MAC が無いこと）を更新しました

### テスト

- `test/support/access_token_http.dart` を追加しました。登録した proxy 宛ての要求に秘密値のヘッダを付ける `HttpOverrides` で、秘密値そのものを検証しないテストも既定の設定（秘密値が必須）のまま実行します
- `test/access_token_test.dart` に、既定で秘密値の無い要求を `403` にし稼働確認は通すこと、既定で CORS ヘッダを付けないこと、許可した origin にだけその origin と `Vary: Origin` を返すこと（大小文字と既定ポートの扱い、不一致・`null`・`Origin` なしを含む）、上流の `Vary` への追加、`'*'` の扱い、内部エンドポイントに付けないこと、`addCorsHeaders: true` で一覧が空の場合と形式の正しくない値での起動の拒否のテストを追加しました
- `test/access_token_test.dart` に、秘密値が必須の設定と `corsAllowedOrigins` を組み合わせ、秘密値付きの要求にだけ CORS ヘッダを返し、秘密値の無い要求と preflight の `403` には付けないことのテストを追加しました
- `test/status_endpoint_test.dart` と `test/admin_api_test.dart` の内部エンドポイントに CORS ヘッダを付けないことのテストを、CORS ヘッダを有効にした設定（`['*']` と一覧指定）で確かめるように直しました
- `test/models_test.dart` に、`requireAccessToken`、`addCorsHeaders`、`corsAllowedOrigins` の既定値のテストを追加しました
- example の e2e（`integration_test/`）が、読み込む前に秘密値の Cookie を置き、WebView 以外からの要求にはヘッダを付けるようにしました（`integration_test/support/access_token.dart`）
- example の Android ビルドを、現行の Flutter（3.47 系）が求める版へ上げました（Gradle 8.14.3、Android Gradle Plugin 8.11.1、Kotlin 2.2.20）。パッケージ本体の要件は変わりません
- example の e2e `offline_web_proxy_device_e2e_test.dart` が、応答キャッシュを開き終わる前に要求を送っていたため、`proxy.cacheReady` を待ってから送るようにしました
- `test/information_exposure_test.dart` を追加しました。要求ログにクエリの値が出ないことと処理中の例外を型名だけで出すこと、`requestReceived` と `redirectHandled` の URL の項目から既定でクエリとフラグメントを除き `includeQueryInEvents: true` で残すこと、外部起動の `externalUrl`（https・`mailto:`・`geo:`）は設定によらずクエリを残し `locationHeader` からは除くこと、状態通知の `recentResendResults` にクエリが無く Dart API には残ること、`queueResendAttempted` の `url` の扱い、Cookie の保存に失敗したイベントに `Set-Cookie` の値が載らないこと（`invalidSetCookie` と `storageFailure`）を確かめます
- `test/cookie_acceptance_test.dart` を追加しました。`Expires` の解釈（RFC 1123、`-` 区切りの 4 桁の年、2 桁の年、3 桁の年、asctime、1 桁の時刻、タブ区切り、月の正式名、年が先頭、うるう年、不正な値）、`Max-Age` の形の検査と不正値の無視・0 以下の即時失効・400 日の上限（`Expires` を含む）、`Path` の default-path、`Secure` の Cookie を影で覆う判定（親ドメイン、path-match）、ウォームアップの応答への受け入れ規則の適用、受け入れ規則の拒否理由ごとの正例と反例、規則を適用しない `restoreCookies()` 向けの解釈、IP ホストと `Domain`、ホスト限定の扱い、過去の `Expires` による削除、`http` の応答が `Secure` の Cookie を上書き・削除できないこと、中継先が設定済み origin へ送られる Cookie を置けないこと、拒否と保存領域の失敗のイベントに値が載らず要求の処理を続けることを確かめます
- `test/information_exposure_test.dart` に、応答をキャッシュへ保存できなかったときの `errorOccurred`（`phase: cacheResponse`）が例外の型名と `reason: storageFailure` だけを載せ、クエリを含まないことのテストを追加しました。redirectHandled の URL の項目の一覧から、常に完全な URL を載せる `externalUrl` を外しました
- `test/encryption_key_reader_test.dart` と `test/storage_integrity_test.dart` に、末尾の改行や空白の付いた鍵を「あり」として読むこと、形式の正しくない鍵のエラーと `StorageIntegrityException`（`toString()` を含む）に鍵の文字列が含まれないことのテストを追加しました
- `test/hive_key_length_test.dart` に、`sha256:<64 桁の 16 進>` の短いキーと長いキーの置き換え後の値が衝突しないことのテストを追加しました
- `test/offline_web_proxy_test.dart` の外部起動（地図）の redirect のテストで、既定の設定のまま `externalUrl` はクエリを含み、`locationHeader` からはクエリを除くことを確かめるように直しました
- `test/forward_webview_cookie_test.dart` を追加しました。既定で WebView の Cookie を上流へ渡さないこと、挙げた名前だけを渡すこと（大小文字の区別を含む）、Cookie Jar の値を優先すること、`'*'` で秘密値以外を渡すこと、不正な名前・秘密値の Cookie 名・`'*'` と他の混在での起動の拒否、中継先の `Set-Cookie` を WebView へ返さず Cookie Jar に保存すること、設定済み origin の `Set-Cookie` は従来どおり返すこと、キューへ保存する `Cookie` を絞り残らなければ保存しないこと、0.25.0 形式の保存データの再送で挙げていない Cookie を送らないこと、`Cookie` ヘッダが複数の行に分かれていても転送とキューへの保存で挙げていない Cookie が値に紛れないこと、中継先の redirect（302 と中継先内の `Location`）の `Set-Cookie` を WebView へ返さず Cookie Jar に保存することを確かめます
- `test/request_target_test.dart` を追加しました。生のソケットで `Host` を偽り、proxy 自身を指す `Host`（`127.0.0.1`、`localhost`、大文字、`[::1]`）を受け付けること、別のホスト名・違うポート・ポートなし・末尾ドット・`127.0.0.2`・`[::2]`・省略形でない IPv6・空の `Host` と `Host` の無い要求・別ホストの絶対 URL を `403`（CORS ヘッダなし、統計とイベントに数えない）にすること、稼働確認も照合し秘密値の検査より先に拒否すること、再バインド後のポートと照合すること、`0.0.0.0`・`192.168.1.10`・`::` などで起動せず `localhost`・`127.0.0.2`・`::1` で起動すること、`..%2F`・`%2E%2E%2F`・`%5C..`・`..;` を `400` とイベントで拒否し、`/` で区切った `%2E%2E/` は dart:io が解決して上流へ `..` を渡さないこと、不正な `%` は `%25` として転送すること、`a%2Fb` を転送すること、`;jsessionid`・末尾の `/`・`%6C`・`//` の書き方でも `authResumePaths` と `queueExcludePaths` に一致すること、要求元を名乗るヘッダが転送・中継・キューへの保存・再送（0.25.0 形式の保存データを含む）で上流へ届かないこと、`X-Forwarded-Host` / `-Proto` を持つ要求をパス・クエリ・userinfo を含む値を含めて `403` にし注入した値がイベントに出ないこと、userinfo を持つ絶対 URL を拒否すること、不正な UTF-8 のパスは shelf が `400` にすることを確かめます
- `test/request_target_check_test.dart` を追加し、パスの検証（dot セグメントと不正な `%` の判定）と `Host` ヘッダの解釈を確かめます。`test/path_pattern_test.dart` に、`;` 以降の除去、`/` の重複と末尾の `/`、非予約文字の `%XX` だけの復号、末尾のワイルドカードの扱いのテストを追加しました
- WebView の Cookie が上流へ届くことを確かめていた既存のテスト（`test/access_token_test.dart`、`test/integration_test.dart`、`test/offline_web_proxy_test.dart`、`test/queued_request_masking_test.dart`、`test/mirrored_origin_test.dart`）は、`forwardWebViewCookieNames` で名前を挙げるように直しました
- `test/resource_limits_test.dart` を追加しました。要求本文の上限ちょうどは受け付け 1 バイト超えると `413` になること（`Content-Length` あり・chunked、オンライン・オフライン）、`413` の後も同じクライアントの後続の要求を処理できること、読み捨てる上限を超える本文の後も処理を続けること、Web ストレージの受け渡しの上限、キューの件数と合計サイズの上限で `503` と `errorOccurred`（`phase: queueLimit`）になること、再起動後も合計サイズを数え直すこと、上限を下げても既存の要求を消さないこと、再送の成功・隔離・ドロップ・`skipPausedRequest()`・持ち主の変更で取り除いた後に再び投入できること、隔離から戻す要求を上限で断らないこと、保存領域の復旧の後に再び投入できること、同時に届いた要求を上限までしか保存しないこと、満杯でも同じべき等性キーの送り直しは既存のキュー ID で受け付けること、オフラインで `queueExcludePaths` に一致する要求は上限を超える本文でも除外の応答を返すこと、chunked の本文が上限を 16 MiB より多く超えた後も処理を続けること、合計が `queueMaxBytes` ちょうどの要求は保存し 1 バイト超えると保存しないこと、上限による `503` の本文が `{"queued":false,"error":"queue_full"}` であること、範囲外の設定で起動しないことを確かめます
- `test/queue_owner_test.dart` に、上流が応答を待たせている間に別の利用者がログインしても受け付けた時点の持ち主を記録すること、並行したログインで応答の順序を入れ替えても Cookie Jar と持ち主が一致すること、`restoreCookies()` の `queueOwnerId` あり（別の利用者・同じ利用者）となし、判定関数が無い場合に `queueOwnerId` を使わないこと、復元中に送り始めていた再送を中断すること、`clearCookies()` の全件と `domain` 指定で一時停止すること、べき等性キーの衝突（内容・持ち主）で `422` になり同じ内容なら既存の ID を返すこと、`origin` を変えた後の再送が `origin_changed` になること、持ち主の記録の改ざん・削除で `ownerUnresolved` になること、0.25.0 形式の記録を 1 回だけ移行すること、`errorOccurred`（`phase: queueSave`）のテストを追加しました。ログインの転送中に終了した場合と停止した場合のテストは、タグを付け直した記録を使い、起動し直した後に前の持ち主の要求を移さず `ownerUnresolved` で止めることを確かめるように直しました。あわせて、`clearCookies()` と `queueOwnerId` の無い `restoreCookies()` の後に起動し直しても要求を移さないこと、`mirroredOrigins` に入れた旧 origin への要求も `origin_changed` になること、相対 URL の旧データを現在の origin で送ること、判定関数が無い間はべき等性キーの照合で持ち主を比べないこと、指紋の無い旧データをメソッドと URL で比べること、上流の 5xx の経路の衝突では上流の応答を返すこと、上流へ届かない経路でも受け付けた時点の持ち主を使うこと、一度も起動していない間の `restoreCookies()` が持ち主を変えないこと、`errorOccurred`（`phase: queueSave`、`reason: lockTimeout`）のテストを追加しました。順番待ちを取れずに外で Cookie が書かれた場合に順番待ちを持つログインが持ち主を決めないこと、正体の分からない持ち主の要求しか無ければ起動時に止めずに送ること、起動時に止めた後の `resumeQueue()` で前の持ち主の要求を移すこと、Cookie の復元と削除に失敗した場合に止めること（テスト用の窓口 `beforeQueueOwnerDecided`・`beforeCookieStoreChanged`・`beforeQueueEntrySaved` を追加）のテストも追加しました
- `test/cache_owner_test.dart` を追加しました。保存した記録（Box の値と平文のファイル）に `Set-Cookie` と `Set-Cookie2` が残らず WebView へは返すこと、利用者ごとの応答を持ち主 A で保存し B ではミス・A に戻すとヒットすること（オフラインと上流到達不能の両方）、正体の分からない持ち主の扱い、誰もログインしていない間の応答は「持ち主なし」の印で保存して持ち主が無い間だけ返し、ログイン後と `clearCookies()` 後はミスにすること、取得の間に持ち主が変わった応答を保存しないこと、`getCacheList()` に持ち主を出さないこと、`cacheUserScopedResponses: false` で Cookie・`Authorization`・`Set-Cookie`・`private` の応答を保存しないこと、判定関数が無い場合は 0.25.0 と同じく保存して返すこと、`forceCachePaths` の除外が変わらないこと、ウォームアップでも同じく扱うことを確かめます。あわせて、Cookie や `Authorization` を送っても `public` の応答は利用者ごとにしないこと（`s-maxage`、`max-age=0, must-revalidate`、`public` と `Vary: Cookie` / `Authorization` / `*` の組み合わせ、`Set-Cookie`、`private="Set-Cookie"` は利用者ごと）、旧記録の `Set-Cookie2` を返さないこと、再起動後も同じ持ち主ならヒットすること、他のログインの転送中に取得した応答と自分自身のログインの `GET`、`Authorization` を送った応答へのタグ、上流を遮断している間の照合を確かめます。`test/models_test.dart` に `cacheUserScopedResponses` の既定値のテストを追加しました
- `test/storage_hardening_test.dart` を追加しました。Web ストレージのスナップショットを暗号化 Box に平文を残さず保存すること、旧平文 Box から移して削除すること（暗号化 Box の写しを上書きしないこと）、無効なら Box を開かず旧 Box を削除すること、`clearWebStorageSnapshot()`（稼働中・停止中・無効な設定で稼働中）、proxy 自身の origin（`127.0.0.1` と `localhost`）からの要求を受け付け、上流の origin・別のポート・`https`・`null` の `Origin`、`Origin` の無い `POST`、`Sec-Fetch-Site: cross-site` / `same-site`、`PUT` などのメソッドを拒否すること、`Cache-Control: no-store`、CORS ヘッダを付けず統計に数えないこと、無効時に上流へ転送せず `404` を返すこと、移行が途中で失敗しても起動を続け次の起動で移すこと（テスト用の窓口 `beforeLegacyWebStorageMoved` を追加）、無効な設定で旧 Box を削除できなくても起動を続け次の起動で消すこと（同 `beforeLegacyWebStorageDeleted`）、暗号化 Box を作り直した場合も移すこと、べき等性キーを `h1:` の HMAC で記録して生のキーを Box とファイルに残さないこと、0.25.0 の規則（`sha256:` で始まる短いキーを含む）で記録した旧記録を照会し、その要求を再送しないことを確かめます
- `test/encrypted_cache_test.dart` に、`encryptResponseCache: false` で `clearCache()` と `clearCacheForUrl()` の後に、削除した本文がファイルに残らないこと、追い出しでは圧縮しないことのテストを追加しました
- `test/storage_recovery_test.dart` に、照合し直しが時間の上限を超えた場合（照合打ち切りの Box と先頭側が壊れた Box）に、何も消さずに `verificationTimedOut` を返すことのテストを追加しました（テスト用の窓口 `recoveryVerificationTimeLimit` を追加）
- Web ストレージの受け渡しの `POST` に `Origin` が必須になったため、`test/offline_web_proxy_test.dart` と `test/resource_limits_test.dart` の要求に proxy 自身の `Origin` を付けました。Web ストレージの Box を既定で開かなくなったため、`test/storage_initialization_test.dart` の段階 2 の Box の確認を、べき等性キーの Box と（有効にした）暗号化した Web ストレージの Box で行うように直しました
- `test/queue_resend_status_test.dart` に、次の送信時刻の保存に失敗しても再試行回数を二重に増やさないことのテストを追加しました（テスト用の窓口 `beforeRetryScheduleSaved` を追加）。`Retry-After` のテストが、再送結果の記録より先に再試行回数を見て抜けることがあったため、再送結果の記録も待つように直しました

## 0.25.0

### 破壊的変更の注意

- `QueuePauseReason` に `ownerUnresolved` を追加しました。`default` の無い `switch` で網羅している場合は、分岐の追加が必要です

### 機能追加

- **別の利用者の送信待ちを、ログインし直した利用者のセッションで送らないようにできるようにした**（opt-in）: 端末を共用していると、利用者 A の送信待ちが残ったまま利用者 B がログインし直した場合に、A の更新が B のセッションで送られていました。`ProxyConfig.queueOwnerResolver`（`QueueOwnerResolver`、`String? Function(QueueOwnerContext)` の同期関数）を指定すると、送信待ちに持ち主を記録し、持ち主が違う要求を送らずに取り除きます。既定は `null` で、0.24.0 と同じ動きです
  - `authResumePaths` に一致する要求に上流が 2xx か 3xx を返したときに呼びます。`QueueOwnerContext` でログインの要求と応答（解凍済みの本文）を渡し、`requestJson`、`responseJson`、`requestFormFields`、`requestHeader()` などで読めます。空でない文字列を返すと現在の持ち主になり、`null` か空文字列なら持ち主を変えません
  - キューへ入れるときに持ち主を記録し、再送の直前（再試行待ちの要求も含む）に現在の持ち主と比べます。両方分かっていて違う場合は、送らずに `dropPolicy` に従って隔離またはドロップ履歴へ移します（理由 `owner_changed`、状態コード `0`、`errorMessage` は `Queue owner changed`）。`retryQuarantinedRequest()` で戻しても持ち主を引き継ぎます。どちらかが分からない要求は従来どおり送ります
  - ログインの転送中はキューから新しく送りません。転送を始める前から送り始めていた再送は、本文を送る直前に中断し、次の周回で送り直します（失敗に数えません）
  - 判定関数が例外を投げた場合と、持ち主を決められない・保存できない場合は、`ProxyEventType.errorOccurred`（`phase: queueOwnerResolve` / `queueOwnerPersist`。`error` は例外の型名だけ）を発行し、ログインした利用者を正体の分からない持ち主とみなして、キューを `QueuePauseReason.ownerUnresolved` で一時停止します。`resumeQueue()` か、持ち主が決まる次のログインで再開します。`skipPausedRequest()` の対象外です
  - 識別子はそのまま保存せず、保存領域の暗号化鍵から導出した鍵の HMAC-SHA256 だけを持ちます。イベント・状態通知・管理 API には出しません。現在の持ち主とログインを転送中かどうかは `proxy_port_preferences` に保存し、起動し直しても引き継ぎます。鍵が変わった値は捨てます
  - 指定したのに `authResumePaths` が空の場合は、`start()` が `ProxyStartException` を投げます
  - この設定を使う前にログインしたセッションで溜まった送信待ちは、持ち主が無いため次のログインまで保護されません。持ち主はインスタンスごとに持ちます
- **断られた応答の本文の先頭を隔離に残せるようにした**（opt-in）: 4xx で隔離した要求の `errorMessage` は `HTTP 400` のような状態コードだけで、上流が拒否した理由が分かりませんでした。`ProxyConfig.quarantineResponseBodyMaxBytes`（既定 `0`、0〜65536）を 0 より大きくすると、本文の先頭を `QuarantinedRequest.responseBodyPreview` に残します
  - 対象は `Content-Type` が `text/*`、`application/json`、`+json` の種類で、文字コードが UTF-8・US-ASCII・指定なしの本文です。gzip は 256 KB までなら解凍してから先頭を取り、それ以外の `Content-Encoding` は残しません。UTF-8 の文字の途中では切りません
  - 隔離と一緒に暗号化して保存し、`quarantineMaxBytes` の合計に含めます。先頭を含めると 1 件で `quarantineMaxBytes` を超える場合は、先頭を外して隔離します
  - 読めるのは `getQuarantinedRequests()` だけで、管理 API の隔離の一覧、イベント、状態通知、ドロップ履歴には出しません。`retryQuarantinedRequest()` で送り直すときに消します
  - 個人情報（利用者が入力した値など）が入り得るため、必要なときだけ有効にし、要求を送った本人にだけ見せてください
  - 範囲外の値は `start()` が `ProxyStartException` を投げます

### 修正

- **停止の途中で失敗した更新系の要求を、閉じたキューへ書き込もうとして 500 を返していた**: `stop()` の前から転送していた要求が失敗してキューへ入れようとすると、閉じた保存領域へ書き込もうとして例外になっていました。保存できない場合と同じく、`503` と `{"queued":false}`（`X-Offline-Queued: 0`）を返すようにしました

### ドキュメント

- 仕様書【5】に「送信待ちの持ち主」と「隔離に残す応答本文」を加え、【1】の端末に保存するデータ、【5】の状態通知と保持上限、【17】のインスタンスと isolate、【20】の API リファレンスを合わせて直しました
- README に、端末を共用する場合の設定例と `quarantineResponseBodyMaxBytes` の説明を加えました

### テスト

- `test/queue_owner_test.dart` に、別の持ち主の要求の隔離、同じ持ち主での送信、判定関数が無い場合と `null` を返した場合の扱い、例外での一時停止と再開、隔離から戻した要求の持ち主、`DropPolicy.drop`、起動し直した後の持ち主の引き継ぎと別の鍵の値の破棄、ログインの転送中の送信の停止と中断、ログインの途中で停止・終了した場合の扱い、GET のログインとリダイレクトの応答、識別子を保存・通知しないこと、`authResumePaths` が空の設定の拒否、`QueueOwnerContext` の読み取りのテストを追加しました
- `test/queue_resend_status_test.dart` で、キューが空になった直後に再送結果を読み、結果の記録より先に判定して失敗することがあったため、上流が受け取った件数分の結果がそろうまで待つようにしました
- `test/quarantine_response_preview_test.dart` に、既定で残さないこと、JSON の本文を残して起動し直した後も読めること、対象の種類と文字コード、文字の境界での切り方、gzip の解凍と 256 KB の上限、他の圧縮方式、管理 API に出さないこと、`quarantineMaxBytes` との関係、受信の締め切り、再び隔離した場合の置き換え、範囲外の値の拒否のテストを追加しました

## 0.24.0

### 動作の変更

- 起動の直後、応答キャッシュを開き終わるまで（0.21.0 以前から更新した直後の移行中は数十秒）は、オンラインの GET の応答を保存しません
- 起動の直後にオフラインの場合、キャッシュから返す要求は応答キャッシュを開き終わるまで待ちます。`requestTimeout` を超えた場合は、キャッシュが無いものとして扱います
- 起動の直後に `stop()` を呼ぶと、応答キャッシュを開き終わるまで（200 MB で数秒）待つことがあります。Hive が Box を開く処理そのものは打ち切れないためです
- 応答キャッシュを開けない場合も `start()` は失敗しなくなりました（下記）

### 改善

- **応答キャッシュを `start()` の後に裏で開くようにした**（#42、#43）: Hive は Box を開くときにファイル全体を読むため、応答キャッシュを開く時間は大きさに比例します。Android エミュレータでの測定では約 30 ms/MB で、既定の上限の 200 MB では約 6 秒（推定）、`start()` がその間返りませんでした。0.21.0 以前から更新したときの暗号化への移行は、200 MB で 40 秒を超える見込み（推定）でした
  - `start()` は応答キャッシュを開き終わるのを待たずに返ります。移行も、開く処理の中で裏で進めます
  - 開き終わるまでは、オンラインの GET の応答を保存しません（`ProxyEventType.cacheSkipped`、`reason: cacheOpening`）。キャッシュから返す要求（オフライン、上流到達不能、上流のタイムアウト）は、要求を受け付けてから `requestTimeout` までを上限に開き終わるのを待ち、キャッシュの API（`getCacheStats()` など）は開き終わるのを待ちます
  - 開き終わりを待つ `cacheReady` を追加しました。起動直後にオフラインで画面を表示する前に待つ場合に使います
  - 応答キャッシュを開けない場合も `start()` を失敗させず、キャッシュを使わずに動作を続けます（`ProxyEventType.errorOccurred`、`phase: cacheOpen`）。これまでは `start()` が失敗していました
  - `stop()` と起動の失敗では、移行を打ち切ってから応答キャッシュを閉じます。移していない記録は次の起動で移します

### ドキュメント

- 応答キャッシュを開く時間と移行にかかる時間の説明（dartdoc、仕様書【8】【16】、README）に、Android エミュレータでの測定値を加えました。0.22.0 で「スマートフォンでは数倍」と書いた見積もりより長くかかる見込みです

### テスト

- `test/encrypted_cache_test.dart` に、`start()` が開き終わるのを待たずに返ること、開いている間の保存・キャッシュからの応答・API の扱い、`requestTimeout` での待ち合わせの打ち切り、`stop()` による移行の打ち切りと次の起動での再開、開けない場合の扱い、起動に失敗した場合の扱い（開く処理を待つ間は別の `start()` を受け付けないこと、別のインスタンスが開いている応答キャッシュを閉じないこと）のテストを追加しました
- 起動の直後にキャッシュを使う既存のテストで、`cacheReady` を待つようにしました

## 0.23.0

### 破壊的変更の注意

- `ProxyEventType` に `authenticationRequired` を追加しました。`default` の無い `switch` で網羅している場合は、分岐の追加が必要です
- キューからの再送で PUT・DELETE への 303 が返ると、届いたものとしてキューから消えるようになりました（これまでは再試行を続けていました）。セッション切れを 303 で返す上流では、`authRequiredStatusCodes` に 303 を指定してください
- キューからの再送で 408・429 が返っても、隔離・ドロップせずに再試行するようになりました。隔離されることを前提にした運用は見直してください

### 機能追加

- **認証が必要な応答でキューの送信を一時停止できるようにした**（opt-in）: Cookie のセッションで認証する上流では、オフラインの間にセッションが切れ、回線が戻るとキューの要求がすべて 4xx で隔離されていました。`ProxyConfig.authRequiredStatusCodes`（例 `{401}`）に指定した状態コードが返ると、その要求をキューに残して送信を一時停止し、後続も送りません
  - 一時停止すると `ProxyEventType.authenticationRequired` を発行し、`ProxyStats.queuePausedReason` と状態通知の `queuePausedReason` が `authenticationRequired` になります。キーで照会した状態は `queued` のままです
  - `resumeQueue()` を呼ぶか、`ProxyConfig.authResumePaths` に一致するログインが proxy を通って 2xx か 3xx を返すと再開します。ログインで受け取った Cookie で送り直します
  - ログインし直しても通らない要求は、`skipPausedRequest()` で `dropPolicy` に従って隔離またはドロップ履歴へ移せます（理由 `authentication_required`）
  - 指定できるのは 300〜499 です。権限不足でも返る `403` などを指定すると、ログインで解決しない要求でキューが止まる点に注意してください
  - `303` も指定できます。指定しない場合、`303` は届いたものとみなします（下記の修正）

### 修正

- **キューからの再送で 408・429 が返ると、再試行せずに隔離していた**（#38）: 一時的な状態を表すため、5xx と同じく取り除かずに再試行するようにしました
  - `Retry-After`（秒数、または HTTP の日時）があれば、その時刻まで待ちます（今から 1 時間を上限。5xx の `Retry-After` は使いません）
  - 429 を受けたら、その要求を送り直す時刻まで、キュー全体の送信を控えます。後続を送り続けてレート制限が長引かないようにするためです。控えている間は、`ProxyStats.queuePausedReason` と状態通知の `queuePausedReason` が `rateLimited`（`QueuePauseReason` に追加）に、`ProxyStats.queuePausedUntil` と状態通知の `queuePausedUntil` が再開する時刻（UTC）になります
- **上流がセッション切れを POST への 303 で返すと、キューの要求が届いたものとして消えていた**（#37）: 再送は `dart:io` の既定でリダイレクトをたどっていたため、POST への 303 は GET で転送先へたどり、ログイン画面の 200 を成功と判定していました
  - 再送ではリダイレクトをたどらないようにしました（最初の転送と同じ）
  - 303（See Other）は、メソッドにかかわらず届いたものとみなします。303 は上流が要求を処理したことを表すためです。これまで PUT・DELETE への 303 は再試行を続けていました
  - セッション切れを 303 で返す上流では、`authRequiredStatusCodes` に 303 を指定すると一時停止できます。指定しない場合は届いたものとみなします（POST は従来と同じ結果、PUT・DELETE はこれまで再試行を続けていました）
  - 303 以外の 3xx は、従来どおり再試行を続けます

### ドキュメント

- 仕様書【16】の「設定例」は、実装に無い設定ファイル（`assets/config/config.yaml`）と、実装に無い項目（`jitterPercent`、`drainIntervalSeconds` など）を記載していました。`ProxyConfig` で渡す実際の例に改め、【8】の有効期限の計算順と `start()` の説明にあった「設定ファイル」の記述も直しました
- 仕様書【16】の、実装に無い記述を実際の動作に改めました。stale 期間の YAML の設定例と上限（`maxStalePeriod`）、定期 purge での破損キャッシュの削除、ディスクの空き容量による削除、終了時のメモリキャッシュのクリア、設定変更時の有効期限の再計算です
- 仕様書【15】の再試行の条件を、【5】に合わせて直しました
- `ProxyConfig.retryBackoffSeconds` の dartdoc の「末尾の値に揺らぎを加える」との記述を、実装に合わせて直しました（揺らぎは加えていません）
- `ProxyConfig.forceCachePaths` の dartdoc に残っていた「応答キャッシュは暗号化しない」との記述を、0.22.0 の既定（暗号化する）に合わせて直しました

### テスト

- `test/queue_auth_pause_test.dart` を追加しました。一時停止と後続の保留、`resumeQueue()` とログインの成功（3xx）による再開、再び一時停止すること、`skipPausedRequest()`（隔離、ドロップ、隔離の上限を超える場合）、3xx の指定、送信中のログイン、設定の検証（境界値を含む）、停止による解除、既定では従来どおり隔離することを確認します
- `test/queue_resend_status_test.dart` を追加しました。408 の再試行、429 の `Retry-After` とキュー全体の送信の控え、`Retry-After` の上限（日時と桁の大きな秒数）、通常の待ち時間より短い値、解釈できない値と負の値、5xx の `Retry-After` を使わないこと、停止による控えの解除、429 を指定した場合の一時停止の優先、控えている間の `queuePausedReason`・`queuePausedUntil`、303 を届いたものとみなしてたどらないこと（POST・PUT）、`authRequiredStatusCodes` に指定した 303 での一時停止、303 以外の 3xx の再試行を確認します

## 0.22.0

### 破壊的変更の注意

- `ProxyConfig.encryptResponseCache` の既定を `true` に変えました。0.21.0 以前から更新すると、最初の `start()` の中で平文の応答キャッシュを暗号化した保存領域へ移し、平文のファイルを削除します。パソコンでの測定で 30 MB に約 1.1 秒、200 MB に約 7.5 秒かかりました（1 回だけ）。移す処理は `start()` を呼んだ isolate で行うため、スマートフォンでは数倍かかり、その間は画面の描画が止まることがあります。従来どおり平文で保存するには `encryptResponseCache: false` を指定してください
- 応答キャッシュの保存先の Box 名と形式を変え、0.21.0 以前の `proxy_cache`・`proxy_cache_secure` は移した後に削除します。**0.21.0 以前へ戻すと、応答キャッシュは空から始まります**

### 変更

- **応答キャッシュを既定で暗号化するようにした**: `forceCachePaths` で保存した個人情報や業務データの API の応答が、既定の設定でも端末に平文で残らなくなります。暗号化しても、本文は返すときに 1 件ずつ復号するため、起動はほとんど遅くなりません（下記）

### 改善

- **応答キャッシュの本文を、開いたときにメモリへ載せないようにした**: 応答キャッシュは 1 つの Hive の Box に全件を置いていたため、`start()` で全件を読み込み（暗号化した場合は全件を復号し）、キャッシュ全体（既定の上限で最大 200 MB）を起動中ずっとメモリに置いていました。メタデータ（ステータスコード、保存日時、有効期限、Content-Type、本文の大きさ）の Box と、ヘッダと本文を 1 件ずつ読む LazyBox に分けました
  - パソコンでの測定で、暗号化した 200 MB のキャッシュを開く時間は約 3.2 秒から約 0.75 秒になり、キャッシュ全体をメモリに置かなくなりました（開いたときに増えるメモリは数 MB）。キャッシュから返すときの読み込みは 1 件あたり 1 ms 未満です
  - 期限切れの削除、`cacheMaxSize` による削除、`getCacheStats()`、`getCacheList()` はメタデータだけで行います
  - 保存先の Box 名が変わりました（`proxy_cache_index_secure`・`proxy_cache_body_secure`、暗号化しない場合は `proxy_cache_index`・`proxy_cache_body`）。0.21.0 以前の `proxy_cache`・`proxy_cache_secure` は、起動時に新しい形式へ移して削除します。平文のまま移す場合の失敗は `ProxyEventType.errorOccurred`（`phase: cacheFormatMigration`）で知らせます

### 修正

- **長いキーを保存すると、次の起動で `start()` が失敗し続けていた**: Hive は文字列キーの長さを 1 バイトの欄に書きます。assert が無効なリリースビルドでは、UTF-8 で 255 バイトを超えるキーを拒否せず、長さを桁あふれさせた壊れた記録をそのまま書きます。次に Box を開くと Hive が例外（`HiveError: Cannot read, unknown typeId`）を送出し、アプリのデータを消すまで `start()` が失敗していました。画面が 255 バイトを超える `Idempotency-Key` を付けた更新系を送信待ちから送った場合と、ドメイン・パス・名前を合わせて 255 バイトを超える Cookie を保存した場合に起きます
  - 255 バイトを超えるキーは、`sha256:` に続く SHA-256 の 16 進（71 バイト）に置き換えて保存するようにしました。255 バイト以下のキーは変えないため、保存済みのデータはそのまま使えます
  - 以前の版が壊した Box（開けない、または proxy が書かない型の値がある）は、起動時に次のとおり扱います。べき等性キーの記録（`proxy_idempotency`）は作り直して起動を続け、`ProxyEventType.errorOccurred`（`phase: idempotencyStoreRecovery`）で知らせます。保持期間内に届いた記録が失われるため、その間は同じキーの要求を送信済みとして止められず、要求の状態の照会は `unknown` を返します。Cookie の暗号化 Box は `StorageIntegrityFailure.corrupted` として破棄して起動を続け、`ProxyEventType.cookieStorageDiscarded` を発行します（再ログインが必要）。鍵と他の暗号化 Box はそのまま使います
  - Hive は開けなかった例外を、proxy が捕まえた後もゾーンの未処理の例外として報告します。壊れた Box を作り直す起動では、アプリのエラー報告に `HiveError` などが記録されることがあります
  - 0.4.0 より前の平文 Cookie Box（`proxy_cookies`）が同じ理由で開けない場合は対象外で、従来どおり起動に失敗します。その版でも起動できなかった状態のためです

### ドキュメント

- 仕様書【8】の「キャッシュファイル形式」から「ファイル命名規則」までの、実装の無い独自のファイル形式と URL の正規化の記述を、実際の保存形式とキャッシュキーの説明に改めました

### テスト

- `test/encrypted_cache_test.dart` を新しい保存形式に合わせ、既定で暗号化すること、0.21.0 以前の形式からの移行（平文・暗号化、暗号化の有無、鍵と合わない場合）、復旧 API が別の処理の開いた本文の Box を閉じること、片方の Box にしかない記録の削除、削除と全削除が両方の Box に効くことのテストを追加しました
- `test/response_cache_store_test.dart` を追加しました（メタデータと本文への分割、置き換え、別の処理が開いている組の扱い、移行で同じキーがある場合、暗号化した組の削除の続行、古いファイルを削除できなかった場合の次回の再試行）
- `test/hive_key_length_test.dart` を追加しました（キーの変換、長いべき等性キーの記録と再起動、長いキーの Cookie、以前の版が壊したべき等性キーの Box と、開けない・別の型の値として開ける Cookie の Box）

## 0.21.0

### 機能追加

- **応答キャッシュを暗号化して保存できるようにした**: 応答キャッシュ（`proxy_cache`）は平文で保存しており、`forceCachePaths` で保存した個人情報や業務データの API の応答が、端末に平文で残っていました。`ProxyConfig.encryptResponseCache`（既定 `false`）を追加し、有効にすると Cookie・キュー・隔離と同じ鍵で暗号化した Box（`proxy_cache_secure`）へ保存します
  - 有効にすると、`start()` の中で平文のキャッシュを移してから平文のファイルを削除します（パソコンでの測定で、30 MB で約 0.7 秒、200 MB で約 7 秒）。無効に戻すと、暗号化したキャッシュを平文へ戻さずに削除します
  - 起動時の鍵の照合の対象にはしません。鍵と合わない場合は、起動を失敗させずにキャッシュを空にします。鍵を作り直した場合と、`recoverEncryptedStorage()` が鍵を削除した場合は、暗号化したキャッシュを削除します
  - Hive は暗号化 Box を開くときに全件を復号するため、キャッシュが大きいほど `start()` が遅くなります（パソコンでの測定で、30 MB で約 0.4 秒、200 MB で約 3.2 秒）。そのため既定は無効にしました
  - Box のキー（正規化した URL の SHA-256）は平文のままです

### テスト

- `test/encrypted_cache_test.dart` を追加しました（既定の平文、暗号化して保存・再起動後の利用、平文からの移行、移せない記録がある場合、移した後の `cacheMaxSize`、無効に戻したときの削除、鍵が合わない場合、鍵を作り直した場合、復旧 API が鍵を削除した場合）

## 0.20.0

### 機能追加

- **上流との通信を gzip で圧縮するようにした**: これまでは上流へ常に `Accept-Encoding: identity` を送っており、上流が圧縮に対応していても非圧縮で受け取っていました。仕様書【7】の「上流との通信は圧縮のまま行う」とも食い違っていました。`ProxyConfig.enableUpstreamCompression`（既定 `true`）を追加し、上流へ `Accept-Encoding: gzip` を送って、gzip の本文を proxy で解凍してから WebView へ返します
  - 転送、キューからの送信、ウォームアップ、別 origin の中継のすべてで同じ値を送ります。キャッシュ・HTML と CSS の書き換え・ウォームアップの参照の抽出・WebView への応答は、解凍後の本文で扱い、`Content-Encoding` を取り除きます
  - 解凍できない本文（壊れている、途中で切れている、解凍後に 64 MB を超える）は、状態コード・ヘッダ・本文を変えずに返し、キャッシュへは保存しません。br など gzip 以外の方式は従来どおりそのまま返します。`Range` を付けた要求には `identity` を送ります
  - **既存の利用者への影響**: 上流へ届く `Accept-Encoding` が `identity` から `gzip` に変わります。WebView が受け取る本文は従来と同じ非圧縮です。nginx や Apache は圧縮した表現に別の ETag を付けるため、更新直後の最初の再検証は `304` ではなく `200` になることがあります。サーバによっては、その後も `304` が返らない場合があります（仕様書【7】）。従来の挙動に戻すには `enableUpstreamCompression: false` を指定します

### 修正

- **`ProxyConfig.cacheMaxSize` が効いていなかった**: 設定と仕様書【16】には「容量を超えたら古いものから削除」とありましたが、実装されておらず、応答キャッシュは期限切れの削除でしか減りませんでした。応答を保存したときと 1 時間ごとの purge で、本文の大きさの合計が上限を超えていれば、保存した日時の古いものから、上限の 9 割に収まるまで削除します
  - 削除したときは、新しい `ProxyEventType.cacheEvicted`（`data` に `reason`・`evictedCount`・`evictedBytes`）を発行します。本文だけで上限を超える応答は保存しません（`ProxyEventType.cacheSkipped`、`reason: cacheMaxSize`）
  - `0` は上限なし、負の値は `start()` が `ProxyStartException` を送出します
  - **既存の利用者への影響**: 応答キャッシュが 200 MB（既定）を超えていた端末では、次に保存したときに古いものから削除されます。長期のオフライン運用で多くの応答を保存している場合は、`cacheMaxSize` を見直してください。`ProxyEventType` に `cacheEvicted` を追加したため、`default` の無い `switch` で網羅している場合は分岐の追加が必要です

### ドキュメント

- 仕様書【14】の「Accept-Encoding ヘッダ」の節にあった、実装の無い設定（managed / passthrough / identity-downstream）の記述を、実際の挙動に改めました
- 仕様書【16】から、実装の無い「静的リソースと API レスポンスで削除優先度を差別化」の記述を削除しました

### テスト

- `test/cache_max_size_test.dart` を追加しました（上限を超えたときの削除、9 割まで下げること、同時の保存、保存し直し、URL 指定の削除後の数え直し、大きすぎる応答、上限なし、負の値、前回の起動から残った分）

## 0.19.0

### 機能追加

- **画面が送った更新系の状態を、べき等性キーで照会できるようにした**: 送信待ちになった要求が、その後に上流へ届いたのか、隔離やドロップされたのかを、画面から知る手段がありませんでした。状態通知（`statusPath`）に `idempotencyKey` を指定すると、キーごとの状態を `requests` として返します。Dart からは `OfflineWebProxy.getRequestStatuses()` で同じ判定を行えます
  - 状態は `queued`・`quarantined`・`delivered`（送信待ちから送り、上流が 2xx を返した）・`dropped`・`unknown` のいずれかです。同じキーが複数の場所にある場合は、`delivered` → `queued` → `quarantined` → `dropped` で先に当てはまるものを返します
  - キーは 50 件まで、長さは 200 文字までで、超えると `400` を返します。保存領域を読めない場合は、`unknown` ではなく `503` を返します
  - すべての保存領域を処理を譲らずに続けて読むため、保存領域の間を移る途中の要求を `unknown` と答えることはありません
  - キーを指定しない場合の応答は変わりません
- **ドロップ履歴に、べき等性キーと受け付けた日時を記録するようにした**: `DroppedRequest.idempotencyKey` と `acceptedAt` を追加しました。隔離から移す場合（`quarantine_limit`・`quarantine_expired`）と `quarantine_too_large` も含みます。0.19.0 より前の履歴では `null` です
- **一覧にべき等性キーを出すようにした**: `QueuedRequest.idempotencyKey`、`QuarantinedRequest.idempotencyKey` と、管理エンドポイントの隔離の一覧の `idempotencyKey` を追加しました

## 0.18.0

### 機能追加

- **キューから送る更新系に、キューからの送信であることを示すヘッダを付けるようにした**: 最初の転送とキューからの送信には、べき等性キーと受付時刻が同じ値で付き、本文も同じため、上流は両者を見分けられませんでした。`ProxyConfig.enableReplayHeader`（既定 `true`）と `replayHeaderName`（既定 `X-Offline-Replay`）を追加し、キューから送る更新系に値 `1` で付けます
  - 回線が無いためにキューへ入れた要求、上流の 5xx や到達できなかったためにキューへ入れた要求、隔離からキューへ戻した要求のすべてに付けます。最初の転送と read 系には付けません
  - 画面が送った同名のヘッダは、画面から受けて上流へ転送する要求（read 系を含む）からは取り除き、キューからの送信では proxy の値で上書きします。無効にした場合は付けることも取り除くこともしません
  - **既存の利用者への影響**: 既定で有効なため、キューから送る更新系で上流に届くヘッダが 1 つ増えます。画面が `X-Offline-Replay` を送っていた場合、そのヘッダは上流へ届かなくなります

## 0.17.0

### 機能追加

- **`ProxyConfig.requireAccessToken` で、proxy への到達を WebView に限れるようにした**: proxy はループバックで待ち受けますが、要求がどのプロセスから来たかを区別しないため、端末内の別アプリが利用側アプリの認証セッション（Cookie Jar）で上流の API を呼べ、`Origin` の無い要求は管理エンドポイントへも届きました
  - `start()` のたびに秘密値を生成し、`OfflineWebProxy.accessToken` で返します（HTTP では返しません）。有効にすると、Cookie `__offline_web_proxy_token`（`OfflineWebProxy.accessTokenCookieName`）かヘッダ `X-Offline-Web-Proxy-Token`（`OfflineWebProxy.accessTokenHeaderName`）に正しい値を持たない要求を `403` で拒否します
  - 対象は転送経路、同梱アセット、別 origin の中継、WebStorage の橋渡し、状態通知、管理エンドポイントです。`GET` / `HEAD` の `healthCheckPath` だけは対象外です
  - 既定は `false` で、従来の挙動は変わりません。有効にした場合は、WebView の読み込み前に、ネイティブの Cookie 管理で proxy の origin へ HttpOnly の Cookie を置く必要があります。内部エンドポイントを `credentials: "omit"` で呼んでいるページは、`same-origin` へ改める必要があります
  - 秘密値の Cookie とヘッダは、設定にかかわらず上流へ転送せず、キューにも保存しません。上流が同じ名前の `Set-Cookie` を返しても WebView へは返しません
- **`ProxyConfig.addCorsHeaders` で、内部エンドポイント以外の応答へ CORS ヘッダを付けないようにできるようにした**: これまでは内部エンドポイントを除くすべての応答へ `Access-Control-Allow-Origin: *` を付けていたため、ブラウザ上の別 origin のページも proxy 経由の応答を読めました。既定は `true` で従来どおりです

### 修正

- **上流が返した複数の `Set-Cookie` が、先頭の 1 件しか WebView に効いていなかった**: 上流の応答ヘッダを 1 行へ平坦化する際に `Set-Cookie` を `, ` で連結して返していたため、ブラウザは先頭の Cookie しか受け取っていませんでした。上流から受け取った応答では 1 件ずつ別の行で返します。CORS ヘッダの付与や本文の書き換えでも行を連結しません
- **キャッシュから返す応答で、保存時の `Set-Cookie` を返さないようにした**: これまではキャッシュした時点の `Set-Cookie` をそのまま返しており、その後に上流が更新したセッションなどを古い値で上書きするおそれがありました。Cookie Jar には上流から受け取った時点で保存済みです
  - **既存の利用者への影響**: オフライン時などにキャッシュから返したページでは、WebView の Cookie が設定されなくなります
- **上流へ転送する要求の一部が、内部エンドポイントとして統計・CORS・要求ログから外れていた**: `POST` の状態通知や、登録していない管理のパスやメソッドは、ルーターでは転送経路として上流へ送る一方、統計・CORS ヘッダ・要求ログの判定では内部エンドポイントとして扱っていました。判定をルーターの登録（メソッドとパスの一致）にそろえました
- **パス先頭の `/` を重ねると、内部エンドポイント宛ての要求が上流へ転送されていた**: ルーターは `//__offline_web_proxy/status` を `/__offline_web_proxy/status` と別のパスとして照合する一方、転送の処理は先頭の `/` を 1 つ落として扱うため、状態通知・管理 API・稼働確認宛ての要求が `/__offline_web_proxy/...` として Cookie Jar のセッション付きで上流へ送られていました。ルーターより前で先頭の `/` の重複を 1 つにまとめるようにしました

### ドキュメント

- `enableAdminApi` の注意書きに、`Origin` の無い要求を許可するため端末内の別アプリからも到達できることを追記しました

### テスト

- `test/access_token_test.dart` を追加しました。秘密値の生成・再起動での更新・起動失敗時の破棄、各経路での拒否と許可、稼働確認だけを除外すること（末尾 `/` を付けたパスは除外しないこと）、上流・中継先・キューへの秘密値の非送出、予約名の `Set-Cookie` の除去、`addCorsHeaders`、複数の `Set-Cookie` を別の行で返すこと（書き換えた HTML・WebStorage の注入・リダイレクトを含む）、キャッシュから `Set-Cookie` を返さないこと、内部エンドポイントの判定がルーターと一致すること、先頭の `/` の重複をまとめてから扱うことを確かめます
- `example/integration_test/offline_web_proxy_access_token_e2e_test.dart` を追加しました。WebView から HttpOnly の Cookie で到達できること、Cookie が無い・古い場合に拒否することを確かめます。最後のテストは別プロセスから要求を送るための待ち時間を設け、その間に上流へ要求が届かないことを確かめます（要求は手動で送る）。計 4 件、Android エミュレータで成功を確認しました（`adb shell` の `nc` から送った要求は、稼働確認を除きすべて `403`）

## 0.16.0

### 機能追加

- **`mirroredOrigins` が CSS 内の参照も中継用のパスへ書き換えるようにした**: これまでは `text/html` の `<script src>`、`<link href>`、`<img src>` だけが対象で、Google Fonts のように CSS（`fonts.googleapis.com`）が別 origin のフォント本体（`fonts.gstatic.com`）を `@font-face { src: url(...) }` で参照する構成では、フォント本体の取得が proxy を通らず、Web フォントをオフライン化できませんでした
  - `text/css` の応答の `url()`（引用符なし、`"`、`'` のいずれも）と `@import "..."` / `@import url(...)` を書き換えます。HTML の `<style>` 要素内も同じく書き換えます。コメント内の URL には触れません
  - 相対 URL は応答の URL を基準に解決してから判定します。設定済み origin から返した CSS 内の相対 URL は書き換えません。中継した CSS 内では `/` で始まるルート相対 URL だけを中継元 origin の中継用パスへ書き換え、`../x` のようなパス相対 URL は書き換えません
  - CSS とフォント本体の両方の origin を `mirroredOrigins` に列挙すると、フォントもキャッシュとオフライン代替の対象になります
  - **既存の利用者への影響**: `mirroredOrigins` を設定している場合、列挙した origin を指す絶対 URL、または中継した CSS 内のルート相対 URL を含む CSS は本文が変わります。そうした CSS を `integrity` 属性付きの `<link>` で読み込んでいると、検証に失敗します
  - `style` 属性内の `url()`、`url()` を使わず文字列で書いた URL（`image-set()` など）は対象外です
- **`warmupCache(followReferences: true)` が CSS の参照も辿るようにした**: HTML からは従来どおり `paths` に指定した HTML の 1 段だけを辿り、新たに `<style>` 要素内の `url()` / `@import` も対象にします。取得したものが CSS なら、その `url()` と `@import` も続けて取得します。HTML → CSS → フォントのように、指定したパスから数えて最大 4 段まで辿ります
  - 同一 origin の CSS が参照するフォントや画像も取得するようになるため、`followReferences: true` を指定している場合は取得件数が増えることがあります
  - `WarmupEntry.referencedFrom` には、CSS から辿った資源では CSS のパスが入ります

### ドキュメント

- **`ProxyConfig.startupPaths` の説明を実装に合わせた**: dartdoc と仕様書に「proxy の起動時に上流から取得する」と書いていましたが、`start()` は `startupPaths` を取得しません。実際は `warmupCache()` で `paths` を省略したときの既定値です。起動時の先読みが必要な場合は、利用側が必要な時点で `warmupCache()` を呼ぶ旨を dartdoc、仕様書、README に明記しました

### テスト

- **CSS の書き換えとウォームアップの連鎖取得のテストを追加**: 引用符の書き方、空白を挟まない `@import`、コメント、文字列内の `/*`、設定済み origin と中継した CSS の相対 URL（ルート相対だけを書き換えること）、`data:`、`<style>` 要素、中継した CSS からのフォントのウォームアップとオフライン配信、`@import` の入れ子の段数上限、参照として取得した HTML を辿らないことを確認します
- **`start()` が `startupPaths` を取得しないことのテストを追加**

## 0.15.1

### 修正

- **pub.dev の配布物に開発用のファイルが入っていた問題を修正**: pub は `.pubignore` があるディレクトリの `.gitignore` を読まないため、`.pubignore` を追加した 0.6.0 以降、ルートの `.gitignore` による除外が配布物に効いていませんでした。`CLAUDE.md`、`codecov.yml`、`doc/cookie-native-session-plan.ja.md`（内部の検討メモ）、`example` の生成物 `GeneratedPluginRegistrant.java` が含まれていたため、`.gitignore` の除外規則を `.pubignore` にも書いて除外します。ライブラリの動作は変わりません

### ドキュメント

- **仕様書の `getCacheList` の `limit` の説明を実装に合わせた**: 「デフォルト: 100」と書いていましたが、実装は `limit` を省略すると上限を設けず、`offset` 以降をすべて返します。dartdoc にも省略時の挙動を追記しました
- **仕様書の英語版に、日本語版だけにあった `acceptedAt` の項目を追加**: クライアントが同名のヘッダを送っていた場合も proxy の値で上書きする、という説明です

### テスト

- **`getCacheList()` の `limit` を省略したときの挙動のテストを追加**: 100 件を超えるキャッシュを用意し、省略時は全件を返すこと、`limit` と `offset` で範囲を絞れることを確認します

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
