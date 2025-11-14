# offline_web_proxy 仕様書

Flutter アプリ内で動作するオフライン対応ローカルプロキシサーバ。
既存の Web システムをアプリ化する際に、オンライン／オフラインを意識せずに動作させることを目的とします。

本プロキシサーバは、WebView から送信される HTTP リクエストを中継し、オンライン時は上流サーバへ転送、オフライン時はキャッシュからレスポンスを返却します。また、更新系リクエスト（POST/PUT/DELETE）はオフライン時にキューに保存し、オンライン復帰時に自動送信することで、シームレスなオフライン対応を実現します。

---

## 【1】基本構成

### アーキテクチャ概要

- **ベース技術**: shelf（Dart の軽量 HTTP サーバフレームワーク）, shelf_router（ルーティング）, shelf_proxy（プロキシ機能）
- **通信経路**: WebView → http://127.0.0.1:<port> → (proxy) → 上流サーバ
- **データ永続化**: SQLite を使用したローカルストレージ
- **Cache-Control 対応**: RFC 準拠のキャッシュ制御とオフライン対応の両立

### データ処理戦略

- **キャッシュ**: GET リクエストのレスポンスをファイルベースで保存。Cache-Control ヘッダを考慮しつつオフライン時の高速レスポンスを実現
- **キュー**: POST/PUT/DELETE リクエストを FIFO（先入先出）で管理。ネットワーク復旧時に順次送信
- **オフライン応答**: キャッシュヒット時はキャッシュを返却、未キャッシュ時はフォールバックページを表示
- **静的リソース**: アプリの assets/フォルダに同梱されたファイル（CSS、JS、画像等）をローカル配信

### プロキシ対象

上流オリジンサーバ（例: https://sample.com）への中継を行います。単一のオリジンサーバに対応します。

## 【2】ポート・接続仕様

### ポート管理

- **自動割当**: システムが利用可能なポートを自動選択。ポート衝突を回避
- **戻り値**: プロキシサーバ起動時に実際に使用されるポート番号を返却
- **バインド先**: 127.0.0.1（ローカルループバック）のみ。外部からのアクセスを防止

### セキュリティ考慮

- **HTTPS 不要**: localhost はブラウザでセキュアコンテキストとして扱われるため、HTTP でも十分
- **外部アクセス制限**: 127.0.0.1 バインドにより、デバイス外からのアクセスを完全に遮断

## 【3】静的リソース判定

### 判定ロジック

リクエストパスに対応するローカルファイルが `assets/static/` 配下に存在するかを自動検出し、静的リソースを判定します。設定ファイルでの明示的な指定は不要で、ファイルの配置のみで自動的に静的リソースとして認識されます。

### 自動マッピング機能

リクエスト URL とローカルファイルの対応関係：

```
リクエスト: http://127.0.0.1:8080/app.css
           ↓
ファイル確認: assets/static/app.css
           ↓
存在する場合: ローカルファイルを返却
存在しない場合: 上流サーバへプロキシ転送またはキャッシュ使用
```

### URL 正規化処理

- **スラッシュ圧縮**: `//` を `/` に変換
- **相対パス解決**: `../` や `./` を適切に解決
- **パストラバーサル防止**: `../` を含むパスを拒否し、`assets/static/` 配下への制限を徹底
- **大文字小文字区別**: ファイルシステムに依存せず、常に区別して処理

### 処理フロー

1. リクエスト URL を正規化
2. パストラバーサル攻撃チェック
3. `assets/static/` 配下の対応ファイル存在確認
4. 存在する場合: ローカルファイルを返却（Content-Type 自動判定）
5. 存在しない場合: 上流サーバへプロキシ転送

### パフォーマンス最適化

- **存在チェックキャッシュ**: ファイル存在確認結果をメモリキャッシュ
- **Content-Type キャッシュ**: 拡張子ベースの Content-Type 判定結果をキャッシュ
- **起動時スキャン**: アプリ起動時に `assets/static/` をスキャンして存在ファイル一覧をメモリ構築

### セキュリティ対策

- **パス制限**: `assets/static/` 配下のみアクセス可能
- **パストラバーサル防止**: `../`, `./`, 絶対パス等を厳格にチェック
- **ファイル名検証**: 不正なファイル名パターンを拒否

### Content-Type 自動判定

拡張子に基づく自動 Content-Type 設定：

```
.html → text/html; charset=utf-8
.css  → text/css; charset=utf-8
.js   → application/javascript; charset=utf-8
.json → application/json; charset=utf-8
.png  → image/png
.jpg  → image/jpeg
.woff2 → font/woff2
（その他） → application/octet-stream
```

## 【4】Cookie Jar 永続化と保護

### ストレージ戦略

- **永続化必須**: 全ての Cookie をファイルベースで永続化。アプリ再起動後も保持
- **暗号化**: AES-256 を使用して Cookie データを暗号化してから保存
- **メモリキャッシュ**: ファイルから読み込んだ Cookie を高速アクセスのためメモリ上にキャッシュ

### Cookie 評価基準

