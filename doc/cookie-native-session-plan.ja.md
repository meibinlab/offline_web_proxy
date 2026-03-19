# Cookie ネイティブ再利用 実装ドラフト

## 1. 目的

WebView 内で確立したログインセッションを、アプリ側の native HTTP 通信やバックグラウンド通信でも再利用できるようにする。

前提:

- `getCookies()` は現状どおり一覧確認用途とし、値マスクを維持する
- 生の Cookie 値を一般公開 API として直接返す方針は採らない
- 最終的な公開 API の第一候補は、対象 URL に対する Cookie ヘッダを返す `getCookieHeaderForUrl` とする

## 2. 現状整理

README と仕様書では Cookie Jar の永続化と RFC 準拠評価を前提としているが、現行実装では以下のギャップがある。

- 上流レスポンスの `Set-Cookie` を複数値のまま保持できていない
- Cookie の内部保存モデルが公開用 `CookieInfo` に比べて未整理
- URL ごとに送信対象 Cookie を判定する evaluator が未実装
- queue 再送時に Cookie を送信直前で再評価する仕組みがない

## 3. フェーズ計画

### Phase 1: 受信基盤の整備

目的:

- `Set-Cookie` を壊さず保持する
- 内部 Cookie モデルを導入する
- 上流レスポンスから Cookie を永続化できるようにする

実装対象:

- レスポンスヘッダのスナップショット化
- `Set-Cookie` の raw 値保持
- 内部保存用 Cookie モデル
- 上流レスポンス受信時の Cookie capture

成功条件:

- 単一 Cookie と複数 Cookie の `Set-Cookie` を保存できる
- `getCookies()` では値マスクが維持される

### Phase 2: URL 評価ロジック

目的:

- 指定 URL に対して送信すべき Cookie を選別する

実装対象:

- Domain / Path / Expires / Max-Age / Secure / SameSite の評価
- Cookie ヘッダ生成ロジック

### Phase 3: MVP API 公開

目的:

- native HTTP 通信から同一セッションを再利用できるようにする

実装対象:

- `getCookieHeaderForUrl(String url)` の追加
- ドキュメント更新
- origin または allowlist 制約の導入検討

2026-03-19 実装状況:

- `getCookieHeaderForUrl(String url)` を public API として追加済み
- 戻り値は `Future<String?>` とし、該当 Cookie が無い場合は `null` を返す

### Phase 4: 本命実装

目的:

- proxy 転送と queue 再送も Cookie Jar 基準に統一する

実装対象:

- 上流転送時の Cookie ヘッダ再構築
- queue 再送時の Cookie 再評価

## 4. MVP と本命の差分

### MVP

- Phase 1 から Phase 3 を対象とする
- native HTTP / background 通信用の再利用を先に成立させる
- 既存 proxy 転送経路への影響を最小に抑える

### 本命

- Phase 4 まで含めて Cookie の capture / evaluation / send を一本化する
- WebView 経由通信と native 通信の挙動差を減らす

## 5. リスク

- `Set-Cookie` の扱いを誤ると既存セッション維持を壊す
- queue 再送の Cookie 戦略を誤ると、古いセッションで再送される
- 将来 API を公開すると互換性制約になるため、内部契約を先に固める必要がある

## 6. 実装開始状況

2026-03-19 時点の着手内容:

- Phase 1 の最小実装として、`Set-Cookie` の raw 値保持を追加する
- 上流レスポンス受信時の Cookie capture を追加する
- 内部保存用 Cookie モデルを追加する
- Phase 1 の自動テストを追加する
- Phase 2 の最小実装として、Domain / Path / Expires / Secure を評価する内部 evaluator を追加する
- 指定 URI 向け Cookie ヘッダを内部生成するユーティリティを追加する

## 7. 次の実装単位

次の PR では、以下を完了条件とする。

- `Set-Cookie` の複数値を内部で保持できる
- Cookie が Hive に保存され、`getCookies()` からマスク付きで確認できる
- 単一 Cookie / 複数 Cookie の capture テストが通る