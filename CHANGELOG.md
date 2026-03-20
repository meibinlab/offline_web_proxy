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