RFC 準拠の Cookie 評価を実装：

- **Domain**: Cookie が有効なドメインの検証
- **Path**: Cookie が有効なパスの検証
- **Expires/Max-Age**: Cookie の有効期限の管理
- **Secure**: HTTPS 接続時のみ送信する Cookie の制御
- **SameSite**: CSRF 攻撃防止のための SameSite 属性の処理

### 管理メソッド

Cookie 管理のためのメソッドを提供します。詳細は【20】API リファレンスを参照してください。

- **`getCookies()`**: 現在保存されている Cookie の一覧取得（値はマスクして返却）
- **`clearCookies()`**: 全 Cookie の削除

## 【5】キュー再送ポリシー

### キュー管理

- **FIFO 保証**: リクエストの順序を厳密に保持。データ整合性を維持
- **永続化**: SQLite でキュー状態を保存。アプリ再起動後も再送を継続

### 再試行戦略

- **指数バックオフ**: 初回失敗後、待機時間を段階的に延長（1 秒 → 2 秒 → 4 秒...）
- **無限再試行**: ネットワークエラーの場合は永続的に再試行
- **ジッター**: 同時再試行による負荷集中を避けるため、±20%のランダム待機時間を追加

### ドロップ条件

以下の場合、リクエストをキューから削除：

- **4xx 系エラー**: クライアントエラー（認証失敗、不正リクエスト等）
- **5xx 系エラー**: サーバエラーのうち、再試行が無意味なもの

### 履歴管理

キュー管理のためのメソッドを提供します。詳細は【20】API リファレンスを参照してください。

- **`getDroppedRequests()`**: ドロップされたリクエストの履歴取得。デバッグやトラブルシューティングに活用

## 【6】Idempotency（べき等性）

### 重複リクエスト防止

同じリクエストの重複実行を防ぐため、べき等性キーを使用します。

### サポートヘッダ

- **Idempotency-Key**: 標準的なべき等性キー（優先）
- **X-Request-ID**: 独自リクエスト ID（代替）

### 保持期間

- **24 時間**: べき等性キーを 24 時間保持。期限切れ後は新規リクエストとして処理
- **ストレージ**: SQLite で永続化。アプリ再起動後も有効

## 【7】レスポンス圧縮

### 上流サーバとの連携

- **Accept-Encoding 管理**: クライアントの圧縮対応状況を上流サーバに適切に伝達
- **透過処理**: 上流サーバからの圧縮レスポンスをそのままクライアントに転送（再圧縮は行わない）

### 非圧縮オプション

- **identity 指定**: `Accept-Encoding: identity` を指定することで、非圧縮レスポンスを強制取得可能
- **用途**: デバッグやレスポンス内容の直接確認時に有用

## 【8】キャッシュ整合性

### Cache-Control 対応とオフライン戦略

#### オンライン時の Cache-Control 処理

レスポンスの Cache-Control ヘッダに基づいてキャッシュ動作を制御：

- **max-age**: 指定された秒数でキャッシュの有効期限を設定
- **no-cache**: 検証なしでキャッシュを使用しないが、**オフライン時は例外的にキャッシュを使用**
- **no-store**: キャッシュに保存しない（オフライン対応のため、設定で上書き可能）
- **must-revalidate**: 有効期限切れ時は必ず上流サーバで検証
- **public/private**: キャッシュの共有可能性を制御
- **s-maxage**: プロキシキャッシュ専用の有効期限（max-age より優先）

#### オフライン対応の特別ルール

標準的な Cache-Control 指示に加えて、オフライン対応のための特別な動作を実装：

1. **no-cache 無視**: `no-cache` が指定されていても、オフライン時はキャッシュを使用
2. **no-store 緩和**: 設定により `no-store` を無視してキャッシュを保存可能
3. **期限切れ許容**: オフライン時は期限切れキャッシュも `X-Cache-Status: stale` ヘッダ付きで返却
4. **強制キャッシュ**: 重要なリソースは Cache-Control に関係なく強制的にキャッシュ保存

#### キャッシュ有効期限の計算優先順位

1. **Cache-Control: s-maxage** (プロキシ専用)
2. **Cache-Control: max-age** (一般的な有効期限)
3. **Expires** ヘッダ (HTTP/1.0 互換)
4. **設定ファイルのデフォルト TTL** (上記すべてが未指定の場合)

#### 条件付きリクエスト対応

キャッシュの検証のため、以下のヘッダを処理：

- **If-Modified-Since / Last-Modified**: 更新日時による検証
- **If-None-Match / ETag**: エンティティタグによる検証
- **304 Not Modified**: キャッシュが有効な場合の応答

### キャッシュファイル形式

メタデータとコンテンツを単一ファイルに統合し、管理を簡素化：

#### ファイル構造

```
[ヘッダ部]
CACHE_VERSION: 1.0
CREATED_AT: 2024-01-01T12:00:00Z
EXPIRES_AT: 2024-01-02T12:00:00Z
STATUS_CODE: 200
CONTENT_TYPE: text/html; charset=utf-8
CONTENT_LENGTH: 1234
CACHE_CONTROL: max-age=3600, public
ETAG: "abc123"
LAST_MODIFIED: Mon, 01 Jan 2024 12:00:00 GMT
X_ORIGINAL_URL: https://example.com/page

[ボディ部]
<html>実際のレスポンスコンテンツ</html>
```

#### HTTP プロトコル準拠の利点

- **標準準拠**: HTTP/1.1 仕様と同じヘッダ・ボディ区切り方式
- **パース容易性**: 既存の HTTP パーサライブラリを流用可能
- **可読性**: 開発者にとって直感的で理解しやすい
- **デバッグ効率**: HTTP ツールでキャッシュファイルを直接確認可能

#### 区切り方式の詳細

- **ヘッダ終端**: CRLF CRLF（`\r\n\r\n`）でヘッダ部とボディ部を区切り
- **行区切り**: 各ヘッダ行は CRLF（`\r\n`）で区切り
- **互換性**: LF のみ（`\n\n`）の環境でも動作するよう柔軟に対応

#### メリット

- **原子性保証**: 1 回のファイル書き込みでメタデータとコンテンツが同期
- **片割れ問題の解消**: メタデータとコンテンツが常に整合
- **管理簡素化**: ファイル数が半減し、ディスク容量も削減
- **読み込み効率**: 1 回のファイルアクセスでメタデータと内容を取得
- **HTTP 互換性**: 標準的な HTTP メッセージ形式で保存

#### デメリットと対策

- **部分読み込み不可**: メタデータのみが必要な場合も全ファイルを読む必要
  → **対策**: ヘッダ部のサイズを小さく保ち（通常 1KB 未満）、影響を最小化
- **大容量ファイルの処理**: 大きなファイルの場合、メタデータ確認のコストが高い
  → **対策**: ファイル先頭から固定バイト数（例：4KB）のみ読み込んでヘッダを解析

### 原子的操作

単一ファイル形式により大幅に簡素化：

- **一時ファイル経由**: レスポンス受信と同時にヘッダ部とボディ部を一時ファイルに書き込み
- **原子的移動**: 書き込み完了後、rename 操作で正式なキャッシュファイルに移動
- **排他制御**: ファイル操作中の競合状態を防止
- **バックアップ不要**: 単一ファイルのため、部分的な破損リスクが低減

### 整合性チェック（簡素化）

- **ヘッダ検証**: ファイル先頭のヘッダ形式が正しいかチェック
- **区切り確認**: CRLF CRLF（`\r\n\r\n`）または LF LF（`\n\n`）の存在を確認
- **サイズ整合性**: `CONTENT_LENGTH` とボディ部の実際のサイズを照合
- **破損検出時**: ファイル全体を削除（部分修復は行わない）

### パフォーマンス最適化

単一ファイル形式の利点を活かした最適化：

#### キャッシュ インデックス

- **SQLite インデックス**: URL、有効期限、ファイルサイズ等でインデックス化
- **メタデータキャッシュ**: よくアクセスされるメタデータをメモリ上に保持
- **遅延読み込み**: 必要な場合のみボディ部を読み込み

#### ストリーミング対応

- **大容量ファイル**: ヘッダ部読み込み後、ボディ部をストリーミングで配信
- **範囲指定**: 将来の Range 対応時も、単一ファイル内で部分配信が可能

#### HTTP パーサ活用

- **ライブラリ流用**: 既存の HTTP メッセージパーサでヘッダ部を解析
- **バリデーション**: HTTP ヘッダのバリデーション機能をそのまま活用
- **拡張性**: 将来的な新しい HTTP ヘッダにも自動対応

### ファイル命名規則

```
cache/
├── content/
│   ├── ab/
│   │   ├── cd1234abcd5678ef90...cache     # 統合キャッシュファイル
│   │   └── ef9876543210abcd...cache       # 他のキャッシュ
│   └── gh/
│       └── ij5678901234cdef...cache
└── index.sqlite                           # キャッシュインデックス
```

#### URL ハッシュ化

URL をハッシュ化する前に正規化処理を行い、一貫したハッシュ値を生成：

##### 正規化手順

1. **URL デコード**: パーセントエンコーディング（%20 等）をすべてデコード
2. **スキーム正規化**: `HTTP` → `http`、`HTTPS` → `https` に統一
3. **ホスト名正規化**: 大文字を小文字に変換（`Example.COM` → `example.com`）
4. **ポート正規化**: デフォルトポート（http:80、https:443）は省略
5. **パス正規化**:
   - 連続スラッシュ圧縮（`//` → `/`）
   - ドット記法解決（`./`、`../` を解決）
   - 末尾スラッシュの統一（設定により追加/削除）
6. **クエリパラメータ正規化**:
   - パラメータをキー名でソート
   - 値を URL エンコード（UTF-8、RFC 3986 準拠）
7. **フラグメント除去**: `#fragment` 部分は除去（キャッシュキーに影響しない）
8. **UTF-8 エンコード**: 最終的に UTF-8 でエンコードしてからハッシュ化

##### 正規化例

```
入力URL: https://Example.COM:443/path//to/../page?b=2&a=1#fragment
                                  ↓
正規化後: https://example.com/path/page?a=1&b=2
                                  ↓
SHA-256: a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456
```

##### ハッシュ衝突対策

- **SHA-256**: URL を SHA-256 でハッシュ化してファイル名に使用
- **衝突検出**: ファイル内の `X_ORIGINAL_URL` ヘッダで実際の URL を照合
- **衝突時の処理**:
  1. キャッシュファイルを読み込み
  2. `X_ORIGINAL_URL` と正規化後 URL を比較
  3. 不一致の場合はキャッシュミスとして扱う
  4. 新しいキャッシュファイルで上書き

##### 階層化ディレクトリ構造

- **サブディレクトリ**: ハッシュの最初の 2 文字でサブディレクトリを作成
- **負荷分散**: ディレクトリあたりのファイル数を制限（通常 1000 ファイル以下）
- **例**: ハッシュ `abcd1234...` → `cache/content/ab/cd1234...cache`

## 【9】コンテンツタイプと文字コード

### Content-Type 処理

- **上流優先**: 上流サーバの Content-Type ヘッダを最優先
- **文字コード補完**: text 系の Content-Type で文字コードが未指定の場合、自動的に `charset=utf-8` を付与
- **デフォルト**: Content-Type が完全に未指定の場合は `application/octet-stream` を使用

## 【10】オフライン応答

### レスポンス種別とヘッダ

オフライン時の応答には、デバッグ用のカスタムヘッダを付与します：

#### キャッシュヒット時

- **ステータス**: 200 OK
- **カスタムヘッダ**:
  - `X-Offline: 1`
  - `X-Offline-Source: cache`
  - `X-Cache-Status: hit` (キャッシュが有効期限内)
  - `X-Cache-Status: stale` (キャッシュが期限切れだがオフラインのため使用)
  - `X-Cache-Control-Override: 1` (no-cache 等を無視した場合)
- **内容**: キャッシュされたレスポンスをそのまま返却

#### フォールバック時

- **ステータス**: 200 OK
- **カスタムヘッダ**: `X-Offline-Source: fallback`
- **内容**: あらかじめ用意されたフォールバックページ（「オフラインです」等）

#### 未対応時

- **ステータス**: 504 Gateway Timeout
- **カスタムヘッダ**: `X-Offline-Source: none`
- **内容**: オフライン対応不可のエラーページ

### Cache-Control 応答ヘッダの処理

オフライン時の応答でも、元の Cache-Control ヘッダを可能な限り保持：

- **オリジナル保持**: `X-Original-Cache-Control` ヘッダで元の値を保存
- **期限切れ表示**: 期限切れキャッシュの場合は `Cache-Control: no-cache` を追加
- **オフライン識別**: `Cache-Control` に `offline-fallback` 拡張を追加（デバッグ用）

## 【11】ルートパス処理

### パス解釈

- **`/` の扱い**: ルートパス `/` はそのまま処理し、`index.html` への自動リダイレクトは行いません
- **理由**: 上流サーバのルーティング設定に依存するため、プロキシ側で変更すべきではない

## 【12】Range リクエスト: 非対応

### 非対応理由

- **実装複雑性**: 部分リクエストの処理はキャッシュ機構と複雑に絡み合う
- **用途限定**: 主に動画ストリーミング等で使用され、一般的な Web アプリでは必要性が低い
- **代替手段**: 全体をキャッシュしてクライアント側で部分利用する方針

## 【13】ServiceWorker: 非対応

### 非対応理由

- **競合回避**: ServiceWorker とプロキシサーバが両方存在すると、リクエスト処理が競合する可能性
- **複雑性**: ServiceWorker の登録・更新・削除の管理が複雑
- **代替**: プロキシサーバが ServiceWorker の役割を代替

## 【14】ヘッダ書換え粒度

### Hop-by-hop ヘッダ

- **処理**: drop 固定（Connection、Upgrade 等のプロキシ間でのみ有効なヘッダを削除）

### Authorization ヘッダ

- **passthrough**: そのまま転送
- **inject**: 設定された認証情報を注入
- **off**: ヘッダを削除

### Cookie ヘッダ

- **jar**: Cookie Jar で管理された Cookie を使用
- **passthrough**: クライアントからの Cookie をそのまま転送
- **off**: Cookie ヘッダを削除

### Set-Cookie ヘッダ

- **capture**: Cookie Jar で Cookie を保存
- **passthrough**: そのまま透過

### Origin/Referer ヘッダ

- **replace**: 上流サーバのオリジンに書き換え
- **passthrough**: そのまま転送
- **remove**: ヘッダを削除

### Accept-Enccoding ヘッダ

- **managed**: プロキシが圧縮を管理
- **passthrough**: クライアントの設定をそのまま転送
- **identity-downstream**: 下流には非圧縮で送信

### Location ヘッダ

- **rewrite**: プロキシサーバの URL に書き換え
- **passthrough**: そのまま透過

## 【15】タイムアウト／リトライ既定値

### タイムアウト設定

- **connectTimeout**: 10 秒（TCP 接続確立の制限時間）
- **sendTimeout**: 15 秒（リクエスト送信の制限時間）
- **receiveTimeout**: 30 秒（レスポンス受信の制限時間）
- **requestTimeout**: 60 秒（リクエスト全体の制限時間）

### バックオフ戦略

- **間隔**: [1, 2, 5, 10, 20, 30]秒の段階的延長
- **再試行**: 無限再試行（ネットワークエラーの場合）
- **ジッター**: ±20%のランダム要素を追加して負荷分散

### キュー処理

- **排出間隔**: 3 秒ごとにキューをチェックして未送信リクエストを処理

## 【16】キャッシュ容量・TTL

### 容量制限

- **maxCacheBytes**: 200MB（デフォルト値）
- **LRU 削除**: 容量超過時は最古のキャッシュから順次削除
- **重要度別管理**: 静的リソースと API レスポンスで削除優先度を差別化

### TTL（生存時間）と Stale 期間の管理

Cache-Control ヘッダを考慮した柔軟な TTL 計算と stale 期間の設定：

#### 計算ロジック

1. **Cache-Control: s-maxage=X**: X 秒を TTL として使用（プロキシ専用）
2. **Cache-Control: max-age=X**: X 秒を TTL として使用
3. **Expires**: Date ヘッダとの差分を TTL として計算
4. **デフォルト TTL**: 上記すべてが未指定の場合、Content-Type に応じたデフォルト値を適用
   - text/html: 1 時間
   - text/css, application/javascript: 24 時間
   - image/\*: 7 日間
   - その他: 設定ファイルの ttlDays

#### キャッシュの状態管理

キャッシュは以下の 3 つの状態で管理され、TTL 期限切れでも即座に削除されません：

##### 1. Fresh（新鮮）

- **条件**: TTL 期限内
- **動作**: オンライン・オフライン問わずキャッシュを使用
- **ヘッダ**: `X-Cache-Status: hit`

##### 2. Stale（期限切れ）

- **条件**: TTL 期限切れ、但し stale 期間内
- **動作**:
  - **オンライン時**: 上流サーバで検証（条件付きリクエスト）、エラー時は stale を使用
  - **オフライン時**: stale キャッシュを使用
- **ヘッダ**: `X-Cache-Status: stale`

##### 3. Expired（完全期限切れ）

- **条件**: stale 期間も超過
- **動作**: キャッシュを使用せず、削除対象
- **削除**: 次回の purge 処理で削除

#### Stale 期間の設定

```yaml
cache:
  stalePeriod:
    "text/html": 86400 # 1日間（TTL切れ後も1日間はstaleとして保持）
    "text/css": 604800 # 7日間
    "image/*": 2592000 # 30日間
    "default": 259200 # 3日間
  maxStalePeriod: 2592000 # 最大stale期間（30日）
```

#### 特別なディレクティブ処理

- **no-cache**: オンライン時は毎回検証、オフライン時は stale 使用可能
- **no-store**: 設定により無視可能（`ignoreNoStore: true`）
- **must-revalidate**: 期限切れ時の強制検証をマーク（オフライン時は無視して stale 使用）

### キャッシュ削除タイミング

#### 自動削除（定期 purge）

- **実行間隔**: 1 時間ごと
- **削除対象**:
  1. **Expired 状態**のキャッシュ（stale 期間も超過）
  2. **破損キャッシュ**（整合性チェック失敗）
  3. **容量超過時の LRU 削除**（stale 状態でも削除対象）

#### 手動削除メソッド

キャッシュ管理のためのメソッドを提供します。詳細は【20】API リファレンスを参照してください。

- **`clearCache()`**: 全キャッシュを即座に削除
- **`clearExpiredCache()`**: Expired 状態のキャッシュのみ削除
- **`clearCacheForUrl(String url)`**: 特定 URL のキャッシュを削除

#### 緊急削除

- **ディスク容量不足**: 空き容量が設定値を下回った場合、stale 状態でも削除
- **破損検出**: ファイル読み込み時に破損を検出した場合、即座に削除

#### アプリライフサイクル連動

- **アプリ起動時**: 破損キャッシュの検出・削除
- **アプリ終了時**: メモリキャッシュのクリア（ファイルキャッシュは保持）
- **設定変更時**: TTL 設定変更時は既存キャッシュの期限を再計算

### キャッシュ使用優先順位

リクエスト処理時の判定順序：

#### オンライン時

1. **Fresh 状態**: そのまま使用
2. **Stale 状態**: 条件付きリクエストで検証
   - **304 Not Modified**: キャッシュ継続使用（TTL リセット）
   - **200 OK**: 新レスポンスでキャッシュ更新
   - **ネットワークエラー**: stale キャッシュを使用
3. **Expired/未キャッシュ**: 上流サーバから取得

#### オフライン時

1. **Fresh 状態**: そのまま使用
2. **Stale 状態**: そのまま使用（`X-Cache-Status: stale`）
3. **Expired/未キャッシュ**: フォールバックまたは 504 エラー

### メンテナンス

- **purge 実行**: 1 時間ごとに Expired キャッシュの削除と LRU 整理を自動実行
- **Cache-Control 検証**: 保存されたキャッシュの Cache-Control 情報を定期的に再評価
- **統計情報**: キャッシュヒット率、stale 使用率、no-cache 無視回数等をログ出力

### 設定例

```yaml
# オフラインWebプロキシ設定ファイル
# assets/config/config.yaml
#
# 全ての設定項目はオプションです。
# 未設定の項目は以下に示すデフォルト値が自動的に使用されます。

proxy:
  # サーバ基本設定
  server:
    port: 0 # 0=自動割当
    host: "127.0.0.1" # ローカルバインド
    origin: "" # 上流 サーバのURL（デフォルトは空、必須設定）
      # 例: "https://api.example.com"

  # キャッシュ設定
  cache:
    maxSizeBytes: 209715200 # 200MB
    purgeIntervalSeconds: 3600 # 1時間ごと

    # 起動時更新設定
    startup:
      enabled: false # 起動時更新を有効にするか
      paths: [] # 起動時に更新するパスリスト（デフォルトは空）
        # - "/config"
        # - "/user/profile"
        # - "/assets/app.css"
      timeout: 30 # 各パスのタイムアウト（秒）
      maxConcurrency: 3 # 同時実行数
      onFailure: "continue" # continue（継続）/abort（中止）

    # TTL設定（秒）
    ttl:
      "text/html": 3600 # 1時間
      "text/css": 86400 # 24時間
      "application/javascript": 86400 # 24時間
      "image/*": 604800 # 7日間
      "default": 86400 # 24時間

    # Stale期間設定（TTL切れ後の保持期間）
    stale:
      "text/html": 86400 # 1日間
      "text/css": 604800 # 7日間
      "image/*": 2592000 # 30日間
      "default": 259200 # 3日間
      maxPeriodSeconds: 2592000 # 最大30日

    # Cache-Control オーバーライド
    override:
      ignoreNoStore: true # no-storeを無視
      ignoreMustRevalidate: true # オフライン時はmust-revalidateを無視
      forceCache: # 強制キャッシュ対象
        - "/static/*"
        - "*.woff2"
        - "*.ttf"

  # リクエストキュー設定
  queue:
    drainIntervalSeconds: 3 # キュー排出間隔
    retryBackoffSeconds: [1, 2, 5, 10, 20, 30, 60] # バックオフ間隔
    jitterPercent: 20 # ±20%

  # タイムアウト設定（秒）
  timeouts:
    connect: 10 # TCP接続確立
    send: 15 # リクエスト送信
    receive: 30 # レスポンス受信
    request: 60 # リクエスト全体

  # べき等性設定
  idempotency:
    retentionHours: 24 # べき等性キーの保持期間

  # ヘッダ書き換え設定（デフォルトは空、必要に応じて設定）
  headers: {} # 空オブジェクト=デフォルト動作（デフォルト）
    # authorization: "passthrough"  # 例: passthrough/inject/off
    # cookies: "jar"                # 例: jar/passthrough/off
    # setCookies: "capture"         # 例: capture/passthrough
    # origin: "replace"             # 例: replace/passthrough/remove
    # referer: "replace"            # 例: replace/passthrough/remove
    # acceptEncoding: "managed"     # 例: managed/passthrough/identity-downstream
    # location: "rewrite"           # 例: rewrite/passthrough

  # フォールバック設定
  fallback:
    offlinePage: "assets/fallback/offline.html"
    errorPage: "assets/fallback/error.html"

  # ログ設定
  logging:
    level: "info" # debug/info/warn/error
    maskSensitiveHeaders: true # Authorization/Cookie等をマスク

  # 開発・デバッグ設定
  debug:
    enableAdminApi: false # セキュリティ重視、開発時のみtrue推奨
    cacheInspection: false # セキュリティ重視、開発時のみtrue推奨
    detailedHeaders: false # パフォーマンス重視、開発時のみtrue推奨
```

## 【17】スレッドセーフティ

### 同期制御

キャッシュ操作（put/get/purge）は直列化（ミューテックス）により排他制御を実装。複数のリクエストが同時にキャッシュにアクセスしても、データの整合性を保証します。

### 実装方針

- **読み書き分離**: 読み取り専用操作は可能な限り並行実行
- **書き込み排他**: 書き込み操作は完全に排他制御
- **デッドロック回避**: ロック取得順序を統一してデッドロックを防止

## 【18】ログと個人情報保護

### ログレベル

- **既定レベル**: info（本番運用に適したレベル）
- **デバッグ**: debug 指定時も機密情報は出力しない

### マスキング対象

- **Authorization**: Bearer token 等の認証情報
- **Cookie**: セッション ID 等の機密 Cookie 値
- **Set-Cookie**: レスポンスで設定される Cookie 値

### ログ出力例

```
INFO: GET /api/user → 200 OK (Authorization: **\***, Cookie: **\***)
```

## 【19】プラットフォーム固有の注意事項

### iOS (App Transport Security)

- **ATS 例外**: 127.0.0.1 への HTTP 接続を許可する設定が必要
- **Info.plist 設定**:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

### Android (Network Security Config)

- **cleartext 例外**: 127.0.0.1 への HTTP 接続を許可
- **network_security_config.xml 設定**:

```xml
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
```

### 推奨事項

- **IP アドレス使用**: `localhost` よりも `127.0.0.1` の使用を推奨
- **理由**: プラットフォームによっては localhost の名前解決が不安定な場合があるため

## 【20】API リファレンス

### 基本操作

#### `Future<int> start({ProxyConfig? config})`

プロキシサーバを起動します。

- **パラメータ**:
  - `config`: 設定オブジェクト（省略時はデフォルト設定またはファイル設定を使用）
- **戻り値**: 実際に使用されるポート番号
- **例外**:
  - `ProxyStartException`: サーバ起動に失敗した場合
  - `PortBindException`: ポートバインドに失敗した場合

```dart
final proxy = OfflineWebProxy();
final port = await proxy.start();
print('Proxy started on port: $port');
```

#### `Future<void> stop()`

プロキシサーバを停止します。

- **戻り値**: なし
- **例外**:
  - `ProxyStopException`: サーバ停止に失敗した場合

```dart
await proxy.stop();
```

#### `bool get isRunning`

プロキシサーバの動作状態を取得します。

- **戻り値**: サーバが動作中の場合 `true`

### キャッシュ管理

#### `Future<void> clearCache()`

全キャッシュを即座に削除します。

- **戻り値**: なし
- **例外**:
  - `CacheOperationException`: キャッシュ削除に失敗した場合

```dart
await proxy.clearCache();
```

#### `Future<void> clearExpiredCache()`

Expired 状態のキャッシュのみ削除します。

- **戻り値**: なし
- **例外**:
  - `CacheOperationException`: キャッシュ削除に失敗した場合

```dart
await proxy.clearExpiredCache();
```

#### `Future<void> clearCacheForUrl(String url)`

特定 URL のキャッシュを削除します。

- **パラメータ**:
  - `url`: 削除対象の URL（正規化されてからハッシュ化される）
- **戻り値**: なし
- **例外**:
  - `ArgumentError`: 無効な URL が指定された場合
  - `CacheOperationException`: キャッシュ削除に失敗した場合

```dart
await proxy.clearCacheForUrl('https://example.com/api/data');
```

#### `Future<List<CacheEntry>> getCacheList({int? limit, int? offset})`

キャッシュエントリの一覧を取得します。

- **パラメータ**:
  - `limit`: 取得件数の上限（デフォルト: 100）
  - `offset`: 取得開始位置（デフォルト: 0）
- **戻り値**: キャッシュエントリのリスト
- **例外**:
  - `CacheOperationException`: キャッシュ取得に失敗した場合

```dart
final cacheList = await proxy.getCacheList(limit: 50);
for (final entry in cacheList) {
  print('URL: ${entry.url}, Status: ${entry.status}');
}
```

#### `Future<CacheStats> getCacheStats()`

キャッシュの統計情報を取得します。

- **戻り値**: キャッシュ統計情報
- **例外**:
  - `CacheOperationException`: 統計情報取得に失敗した場合

```dart
final stats = await proxy.getCacheStats();
print('Cache size: ${stats.totalSize} bytes');
```

#### `Future<WarmupResult> warmupCache({List<String>? paths, int? timeout, int? maxConcurrency, WarmupProgressCallback? onProgress, WarmupErrorCallback? onError})`

指定されたパスリストのキャッシュを一括更新します。

- **パラメータ**:
  - `paths`: 更新対象のパスリスト（省略時は設定ファイルの startup.paths を使用）
  - `timeout`: 各パスのタイムアウト秒数（省略時は設定値を使用）
  - `maxConcurrency`: 同時実行数（省略時は設定値を使用）
  - `onProgress`: 進捗コールバック関数
  - `onError`: エラーコールバック関数
- **戻り値**: 更新結果の詳細情報
- **例外**:
  - `ArgumentError`: 無効なパスが含まれている場合
  - `WarmupException`: 更新処理全体が失敗した場合

```dart
// 設定ファイルのパスリストで更新
final result = await proxy.warmupCache();

// カスタムパスリストで更新
final result = await proxy.warmupCache(
  paths: [
    '/config',
    '/user/profile',
  ],
  timeout: 10,
  maxConcurrency: 2,
  onProgress: (completed, total) {
    print('Progress: $completed/$total');
  },
  onError: (path, error) {
    print('Failed to update $path: $error');
  },
);

print('Success: ${result.successCount}, Failed: ${result.failureCount}');
```

### Cookie 管理

#### `Future<List<CookieInfo>> getCookies({String? domain})`

現在保存されている Cookie の一覧を取得します。

- **パラメータ**:
  - `domain`: フィルタリング対象のドメイン（省略時は全ドメイン）
- **戻り値**: Cookie の情報リスト（値はセキュリティ上マスクされる）
- **例外**:
  - `CookieOperationException`: Cookie 取得に失敗した場合

```dart
final cookies = await proxy.getCookies(domain: 'example.com');
for (final cookie in cookies) {
  print('Name: ${cookie.name}, Domain: ${cookie.domain}');
}
```

#### `Future<void> clearCookies({String? domain})`

Cookie を削除します。

- **パラメータ**:
  - `domain`: 削除対象のドメイン（省略時は全 Cookie を削除）
- **戻り値**: なし
- **例外**:
  - `CookieOperationException`: Cookie 削除に失敗した場合
- **注意**: ファイルから削除すると同時にメモリキャッシュからも削除されます

```dart
await proxy.clearCookies(); // 全Cookie削除（ファイル+メモリ）
await proxy.clearCookies(domain: 'example.com'); // 特定ドメインのみ削除
```

### キュー管理

#### `Future<List<QueuedRequest>> getQueuedRequests()`

現在キューに保存されているリクエストの一覧を取得します。

- **戻り値**: キューイングされたリクエストのリスト
- **例外**:
  - `QueueOperationException`: キュー取得に失敗した場合

```dart
final queued = await proxy.getQueuedRequests();
print('Queued requests: ${queued.length}');
```

#### `Future<List<DroppedRequest>> getDroppedRequests({int? limit})`

ドロップされたリクエストの履歴を取得します。

- **パラメータ**:
  - `limit`: 取得件数の上限（デフォルト: 100）
- **戻り値**: ドロップされたリクエストのリスト
- **例外**:
  - `QueueOperationException`: 履歴取得に失敗した場合

```dart
final dropped = await proxy.getDroppedRequests();
for (final request in dropped) {
  print('URL: ${request.url}, Reason: ${request.dropReason}');
}
```

#### `Future<void> clearDroppedRequests()`

ドロップされたリクエストの履歴をクリアします。

- **戻り値**: なし
- **例外**:
  - `QueueOperationException`: 履歴削除に失敗した場合

```dart
await proxy.clearDroppedRequests();
```

### 統計・監視

#### `Future<ProxyStats> getStats()`

プロキシサーバの統計情報を取得します。

- **戻り値**: プロキシ統計情報
- **例外**:
  - `StatsOperationException`: 統計情報取得に失敗した場合

```dart
final stats = await proxy.getStats();
print('Total requests: ${stats.totalRequests}');
print('Cache hit rate: ${stats.cacheHitRate}%');
print('Queue length: ${stats.queueLength}');
```

#### `Stream<ProxyEvent> get events`

プロキシサーバのイベントストリームを取得します。

- **戻り値**: プロキシイベントの Stream
- **用途**: リアルタイム監視、ログ出力

```dart
proxy.events.listen((event) {
  switch (event.type) {
    case ProxyEventType.cacheHit:
      print('Cache hit: ${event.url}');
      break;
    case ProxyEventType.requestQueued:
      print('Request queued: ${event.url}');
      break;
  }
});
```

### データクラス定義

#### `CacheEntry`

```dart
class CacheEntry {
  final String url;
  final int statusCode;
  final String contentType;
  final DateTime createdAt;
  final DateTime expiresAt;
  final CacheStatus status; // fresh, stale, expired
  final int sizeBytes;
}
```

#### `CookieInfo`

```dart
class CookieInfo {
  final String name;
  final String value; // マスクされた値
  final String domain;
  final String path;
  final DateTime? expires;
  final bool secure;
  final String? sameSite;
}
```

#### `QueuedRequest`

```dart
class QueuedRequest {
  final String url;
  final String method;
  final Map<String, String> headers;
  final DateTime queuedAt;
  final int retryCount;
  final DateTime nextRetryAt;
}
```

#### `DroppedRequest`

```dart
class DroppedRequest {
  final String url;
  final String method;
  final DateTime droppedAt;
  final String dropReason;
  final int statusCode;
  final String errorMessage;
}
```

#### `ProxyStats`

```dart
class ProxyStats {
  final int totalRequests;
  final int cacheHits;
  final int cacheMisses;
  final double cacheHitRate;
  final int queueLength;
  final int droppedRequestsCount;
  final DateTime startedAt;
  final Duration uptime;
}
```

#### `CacheStats`

```dart
class CacheStats {
  final int totalEntries;
  final int freshEntries;
  final int staleEntries;
  final int expiredEntries;
  final int totalSize;
  final double hitRate;
  final double staleUsageRate;
}
```

#### `WarmupResult`

```dart
class WarmupResult {
  final int successCount;
  final int failureCount;
  final Duration totalDuration;
  final List<WarmupEntry> entries;
}

class WarmupEntry {
  final String path;
  final bool success;
  final int? statusCode;
  final String? errorMessage;
  final Duration duration;
}
```
