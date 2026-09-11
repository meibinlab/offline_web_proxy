/// # offline_web_proxy
///
/// Flutter WebView内で動作するオフライン対応ローカルプロキシサーバ。
/// 既存のWebシステムをモバイルアプリでシームレスに動作させ、
/// オンライン/オフライン状態を意識する必要をなくします。
///
/// ## 主な機能
///
/// * **インテリジェントキャッシング**: RFC準拠のキャッシュ制御とオフライン戦略
/// * **リクエストキューイング**: オフライン時のPOST/PUT/DELETEリクエストの自動キュー。
///   キュー・隔離・ドロップ履歴は AES-256 で暗号化して保存し、隔離と履歴には保持上限を設ける
/// * **Cookie管理**: AES-256暗号化による安全なCookie永続化
/// * **静的リソース配信**: `assets/static/` 配下を起動時に走査し、同梱アセットとして配信
/// * **シームレスなオフライン対応**: 透過的なオンライン/オフライン切り替え
///
/// ## クイックスタート
///
/// ```dart
/// import 'package:offline_web_proxy/offline_web_proxy.dart';
///
/// final proxy = OfflineWebProxy();
/// final config = ProxyConfig(
///   origin: 'https://your-api-server.com',
///   port: 0, // ポート自動割り当て
///   preferredPort: 8787, // 利用可能なら固定ポートを優先する
/// );
///
/// // プロキシサーバを起動
/// final port = await proxy.start(config: config);
/// print('Proxy running on http://127.0.0.1:$port');
///
/// // WebViewで使用
/// webViewController.loadUrl('http://127.0.0.1:$port/your-app-path');
/// ```
///
/// ## アーキテクチャ
///
/// プロキシはWebViewからのHTTPリクエストを横取りして:
/// 1. **オンライン時**: リクエストを上流サーバに転送し、レスポンスをキャッシュ
/// 2. **オフライン時**: キャッシュから配信、または更新リクエストをキューに保存
/// 3. **復旧時**: オンライン復帰時にキューされたリクエストを自動的に消化
///
/// ## キャッシュ戦略
///
/// * **Fresh**: TTL内、即座に配信
/// * **Stale**: TTL切れだがStale期間内、オンラインなら検証
/// * **Expired**: Stale期間外、クリーンアップ時に削除
///
/// 設定オプションは [ProxyConfig] を、詳細な技術仕様は
/// [specs.md](https://github.com/meibinlab/offline_web_proxy/blob/main/specs.md) を参照してください。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'src/exceptions/exceptions.dart';
import 'src/matching/path_pattern.dart';
import 'src/models/cache_entry.dart';
import 'src/models/cache_stats.dart';
import 'src/models/cookie_header_builder.dart';
import 'src/models/cookie_info.dart';
import 'src/models/cookie_record.dart';
import 'src/models/cookie_restore_entry.dart';
import 'src/models/drop_policy.dart';
import 'src/models/dropped_request.dart';
import 'src/models/online_decision_source.dart';
import 'src/models/proxy_config.dart';
import 'src/models/proxy_diagnostics.dart';
import 'src/models/proxy_event.dart';
import 'src/models/proxy_navigation_resolution.dart';
import 'src/models/proxy_recovery_result.dart';
import 'src/models/proxy_response_config.dart';
import 'src/models/proxy_stats.dart';
import 'src/models/proxy_webview_navigation_recommendation.dart';
import 'src/models/quarantined_request.dart';
import 'src/models/queue_exclude_rule.dart';
import 'src/models/queue_resend_result.dart';
import 'src/models/queued_request.dart';
import 'src/models/response_header_snapshot.dart';
import 'src/models/storage_integrity.dart';
import 'src/models/upstream_circuit_state.dart';
import 'src/models/warmup_result.dart';
import 'src/pages/offline_recovery_page.dart';
import 'src/storage/async_lock.dart';
import 'src/storage/encrypted_storage_integrity.dart';
import 'src/storage/encryption_key_reader.dart';
import 'src/storage/encryption_key_storage.dart';
import 'src/storage/hive_frame_inspector.dart';
import 'src/storage/storage_order.dart';

export 'src/exceptions/exceptions.dart';
export 'src/lifecycle/proxy_lifecycle_guard.dart';
export 'src/models/cache_entry.dart';
export 'src/models/cache_stats.dart';
export 'src/models/cookie_info.dart';
export 'src/models/cookie_restore_entry.dart';
export 'src/models/drop_policy.dart';
export 'src/models/dropped_request.dart';
export 'src/models/online_decision_source.dart';
export 'src/models/proxy_config.dart';
export 'src/models/proxy_diagnostics.dart';
export 'src/models/proxy_event.dart';
export 'src/models/proxy_navigation_resolution.dart';
export 'src/models/proxy_recovery_result.dart';
export 'src/models/proxy_response_config.dart';
export 'src/models/proxy_stats.dart';
export 'src/models/proxy_webview_navigation_recommendation.dart';
export 'src/models/quarantined_request.dart';
export 'src/models/queue_exclude_rule.dart';
export 'src/models/queue_resend_result.dart';
export 'src/models/queued_request.dart';
export 'src/models/storage_integrity.dart';
export 'src/models/upstream_circuit_state.dart';
export 'src/models/warmup_result.dart';

/// 上流への同時接続数の空き待ちが締め切りを超えたことを表す例外。
///
/// 上流サーバの障害ではなく proxy 側の混雑が原因のため、
/// 上流到達性の判定には数えません。
class _UpstreamSlotTimeoutException implements Exception {
  /// 例外を生成します。
  ///
  /// [message] 失敗内容の説明。
  const _UpstreamSlotTimeoutException(this.message);

  /// 失敗内容の説明。
  final String message;

  @override
  String toString() => 'UpstreamSlotTimeoutException: $message';
}

/// キャッシュ事前更新の進捗を通知するコールバック関数。
typedef WarmupProgressCallback = void Function(int completed, int total);

/// キャッシュ事前更新でエラーが発生した際に呼ばれるコールバック関数。
typedef WarmupErrorCallback = void Function(String path, String error);

const String _encryptedCookieBoxName = 'proxy_cookies_secure';
const String _legacyCookieBoxName = 'proxy_cookies';
const String _portPreferenceBoxName = 'proxy_port_preferences';
const String _webStorageBoxName = 'proxy_web_storage';
const String _cookieEncryptionKeyStorageKey =
    'offline_web_proxy.cookie_box_encryption_key';
const int _cookieEncryptionKeyLength = 32;

/// 暗号化して保存するキューの Box 名。
const String _encryptedQueueBoxName = 'proxy_queue_secure';

/// 暗号化して保存する隔離の Box 名。
const String _encryptedQuarantineBoxName = 'proxy_quarantined_requests_secure';

/// 暗号化して保存するドロップ履歴の Box 名。
const String _encryptedDroppedRequestBoxName = 'proxy_dropped_requests_secure';

/// 鍵と照合する暗号化 Box の一覧。
const Map<ProxyStorageBox, String> _encryptedBoxNames = {
  ProxyStorageBox.cookies: _encryptedCookieBoxName,
  ProxyStorageBox.queue: _encryptedQueueBoxName,
  ProxyStorageBox.quarantine: _encryptedQuarantineBoxName,
  ProxyStorageBox.droppedRequests: _encryptedDroppedRequestBoxName,
};

/// 起動時の照合で、走査を打ち切る時間の上限。
/// 異常な場合の安全装置で、判定が端末の速さで変わらないようバイト数では打ち切らない。
const Duration _defaultStorageVerificationTimeLimit = Duration(seconds: 10);

/// 中身のある暗号化 Box があり鍵を読めない場合に、読み直す間隔。
const Duration _defaultKeyRereadInterval = Duration(milliseconds: 500);

/// 中身のある暗号化 Box があり鍵を読めない場合に、読み直す回数。
const int _defaultKeyRereadAttempts = 3;

/// 移行元の旧平文 Box の一覧。移行する順に並べる。
const Map<ProxyStorageBox, String> _legacyBoxNames = {
  ProxyStorageBox.queue: _legacyQueueBoxName,
  ProxyStorageBox.quarantine: _legacyQuarantinedRequestBoxName,
  ProxyStorageBox.droppedRequests: _legacyDroppedRequestBoxName,
};

/// 鍵を生成したインスタンスで、旧平文 Box の移行を遅らせる時間。
///
/// Android の secure storage はメモリ上の値を先に更新し、ディスクへは非同期に
/// 書くため、同じプロセスで読み直しても書き込みの確認にならない。保証できるのは
/// この待ち時間だけ。
const Duration _defaultDeferredMigrationDelay = Duration(seconds: 30);

/// キュー消化・隔離・ドロップ履歴の排他を取得するまでの上限時間。
const Duration _defaultStorageLockTimeout = Duration(seconds: 30);

/// 機密情報としてマスクするヘッダ名（小文字にし `_` を `-` にそろえた形）。
const Set<String> _sensitiveHeaderNames = {
  'cookie',
  'authorization',
  'proxy-authorization',
};

/// 名前に含まれていれば、機密情報としてマスクするヘッダ名の一部。
const List<String> _sensitiveHeaderNameFragments = [
  'auth',
  'token',
  'secret',
  'session',
  'csrf',
  'xsrf',
  'key',
  'pass',
  'credential',
  'signature',
  'jwt',
  'cookie',
];

/// マスクしたヘッダの値。
const String _maskedHeaderValue = '***';

/// 一覧を組み立てるときに、UI の isolate へ処理を譲る件数の間隔。
const int _storedEntryYieldInterval = 50;

/// 隔離の件数または合計バイト数の上限により、ドロップ履歴へ移したときの理由。
const String _quarantineLimitDropReason = 'quarantine_limit';

/// 隔離の保持期間を過ぎたため、ドロップ履歴へ移したときの理由。
const String _quarantineExpiredDropReason = 'quarantine_expired';

/// 1 件で隔離の合計バイト数の上限を超えたため、隔離せずに記録したときの理由。
const String _quarantineTooLargeDropReason = 'quarantine_too_large';

/// 暗号化する前のキューの Box 名（移行元）。
const String _legacyQueueBoxName = 'proxy_queue';

/// 暗号化する前のドロップ履歴の Box 名（移行元）。
const String _legacyDroppedRequestBoxName = 'proxy_dropped_requests';

/// 暗号化する前の隔離の Box 名（移行元）。
const String _legacyQuarantinedRequestBoxName = 'proxy_quarantined_requests';
const Set<String> _loopbackHosts = {'127.0.0.1', 'localhost'};
const String _defaultHealthCheckPath = '/__offline_web_proxy/health';
const String _defaultStatusPath = '/__offline_web_proxy/status';

/// 管理エンドポイントのパス接頭辞。
/// proxy が予約している名前空間の下に固定し、業務ルートと衝突させない。
const String _adminPathPrefix = '/__offline_web_proxy/admin';

/// 別 origin の資源を中継するパスの接頭辞。
/// proxy が予約している名前空間の下に固定し、業務ルートと衝突させない。
const String _mirroredOriginPathPrefix = '/__offline_web_proxy/ext';
const String _defaultLoopbackHost = '127.0.0.1';

/// 復旧の連続失敗時に挟む待機秒数。末尾の値は以降も維持されます。
const List<int> _recoveryBackoffSeconds = [0, 1, 2, 5, 10];

/// 設定が読み込めない場合に使う既定のべき等性キーのヘッダ名。
const String _defaultIdempotencyHeaderName = 'Idempotency-Key';

/// 設定が読み込めない場合に使う既定のべき等性キーの保持期間。
const Duration _defaultIdempotencyRetention = Duration(hours: 24);

/// 設定が読み込めない場合に使う既定の受付時刻ヘッダ名。
const String _defaultAcceptedAtHeaderName = 'X-Offline-Accepted-At';

/// 保持するキュー再送結果の件数。
/// 監視用の直近確認が目的のため、上限を設けてメモリ使用量を抑える。
const int _recentResendResultCapacity = 20;

/// 設定が読み込めない場合に使う既定のキュー投入応答。
const ProxyResponseConfig _defaultQueuedResponse = ProxyResponseConfig(
  statusCode: 202,
  contentType: 'application/json; charset=utf-8',
  body: '{"queued":true}',
);

/// 設定が読み込めない場合に使う既定のオフライン時キャッシュミス応答。
const ProxyResponseConfig _defaultOfflineMissResponse = ProxyResponseConfig(
  statusCode: 504,
  contentType: 'application/json; charset=utf-8',
  body: '{"offline":true}',
);

/// 設定が読み込めない場合に使う既定の接続タイムアウト。
const Duration _defaultConnectTimeout = Duration(seconds: 5);

/// 設定が読み込めない場合に使う既定のリクエスト全体の締め切り。
const Duration _defaultRequestTimeout = Duration(seconds: 20);

/// 代替ページが状態通知を読む間隔の既定値。
const Duration _defaultAutoReloadPollInterval = Duration(seconds: 3);

/// 代替ページが再送の完了を待つ上限時間の既定値。
const Duration _defaultAutoReloadQueueWaitTimeout = Duration(seconds: 10);

/// 上流の復帰確認で使う既定のバックオフ秒数。
/// 設定が空の場合のフォールバックとして使用します。
const List<int> _defaultUpstreamProbeBackoffSeconds = [1, 2, 5, 10, 30];

/// 起動時に接続状態の取得を待つ上限時間。
/// プラットフォーム応答が遅い場合でも起動を止めないために設けています。
const Duration _initialConnectivityTimeout = Duration(milliseconds: 500);

/// 上流断を検知済みのためウォームアップを試行しなかった場合のメッセージ。
const String _upstreamUnreachableWarmupMessage = '上流へ到達できないため取得しませんでした';

/// 保存領域のキーに使うタイムスタンプの桁数。
/// マイクロ秒値をゼロ埋めし、辞書順と時系列順を一致させます。
const int _storageKeyTimestampDigits = 19;

/// 保存領域のキーに使う連番の桁数。
/// 同一マイクロ秒内で採番するため、この桁数を超えることは実質ありません。
const int _storageKeySequenceDigits = 6;

const Set<int> _redirectStatusCodes = {
  HttpStatus.movedPermanently,
  HttpStatus.found,
  HttpStatus.seeOther,
  HttpStatus.temporaryRedirect,
  HttpStatus.permanentRedirect,
};

/// ウォームアップで参照資源を抽出する対象タグ。
/// 実行時に組み立てられる URL には届かないため、最善努力の抽出に留める。
final RegExp _referenceTagPattern = RegExp(
  r'<\s*(script|link|img)\b([^>]*)>',
  caseSensitive: false,
);

/// `<link>` の `rel` を取り出す正規表現。
final RegExp _linkRelPattern = RegExp(
  '''\\brel\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'>]+))''',
  caseSensitive: false,
);

/// ウォームアップ対象として扱う `<link>` の `rel` 値。
const Set<String> _resourceLinkRelations = {
  'stylesheet',
  'preload',
  'prefetch',
  'icon',
  'shortcut',
  'apple-touch-icon',
  'apple-touch-icon-precomposed',
  'manifest',
};

/// 参照資源のタグ属性から URL を取り出す正規表現。
final RegExp _referenceUrlPattern = RegExp(
  '''\\b(?:src|href)\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'>]+))''',
  caseSensitive: false,
);

const List<String> _staticResourceAssetPrefixes = [
  'assets/static/',
  'packages/offline_web_proxy/assets/static/',
];

/// Flutter WebView内で動作するオフライン対応ローカルプロキシサーバ。
/// WebViewからのリクエストを横取りし、ネットワーク接続状態に基づいて
/// インテリジェントに処理を行うローカルHTTPサーバを作成します。
///
/// * **オンラインモード**: リクエストを上流サーバに転送し、レスポンスをキャッシュ
/// * **オフラインモード**: キャッシュから配信、または更新リクエストをキューに保存
/// * **復旧モード**: 接続復帰時にキューされたリクエストを自動的に消化
///
/// ## 使用例
///
/// ```dart
/// final proxy = OfflineWebProxy();
///
/// // プロキシの設定
/// final config = ProxyConfig(
///   origin: 'https://api.example.com',
///   cacheMaxSize: 100 * 1024 * 1024, // 100MBキャッシュ
///   connectTimeout: Duration(seconds: 5),
/// );
///
/// // サーバを起動
/// final port = await proxy.start(config: config);
///
/// // WebViewで使用
/// webViewController.loadUrl('http://127.0.0.1:$port');
///
/// // イベントを監視
/// proxy.events.listen((event) {
///   if (event.type == ProxyEventType.cacheHit) {
///     print('Cache hit: ${event.url}');
///   }
/// });
///
/// // 統計情報を取得
/// final stats = await proxy.getStats();
/// print('Hit rate: ${stats.cacheHitRate}');
///
/// // クリーンアップ
/// await proxy.stop();
/// ```
///
/// ## スレッドセーフティ
///
/// このクラスは並行操作に対してスレッドセーフです。キャッシュ操作は
/// mutexロックを使用してシリアライズされ、データの一貫性が保証されます。
///
/// ## セキュリティ
///
/// * サーバは `127.0.0.1` のみにバインド（外部アクセス不可）
/// * Cookieは永続化前にAES-256で暗号化
/// * 機密ヘッダはログ内でマスク
/// * 静的アセットに対するパストラバーサル攻撃を防止
///
/// 参照:
/// * [ProxyConfig] 設定オプション
/// * [ProxyStats] 監視機能
/// * [ProxyEvent] リアルタイムイベントストリーミング
class OfflineWebProxy {
  /// 内部HTTPサーバのインスタンス。
  HttpServer? _server;

  /// プロキシサーバの設定。
  ProxyConfig? _config;

  /// プロキシサーバの動作状態。
  bool _isRunning = false;

  /// プロキシサーバの開始日時。
  DateTime? _startedAt;

  /// 総リクエスト数（統計用）。
  int _totalRequests = 0;

  /// キャッシュヒット数（統計用）。
  int _cacheHits = 0;

  /// キャッシュミス数（統計用）。
  int _cacheMisses = 0;

  /// プロキシイベントの配信用ストリームコントローラ。
  StreamController<ProxyEvent> _eventController =
      StreamController<ProxyEvent>.broadcast();

  /// ネットワーク接続状態の監視用サブスクリプション。
  /// ライブラリのバージョンによって `ConnectivityResult` または `List<ConnectivityResult>` を返す場合があるため
  /// 汎用的に受け取れるよう `dynamic` 型にしています。
  late StreamSubscription<dynamic> _connectivitySubscription;

  /// 現在のオンライン状態。
  bool _isOnline = true;

  /// 現在のオンライン判定の根拠。
  OnlineDecisionSource _onlineDecisionSource = OnlineDecisionSource.initial;

  /// 接続状態の変化イベントを受信済みかを示すフラグ。
  /// 起動時の初期化が、より新しい変化イベントを上書きしないようにするために使う。
  bool _hasReceivedConnectivityEvent = false;

  /// 上流到達性のサーキットブレーカ状態。
  UpstreamCircuitState _upstreamCircuitState = UpstreamCircuitState.closed;

  /// 上流へ到達できなかった連続回数。上流が応答した時点で 0 に戻す。
  /// 復帰確認の失敗は含めず、転送を試みたリクエストの失敗だけを数える。
  int _consecutiveUpstreamFailures = 0;

  /// 最後に上流へ到達できた日時。未到達の場合は `null`。
  DateTime? _lastUpstreamSuccessAt;

  /// 上流の復帰確認を予約するタイマー。
  Timer? _upstreamProbeTimer;

  /// 復帰確認の連続失敗回数。バックオフ段階の決定に使う。
  int _upstreamProbeAttempts = 0;

  /// キュー消化が実行中かを示すフラグ（重複実行防止）。
  bool _isDrainingQueue = false;

  /// 上流サーバへのリクエスト用HTTPクライアント（dart:io）。
  HttpClient? _httpClient;

  /// バックグラウンドタスク用タイマー（stop()で確実に停止する）。
  Timer? _queueDrainTimer;
  Timer? _cachePurgeTimer;

  /// キャッシュデータの永続化ボックス。
  Box? _cacheBox;

  /// キューデータの永続化ボックス。
  Box? _queueBox;

  /// Cookieデータの永続化ボックス。
  Box? _cookieBox;

  /// 直前に成功したバインドポートの永続化ボックス。
  Box? _portPreferenceBox;

  /// WebStorage 継承データの永続化ボックス。
  Box? _webStorageBox;

  /// べき等性キーの永続化ボックス。
  Box? _idempotencyBox;

  /// ドロップされたリクエスト履歴の永続化ボックス。
  Box? _droppedRequestBox;

  /// 上流に拒否されたリクエストの隔離領域。
  Box? _quarantinedRequestBox;

  /// べき等性キーの生成に使う乱数生成器。
  final Random _idempotencyKeyRandom = Random.secure();

  /// 未確認のドロップ履歴の件数。
  /// `getStats()` のたびに履歴を全走査しないよう保持し、更新時に破棄する。
  int? _unacknowledgedDroppedCount;

  /// 起動時に構築した静的リソースの proxy URL と asset key の対応表。
  final Map<String, String> _staticResourceAssetMap = {};

  /// 起動時に構築した、`no-store` を無視して保存するパスのパターン一覧。
  /// リクエストのたびに正規表現を組み立てないよう保持する。
  List<PathPattern> _forceCachePatterns = const [];

  /// 起動時に構築した、キューへ入れない更新系リクエストの規則一覧。
  List<({PathPattern pattern, QueueExcludeRule rule})> _queueExcludeRules =
      const [];

  /// 起動時に構築した、proxy 経由で中継する別 origin の一覧。
  /// scheme と host は小文字化し、既定ポートは省いた形で保持する。
  List<Uri> _mirroredOrigins = const [];

  /// 直近のキュー再送結果。古いものから捨てる。
  /// 監視用のため永続化はせず、アプリのプロセスが終了すると失われる。
  final Queue<QueueResendResult> _recentResendResults =
      Queue<QueueResendResult>();

  /// asset key ごとに算出した静的リソースの `ETag`。
  /// 同梱アセットはプロセス実行中に変化しないため、要求のたびに
  /// 全バイトをハッシュし直さないよう保持する。
  final Map<String, String> _staticResourceEntityTags = {};

  /// 上流サーバへの同時接続数を制限するセマフォ。
  /// WebView が短時間に多数のリクエストを投げた場合にネイティブ側のソケット枯渇を防ぐ。
  final Semaphore _upstreamSemaphore = Semaphore(50);

  /// 直前に保存領域のキーへ使用したマイクロ秒。
  /// 同一マイクロ秒内での連番採番に使う。
  int _lastStorageKeyMicroseconds = -1;

  /// 同一マイクロ秒内で採番する連番。
  /// マイクロ秒が変わるたびに 0 へ戻す。
  int _storageKeySequence = 0;

  /// 現在バインドしているポート番号。
  /// サスペンドでソケットが無効化された後も参照できるよう、サーバとは別に保持する。
  int? _boundPort;

  /// 再バインドで再利用する shelf ハンドラ。
  shelf.Handler? _handler;

  /// 死活監視用タイマー（定期ヘルスチェックが有効な場合のみ動作する）。
  Timer? _healthCheckTimer;

  /// 進行中の復旧処理。多重実行を防ぐために保持する。
  Future<ProxyRecoveryResult>? _recoveryOperation;

  /// 再バインドを実行した回数。
  int _restartCount = 0;

  /// 再バインドを試行した時刻の履歴（1 分あたりの上限判定に使用）。
  final List<DateTime> _restartAttempts = [];

  /// 連続した復旧失敗回数（待機時間の算出に使用）。
  int _consecutiveRecoveryFailures = 0;

  /// 最終稼働確認の日時。
  DateTime? _lastProbeAt;

  /// 最終稼働確認の結果。
  bool? _lastProbeSucceeded;

  /// 最終復旧処理の判定種別。
  ProxyRecoveryCause? _lastRecoveryCause;

  /// 最終復旧処理が失敗した場合の内容。
  String? _lastRecoveryError;

  /// 直近の停止推定時間（ミリ秒）。
  int? _lastDowntimeMs;

  /// この proxy が使用したポートの集合。
  /// 旧ポート URL の読み替え対象を自インスタンスのポートに限定するために使う。
  final Set<int> _knownProxyPorts = <int>{};

  /// 停止処理と再バインドを排他にするためのロック。
  /// 停止後にソケットやバックグラウンドタイマーが残らないようにする。
  final Semaphore _lifecycleLock = Semaphore(1);

  /// 保存領域の初期化（段階 1 と段階 2）と復旧を直列化するためのロック。
  ///
  /// 鍵（secure storage 上の固定の名前）と Box（Hive への登録）は同じ isolate 内の
  /// インスタンスで共有されるため、インスタンスをまたいで直列化する。同時に
  /// 呼ばれても、鍵の生成と Box のオープンが重ならないようにする。static な
  /// フィールドと Hive への登録は isolate ごとのため、複数の isolate から同時に
  /// 使う場合は対象外。
  static final AsyncLock _storageInitializationLock = AsyncLock();

  /// この isolate で稼働中または起動処理中の proxy。
  ///
  /// 復旧 API は Box を閉じて削除するため、どのインスタンスも保存領域を
  /// 使っていない場合に限って実行する。
  static final Set<OfflineWebProxy> _activeInstances = <OfflineWebProxy>{};

  /// この isolate の保存領域の世代。復旧 API が Box を削除・作り直すたびに進める。
  ///
  /// 復旧 API は呼び出したインスタンスの状態しか捨てられないため、別のインスタンスは
  /// 段階 1 を済ませたときの世代と比べ、違っていれば古い鍵を使わずに段階 1 から
  /// やり直す。
  static int _storageGeneration = 0;

  /// 実行中または完了済みの段階 1（鍵と Cookie Box）の結果。失敗した場合は捨てる。
  ///
  /// 別の error zone から待つ呼び出しにも失敗を伝えられるよう、Future 自体は
  /// 失敗させず、失敗も結果として持つ。
  Future<_StageOutcome<Box>>? _keyStageFuture;

  /// 段階 1 が完了しているかどうか。
  bool _keyStageCompleted = false;

  /// 実行中または完了済みの段階 2（キューなどの Box）の結果。失敗した場合は捨てる。
  Future<_StageOutcome<void>>? _dataStageFuture;

  /// 段階 2 が完了しているかどうか。
  bool _dataStageCompleted = false;

  /// Cookie と業務データの暗号化鍵の読み書きに使う窓口。
  final EncryptionKeyStorage _keyStorage;

  /// テストから差し替えた保存領域の処理と待ち時間。通常は `null`。
  final ProxyStorageTestHooks? _storageTestHooks;

  /// 段階 1 で確定した暗号化鍵。段階 2 で業務データの Box を開くために使う。
  Uint8List? _storageEncryptionKey;

  /// 段階 1 を済ませたときの保存領域の世代。済ませていない場合は `null`。
  int? _keyStageGeneration;

  /// このインスタンスで暗号化鍵を生成してからの経過時間の計測。生成していない
  /// 場合は `null`。生成した場合は、旧平文 Box の移行を待ち時間の後へ遅らせる。
  /// 端末の時計を戻しても遅れないよう、日時ではなく経過時間で判定する。
  Stopwatch? _encryptionKeyGeneratedStopwatch;

  /// 移行を待っている旧平文キューの Box。移行を待っていない場合は `null`。
  Box? _legacyQueueBox;

  /// 移行を待っている旧平文隔離の Box。移行を待っていない場合は `null`。
  Box? _legacyQuarantineBox;

  /// 移行を待っている旧平文ドロップ履歴の Box。移行を待っていない場合は `null`。
  Box? _legacyDroppedRequestBox;

  /// 移行を待っている旧平文 Box ごとのキーの一覧。
  ///
  /// 書き写したキーを暗号化 Box から消せなかった場合に備え、旧 Box が空になるまで
  /// 暗号化 Box にある同じキーを、再送・隔離の変更・履歴の削除・件数と一覧から外す。
  final Map<ProxyStorageBox, Set<String>> _pendingLegacyKeys = {};

  /// 遅らせた移行を始めるタイマー。
  Timer? _deferredMigrationTimer;

  /// 実行中の遅らせた移行。完了すると、移行した Box があったかどうかを返す。
  Future<bool>? _deferredMigrationFuture;

  /// 遅らせた移行が書き写しを始めているかどうか。
  bool _deferredMigrationCopying = false;

  /// 送信を終えたキューの 1 件の保存（隔離・履歴への記録とキューからの削除）。
  /// 保存中でない場合は `null`。stop() は Box を閉じる前にこれを待つ。
  Future<void>? _queuedItemSaving;

  /// stop() が Box を閉じ始めたかどうか。
  ///
  /// stop() が保存中の 1 件を待つと決めた後に始まった保存は待てないため、
  /// 送信を終えたキューの 1 件は、これが立っていれば保存を始めずにキューに残す
  /// （次の起動で再送する）。
  bool _isClosingStorage = false;

  /// 実行中の stop() の呼び出し数。同時に呼ばれた stop() がすべて終わるまで、
  /// 停止中フラグを下ろさない。
  int _pendingStopCount = 0;

  /// start() の処理中かどうか。`_isRunning` は起動の最後に立つため、
  /// 起動処理中の復旧 API を拒否するために別に持つ。
  bool _isStarting = false;

  /// stop() の処理中かどうか。キュー消化は次の 1 件へ進む前に、遅らせた移行は
  /// 書き写しを始める前に、これを見て抜ける。
  bool _isStopping = false;

  /// キュー消化と遅らせた移行を排他にするロック。
  ///
  /// 複数のロックを取る場合は、キュー消化 → 隔離 → ドロップ履歴の順に取る。
  final AsyncLock _queueDrainLock = AsyncLock();

  /// 隔離を変更する処理（追加・上限による削除・再送・破棄・全削除・移行）を
  /// 直列化するロック。
  final AsyncLock _quarantineLock = AsyncLock();

  /// ドロップ履歴を変更する処理（追加・確認済みへの変更・全削除・上限による削除・
  /// 移行）を直列化するロック。
  final AsyncLock _droppedRequestLock = AsyncLock();

  /// 段階 1 で特定した Hive の保存先ディレクトリ。
  String? _hiveDirectoryPath;

  /// このインスタンスが最後に Cookie の暗号化 Box を破棄した日時。
  DateTime? _lastCookieStorageDiscardedAt;

  /// このインスタンスが最後に Cookie の暗号化 Box を破棄した理由。
  StorageIntegrityFailure? _lastCookieStorageDiscardReason;

  /// プロキシサーバのインスタンスを生成します。
  OfflineWebProxy() : this._(null);

  /// 保存領域の処理を差し替えたインスタンスを生成します。
  ///
  /// テスト専用です。鍵の読み取りの失敗や、照合と移行の待ち時間を差し替えます。
  ///
  /// [hooks] 差し替える処理と待ち時間。
  @visibleForTesting
  OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks hooks)
      : this._(hooks);

  /// インスタンスを生成します。
  ///
  /// [hooks] テストから差し替える保存領域の処理。通常は `null`。
  OfflineWebProxy._(ProxyStorageTestHooks? hooks)
      : _storageTestHooks = hooks,
        _keyStorage = hooks?.keyStorage ?? const SecureEncryptionKeyStorage();

  /// プロキシサーバを起動します。
  ///
  /// [config] 設定オブジェクト。省略時はデフォルト設定を使用します。
  ///
  /// Returns: 実際に使用されるポート番号。
  ///
  /// Throws:
  ///   * [ProxyStartException] サーバ起動に失敗した場合。既に稼働中、または
  ///     起動処理中の場合を含みます。
  ///   * [StorageIntegrityException] 暗号化した保存領域を使えない場合。
  ///     [ProxyStartException] のサブクラスで、包まずに送出します。何も
  ///     消していません。[StorageIntegrityException.failure] で理由を判別し、
  ///     必要なら利用者の確認を経て [recoverEncryptedStorage] を呼び出して
  ///     ください。
  ///   * [PortBindException] ポートバインドに失敗した場合。
  Future<int> start({ProxyConfig? config}) async {
    if (_isRunning) {
      throw ProxyStartException('Proxy server is already running', null);
    }
    if (_isStarting) {
      throw ProxyStartException('Proxy server is already starting', null);
    }

    _isStarting = true;
    _activeInstances.add(this);
    // 前回の stop() が残した停止中フラグを下ろし、キュー消化がすぐ抜け続けないようにする
    _isStopping = false;
    _isClosingStorage = false;
    try {
      if (_eventController.isClosed) {
        _eventController = StreamController<ProxyEvent>.broadcast();
      }

      // Hiveが初期化されていない場合は初期化
      if (!Hive.isAdapterRegistered(0)) {
        await Hive.initFlutter();
      }

      // 設定を読み込み
      _config = config ?? await _loadDefaultConfig();
      _validateHealthCheckPath();
      _validateStatusPath();
      _validateAutoReloadSettings();
      _validateRetentionSettings();
      _validateMirroredOrigins();
      _compileConfiguredPatterns();
      _resetRecoveryState();

      // ストレージを初期化
      await _initializeStorage();

      // 隔離とドロップ履歴の保持上限を判定する（ロックを取れない場合は定期処理へ回す）
      await _enforceRetentionLimits();

      // 旧ポート URL の読み替え対象として、直前のバインドポートを記録
      final persistedPort = await _loadPersistedPortForHost(_config!.host);
      if (persistedPort != null && persistedPort > 0) {
        _knownProxyPorts.add(persistedPort);
      }

      // 静的リソース一覧を初期化
      await _initializeStaticResourceIndex();

      // 上流到達性の判定状態を初期化する
      _resetUpstreamCircuit();

      // 接続状態の監視を開始し、起動時の実状態で初期値を確定する
      _startConnectivityMonitoring();
      await _initializeOnlineState();

      // ルーターとミドルウェアを作成し、再バインドで再利用できるよう保持する
      final router = _createRouter();
      final handler = const shelf.Pipeline()
          .addMiddleware(_errorHandlingMiddleware)
          .addMiddleware(_requestLoggingMiddleware())
          .addMiddleware(_corsMiddleware)
          .addMiddleware(_statisticsMiddleware)
          .addHandler(router.call);
      _handler = handler;

      // サーバを起動
      final server = await _bindServer(handler);
      _server = server;
      _boundPort = server.port;
      _knownProxyPorts.add(server.port);
      server.idleTimeout = _config!.serverIdleTimeout;

      _isRunning = true;
      _startedAt = DateTime.now();

      // サーバ起動イベントを発行
      _emitEvent(ProxyEventType.serverStarted, '', {
        'port': server.port,
        'host': _config!.host,
      });

      // バックグラウンドタスクを開始
      _startBackgroundTasks();

      return server.port;
    } on ProxyStartException {
      // 設定検証などで既に理由が確定している場合はそのまま伝播する
      rethrow;
    } catch (e) {
      throw ProxyStartException(
          'Failed to start proxy server: $e', e is Exception ? e : null);
    } finally {
      _isStarting = false;
      if (!_isRunning) {
        _activeInstances.remove(this);
      }
    }
  }

  /// プロキシサーバを停止します。
  ///
  /// Throws:
  ///   * [ProxyStopException] サーバ停止に失敗した場合。復旧処理との排他を
  ///     上限時間内に取得できなかった場合を含みます。
  Future<void> stop() async {
    if (!_isRunning) {
      return;
    }

    // キュー消化が次の 1 件へ進まず、遅らせた移行が書き写しを始めないよう、最初に立てる。
    // 同時に呼ばれた stop() がすべて終わるまで下ろさない
    _pendingStopCount++;
    _isStopping = true;

    // 復旧処理と同時に実行されないよう排他制御する
    try {
      await _lifecycleLock.acquire();
    } catch (e) {
      // 取得できなかった場合は停止しないため、キュー消化と移行を止めたままにしない
      _finishStopCall();
      throw ProxyStopException(
        'Failed to stop proxy server: $e',
        e is Exception ? e : null,
      );
    }
    if (!_isRunning) {
      _finishStopCall();
      _lifecycleLock.release();
      return;
    }

    Object? failure;
    try {
      _queueDrainTimer?.cancel();
      _queueDrainTimer = null;
      _deferredMigrationTimer?.cancel();
      _deferredMigrationTimer = null;
      _cachePurgeTimer?.cancel();
      _cachePurgeTimer = null;
      _healthCheckTimer?.cancel();
      _healthCheckTimer = null;
      _upstreamProbeTimer?.cancel();
      _upstreamProbeTimer = null;

      await _server?.close();
      await _connectivitySubscription.cancel();

      // 書き写しを始めた遅らせた移行は、ネットワークを使わず短いため終わるのを待つ。
      // まだ始めていなければ、停止中フラグを見て取り消される。
      final deferredMigration = _deferredMigrationFuture;
      if (deferredMigration != null && _deferredMigrationCopying) {
        await deferredMigration;
      }

      // 送信を終えたキューの 1 件の保存も、ネットワークを使わず短いため終わるのを待つ。
      // 途中で Box を閉じると、隔離や履歴に記録したのにキューに残り、次の起動で二重になる。
      // この後に保存を始める 1 件は、閉じ始めたことを見てキューに残す
      _isClosingStorage = true;
      final queuedItemSaving = _queuedItemSaving;
      if (queuedItemSaving != null) {
        await queuedItemSaving;
      }

      // Hiveボックスを閉じる
      await _cacheBox?.close();
      await _queueBox?.close();
      await _cookieBox?.close();
      await _portPreferenceBox?.close();
      await _webStorageBox?.close();
      await _idempotencyBox?.close();
      await _droppedRequestBox?.close();
      await _quarantinedRequestBox?.close();
      await _legacyQueueBox?.close();
      await _legacyQuarantineBox?.close();
      await _legacyDroppedRequestBox?.close();

      // HTTPクライアントを閉じる
      _httpClient?.close(force: true);
      _httpClient = null;
      _staticResourceAssetMap.clear();
      _staticResourceEntityTags.clear();
      _forceCachePatterns = const [];
      _queueExcludeRules = const [];
      _mirroredOrigins = const [];
    } catch (e) {
      failure = e;
    } finally {
      // 途中で失敗しても「稼働中だが実体なし」の状態を残さない
      _isRunning = false;
      _server = null;
      _boundPort = null;
      _handler = null;
      // 障害解析のため診断値は残し、実行制御状態のみ初期化する
      _resetRecoveryControlState();
      // 閉じた Box を共有しないよう、次の起動や Cookie API で初期化し直す
      _keyStageFuture = null;
      _keyStageCompleted = false;
      _dataStageFuture = null;
      _dataStageCompleted = false;
      // 移行を待っている旧 Box は、次の起動の段階 2 で改めて開いて予約し直す
      _legacyQueueBox = null;
      _legacyQuarantineBox = null;
      _legacyDroppedRequestBox = null;
      _pendingLegacyKeys.clear();
      // 停止後の getStats() が前回の件数を返さないよう、未確認件数のキャッシュを捨てる
      _unacknowledgedDroppedCount = null;
      _activeInstances.remove(this);
      _isClosingStorage = false;
      _finishStopCall();
      _lifecycleLock.release();
    }

    if (failure != null) {
      throw ProxyStopException('Failed to stop proxy server: $failure',
          failure is Exception ? failure : null);
    }

    _emitEvent(ProxyEventType.serverStopped, '', {});
  }

  /// stop() の呼び出しを 1 つ終えます。
  ///
  /// 同時に呼ばれた stop() がすべて終わっていれば、停止中フラグを下ろします。
  void _finishStopCall() {
    _pendingStopCount--;
    if (_pendingStopCount <= 0) {
      _pendingStopCount = 0;
      _isStopping = false;
    }
  }

  /// プロキシサーバの動作状態を取得します。
  ///
  /// Returns: サーバが動作中の場合は `true`。
  bool get isRunning => _isRunning;

  /// プロキシサーバのイベントストリームを取得します。
  ///
  /// リアルタイム監視やログ出力に使用できます。
  ///
  /// Returns: プロキシイベントのストリーム。
  Stream<ProxyEvent> get events => _eventController.stream;

  /// 現在バインドしているポート番号を取得します。
  ///
  /// Returns: 稼働中はポート番号。未起動時は `null`。
  int? get port => _boundPort;

  /// WebView から読み込む proxy のベース URI を取得します。
  ///
  /// Returns: `http://<host>:<port>` 形式の URI。未起動時は `null`。
  Uri? get baseUri {
    final boundPort = _boundPort;
    if (boundPort == null) {
      return null;
    }

    return Uri.parse('http://$_effectiveHost:$boundPort');
  }

  /// ヘルスチェックパスへ要求を送り、proxy が実際に応答するかを確認します。
  ///
  /// [timeout] は応答待ちの上限時間です。
  ///
  /// Returns: `204` を受け取った場合は `true`。接続失敗、タイムアウト、
  /// 想定外のステータスの場合は `false`。
  Future<bool> probe({Duration timeout = const Duration(seconds: 2)}) async {
    final boundPort = _boundPort;
    if (boundPort == null) {
      _recordProbeResult(false);
      return false;
    }

    // 死んだ keep-alive 接続を再利用しないよう、確認専用のクライアントを使う。
    // 本文は読み捨てるだけだが、自動解凍は共有クライアントと同じ扱いにそろえる。
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false;
    try {
      final uri =
          Uri.parse('http://$_effectiveHost:$boundPort$_healthCheckPath');
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>();

      final succeeded = response.statusCode == HttpStatus.noContent;
      _recordProbeResult(succeeded);
      return succeeded;
    } catch (_) {
      _recordProbeResult(false);
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 稼働確認を行い、応答しない場合のみサーバを再バインドします。
  ///
  /// [probeTimeout] は稼働確認のタイムアウトです。
  /// [force] を `true` にすると稼働確認の結果にかかわらず再バインドします。
  /// [downtime] は停止推定時間です。イベントと診断情報へ記録します。
  ///
  /// Returns: 復旧結果。例外は送出せず、失敗内容は結果に含めます。
  Future<ProxyRecoveryResult> ensureRunning({
    Duration probeTimeout = const Duration(seconds: 2),
    bool force = false,
    Duration? downtime,
  }) {
    return _beginRecovery(
      probeTimeout: probeTimeout,
      force: force,
      downtime: downtime,
    );
  }

  /// WebView が報告したリソースエラーを起点に復旧を試みます。
  ///
  /// [errorCode] は WebView が報告したエラーコードです（診断情報として記録）。
  /// [failingUrl] は失敗した URL です。
  /// [isMainFrame] はメインフレームの失敗かどうかです（判定には使用しません）。
  ///
  /// Returns: 復旧結果。proxy と無関係な URL の場合は `unrelated` を返します。
  Future<ProxyRecoveryResult> recoverFromWebResourceError({
    int? errorCode,
    String? failingUrl,
    bool isMainFrame = true,
  }) async {
    final trimmedUrl = failingUrl?.trim();
    if (trimmedUrl == null || trimmedUrl.isEmpty) {
      return ProxyRecoveryResult(
        cause: ProxyRecoveryCause.unrelated,
        port: _boundPort,
      );
    }

    final targetUri = Uri.tryParse(trimmedUrl);
    if (targetUri == null || !_isRecoverableProxyUri(targetUri)) {
      return ProxyRecoveryResult(
        cause: ProxyRecoveryCause.unrelated,
        port: _boundPort,
      );
    }

    final previousPort = _boundPort;
    final result = await _beginRecovery(
      probeTimeout: const Duration(seconds: 2),
      force: false,
      webResourceErrorCode: errorCode,
      isMainFrame: isMainFrame,
    );

    if (result.cause == ProxyRecoveryCause.notStarted ||
        result.cause == ProxyRecoveryCause.recoveryFailed) {
      return result;
    }

    // ポートのみが異なる場合は再バインドせず URL の読み替えで復帰させる
    final hasStalePort =
        previousPort != null && _effectivePort(targetUri) != previousPort;
    final cause = result.restarted
        ? result.cause
        : (hasStalePort ? ProxyRecoveryCause.stalePort : result.cause);

    return ProxyRecoveryResult(
      cause: cause,
      restarted: result.restarted,
      port: result.port,
      portChanged: result.portChanged,
      reloadUri: resolveReloadUri(trimmedUrl),
      downtimeMs: result.downtimeMs,
      error: result.error,
    );
  }

  /// WebView が保持していた URL を、現行ポートで読み込める URL へ読み替えます。
  ///
  /// [lastUrl] は WebView が保持していた URL です。
  ///
  /// Returns: 読み替え後の URI。読み替え対象外の場合は `null`。
  Uri? resolveReloadUri(String lastUrl) {
    final boundPort = _boundPort;
    if (boundPort == null) {
      return null;
    }

    final targetUri = Uri.tryParse(lastUrl.trim());
    if (targetUri == null || !_isRecoverableProxyUri(targetUri)) {
      return null;
    }

    // 別ポートで動作する他のローカルサーバへの遷移を奪わないため、
    // この proxy が使用したポートに限って読み替える
    if (!_isKnownProxyPort(_effectivePort(targetUri))) {
      return null;
    }

    // ホスト表記は設定ホストへ揃え、パス以降はそのまま保持する
    return targetUri.replace(host: _effectiveHost, port: boundPort);
  }

  /// 死活監視と復旧に関する診断情報を取得します。
  ///
  /// Returns: 診断情報。
  Future<ProxyDiagnostics> getDiagnostics() async {
    final persistedPort = await _loadPersistedPortForHost(_effectiveHost);

    return ProxyDiagnostics(
      isRunning: _isRunning,
      port: _boundPort,
      preferredPort: _config?.preferredPort ?? 0,
      persistedPort: persistedPort,
      startedAt: _startedAt,
      lastProbeAt: _lastProbeAt,
      lastProbeSucceeded: _lastProbeSucceeded,
      restartCount: _restartCount,
      lastRecoveryCause: _lastRecoveryCause,
      lastRecoveryError: _lastRecoveryError,
      lastDowntimeMs: _lastDowntimeMs,
      isOnline: _isOnline,
      onlineDecisionSource: _onlineDecisionSource,
      isUpstreamReachable: _isUpstreamReachable,
      upstreamCircuitState: _upstreamCircuitState,
      consecutiveUpstreamFailures: _consecutiveUpstreamFailures,
      lastUpstreamSuccessAt: _lastUpstreamSuccessAt,
      lastCookieStorageDiscardedAt: _lastCookieStorageDiscardedAt,
      lastCookieStorageDiscardReason: _lastCookieStorageDiscardReason,
    );
  }

  /// 内部状態を変更せずサーバのソケットのみを閉じます。
  ///
  /// 端末のサスペンドでソケットが無効化された「ソケット死亡」状態を
  /// テストで再現するための入口です。テスト以外では使用しません。
  ///
  /// Returns: 処理完了を表す Future。
  @visibleForTesting
  Future<void> closeServerSocketForTesting() async {
    final server = _server;
    if (server == null) {
      return;
    }

    try {
      await server.close(force: true);
    } catch (_) {
      // 既に閉じられている場合は無視する
    }
  }

  /// 稼働確認に使用するパスを返します。
  String get _healthCheckPath {
    final configuredPath = _config?.healthCheckPath.trim() ?? '';
    if (configuredPath.isEmpty) {
      return _defaultHealthCheckPath;
    }

    return configuredPath.startsWith('/') ? configuredPath : '/$configuredPath';
  }

  /// バインド対象のホスト名を返します。
  String get _effectiveHost {
    final configuredHost = _config?.host ?? '';
    return configuredHost.isNotEmpty ? configuredHost : _defaultLoopbackHost;
  }

  /// 状態通知に使用するパスを返します。
  ///
  /// Returns: 設定値。空の場合は空文字列（無効）。
  String get _statusPath {
    final configuredPath = _config?.statusPath.trim() ?? _defaultStatusPath;
    return configuredPath;
  }

  /// 統計やイベントの対象外とする proxy 内部のエンドポイントかを返します。
  ///
  /// [request] 判定する要求。
  ///
  /// Returns: 内部エンドポイント宛ての場合は `true`。
  bool _isInternalEndpointRequest(shelf.Request request) {
    // 稼働確認は GET / HEAD だけを内部扱いとし、他のメソッドは従来どおり
    // 通常の転送経路として統計へ計上する
    if (_isHealthCheckRequest(request)) {
      return true;
    }

    final normalizedPath = _normalizedRequestPath(request);

    final statusPath = _statusPath;
    if (statusPath.isNotEmpty && normalizedPath == statusPath) {
      return true;
    }

    // 無効な間は通常の転送経路のため、統計からも外さない
    if (!(_config?.enableAdminApi ?? false)) {
      return false;
    }

    return normalizedPath.startsWith('$_adminPathPrefix/') ||
        normalizedPath == _adminPathPrefix;
  }

  /// proxy 自身の origin からの要求かどうかを返します。
  ///
  /// 同一 origin の `fetch` は `Origin` を送らないことがあるため、ヘッダが
  /// 無い場合は許可します。別 origin のページから内部エンドポイントを
  /// 操作されないよう、値がある場合は proxy 自身の origin とだけ一致させます。
  ///
  /// [request] 判定する要求。
  ///
  /// Returns: 許可する場合は `true`。
  bool _isSameOriginInternalRequest(shelf.Request request) {
    final origin = request.headers['origin'];
    if (origin == null || origin.trim().isEmpty) {
      return true;
    }

    final proxyBaseUri = baseUri;
    if (proxyBaseUri == null) {
      return false;
    }

    final requestOrigin = Uri.tryParse(origin.trim());
    if (requestOrigin == null) {
      return false;
    }

    if (requestOrigin.scheme != proxyBaseUri.scheme ||
        requestOrigin.port != proxyBaseUri.port) {
      return false;
    }

    if (requestOrigin.host == proxyBaseUri.host) {
      return true;
    }

    // 127.0.0.1 と localhost は同じ proxy を指すため、どちらでも許可する
    return _isLoopbackHost(requestOrigin.host) &&
        _isLoopbackHost(proxyBaseUri.host);
  }

  /// 内部エンドポイントの JSON 応答を組み立てます。
  ///
  /// [statusCode] 応答のステータスコード。
  /// [body] JSON へ変換する内容。
  ///
  /// Returns: JSON 応答。
  shelf.Response _buildInternalJsonResponse(
    int statusCode,
    Map<String, dynamic> body,
  ) {
    return shelf.Response(
      statusCode,
      body: jsonEncode(body),
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        // 状態は都度変わるため、WebView 側にも保存させない
        'Cache-Control': 'no-store',
      },
    );
  }

  /// 状態通知エンドポイントの要求を処理します。
  ///
  /// [request] 受信した要求。
  ///
  /// Returns: 現在の状態を表す JSON 応答。
  Future<shelf.Response> _handleStatusRequest(shelf.Request request) async {
    if (!_isSameOriginInternalRequest(request)) {
      return _buildInternalJsonResponse(
        HttpStatus.forbidden,
        {'error': 'origin is not allowed'},
      );
    }

    final stats = await getStats();

    return _buildInternalJsonResponse(HttpStatus.ok, {
      'isOnline': _isOnline,
      'onlineDecisionSource': _onlineDecisionSource.name,
      'isUpstreamReachable': _isUpstreamReachable,
      'upstreamCircuitState': _upstreamCircuitState.name,
      'queueLength': stats.queueLength,
      'quarantinedCount': stats.quarantinedCount,
      'unacknowledgedDroppedCount': stats.unacknowledgedDroppedCount,
      'recentResendResults': _recentResendResults
          .map((result) => result.toMap())
          .toList(growable: false),
    });
  }

  /// 隔離キューの一覧を返します。
  ///
  /// [request] 受信した要求。
  ///
  /// Returns: 隔離されたリクエストの一覧を表す JSON 応答。
  Future<shelf.Response> _handleAdminQuarantineList(
    shelf.Request request,
  ) async {
    if (!_isSameOriginInternalRequest(request)) {
      return _buildInternalJsonResponse(
        HttpStatus.forbidden,
        {'error': 'origin is not allowed'},
      );
    }

    final requests = await getQuarantinedRequests();
    return _buildInternalJsonResponse(HttpStatus.ok, {
      'requests': requests
          .map((request) => {
                'id': request.id,
                'url': request.url,
                'method': request.method,
                'quarantinedAt':
                    request.quarantinedAt.toUtc().toIso8601String(),
                'queuedAt': request.queuedAt.toUtc().toIso8601String(),
                'acceptedAt': request.acceptedAt.toUtc().toIso8601String(),
                'reason': request.reason,
                'statusCode': request.statusCode,
                'errorMessage': request.errorMessage,
                'pendingMigration': request.pendingMigration,
              })
          .toList(growable: false),
    });
  }

  /// 隔離されたリクエストをキューへ戻します。
  ///
  /// [request] 受信した要求。
  ///
  /// Returns: 再送を受け付けたかどうかを表す JSON 応答。
  Future<shelf.Response> _handleAdminQuarantineRetry(
    shelf.Request request,
    String id,
  ) async {
    if (!_isSameOriginInternalRequest(request)) {
      return _buildInternalJsonResponse(
        HttpStatus.forbidden,
        {'error': 'origin is not allowed'},
      );
    }

    final result = await _retryQuarantinedRequestInternal(id);
    return switch (result) {
      _QuarantineOperationResult.done =>
        _buildInternalJsonResponse(HttpStatus.ok, {'retried': true}),
      // 移行を待っている記録は、見つからない（404）ではなく操作できない状態として返す
      _QuarantineOperationResult.pendingMigration => _buildInternalJsonResponse(
          HttpStatus.conflict,
          {
            'retried': false,
            'error': 'quarantined request is waiting for storage migration',
          },
        ),
      _QuarantineOperationResult.notFound => _buildInternalJsonResponse(
          HttpStatus.notFound,
          {'retried': false, 'error': 'quarantined request was not found'},
        ),
    };
  }

  /// 隔離されたリクエストを破棄します。
  ///
  /// [request] 受信した要求。
  ///
  /// Returns: 破棄したかどうかを表す JSON 応答。
  Future<shelf.Response> _handleAdminQuarantineDiscard(
    shelf.Request request,
    String id,
  ) async {
    if (!_isSameOriginInternalRequest(request)) {
      return _buildInternalJsonResponse(
        HttpStatus.forbidden,
        {'error': 'origin is not allowed'},
      );
    }

    final result = await _discardQuarantinedRequestInternal(id);
    return switch (result) {
      _QuarantineOperationResult.done =>
        _buildInternalJsonResponse(HttpStatus.ok, {'discarded': true}),
      // 移行を待っている記録は、見つからない（404）ではなく操作できない状態として返す
      _QuarantineOperationResult.pendingMigration => _buildInternalJsonResponse(
          HttpStatus.conflict,
          {
            'discarded': false,
            'error': 'quarantined request is waiting for storage migration',
          },
        ),
      _QuarantineOperationResult.notFound => _buildInternalJsonResponse(
          HttpStatus.notFound,
          {'discarded': false, 'error': 'quarantined request was not found'},
        ),
    };
  }

  /// 稼働確認要求かどうかを返します。
  ///
  /// 稼働確認として扱うのは `GET` と `HEAD` のみです。
  bool _isHealthCheckRequest(shelf.Request request) {
    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      return false;
    }

    return _normalizedRequestPath(request) == _healthCheckPath;
  }

  /// 要求のパスを `/` で始まる形にそろえて返します。
  ///
  /// [request] 対象の要求。
  ///
  /// Returns: 先頭に `/` を付けた要求のパス。
  String _normalizedRequestPath(shelf.Request request) {
    final requestPath = request.url.path;
    return requestPath.startsWith('/') ? requestPath : '/$requestPath';
  }

  /// 要求ログを出力するミドルウェアを返します。
  ///
  /// 表示中の代替ページは状態通知を一定間隔で読むため、そのまま記録すると
  /// ログが埋まります。GET / HEAD の稼働確認と GET の状態通知だけを出力から
  /// 外し、管理 API や同じパスへの他メソッドの要求は従来どおり記録します。
  ///
  /// Returns: 要求ログを出力するミドルウェア。
  shelf.Middleware _requestLoggingMiddleware() {
    final logRequests = shelf.logRequests();
    return (shelf.Handler innerHandler) {
      final loggedHandler = logRequests(innerHandler);
      return (shelf.Request request) {
        if (_isUnloggedInternalRequest(request)) {
          return innerHandler(request);
        }
        return loggedHandler(request);
      };
    };
  }

  /// 要求ログへ出力しない内部要求かどうかを返します。
  ///
  /// [request] 判定する要求。
  ///
  /// Returns: GET / HEAD の稼働確認、または GET の状態通知の場合は `true`。
  bool _isUnloggedInternalRequest(shelf.Request request) {
    if (_isHealthCheckRequest(request)) {
      return true;
    }

    final statusPath = _statusPath;
    if (statusPath.isEmpty || request.method.toUpperCase() != 'GET') {
      return false;
    }

    return _normalizedRequestPath(request) == statusPath;
  }

  /// 稼働確認要求に応答します。
  ///
  /// [request] は受信した稼働確認要求です。
  ///
  /// Returns: 本文を持たない 204 応答。
  shelf.Response _handleHealthCheck(shelf.Request request) {
    return shelf.Response(
      HttpStatus.noContent,
      headers: {'Cache-Control': 'no-store'},
    );
  }

  /// この proxy が使用した可能性のあるポートかどうかを返します。
  ///
  /// 起動後にバインドしたポート、永続化された直前のバインドポート、
  /// および `preferredPort` を対象とします。
  bool _isKnownProxyPort(int port) {
    if (port <= 0) {
      return false;
    }

    if (port == _boundPort || _knownProxyPorts.contains(port)) {
      return true;
    }

    final preferredPort = _config?.preferredPort ?? 0;
    return preferredPort > 0 && port == preferredPort;
  }

  /// ヘルスチェックパスの設定値を検証します。
  ///
  /// Throws:
  ///   * [ProxyStartException] パスとして使用できない値が指定された場合。
  void _validateHealthCheckPath() {
    final configuredPath = _config?.healthCheckPath.trim() ?? '';
    if (configuredPath.isEmpty) {
      return;
    }

    if (!configuredPath.startsWith('/')) {
      throw ProxyStartException(
        'healthCheckPath must start with "/": $configuredPath',
        null,
      );
    }

    // shelf_router のパスパラメータ記法を含むと業務ルートを広く奪うため拒否する
    if (RegExp(r'[<>?#\s]').hasMatch(configuredPath)) {
      throw ProxyStartException(
        'healthCheckPath must not contain "<", ">", "?", "#" or whitespace: '
        '$configuredPath',
        null,
      );
    }
  }

  /// ミラー対象 origin の設定値を検証します。
  ///
  /// 誤った値のままでも書き換えと中継が静かに行われないだけで動作は続くため、
  /// 設定の誤りに気付けるよう起動時に弾きます。
  ///
  /// Throws:
  ///   * [ProxyStartException] origin として解釈できない値がある場合。
  void _validateMirroredOrigins() {
    for (final origin in _config?.mirroredOrigins ?? const <String>[]) {
      if (_tryNormalizeMirroredOrigin(origin) == null) {
        throw ProxyStartException(
          'mirroredOrigins must be an http(s) origin without a path, '
          'such as "https://cdn.example.com": $origin',
          null,
        );
      }
    }
  }

  /// 設定に含まれるパスパターンを起動時に組み立てます。
  ///
  /// リクエストのたびに正規表現を生成しないよう、`start()` で一度だけ
  /// 変換して保持します。
  void _compileConfiguredPatterns() {
    _forceCachePatterns =
        PathPattern.compileAll(_config?.forceCachePaths ?? const []);
    _queueExcludeRules = (_config?.queueExcludePaths ?? const [])
        .map((rule) => (pattern: PathPattern(rule.path), rule: rule))
        .toList(growable: false);
    _mirroredOrigins = (_config?.mirroredOrigins ?? const <String>[])
        .map(_tryNormalizeMirroredOrigin)
        .whereType<Uri>()
        .toList(growable: false);
  }

  /// 直近のキュー再送結果を取得します。
  ///
  /// 再送は画面の裏側で行われるため、結果が要求元へ返りません。上流が実際に
  /// 記録した内容と突き合わせたい場合に参照してください。本文は含みません。
  ///
  /// 監視用にメモリ上へ保持するだけで、永続化しません。件数は最大 20 件で、
  /// アプリのプロセスが終了すると失われます。
  ///
  /// Returns: 新しいものが末尾になる再送結果の一覧。
  List<QueueResendResult> get recentResendResults =>
      List.unmodifiable(_recentResendResults);

  /// 更新系リクエストをキューへ入れない規則を探します。
  ///
  /// [method] リクエストのHTTPメソッド。
  /// [path] リクエストのパス。
  ///
  /// Returns: 一致した規則。該当が無い場合は `null`。
  QueueExcludeRule? _findQueueExcludeRule(String method, String path) {
    if (_queueExcludeRules.isEmpty) {
      return null;
    }

    // 照合対象はパスのみのため、クエリとフラグメントを落とす
    final pathOnly = path.split('?').first.split('#').first;
    final normalizedMethod = method.toUpperCase();

    for (final entry in _queueExcludeRules) {
      final methods = entry.rule.methods;
      // 空指定は「キュー対象の更新系すべて」を意味する
      if (methods.isNotEmpty &&
          !methods.any((value) => value.toUpperCase() == normalizedMethod)) {
        continue;
      }
      if (entry.pattern.matches(pathOnly)) {
        return entry.rule;
      }
    }

    return null;
  }

  /// キューへ入れずに返す応答を組み立てます。
  ///
  /// 成功と誤認されないよう、キュー投入と区別できるヘッダを付けます。
  ///
  /// [rule] 一致した規則。
  ///
  /// Returns: 規則に従った応答。
  shelf.Response _buildQueueExcludedResponse(QueueExcludeRule rule) {
    return _buildConfiguredResponse(
      rule.response,
      extraHeaders: {
        'X-Offline-Queued': '0',
        'X-Offline-Excluded': '1',
        'Connection': 'close',
      },
    );
  }

  /// 受付時刻ヘッダへ載せる値を決めます。
  ///
  /// オフラインで行った操作の発生時刻を上流へ伝えるため、最初の転送と
  /// 以降の再送で同じ値を送ります。タイムゾーンの解釈が割れないよう UTC で
  /// 表現します。
  ///
  /// キューへも保存するため、ヘッダ付与が無効でも値自体は決めます。
  ///
  /// Returns: UTC の ISO 8601 文字列。
  String _resolveAcceptedAt() {
    return DateTime.now().toUtc().toIso8601String();
  }

  /// キューデータから受付時刻を取り出します。
  ///
  /// 受付時刻を持たない旧バージョンのデータは、キューへ保存した時刻で補います。
  ///
  /// [data] キューデータ。
  ///
  /// Returns: UTC の ISO 8601 文字列。決められない場合は `null`。
  String? _resolveQueuedAcceptedAt(Map data) {
    final acceptedAt = data['acceptedAt'] as String?;
    if (acceptedAt != null && acceptedAt.isNotEmpty) {
      return acceptedAt;
    }

    final queuedAt = DateTime.tryParse(data['queuedAt'] as String? ?? '');
    return queuedAt?.toUtc().toIso8601String();
  }

  /// 受付時刻ヘッダを上流リクエストへ付与します。
  ///
  /// 値は proxy 自身の観測結果のため、クライアントが同名のヘッダを送っていた
  /// 場合も proxy の値で上書きします。
  ///
  /// [ioRequest] 送信する上流リクエスト。
  /// [acceptedAt] 受付時刻。`null` の場合は付与しません。
  void _applyAcceptedAtHeader(HttpClientRequest ioRequest, String? acceptedAt) {
    if (acceptedAt == null || !(_config?.enableAcceptedAtHeader ?? true)) {
      return;
    }

    ioRequest.headers.set(
      _config?.acceptedAtHeaderName ?? _defaultAcceptedAtHeaderName,
      acceptedAt,
    );
  }

  /// キュー再送の結果を記録し、イベントとして通知します。
  ///
  /// [data] 再送したキューデータ。
  /// [statusCode] 上流から返されたステータスコード。到達できない場合は `0`。
  /// [success] 上流が受け付けたかどうか。
  /// [dropReason] キューから取り除いた理由。
  /// [willRetry] キューへ残して再試行するかどうか。
  void _recordResendResult(
    Map data, {
    required int statusCode,
    required bool success,
    String? dropReason,
    required bool willRetry,
  }) {
    final result = QueueResendResult(
      url: data['url'] as String? ?? '',
      method: data['method'] as String? ?? '',
      statusCode: statusCode,
      success: success,
      idempotencyKey: data['idempotencyKey'] as String?,
      dropReason: dropReason,
      willRetry: willRetry,
      // JSON へ出したときにタイムゾーンの解釈が割れないよう UTC で表す
      attemptedAt: DateTime.now().toUtc(),
    );

    _recentResendResults.addLast(result);
    while (_recentResendResults.length > _recentResendResultCapacity) {
      _recentResendResults.removeFirst();
    }

    _emitEvent(
      ProxyEventType.queueResendAttempted,
      result.url,
      result.toMap(),
    );
  }

  /// 状態通知パスの設定値を検証します。
  ///
  /// Throws:
  ///   * [ProxyStartException] パスとして使用できない値が指定された場合。
  void _validateStatusPath() {
    final configuredPath = _config?.statusPath.trim() ?? '';
    if (configuredPath.isEmpty) {
      return;
    }

    if (!configuredPath.startsWith('/')) {
      throw ProxyStartException(
        'statusPath must start with "/": $configuredPath',
        null,
      );
    }

    // shelf_router のパスパラメータ記法を含むと業務ルートを広く奪うため拒否する
    if (RegExp(r'[<>?#\s]').hasMatch(configuredPath)) {
      throw ProxyStartException(
        'statusPath must not contain "<", ">", "?", "#" or whitespace: '
        '$configuredPath',
        null,
      );
    }

    if (configuredPath == _healthCheckPath) {
      throw ProxyStartException(
        'statusPath must differ from healthCheckPath: $configuredPath',
        null,
      );
    }
  }

  /// 代替ページの自動復帰に関する設定値を検証します。
  ///
  /// Throws:
  ///   * [ProxyStartException] 監視間隔が 100 ミリ秒未満または 24 時間を超える
  ///     場合、または再送の完了を待つ上限時間が負の場合。
  void _validateAutoReloadSettings() {
    final config = _config;
    if (config == null) {
      return;
    }

    final pollInterval = config.autoReloadPollInterval;
    if (pollInterval < offlineRecoveryMinimumPollInterval ||
        pollInterval > offlineRecoveryMaximumPollInterval) {
      throw ProxyStartException(
        'autoReloadPollInterval must be between '
        '${offlineRecoveryMinimumPollInterval.inMilliseconds} milliseconds '
        'and ${offlineRecoveryMaximumPollInterval.inHours} hours: '
        '$pollInterval',
        null,
      );
    }

    if (config.autoReloadQueueWaitTimeout.isNegative) {
      throw ProxyStartException(
        'autoReloadQueueWaitTimeout must not be negative: '
        '${config.autoReloadQueueWaitTimeout}',
        null,
      );
    }
  }

  /// 隔離とドロップ履歴の保持上限の設定を検証します。
  ///
  /// 0 は上限なしとして受け付け、負の値は拒否します。
  ///
  /// Throws:
  ///   * [ProxyStartException] 負の値が指定されている場合。
  void _validateRetentionSettings() {
    final config = _config;
    if (config == null) {
      return;
    }

    final limits = <String, int>{
      'quarantineMaxCount': config.quarantineMaxCount,
      'quarantineMaxBytes': config.quarantineMaxBytes,
      'droppedRequestMaxCount': config.droppedRequestMaxCount,
    };
    for (final entry in limits.entries) {
      if (entry.value < 0) {
        throw ProxyStartException(
          '${entry.key} must not be negative: ${entry.value}',
          null,
        );
      }
    }

    final retentions = <String, Duration>{
      'quarantineRetention': config.quarantineRetention,
      'droppedRequestRetention': config.droppedRequestRetention,
    };
    for (final entry in retentions.entries) {
      if (entry.value.isNegative) {
        throw ProxyStartException(
          '${entry.key} must not be negative: ${entry.value}',
          null,
        );
      }
    }
  }

  /// 復旧対象として扱える URL かどうかを返します。
  bool _isRecoverableProxyUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'http' || uri.host.isEmpty) {
      return false;
    }

    if (uri.host.toLowerCase() == _effectiveHost.toLowerCase()) {
      return true;
    }

    return _isLoopbackHost(uri.host) && _isLoopbackHost(_effectiveHost);
  }

  /// 復旧処理を開始します。実行中の場合は進行中の結果を共有します。
  Future<ProxyRecoveryResult> _beginRecovery({
    required Duration probeTimeout,
    required bool force,
    Duration? downtime,
    int? webResourceErrorCode,
    bool? isMainFrame,
  }) async {
    final pendingOperation = _recoveryOperation;
    if (pendingOperation != null) {
      return pendingOperation;
    }

    final operation = _runRecovery(
      probeTimeout: probeTimeout,
      force: force,
      downtime: downtime,
      webResourceErrorCode: webResourceErrorCode,
      isMainFrame: isMainFrame,
    );
    _recoveryOperation = operation;

    try {
      return await operation;
    } finally {
      _recoveryOperation = null;
    }
  }

  /// 稼働確認と再バインドの本体処理です。
  Future<ProxyRecoveryResult> _runRecovery({
    required Duration probeTimeout,
    required bool force,
    Duration? downtime,
    int? webResourceErrorCode,
    bool? isMainFrame,
  }) async {
    // 停止推定時間は呼び出し単位の値として扱い、他の復旧結果へ引き継がない
    final downtimeMs = downtime?.inMilliseconds;
    if (downtimeMs != null) {
      _lastDowntimeMs = downtimeMs;
    }

    if (!_isRunning || _config == null || _handler == null) {
      _lastRecoveryCause = ProxyRecoveryCause.notStarted;
      return ProxyRecoveryResult(
        cause: ProxyRecoveryCause.notStarted,
        port: _boundPort,
        downtimeMs: downtimeMs,
      );
    }

    if (!force && await probe(timeout: probeTimeout)) {
      _lastRecoveryCause = ProxyRecoveryCause.healthy;
      return ProxyRecoveryResult(
        cause: ProxyRecoveryCause.healthy,
        port: _boundPort,
        downtimeMs: downtimeMs,
      );
    }

    final previousPort = _boundPort;

    if (!_canAttemptRestart()) {
      const limitMessage = 'Restart attempts exceeded the configured limit';
      _lastRecoveryCause = ProxyRecoveryCause.recoveryFailed;
      _lastRecoveryError = limitMessage;

      final limitResult = ProxyRecoveryResult(
        cause: ProxyRecoveryCause.recoveryFailed,
        port: previousPort,
        downtimeMs: downtimeMs,
        error: StateError(limitMessage),
      );
      _emitRecoveryEvent(
        ProxyEventType.serverUnavailable,
        limitResult,
        previousPort,
        webResourceErrorCode: webResourceErrorCode,
        isMainFrame: isMainFrame,
      );
      return limitResult;
    }

    await _awaitRecoveryBackoff();
    _restartAttempts.add(DateTime.now());

    try {
      final newPort = await _rebindServer(priorPort: previousPort);
      _restartCount++;
      _consecutiveRecoveryFailures = 0;
      _lastRecoveryCause = ProxyRecoveryCause.socketDead;
      _lastRecoveryError = null;

      final recoveredResult = ProxyRecoveryResult(
        cause: ProxyRecoveryCause.socketDead,
        restarted: true,
        port: newPort,
        portChanged: previousPort != null && previousPort != newPort,
        downtimeMs: downtimeMs,
      );
      _emitRecoveryEvent(
        ProxyEventType.serverRecovered,
        recoveredResult,
        previousPort,
        webResourceErrorCode: webResourceErrorCode,
        isMainFrame: isMainFrame,
      );
      return recoveredResult;
    } catch (e) {
      _consecutiveRecoveryFailures++;
      _lastRecoveryCause = ProxyRecoveryCause.recoveryFailed;
      _lastRecoveryError = e.toString();

      final failedResult = ProxyRecoveryResult(
        cause: ProxyRecoveryCause.recoveryFailed,
        port: _boundPort,
        downtimeMs: downtimeMs,
        error: e,
      );
      _emitRecoveryEvent(
        ProxyEventType.serverUnavailable,
        failedResult,
        previousPort,
        webResourceErrorCode: webResourceErrorCode,
        isMainFrame: isMainFrame,
      );
      return failedResult;
    }
  }

  /// サーバのソケットのみを作り直します。
  ///
  /// キャッシュ、キュー、Cookie の永続化領域は閉じずに維持します。
  Future<int> _rebindServer({int? priorPort}) async {
    // 停止処理と同時に実行されないよう排他制御する
    await _lifecycleLock.acquire();
    try {
      final handler = _handler;
      if (handler == null || !_isRunning) {
        // ロック取得を待つ間に stop() が完了した場合は復旧を中止する
        throw ProxyStopException('Proxy was stopped during recovery', null);
      }

      final previousServer = _server;
      _server = null;
      if (previousServer != null) {
        try {
          await previousServer.close(force: true);
        } catch (_) {
          // OS 側で既に閉じられている場合は無視する
        }
      }

      final server = await _bindServer(handler, priorPort: priorPort);
      server.idleTimeout = _config!.serverIdleTimeout;
      _server = server;
      _boundPort = server.port;
      _knownProxyPorts.add(server.port);
      _isRunning = true;
      _startBackgroundTasks();

      return server.port;
    } finally {
      _lifecycleLock.release();
    }
  }

  /// 1 分あたりの再バインド上限に達していないかを返します。
  bool _canAttemptRestart() {
    final limit = _config?.maxRestartAttemptsPerMinute ?? 5;
    if (limit <= 0) {
      return false;
    }

    final threshold = DateTime.now().subtract(const Duration(minutes: 1));
    _restartAttempts.removeWhere((DateTime attemptedAt) {
      return attemptedAt.isBefore(threshold);
    });

    return _restartAttempts.length < limit;
  }

  /// 連続失敗回数に応じた待機を行います。
  Future<void> _awaitRecoveryBackoff() async {
    if (_consecutiveRecoveryFailures <= 0) {
      return;
    }

    final index = _consecutiveRecoveryFailures < _recoveryBackoffSeconds.length
        ? _consecutiveRecoveryFailures
        : _recoveryBackoffSeconds.length - 1;
    final waitSeconds = _recoveryBackoffSeconds[index];
    if (waitSeconds <= 0) {
      return;
    }

    await Future<void>.delayed(Duration(seconds: waitSeconds));
  }

  /// 稼働確認の実施結果を記録します。
  void _recordProbeResult(bool succeeded) {
    _lastProbeAt = DateTime.now();
    _lastProbeSucceeded = succeeded;
  }

  /// 復旧の実行制御に関する状態のみを初期化します。
  ///
  /// 停止時に呼び出し、診断値は次回起動まで保持します。
  void _resetRecoveryControlState() {
    _restartAttempts.clear();
    _consecutiveRecoveryFailures = 0;
    _knownProxyPorts.clear();
  }

  /// 復旧関連の状態と診断値をすべて初期化します。
  void _resetRecoveryState() {
    _resetRecoveryControlState();
    _restartCount = 0;
    _lastProbeAt = null;
    _lastProbeSucceeded = null;
    _lastRecoveryCause = null;
    _lastRecoveryError = null;
    _lastDowntimeMs = null;
  }

  /// 復旧結果をイベントとして発行します。
  void _emitRecoveryEvent(
    ProxyEventType type,
    ProxyRecoveryResult result,
    int? previousPort, {
    int? webResourceErrorCode,
    bool? isMainFrame,
  }) {
    _emitEvent(type, '', {
      'cause': result.cause.name,
      'previousPort': previousPort,
      'newPort': result.restarted ? result.port : null,
      'portChanged': result.portChanged,
      'downtimeMs': result.downtimeMs,
      'restartCount': _restartCount,
      'probeError': result.error?.toString(),
      if (webResourceErrorCode != null)
        'webResourceErrorCode': webResourceErrorCode,
      if (isMainFrame != null) 'isMainFrame': isMainFrame,
    });
  }

  /// 定期ヘルスチェックのタイマーを設定します。
  void _startHealthCheckTimer() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;

    final interval = _config?.healthCheckInterval ?? Duration.zero;
    if (interval <= Duration.zero) {
      return;
    }

    _healthCheckTimer = Timer.periodic(interval, (Timer timer) {
      // ignore: discarded_futures
      _runPeriodicHealthCheck();
    });
  }

  /// 定期ヘルスチェックを実行し、応答が無い場合は復旧を試みます。
  Future<void> _runPeriodicHealthCheck() async {
    if (!_isRunning || _recoveryOperation != null) {
      return;
    }

    await ensureRunning(probeTimeout: _periodicProbeTimeout);
  }

  /// 定期ヘルスチェックで使用する稼働確認タイムアウトを返します。
  ///
  /// 確認間隔に連動させ、500 ミリ秒以上 2 秒以下にクランプします。
  Duration get _periodicProbeTimeout {
    const minimumTimeout = Duration(milliseconds: 500);
    const maximumTimeout = Duration(seconds: 2);
    final interval = _config?.healthCheckInterval ?? Duration.zero;

    if (interval <= minimumTimeout) {
      return minimumTimeout;
    }
    if (interval >= maximumTimeout) {
      return maximumTimeout;
    }
    return interval;
  }

  /// 全キャッシュを即座に削除します。
  ///
  /// Throws:
  ///   * [CacheOperationException] キャッシュ削除に失敗した場合。
  Future<void> clearCache() async {
    try {
      await _cacheBox?.clear();
      _emitEvent(ProxyEventType.cacheCleared, '', {});
    } catch (e) {
      throw CacheOperationException(
          'clear', 'キャッシュのクリアに失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// 期限切れキャッシュのみを削除します。
  ///
  /// Expired状態のキャッシュエントリのみが削除対象となります。
  ///
  /// Throws:
  ///   * [CacheOperationException] キャッシュ削除に失敗した場合。
  Future<void> clearExpiredCache() async {
    try {
      final keysToDelete = <String>[];

      if (_cacheBox != null) {
        final keys = _cacheBox!.keys.toList(growable: false);
        for (var i = 0; i < keys.length; i++) {
          final key = keys[i];
          final entry = _cacheBox!.get(key) as Map?;
          if (entry != null) {
            if (_determineStatus(entry) == CacheStatus.expired) {
              keysToDelete.add(key as String);
            }
          }

          if (i % 200 == 0) {
            await Future.delayed(Duration.zero);
          }
        }

        for (var i = 0; i < keysToDelete.length; i++) {
          final key = keysToDelete[i];
          await _cacheBox!.delete(key);

          if (i % 200 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      }
    } catch (e) {
      throw CacheOperationException(
          'clearExpired', '期限切れキャッシュの削除に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// 特定URLのキャッシュを削除します。
  ///
  /// [url] 削除対象のURL。正規化されてからハッシュ化されます。
  ///
  /// Throws:
  ///   * [ArgumentError] 無効なURLが指定された場合。
  ///   * [CacheOperationException] キャッシュ削除に失敗した場合。
  Future<void> clearCacheForUrl(String url) async {
    if (url.isEmpty || url.trim().isEmpty) {
      throw ArgumentError('URLは空または空白のみにはできません');
    }

    try {
      final normalizedUrl = _normalizeUrl(url);
      final cacheKey = _generateCacheKey(normalizedUrl);
      await _cacheBox?.delete(cacheKey);
    } catch (e) {
      throw CacheOperationException(
          'clearForUrl', 'URLのキャッシュ削除に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// キャッシュエントリの一覧を取得します。
  ///
  /// [limit] 取得する最大エントリ数。
  /// [offset] スキップするエントリ数。
  ///
  /// Returns: キャッシュエントリの一覧。
  ///
  /// Throws:
  ///   * [CacheOperationException] キャッシュ一覧の取得に失敗した場合。
  Future<List<CacheEntry>> getCacheList({int? limit, int? offset}) async {
    try {
      final entries = <CacheEntry>[];
      final keys = _cacheBox?.keys.toList() ?? [];

      final startIndex = offset ?? 0;
      final endIndex = limit != null
          ? (startIndex + limit).clamp(0, keys.length)
          : keys.length;

      for (int i = startIndex; i < endIndex; i++) {
        final key = keys[i];
        final data = _cacheBox!.get(key) as Map?;
        if (data != null) {
          entries.add(_mapToCacheEntry(data));
        }
      }

      return entries;
    } catch (e) {
      throw CacheOperationException(
          'getCacheList', 'キャッシュリストの取得に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// キャッシュの統計情報を取得します。
  ///
  /// Returns: キャッシュのサイズやヒット率などの統計情報。
  ///
  /// Throws:
  ///   * [CacheOperationException] 統計情報の取得に失敗した場合。
  Future<CacheStats> getCacheStats() async {
    try {
      int totalEntries = 0;
      int freshEntries = 0;
      int staleEntries = 0;
      int expiredEntries = 0;
      int totalSize = 0;

      if (_cacheBox != null) {
        for (final key in _cacheBox!.keys) {
          final entry = _cacheBox!.get(key) as Map?;
          if (entry != null) {
            totalEntries++;
            totalSize += (entry['sizeBytes'] as int? ?? 0);

            switch (_determineStatus(entry)) {
              case CacheStatus.fresh:
                freshEntries++;
              case CacheStatus.stale:
                staleEntries++;
              case CacheStatus.expired:
                expiredEntries++;
            }
          }
        }
      }

      final hitRate = _totalRequests > 0 ? _cacheHits / _totalRequests : 0.0;
      final staleUsageRate = _cacheHits > 0 ? staleEntries / _cacheHits : 0.0;

      return CacheStats(
        totalEntries: totalEntries,
        freshEntries: freshEntries,
        staleEntries: staleEntries,
        expiredEntries: expiredEntries,
        totalSize: totalSize,
        hitRate: hitRate,
        staleUsageRate: staleUsageRate,
      );
    } catch (e) {
      throw CacheOperationException(
          'getStats', 'キャッシュ統計情報の取得に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// 指定したパス一覧でキャッシュの事前ウォームアップを実行します。
  ///
  /// [paths] ウォームアップ対象の相対パス一覧。
  /// [timeout] 各リクエストの締め切り秒数。省略時は
  ///   [ProxyConfig.requestTimeout] を使用します。
  /// [maxConcurrency] 同時実行する最大リクエスト数。
  /// [followReferences] 取得した HTML が参照する同一 origin の資源も続けて
  ///   取得する場合は `true`。`<script src>`、`<link href>`、`<img src>` を
  ///   対象とし、1 段だけ辿ります。既定は `false` で従来の挙動です。
  /// [onProgress] 進捗状態を通知するコールバック関数。
  /// [onError] エラー発生時に呼ばれるコールバック関数。
  ///
  /// Returns: ウォームアップ結果の一覧。
  ///
  /// Throws:
  ///   * [WarmupException] ウォームアップ処理でエラーが発生した場合。
  Future<WarmupResult> warmupCache({
    List<String>? paths,
    int? timeout,
    int? maxConcurrency,
    bool followReferences = false,
    WarmupProgressCallback? onProgress,
    WarmupErrorCallback? onError,
  }) async {
    final targetPaths = paths ?? _config?.startupPaths ?? [];
    if (targetPaths.isEmpty) {
      return WarmupResult(
        successCount: 0,
        failureCount: 0,
        totalDuration: Duration.zero,
        entries: [],
      );
    }

    final startTime = DateTime.now();
    final entries = <WarmupEntry>[];

    try {
      final semaphore = Semaphore(maxConcurrency ?? 10);
      // 同じ資源を二度取得しないよう、要求済みのパスを覚えておく
      final requestedPaths = <String>{};
      var completed = 0;
      var total = targetPaths.length;

      /// 1 パス分を取得し、進捗を通知します。
      Future<({WarmupEntry entry, List<String> references})> run(
        String path,
        String? referencedFrom,
      ) async {
        await semaphore.acquire(timeout: const Duration(seconds: 30));
        try {
          return await _warmupSinglePath(
            path: path,
            timeout: timeout,
            followReferences: followReferences,
            referencedFrom: referencedFrom,
            onError: onError,
          );
        } finally {
          semaphore.release();
          completed++;
          // 成功・失敗問わず進捗コールバックを呼ぶ
          onProgress?.call(completed, total);
        }
      }

      for (final path in targetPaths) {
        requestedPaths.add(_normalizeWarmupPath(path));
      }

      final results = await Future.wait(
        targetPaths.map((path) => run(path, null)),
      );
      entries.addAll(results.map((result) => result.entry));

      if (followReferences) {
        // 参照元ごとに、まだ取得していないパスだけを集める
        final referenceTargets = <({String path, String referencedFrom})>[];
        for (var index = 0; index < results.length; index++) {
          for (final reference in results[index].references) {
            if (requestedPaths.add(_normalizeWarmupPath(reference))) {
              referenceTargets.add((
                path: reference,
                referencedFrom: targetPaths[index],
              ));
            }
          }
        }

        if (referenceTargets.isNotEmpty) {
          total += referenceTargets.length;
          final referenceResults = await Future.wait(
            referenceTargets
                .map((target) => run(target.path, target.referencedFrom)),
          );
          entries.addAll(referenceResults.map((result) => result.entry));
        }
      }

      final successCount = entries.where((entry) => entry.success).length;

      return WarmupResult(
        successCount: successCount,
        failureCount: entries.length - successCount,
        totalDuration: DateTime.now().difference(startTime),
        entries: entries,
      );
    } catch (e) {
      throw WarmupException(
          'ウォームアップに失敗しました: $e', entries, e is Exception ? e : null);
    }
  }

  /// ウォームアップ 1 件分を実行します。
  ///
  /// [path] 取得するパス。
  /// [timeout] 締め切り秒数。
  /// [followReferences] 参照資源を抽出する場合は `true`。
  /// [referencedFrom] 参照元のパス。直接指定した場合は `null`。
  /// [onError] エラー発生時に呼ばれるコールバック関数。
  ///
  /// Returns: 結果と、続けて取得すべき同一 origin の参照パス一覧。
  Future<({WarmupEntry entry, List<String> references})> _warmupSinglePath({
    required String path,
    required int? timeout,
    required bool followReferences,
    required String? referencedFrom,
    WarmupErrorCallback? onError,
  }) async {
    final entryStartTime = DateTime.now();

    // 上流断を検知済みの間は待たせず、復帰確認に判定を委ねる
    if (_isRunning && !_isUpstreamReachable) {
      onError?.call(path, _upstreamUnreachableWarmupMessage);
      return (
        entry: WarmupEntry(
          path: path,
          success: false,
          statusCode: null,
          errorMessage: _upstreamUnreachableWarmupMessage,
          duration: DateTime.now().difference(entryStartTime),
          referencedFrom: referencedFrom,
        ),
        references: const <String>[],
      );
    }

    try {
      final response = await _fetchFromUpstream(path, timeout: timeout);

      // 上流が応答した以上は到達可能とみなし、遮断中なら解除する
      if (_isRunning) {
        _recordUpstreamSuccess();
      }

      var references = const <String>[];
      if (response.statusCode == HttpStatus.ok) {
        final upstreamUri = _buildUpstreamUriFromParts(path: path);
        final cacheKey = _generateCacheKey(upstreamUri.toString());
        await _cacheResponseBytes(
          cacheKey,
          response.statusCode,
          response.headers,
          response.bodyBytes,
          // ウォームアップも同じ判定で保存し、転送経路と挙動を揃える
          allowNoStore: _resolveForceCacheAllowance(
            path: path,
            requestHeaders: const {},
            responseHeaders: response.headers,
            eventUrl: upstreamUri.toString(),
          ),
        );

        if (followReferences) {
          references = _extractWarmupReferences(
            response: response,
            baseUri: upstreamUri,
          );
        }
      }

      return (
        entry: WarmupEntry(
          path: path,
          success: true,
          statusCode: response.statusCode,
          errorMessage: null,
          duration: DateTime.now().difference(entryStartTime),
          referencedFrom: referencedFrom,
        ),
        references: references,
      );
    } catch (e) {
      // 画面操作が無い状況でも上流断を検知できるよう、判定材料に含める。
      // 停止中は復帰確認を予約できないため数えない。
      if (_isRunning && _shouldCountUpstreamFailure(e)) {
        _recordUpstreamFailure();
      }

      onError?.call(path, e.toString());
      return (
        entry: WarmupEntry(
          path: path,
          success: false,
          statusCode: null,
          errorMessage: e.toString(),
          duration: DateTime.now().difference(entryStartTime),
          referencedFrom: referencedFrom,
        ),
        references: const <String>[],
      );
    }
  }

  /// ウォームアップ対象のパスを重複判定用に正規化します。
  ///
  /// [path] 正規化するパス。
  ///
  /// Returns: 先頭に `/` を持つパス。
  String _normalizeWarmupPath(String path) {
    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) {
      return '/';
    }
    return trimmedPath.startsWith('/') ? trimmedPath : '/$trimmedPath';
  }

  /// ウォームアップした HTML から取得対象の参照資源を抽出します。
  ///
  /// `<script src>`、`<link href>`、`<img src>` を対象とします。実行時に
  /// JavaScript が組み立てる URL には届かないため、最善努力の抽出です。
  /// ミラー対象 origin の資源は中継用のパスとして返します。
  ///
  /// [response] 取得した応答。
  /// [baseUri] 相対 URL の解決に使う上流 URI。
  ///
  /// Returns: 取得すべきパスの一覧。HTML でない場合は空。
  List<String> _extractWarmupReferences({
    required http.Response response,
    required Uri baseUri,
  }) {
    final contentType =
        (_getHeaderValueIgnoreCase(response.headers, 'content-type') ?? '')
            .toLowerCase();
    if (!contentType.contains('text/html')) {
      return const <String>[];
    }

    final String html;
    try {
      html = utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (_) {
      return const <String>[];
    }

    final references = <String>{};
    for (final tagMatch in _referenceTagPattern.allMatches(html)) {
      final tagName = (tagMatch.group(1) ?? '').toLowerCase();
      final attributes = tagMatch.group(2) ?? '';

      // canonical や alternate は資源ではなく別ページを指すため取得しない
      if (tagName == 'link' && !_isResourceLinkTag(attributes)) {
        continue;
      }

      for (final urlMatch in _referenceUrlPattern.allMatches(attributes)) {
        final rawUrl =
            urlMatch.group(1) ?? urlMatch.group(2) ?? urlMatch.group(3);
        if (rawUrl == null || rawUrl.trim().isEmpty) {
          continue;
        }

        final resolved = _resolveWarmupReference(rawUrl.trim(), baseUri);
        if (resolved != null) {
          references.add(resolved);
        }
      }
    }

    return references.toList(growable: false);
  }

  /// `<link>` が資源を指しているかどうかを返します。
  ///
  /// `canonical` や `alternate` は別ページを指すため、ウォームアップの
  /// 対象から外します。`rel` が無い場合も対象にしません。
  ///
  /// [attributes] タグの属性部分。
  ///
  /// Returns: 資源を指す `rel` の場合は `true`。
  bool _isResourceLinkTag(String attributes) {
    final relMatch = _linkRelPattern.firstMatch(attributes);
    final rel = (relMatch?.group(1) ?? relMatch?.group(2) ?? relMatch?.group(3))
        ?.toLowerCase();
    if (rel == null || rel.trim().isEmpty) {
      return false;
    }

    return rel
        .split(RegExp(r'\s+'))
        .any((value) => _resourceLinkRelations.contains(value));
  }

  /// 参照 URL をウォームアップ用のパスへ変換します。
  ///
  /// 設定済み origin とミラー対象 origin の資源を対象とし、それ以外の別
  /// origin や `data:` などの取得対象にならない URL は除外します。
  ///
  /// [rawUrl] HTML に書かれていた URL。
  /// [baseUri] 相対 URL の解決に使う上流 URI。
  ///
  /// Returns: 取得に使うクエリを含むパス。対象外の場合は `null`。
  String? _resolveWarmupReference(String rawUrl, Uri baseUri) {
    if (_isNonFetchableReferenceUrl(rawUrl)) {
      return null;
    }

    final Uri resolved;
    try {
      resolved = baseUri.resolve(rawUrl);
    } catch (_) {
      return null;
    }

    // ミラー対象は中継用のパスで取得する。書き換えた資源と同じ判定を使い、
    // 画面が読み込む URL とウォームアップの対象を一致させる。
    if (!_isSameOriginAsConfiguredOrigin(resolved)) {
      return _buildMirroredProxyPath(resolved);
    }

    if (resolved.scheme != baseUri.scheme ||
        resolved.host != baseUri.host ||
        resolved.port != baseUri.port) {
      return null;
    }

    // upstream の path 接頭辞を含めたままだと二重に付与されるため取り除く
    final originPath = _configuredOriginUri?.path ?? '';
    final strippedPath =
        _stripConfiguredOriginPathPrefix(resolved.path, originPath);
    if (strippedPath == null) {
      return null;
    }

    return resolved.query.isEmpty
        ? strippedPath
        : '$strippedPath?${resolved.query}';
  }

  /// 保存されているCookieの一覧を取得します。
  ///
  /// [domain] 特定ドメインのCookieのみを取得したい場合に指定。
  ///
  /// Returns: Cookie情報の一覧。
  ///
  /// Throws:
  ///   * [CookieOperationException] Cookieの取得に失敗した場合。暗号化した
  ///     保存領域を使えない場合は、[StorageIntegrityException] を cause に持ちます。
  Future<List<CookieInfo>> getCookies({String? domain}) async {
    try {
      await _ensureCookieStorageInitialized();
      final cookies = <CookieInfo>[];

      if (_cookieBox != null) {
        int idx = 0;
        for (final key in _cookieBox!.keys) {
          final data = _cookieBox!.get(key) as Map?;
          if (data != null) {
            final cookieInfo = _mapToCookieInfo(data);
            if (domain == null || cookieInfo.domain == domain) {
              cookies.add(cookieInfo);
            }
          }

          // 大量のCookieを処理する場合にUIをブロックしないよう一時的にyield
          idx++;
          if (idx % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      }

      return cookies;
    } catch (e) {
      throw CookieOperationException(
          'get', 'Cookieの取得に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// 指定 URL に送信すべき Cookie ヘッダ値を取得します。
  ///
  /// [url] は送信対象の絶対 URL です。
  ///
  /// Returns: `Cookie` ヘッダ値。送信対象 Cookie が無い場合は `null`。
  ///
  /// Throws:
  ///   * [ArgumentError] URL が空または絶対 URL ではない場合。
  ///   * [CookieOperationException] Cookie ヘッダ生成に失敗した場合。暗号化した
  ///     保存領域を使えない場合は、[StorageIntegrityException] を cause に持ちます。
  Future<String?> getCookieHeaderForUrl(String url) async {
    if (url.trim().isEmpty) {
      throw ArgumentError('URL must not be empty');
    }

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError('URL must be an absolute URL: $url');
    }
    if (!_isSameOriginAsConfiguredOrigin(uri)) {
      throw ArgumentError(
        'URL must match configured origin: $url',
      );
    }

    try {
      return await _buildCookieHeaderForUri(uri);
    } catch (e) {
      throw CookieOperationException(
        'getHeader',
        'Cookie ヘッダの生成に失敗しました: $e',
        e is Exception ? e : null,
      );
    }
  }

  /// 指定 URL を upstream URL として解決します。
  ///
  /// [url] は解決対象の絶対 URL です。
  /// proxy URL または設定済み origin と同一 origin の URL を受け付けます。
  ///
  /// Returns: 解決できた upstream URL。解決不能な場合は `null`。
  Uri? tryResolveUpstreamUrl(String url) {
    final resolution = resolveNavigationTarget(targetUrl: url);
    return switch (resolution.disposition) {
      ProxyNavigationDisposition.inWebView => resolution.upstreamUri,
      _ => null,
    };
  }

  /// WebView 遷移前に target URL を解決します。
  ///
  /// [targetUrl] は遷移先候補の URL です。
  /// [sourceUrl] は相対 URL を解決するための基準 URL です。
  ///
  /// Returns: upstream URL、proxy URL、判定理由を含む解決結果。
  ProxyNavigationResolution resolveNavigationTarget({
    required String targetUrl,
    String? sourceUrl,
  }) {
    return _resolveNavigationTargetInternal(
      targetUrl: targetUrl,
      sourceUrl: sourceUrl,
    );
  }

  /// WebView の main frame 遷移向けに推奨アクションを返します。
  ///
  /// [targetUrl] は遷移先候補の URL です。
  /// [sourceUrl] は相対 URL を解決するための基準 URL です。
  ///
  /// Returns: delegate で利用できる推奨アクションと補助 URI を含む結果。
  ProxyWebViewNavigationRecommendation recommendMainFrameNavigation({
    required String targetUrl,
    String? sourceUrl,
  }) {
    return _recommendWebViewNavigation(
      targetUrl: targetUrl,
      sourceUrl: sourceUrl,
      allowInPlace: true,
    );
  }

  /// WebView の新規 window 遷移向けに推奨アクションを返します。
  ///
  /// [targetUrl] は遷移先候補の URL です。
  /// [sourceUrl] は相対 URL を解決するための基準 URL です。
  ///
  /// Returns: delegate で利用できる推奨アクションと補助 URI を含む結果。
  ProxyWebViewNavigationRecommendation recommendNewWindowNavigation({
    required String targetUrl,
    String? sourceUrl,
  }) {
    return _recommendWebViewNavigation(
      targetUrl: targetUrl,
      sourceUrl: sourceUrl,
      allowInPlace: false,
    );
  }

  /// 外部から取得した Cookie を復元します。
  ///
  /// [entries] は復元対象の Cookie 一覧です。
  /// start 前でも呼び出せ、復元済み Cookie は起動後の上流リクエストに利用されます。
  ///
  /// Throws:
  ///   * [CookieOperationException] Cookie の復元に失敗した場合。暗号化した
  ///     保存領域を使えない場合は、[StorageIntegrityException] を cause に持ちます。
  Future<void> restoreCookies(Iterable<CookieRestoreEntry> entries) async {
    try {
      await _ensureCookieStorageInitialized();

      final restoredAt = DateTime.now();
      final cookieRecords = entries
          .map((entry) => entry.toCookieRecord(restoredAt: restoredAt))
          .toList(growable: false);

      await _persistCookieRecords(cookieRecords, now: restoredAt.toUtc());
    } catch (e) {
      throw CookieOperationException(
        'restore',
        'Cookie の復元に失敗しました: $e',
        e is Exception ? e : null,
      );
    }
  }

  /// 指定 URI が設定済み origin と同一 origin かどうかを返します。
  ///
  /// [targetUri] は検証対象の URI です。
  /// 戻り値は同一 origin の場合に `true` です。
  bool _isSameOriginAsConfiguredOrigin(Uri targetUri) {
    final originUri = _configuredOriginUri;
    if (originUri == null) {
      return false;
    }

    return originUri.scheme.toLowerCase() == targetUri.scheme.toLowerCase() &&
        originUri.host.toLowerCase() == targetUri.host.toLowerCase() &&
        _effectivePort(originUri) == _effectivePort(targetUri);
  }

  /// 設定済み origin を URI として返します。
  Uri? get _configuredOriginUri {
    final configuredOrigin = _config?.origin ?? '';
    if (configuredOrigin.isEmpty) {
      return null;
    }

    final originUri = Uri.tryParse(configuredOrigin);
    if (originUri == null || !originUri.hasScheme || originUri.host.isEmpty) {
      return null;
    }
    return originUri;
  }

  /// URI の実効ポート番号を返します。
  int _effectivePort(Uri uri) {
    if (uri.hasPort) {
      return uri.port;
    }
    return _defaultPortForScheme(uri.scheme);
  }

  /// スキームの既定ポート番号を返します。
  ///
  /// [scheme] 判定するスキーム。
  ///
  /// Returns: 既定ポート。HTTP(S) 以外は `-1`。
  int _defaultPortForScheme(String scheme) {
    return switch (scheme.toLowerCase()) {
      'https' => 443,
      'http' => 80,
      _ => -1,
    };
  }

  /// 保存されているCookieを削除します。
  ///
  /// [domain] 特定ドメインのCookieのみを削除したい場合に指定。省略時は全Cookieを削除。
  ///
  /// Throws:
  ///   * [CookieOperationException] Cookieの削除に失敗した場合。暗号化した
  ///     保存領域を使えない場合は、[StorageIntegrityException] を cause に持ちます。
  Future<void> clearCookies({String? domain}) async {
    try {
      await _ensureCookieStorageInitialized();
      if (_cookieBox != null) {
        if (domain == null) {
          // 全Cookieを削除
          await _cookieBox!.clear();
        } else {
          // 特定ドメインのCookieを削除
          final keysToDelete = <String>[];
          for (final key in _cookieBox!.keys) {
            final data = _cookieBox!.get(key) as Map?;
            if (data != null && data['domain'] == domain) {
              keysToDelete.add(key as String);
            }
          }

          for (final key in keysToDelete) {
            await _cookieBox!.delete(key);
          }
        }
      }
    } catch (e) {
      throw CookieOperationException(
          'clear', 'Cookieの削除に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// オフライン時にキューに保存されたリクエストの一覧を取得します。
  ///
  /// 保存日時（`queuedAt`）の古い順に並びます。保存日時が同じ場合は、保存に
  /// 使ったキーを時刻として読み直した値で並べます。暗号化する前の保存領域から
  /// 移行を待っている項目も含み、その項目は [QueuedRequest.pendingMigration] が
  /// `true` になります。
  ///
  /// [QueuedRequest.headers] は、機密情報を含み得るヘッダの値を `***` に
  /// 置き換えます。対象は、名前を小文字にし `_` を `-` とみなしたときに
  /// `cookie`、`authorization`、`proxy-authorization` と一致するか、`auth`、
  /// `token`、`secret`、`session`、`csrf`、`xsrf`、`key`、`pass`、
  /// `credential`、`signature`、`jwt`、`cookie` のいずれかを含むものです。
  /// [ProxyConfig.idempotencyHeaderName] のヘッダは置き換えません。保存される
  /// ヘッダはクライアントが送ったものだけで、proxy が付けるヘッダは送信時に
  /// 加えます。URL のクエリは置き換えません。再送には保存した値をそのまま
  /// 使います。
  ///
  /// Returns: キューに保存されているリクエストの一覧。
  ///
  /// Throws:
  ///   * [QueueOperationException] キュー情報の取得に失敗した場合。
  Future<List<QueuedRequest>> getQueuedRequests() async {
    try {
      final entries =
          await _collectStoredEntries(ProxyStorageBox.queue, 'queuedAt');
      return entries
          .map((entry) => _mapToQueuedRequest(
                entry.data,
                pendingMigration: entry.pendingMigration,
              ))
          .toList();
    } catch (e) {
      throw QueueOperationException(
          'get', 'キューされたリクエストの取得に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// キューから除外されたリクエストの履歴を取得します。
  ///
  /// 記録した日時（`droppedAt`）の古い順に並びます。暗号化する前の保存領域から
  /// 移行を待っている履歴も含み、その履歴は [DroppedRequest.pendingMigration] が
  /// `true` になります。
  ///
  /// [limit] 取得する最大件数。並べた後の先頭からの件数です。
  ///
  /// Returns: ドロップされたリクエストの履歴。
  ///
  /// Throws:
  ///   * [QueueOperationException] 履歴情報の取得に失敗した場合。
  Future<List<DroppedRequest>> getDroppedRequests({int? limit}) async {
    try {
      if (limit != null && limit <= 0) {
        return const <DroppedRequest>[];
      }

      final entries = await _collectStoredEntries(
        ProxyStorageBox.droppedRequests,
        'droppedAt',
      );
      final selected = limit == null ? entries : entries.take(limit);
      return selected
          .map((entry) => _mapToDroppedRequest(
                entry.data,
                pendingMigration: entry.pendingMigration,
              ))
          .toList();
    } catch (e) {
      throw QueueOperationException('getDropped', 'ドロップされたリクエストの取得に失敗しました: $e',
          e is Exception ? e : null);
    }
  }

  /// ドロップされたリクエストの履歴を確認済みにします。
  ///
  /// 起動時に未確認の履歴を検知したあと、利用者へ提示し終えた時点で
  /// 呼び出してください。履歴自体は削除しないため、内容は後から参照できます。
  /// 暗号化する前の保存領域から移行を待っている履歴も確認済みにし、移行後に
  /// 未確認へ戻らないようにします。
  ///
  /// Returns: 確認済みへ変更した件数。
  ///
  /// Throws:
  ///   * [QueueOperationException] 更新に失敗した場合。履歴のロックを
  ///     30 秒以内に取得できなかった場合を含みます。
  Future<int> acknowledgeDroppedRequests() async {
    try {
      return await _droppedRequestLock.synchronized(() async {
        final excludedKeys =
            _excludedLegacyKeys(ProxyStorageBox.droppedRequests);
        final sources = [
          (box: _droppedRequestBox, isLegacy: false),
          (box: _legacyDroppedRequestBox, isLegacy: true),
        ];

        var updated = 0;
        for (final source in sources) {
          final box = source.box;
          if (box == null || !box.isOpen) {
            continue;
          }

          for (final key in box.keys.toList()) {
            if (!source.isLegacy && excludedKeys.contains(key.toString())) {
              continue;
            }

            final data = box.get(key) as Map?;
            if (data == null || data['acknowledged'] == true) {
              continue;
            }

            final updatedData = Map<String, dynamic>.from(data);
            updatedData['acknowledged'] = true;
            await box.put(key, updatedData);
            updated++;
          }
        }

        _unacknowledgedDroppedCount = null;
        return updated;
      }, timeout: _storageLockTimeout);
    } catch (e) {
      throw QueueOperationException('acknowledgeDropped',
          'ドロップされたリクエストの確認状態の更新に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// 隔離されたリクエストの一覧を取得します。
  ///
  /// 上流に拒否されて再送を中止したリクエストのうち、
  /// [ProxyConfig.dropPolicy] が [DropPolicy.quarantine] の場合に退避した
  /// ものを返します。本文は返しません。
  ///
  /// [limit] 取得する最大件数。
  ///
  /// Returns: 隔離されているリクエストの一覧。隔離した日時（`quarantinedAt`）の
  ///   古い順に並び、[limit] は並べた後の先頭からの件数です。暗号化する前の
  ///   保存領域から移行を待っている項目も含み、その項目は
  ///   [QuarantinedRequest.pendingMigration] が `true` になります。
  ///
  /// Throws:
  ///   * [QueueOperationException] 取得に失敗した場合。
  Future<List<QuarantinedRequest>> getQuarantinedRequests({int? limit}) async {
    try {
      if (limit != null && limit <= 0) {
        return const <QuarantinedRequest>[];
      }

      final entries = await _collectStoredEntries(
        ProxyStorageBox.quarantine,
        'quarantinedAt',
      );
      final selected = limit == null ? entries : entries.take(limit);
      return selected
          .map((entry) => _mapToQuarantinedRequest(
                entry.key,
                entry.data,
                pendingMigration: entry.pendingMigration,
              ))
          .toList();
    } catch (e) {
      throw QueueOperationException('getQuarantined',
          '隔離されたリクエストの取得に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// 隔離されたリクエストをキューへ戻して再送します。
  ///
  /// 拒否の原因を解消したあとに呼び出してください。再試行回数は初期化し、
  /// オンラインであれば直ちに送信を試みます。
  ///
  /// [id] [getQuarantinedRequests] が返した識別子。
  ///
  /// Returns: キューへ戻した場合は `true`。該当が無い場合と、暗号化する前の
  ///   保存領域から移行を待っている項目の場合は `false`。
  ///
  /// Throws:
  ///   * [QueueOperationException] 操作に失敗した場合。隔離のロックを
  ///     30 秒以内に取得できなかった場合を含みます。
  Future<bool> retryQuarantinedRequest(String id) async {
    return await _retryQuarantinedRequestInternal(id) ==
        _QuarantineOperationResult.done;
  }

  /// 隔離されたリクエストをキューへ戻し、操作の結果を返します。
  ///
  /// 隔離のロックの中でキューへ戻し、ロックを離してからキュー消化を始めます
  /// （ロックの順序を守り、互いに待ち合って止まらないようにするため）。
  ///
  /// [id] 隔離領域内での識別子。
  ///
  /// Returns: 操作の結果。
  ///
  /// Throws:
  ///   * [QueueOperationException] 操作に失敗した場合。
  Future<_QuarantineOperationResult> _retryQuarantinedRequestInternal(
    String id,
  ) async {
    try {
      final result = await _quarantineLock.synchronized(() async {
        if (_isPendingLegacyQuarantine(id)) {
          return _QuarantineOperationResult.pendingMigration;
        }

        final quarantineBox = _quarantinedRequestBox;
        final queueBox = _queueBox;
        if (quarantineBox == null ||
            !quarantineBox.isOpen ||
            queueBox == null ||
            !queueBox.isOpen) {
          return _QuarantineOperationResult.notFound;
        }

        final data = quarantineBox.get(id) as Map?;
        if (data == null) {
          return _QuarantineOperationResult.notFound;
        }

        final now = DateTime.now();
        final queueData = Map<String, dynamic>.from(data)
          ..remove('quarantinedAt')
          ..remove('reason')
          ..remove('errorMessage')
          ..remove('statusCode')
          ..['retryCount'] = 0
          ..['nextRetryAt'] = now.toIso8601String()
          // 再送は改めて受け付けた時点を起点にし、待機中の要求より後に送る。
          // 業務上の発生時刻は acceptedAt が保持するため、ここでは触れない。
          ..['queuedAt'] = now.toIso8601String();

        final key = _generateUniqueStorageKey(queueBox, _legacyQueueBox);
        await queueBox.put(key, queueData);
        await quarantineBox.delete(id);

        _emitEvent(ProxyEventType.requestQueued,
            queueData['url'] as String? ?? '', {'queueId': key});
        return _QuarantineOperationResult.done;
      }, timeout: _storageLockTimeout);

      if (result == _QuarantineOperationResult.done) {
        // ignore: discarded_futures
        _drainQueue();
      }
      return result;
    } catch (e) {
      throw QueueOperationException('retryQuarantined',
          '隔離されたリクエストの再送に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// 隔離の記録が、移行を待っている旧平文 Box の記録かどうかを返します。
  ///
  /// [id] 隔離領域内での識別子。
  ///
  /// Returns: 移行を待っている記録の場合は `true`。
  bool _isPendingLegacyQuarantine(String id) {
    final legacyBox = _legacyQuarantineBox;
    if (legacyBox != null && legacyBox.isOpen && legacyBox.containsKey(id)) {
      return true;
    }
    return _excludedLegacyKeys(ProxyStorageBox.quarantine).contains(id);
  }

  /// 隔離されたリクエストを破棄します。
  ///
  /// 内容を確認したうえで送信しないと判断した場合に呼び出してください。
  ///
  /// [id] [getQuarantinedRequests] が返した識別子。
  ///
  /// Returns: 破棄した場合は `true`。該当が無い場合と、暗号化する前の保存領域から
  ///   移行を待っている項目の場合は `false`。
  ///
  /// Throws:
  ///   * [QueueOperationException] 操作に失敗した場合。隔離のロックを
  ///     30 秒以内に取得できなかった場合を含みます。
  Future<bool> discardQuarantinedRequest(String id) async {
    return await _discardQuarantinedRequestInternal(id) ==
        _QuarantineOperationResult.done;
  }

  /// 隔離されたリクエストを破棄し、操作の結果を返します。
  ///
  /// [id] 隔離領域内での識別子。
  ///
  /// Returns: 操作の結果。
  ///
  /// Throws:
  ///   * [QueueOperationException] 操作に失敗した場合。
  Future<_QuarantineOperationResult> _discardQuarantinedRequestInternal(
    String id,
  ) async {
    try {
      return await _quarantineLock.synchronized(() async {
        if (_isPendingLegacyQuarantine(id)) {
          return _QuarantineOperationResult.pendingMigration;
        }

        final box = _quarantinedRequestBox;
        if (box == null || !box.isOpen || !box.containsKey(id)) {
          return _QuarantineOperationResult.notFound;
        }

        await box.delete(id);
        return _QuarantineOperationResult.done;
      }, timeout: _storageLockTimeout);
    } catch (e) {
      throw QueueOperationException('discardQuarantined',
          '隔離されたリクエストの破棄に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// 隔離されたリクエストを全て破棄します。
  ///
  /// 暗号化する前の保存領域から移行を待っている項目も破棄します。
  ///
  /// Throws:
  ///   * [QueueOperationException] 破棄に失敗した場合。隔離のロックを
  ///     30 秒以内に取得できなかった場合を含みます。
  Future<void> clearQuarantinedRequests() async {
    try {
      await _quarantineLock.synchronized(() async {
        await _quarantinedRequestBox?.clear();
        // 利用者の意図は全件の破棄のため、移行を待っている分も消す。
        // 移行と同じロックの中で消し、書き写しで暗号化 Box に残らないようにする。
        await _clearLegacyBox(ProxyStorageBox.quarantine);
      }, timeout: _storageLockTimeout);
    } catch (e) {
      throw QueueOperationException('clearQuarantined',
          '隔離されたリクエストの破棄に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// ドロップされたリクエストの履歴を全て削除します。
  ///
  /// 暗号化する前の保存領域から移行を待っている履歴も削除します。
  ///
  /// Throws:
  ///   * [QueueOperationException] 履歴の削除に失敗した場合。履歴のロックを
  ///     30 秒以内に取得できなかった場合を含みます。
  Future<void> clearDroppedRequests() async {
    try {
      await _droppedRequestLock.synchronized(() async {
        await _droppedRequestBox?.clear();
        // 利用者の意図は全件の削除のため、移行を待っている分も消す。
        // 移行と同じロックの中で消し、書き写しで暗号化 Box に残らないようにする。
        await _clearLegacyBox(ProxyStorageBox.droppedRequests);
        _unacknowledgedDroppedCount = null;
      }, timeout: _storageLockTimeout);
    } catch (e) {
      throw QueueOperationException('clearDropped',
          'ドロップされたリクエスト履歴の削除に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// 暗号化した保存領域を、利用者の確認を経て復旧します。
  ///
  /// `start()` や Cookie API が [StorageIntegrityException] で失敗し、再試行しても
  /// 解消しない場合に、失われる内容を利用者へ説明し、同意を得てから呼び出して
  /// ください。この isolate の proxy のいずれかが稼働中または起動処理中の場合は、
  /// 使用中の Box を閉じないよう何もしません
  /// （[StorageRecoveryRejection.proxyActive]）。
  ///
  /// 直前に `start()` と同じく鍵を読み直し、同じ時間の上限で暗号化 Box と照合して、
  /// 次のとおり扱います。
  /// * 鍵を一時的に読めない場合は、何もしません
  ///   （[StorageRecoveryRejection.temporarilyUnavailable]）。
  /// * 鍵があり、キュー・隔離・ドロップ履歴の Box に問題が無い場合は、何もしません
  ///   （[StorageRecoveryRejection.startWillSucceed]）。Cookie Box だけの問題は
  ///   `start()` が Cookie Box を破棄して続けるためです。
  /// * 鍵があり、問題のある Box がある場合は、鍵を残して Box ごとに扱います。
  ///   鍵と一致しない Box は削除します。先頭側が壊れた Box は、鍵と一致する
  ///   最初の記録から後ろを残して作り直します（失われる先頭側の記録の件数は
  ///   分かりません）。照合が時間の上限を超えた Box は、Box を閉じた後に
  ///   時間の上限を設けずに照合し直し、その結果で扱います（鍵と一致しなければ
  ///   削除、先頭側が壊れていれば作り直し）。先頭の記録が書きかけで鍵と一致する
  ///   記録も無ければ、0 バイトに切り詰めます（開いたときに Hive も同じく
  ///   切り詰めるため、失うものはありません）。問題の無い Box は残します。
  /// * 鍵の形式が正しくない場合、または鍵なし・読み取り不能の場合（中身のある
  ///   暗号化 Box があれば、読み直しても続く場合）は、次のとおりです。
  ///   キュー・隔離・ドロップ履歴の Box のどれかに中身があれば、暗号化 Box
  ///   （Cookie・キュー・隔離・ドロップ履歴）をすべて削除してから鍵を削除します。
  ///   Cookie も消えるため、再ログインが必要になります。どれにも中身が無ければ
  ///   何も消しません（[StorageRecoveryRejection.startWillSucceed]）。
  ///
  /// 鍵を書き込めずに起動に失敗した場合（[StorageIntegrityFailure.keyWriteFailed]）は、
  /// 消す必要のある Box が無いため何もしません
  /// （[StorageRecoveryRejection.startWillSucceed]）。時間をおいて `start()` を
  /// 再試行してください。
  ///
  /// 削除や作り直しの前に proxy の Box をすべて閉じます。作り直しは置き換えが
  /// 終わるまで元のファイルを残すため、途中で失敗しても再実行できます。
  /// 暗号化する前の旧平文 Box は削除しません（鍵が無くても読めるため、次の
  /// `start()` で移行します）。終了後は、プロセスを再起動せずに `start()` を
  /// 呼び出せます。鍵を削除した場合、次の `start()` は新しい鍵を生成します。
  ///
  /// 暗号化された記録の件数は読めないため返しません。起動に失敗した後の
  /// [getStats] は 0 件を返すため、確認画面の根拠には使わないでください。
  ///
  /// Returns: 実行したかどうか、削除・作り直し・そのまま残した Box、鍵を
  ///   削除したかどうか。
  ///
  /// Throws:
  ///   * [StorageRecoveryException] Box のファイルや鍵の削除などに失敗した場合。
  Future<EncryptedStorageRecoveryResult> recoverEncryptedStorage() async {
    if (_activeInstances.isNotEmpty) {
      return const EncryptedStorageRecoveryResult.rejected(
        StorageRecoveryRejection.proxyActive,
      );
    }

    try {
      // 初期化と同じ直列化に入り、Cookie API がきっかけの初期化とも重ならないようにする
      return await _storageInitializationLock.synchronized(_runStorageRecovery);
    } on StorageRecoveryException {
      rethrow;
    } catch (error) {
      throw StorageRecoveryException(
        'Failed to recover encrypted storage: $error',
        error,
      );
    }
  }

  /// プロキシサーバの統計情報を取得します。
  ///
  /// キュー・隔離・ドロップ履歴の件数には、暗号化する前の保存領域から移行を
  /// 待っている分も含みます。保存領域を開く前に起動に失敗した場合
  /// （[StorageIntegrityException] など）と停止後は、これらの件数は 0 です。
  ///
  /// Returns: リクエスト数、キャッシュヒット率、キュー長などの統計情報。
  ///
  /// Throws:
  ///   * [StatsOperationException] 統計情報の取得に失敗した場合。
  Future<ProxyStats> getStats() async {
    try {
      // 暗号化する前の保存領域から移行を待っている分も含める。
      // 未送信があるときに精算させない、といった判断で見落とさないようにするため。
      final queueLength = _countStoredEntries(ProxyStorageBox.queue);
      final droppedRequestsCount =
          _countStoredEntries(ProxyStorageBox.droppedRequests);
      final quarantinedCount = _countStoredEntries(ProxyStorageBox.quarantine);
      final unacknowledgedDroppedCount = _countUnacknowledgedDroppedRequests();
      final uptime = _startedAt != null
          ? DateTime.now().difference(_startedAt!)
          : Duration.zero;

      return ProxyStats(
        totalRequests: _totalRequests,
        cacheHits: _cacheHits,
        cacheMisses: _cacheMisses,
        cacheHitRate: _totalRequests > 0 ? _cacheHits / _totalRequests : 0.0,
        queueLength: queueLength,
        droppedRequestsCount: droppedRequestsCount,
        unacknowledgedDroppedCount: unacknowledgedDroppedCount,
        quarantinedCount: quarantinedCount,
        startedAt: _startedAt ?? DateTime.now(),
        uptime: uptime,
      );
    } catch (e) {
      throw StatsOperationException(
          '統計情報の取得に失敗しました: $e', e is Exception ? e : null);
    }
  }

  // ──────────────────────────────────────────────────────
  // プライベートメソッド
  // ──────────────────────────────────────────────────────

  /// 未確認のドロップ履歴の件数を数えます。
  ///
  /// Returns: `acknowledged` が `false` の履歴件数。
  int _countUnacknowledgedDroppedRequests() {
    final cached = _unacknowledgedDroppedCount;
    if (cached != null) {
      return cached;
    }

    final excludedKeys = _excludedLegacyKeys(ProxyStorageBox.droppedRequests);
    final sources = [
      (box: _droppedRequestBox, isLegacy: false),
      (box: _legacyDroppedRequestBox, isLegacy: true),
    ];

    var count = 0;
    for (final source in sources) {
      final box = source.box;
      if (box == null || !box.isOpen) {
        continue;
      }

      for (final key in box.keys) {
        if (!source.isLegacy && excludedKeys.contains(key.toString())) {
          continue;
        }
        final data = box.get(key) as Map?;
        if (data != null && data['acknowledged'] != true) {
          count++;
        }
      }
    }

    _unacknowledgedDroppedCount = count;
    return count;
  }

  /// デフォルト設定を読み込みます。
  ///
  /// assets/config/config.yamlファイルが存在する場合はその内容を読み込み、
  /// 存在しない場合はビルトインのデフォルト設定を使用します。
  ///
  /// Returns: プロキシサーバの設定オブジェクト。
  Future<ProxyConfig> _loadDefaultConfig() async {
    // assets/config/config.yamlが存在する場合は読み込み、無い場合はデフォルト設定を使用
    return ProxyConfig(
      origin: '',
      host: '127.0.0.1',
      port: 0,
      preferredPort: 0,
      cacheMaxSize: 200 * 1024 * 1024, // 200MB
      cacheTtl: {
        'text/html': 3600,
        'text/css': 86400,
        'application/javascript': 86400,
        'image/*': 604800,
        'default': 86400,
      },
      cacheStale: {
        'text/html': 86400,
        'text/css': 604800,
        'image/*': 2592000,
        'default': 259200,
      },
      connectTimeout: const Duration(seconds: 5),
      requestTimeout: const Duration(seconds: 20),
      retryBackoffSeconds: [1, 2, 5, 10, 20, 30],
      enableAdminApi: false,
      logLevel: 'info',
    );
  }

  /// Hiveデータベースの初期化を行います。
  ///
  /// 段階 1（鍵と Cookie Box）と段階 2（キャッシュ、キュー、べき等性キー
  /// などの Box）を順に完了させます。
  Future<void> _initializeStorage() async {
    await _ensureDataStage();
  }

  /// 保存領域の初期化の段階 2 を実行します。
  ///
  /// `start()` だけが呼び出します。段階 1 の完了を待ってから、段階 1 と
  /// 同じ直列化の中で実行します。実行中の段階 2 があればその結果を共有します。
  /// 完了済みの結果を使う場合も初期化のロックを 1 回通り、Box が閉じられて
  /// いないことと保存領域の世代が変わっていないことを確かめ直します。失敗した
  /// 場合は段階 2 の結果だけを捨て、段階 1 の結果（Cookie Box）はそのまま
  /// 使えるようにします。
  Future<void> _ensureDataStage() async {
    await _ensureKeyStage();

    final current = _dataStageFuture;
    if (current != null && !_dataStageCompleted) {
      // 実行中の段階 2 を共有する
      (await current).unwrap();
      return;
    }

    // 完了済みの結果を使う場合も、初期化のロックを 1 回通ってから確かめ直す。
    // 照合の間に復旧 API がこのロックの中で Box を削除・作り直していた場合に、
    // 閉じた Box や古い鍵のまま起動しないため
    final wasCompleted = current != null;
    late final Future<_StageOutcome<void>> stage;
    stage = _storageInitializationLock.synchronized(() async {
      try {
        if (!wasCompleted || !_isDataStageFresh) {
          await _runDataStage();
        }
        if (identical(_dataStageFuture, stage)) {
          _dataStageCompleted = true;
        }
        return const _StageOutcome<void>.success(null);
      } catch (error, stackTrace) {
        if (identical(_dataStageFuture, stage)) {
          _dataStageFuture = null;
        }
        return _StageOutcome<void>.failure(error, stackTrace);
      }
    });
    _dataStageFuture = stage;
    _dataStageCompleted = false;
    (await stage).unwrap();
  }

  /// 完了済みの段階 2 の結果を、そのまま使えるかどうかを返します。
  ///
  /// 段階 2 で開いた Box がどれも閉じられておらず、段階 1 を済ませた後に
  /// 保存領域の世代が変わっていない場合に `true` です。
  bool get _isDataStageFresh =>
      _keyStageGeneration == _storageGeneration &&
      _dataStageBoxes.every((box) => box != null && box.isOpen);

  /// 段階 2 で開く Box の一覧を返します（移行を待つ旧平文 Box は含みません）。
  ///
  /// 段階 2 の結果をそのまま使えるか（どれも閉じられていないか）の判定に使います。
  List<Box?> get _dataStageBoxes => [
        _cacheBox,
        _webStorageBox,
        _idempotencyBox,
        _queueBox,
        _quarantinedRequestBox,
        _droppedRequestBox,
      ];

  /// 段階 2 の本体です。
  ///
  /// キャッシュ、WebStorage、べき等性キーの Box と、段階 1 で確定した鍵で
  /// キュー・隔離・ドロップ履歴の暗号化 Box を開き、旧平文 Box を移行します。
  /// このインスタンスで鍵を生成した場合は、旧平文 Box を開いてキーの一覧を
  /// 持つだけにし、移行は待ち時間の後へ遅らせます。
  ///
  /// 失敗した場合は、この呼び出しで開いた Box を閉じ、フィールドを `null` に
  /// 戻してから例外を送出します。
  ///
  /// 初期化のロックを保持したまま実行されます。ロックは再入できないため、
  /// ここから `_ensure` で始まる関数や Cookie を保存する関数を呼んではいけません。
  /// 段階 1 の後に復旧 API が保存領域を変えていた場合（別のインスタンスの復旧を
  /// 含む）は、古い鍵を使わないよう、ロックの中で段階 1 の本体をやり直してから
  /// 進みます。
  ///
  /// Throws:
  ///   * [StorageIntegrityException] やり直した段階 1 が判定表で起動失敗と
  ///     なった場合。
  ///   * [StateError] 段階 1 で鍵と保存先が確定していない場合。
  Future<void> _runDataStage() async {
    if (_storageEncryptionKey == null ||
        _hiveDirectoryPath == null ||
        _keyStageGeneration != _storageGeneration) {
      await _runKeyStage();
    }

    final encryptionKey = _storageEncryptionKey;
    final directoryPath = _hiveDirectoryPath;
    if (encryptionKey == null || directoryPath == null) {
      throw StateError('Encrypted storage is not initialized');
    }

    final openedBoxes = <Box>[];
    try {
      _cacheBox = await _openBoxTracked('proxy_cache', openedBoxes);
      _webStorageBox = await _openBoxTracked(_webStorageBoxName, openedBoxes);
      _idempotencyBox = await _openBoxTracked('proxy_idempotency', openedBoxes);
      _queueBox = await _openBoxTracked(
        _encryptedQueueBoxName,
        openedBoxes,
        encryptionKey: encryptionKey,
      );
      _quarantinedRequestBox = await _openBoxTracked(
        _encryptedQuarantineBoxName,
        openedBoxes,
        encryptionKey: encryptionKey,
      );
      _droppedRequestBox = await _openBoxTracked(
        _encryptedDroppedRequestBoxName,
        openedBoxes,
        encryptionKey: encryptionKey,
      );
      _unacknowledgedDroppedCount = null;

      await _prepareLegacyMigration(directoryPath, openedBoxes);
    } catch (_) {
      await _closeBoxesQuietly(openedBoxes);
      _cacheBox = null;
      _webStorageBox = null;
      _idempotencyBox = null;
      _queueBox = null;
      _quarantinedRequestBox = null;
      _droppedRequestBox = null;
      _legacyQueueBox = null;
      _legacyQuarantineBox = null;
      _legacyDroppedRequestBox = null;
      _pendingLegacyKeys.clear();
      rethrow;
    }
  }

  /// 失敗時の後始末として Box を閉じます。
  ///
  /// 元の失敗を呼び出し側へ伝えるため、閉じる処理の失敗は送出しません。
  ///
  /// [boxes] 閉じる Box の一覧。
  Future<void> _closeBoxesQuietly(Iterable<Box> boxes) async {
    for (final box in boxes) {
      if (!box.isOpen) {
        continue;
      }
      try {
        await box.close();
      } catch (_) {
        // 元の失敗を優先して送出するため、閉じる処理の失敗は無視する
      }
    }
  }

  /// キュー消化・隔離・ドロップ履歴の排他を取得するまでの上限時間を返します。
  Duration get _storageLockTimeout =>
      _storageTestHooks?.storageLockTimeout ?? _defaultStorageLockTimeout;

  /// 移行を待っている旧平文 Box があるかどうかを返します。
  bool get _hasPendingLegacyMigration =>
      _legacyQueueBox != null ||
      _legacyQuarantineBox != null ||
      _legacyDroppedRequestBox != null;

  /// 種類に対応する暗号化 Box を返します。
  ///
  /// [kind] Box の種類。
  ///
  /// Returns: 暗号化 Box。開いていない場合は `null`。
  Box? _encryptedBoxFor(ProxyStorageBox kind) {
    return switch (kind) {
      ProxyStorageBox.queue => _queueBox,
      ProxyStorageBox.quarantine => _quarantinedRequestBox,
      ProxyStorageBox.droppedRequests => _droppedRequestBox,
      ProxyStorageBox.cookies => _cookieBox,
    };
  }

  /// 種類に対応する、移行を待っている旧平文 Box を返します。
  ///
  /// [kind] Box の種類。
  ///
  /// Returns: 旧平文 Box。移行を待っていない場合は `null`。
  Box? _legacyBoxFor(ProxyStorageBox kind) {
    return switch (kind) {
      ProxyStorageBox.queue => _legacyQueueBox,
      ProxyStorageBox.quarantine => _legacyQuarantineBox,
      ProxyStorageBox.droppedRequests => _legacyDroppedRequestBox,
      ProxyStorageBox.cookies => null,
    };
  }

  /// 種類に対応する、移行を待っている旧平文 Box を設定します。
  ///
  /// [kind] Box の種類。
  /// [box] 設定する旧平文 Box。移行を終えた場合は `null`。
  void _setLegacyBox(ProxyStorageBox kind, Box? box) {
    switch (kind) {
      case ProxyStorageBox.queue:
        _legacyQueueBox = box;
      case ProxyStorageBox.quarantine:
        _legacyQuarantineBox = box;
      case ProxyStorageBox.droppedRequests:
        _legacyDroppedRequestBox = box;
      case ProxyStorageBox.cookies:
        break;
    }
  }

  /// 暗号化 Box の側で対象から外す、移行を待っているキーの一覧を返します。
  ///
  /// 旧平文 Box が開いていて空でない間だけ外します。旧 Box が空になった後は、
  /// 書き写した記録が唯一の記録になるためです。
  ///
  /// [kind] Box の種類。
  ///
  /// Returns: 外すキーの一覧。外すものが無い場合は空の集合。
  Set<String> _excludedLegacyKeys(ProxyStorageBox kind) {
    final legacyBox = _legacyBoxFor(kind);
    if (legacyBox == null || !legacyBox.isOpen || legacyBox.isEmpty) {
      return const <String>{};
    }
    return _pendingLegacyKeys[kind] ?? const <String>{};
  }

  /// 種類に対応するロックの中で処理を実行します。
  ///
  /// 隔離は隔離のロック、ドロップ履歴は履歴のロックを取ります。キューは、
  /// 呼び出し側がキュー消化の排他を持つか、キュー消化を始める前に呼ぶため、
  /// ロックを取りません。
  ///
  /// [kind] Box の種類。
  /// [action] ロックの中で実行する処理。
  ///
  /// Returns: [action] の戻り値。
  ///
  /// Throws:
  ///   * [TimeoutException] ロックを上限時間内に取得できなかった場合。
  Future<T> _runWithStorageLock<T>(
    ProxyStorageBox kind,
    Future<T> Function() action,
  ) {
    return switch (kind) {
      ProxyStorageBox.quarantine =>
        _quarantineLock.synchronized(action, timeout: _storageLockTimeout),
      ProxyStorageBox.droppedRequests =>
        _droppedRequestLock.synchronized(action, timeout: _storageLockTimeout),
      _ => action(),
    };
  }

  /// 旧平文 Box（キュー・隔離・ドロップ履歴）を移行するか、遅らせる準備をします。
  ///
  /// 通常は、再送を始める前のここで移行します。隔離とドロップ履歴は、`start()` を
  /// 待たずに呼ばれた API と重ならないよう、対応するロックの中で移行します。
  /// このインスタンスで暗号化鍵を生成した場合は、鍵の書き込みがディスクへ
  /// 確定するのを待つため、旧 Box を開いてキーの一覧を持つだけにします。移行は
  /// 待ち時間の後、稼働中に行います。
  ///
  /// [directoryPath] Hive の保存先ディレクトリ。
  /// [openedBoxes] 新たに開いた Box を記録する一覧。失敗時に閉じるために使います。
  Future<void> _prepareLegacyMigration(
    String directoryPath,
    List<Box> openedBoxes,
  ) async {
    for (final entry in _legacyBoxNames.entries) {
      final kind = entry.key;
      final legacyName = entry.value;
      if (!await Hive.boxExists(legacyName, path: directoryPath)) {
        continue;
      }

      final legacyBox = await _openBoxTracked(legacyName, openedBoxes);
      if (legacyBox.isEmpty) {
        // 移す記録が無いため、待たずに片付ける
        await _closeAndDeleteLegacyBox(legacyBox, legacyName, directoryPath);
        continue;
      }

      if (_encryptionKeyGeneratedStopwatch == null) {
        await _runWithStorageLock(kind, () async {
          await _copyLegacyBox(kind, legacyBox, _encryptedBoxFor(kind)!);
          if (kind == ProxyStorageBox.droppedRequests) {
            _unacknowledgedDroppedCount = null;
          }
          await _closeAndDeleteLegacyBox(legacyBox, legacyName, directoryPath);
        });
        continue;
      }

      _setLegacyBox(kind, legacyBox);
      _pendingLegacyKeys[kind] =
          legacyBox.keys.map((key) => key.toString()).toSet();
    }
  }

  /// 旧平文 Box の記録を、キーを保ったまま暗号化 Box へ書き写し、旧 Box を空にします。
  ///
  /// 旧 Box を空にする前に失敗した場合は、二重にならないよう書き写したキーを
  /// 暗号化 Box から消してから例外を送出します。消せなかったキーは、旧 Box が
  /// 空になるまで [_pendingLegacyKeys] で対象から外します。
  ///
  /// [kind] 書き写す Box の種類。
  /// [legacyBox] 書き写す旧平文 Box。
  /// [targetBox] 書き写し先の暗号化 Box。
  Future<void> _copyLegacyBox(
    ProxyStorageBox kind,
    Box legacyBox,
    Box targetBox,
  ) async {
    final copiedKeys = <dynamic>[];
    try {
      for (final key in legacyBox.keys.toList()) {
        final value = legacyBox.get(key);
        if (value == null) {
          continue;
        }
        await targetBox.put(key, value);
        copiedKeys.add(key);
      }
      await targetBox.flush();
      await _storageTestHooks?.beforeLegacyBoxCleared?.call(kind);
      await legacyBox.clear();
    } catch (_) {
      // 旧 Box に記録が残っている場合だけ、書き写した分を消す。
      // 空になっている場合は、書き写した分が唯一の記録のため残す。
      if (legacyBox.isOpen && legacyBox.isNotEmpty && targetBox.isOpen) {
        try {
          await targetBox.deleteAll(copiedKeys);
        } catch (_) {
          // 消せなかったキーは、旧 Box が空になるまで対象から外して扱う
        }
      }
      rethrow;
    }
  }

  /// 空にした旧平文 Box を閉じ、ファイルを削除します。
  ///
  /// 中身は空にしてあるため、削除に失敗しても処理は続け、イベントで知らせます。
  ///
  /// [legacyBox] 閉じる旧平文 Box。
  /// [legacyName] 旧平文 Box の名前。
  /// [directoryPath] Hive の保存先ディレクトリ。
  Future<void> _closeAndDeleteLegacyBox(
    Box legacyBox,
    String legacyName,
    String directoryPath,
  ) async {
    if (legacyBox.isOpen) {
      await legacyBox.close();
    }

    try {
      await Hive.deleteBoxFromDisk(legacyName, path: directoryPath);
    } catch (error) {
      _emitEvent(ProxyEventType.errorOccurred, '', {
        'operation': 'legacyStorageDelete',
        'box': legacyName,
        'error': error.toString(),
      });
    }
  }

  /// 遅らせた移行を始めるまでの残り時間を返します。
  ///
  /// 端末の時計を戻しても遅れないよう、鍵を生成してからの経過時間で求めます。
  Duration get _deferredMigrationRemaining {
    final delay = _storageTestHooks?.deferredMigrationDelay ??
        _defaultDeferredMigrationDelay;
    final remaining =
        delay - (_encryptionKeyGeneratedStopwatch?.elapsed ?? delay);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// 移行を待っている旧平文 Box があれば、遅らせた移行を予約します。
  void _scheduleDeferredMigration() {
    _deferredMigrationTimer?.cancel();
    _deferredMigrationTimer = null;
    if (!_hasPendingLegacyMigration) {
      return;
    }

    _deferredMigrationTimer = Timer(_deferredMigrationRemaining, () {
      _deferredMigrationTimer = null;
      if (_deferredMigrationRemaining > Duration.zero) {
        // タイマーは計測した経過時間よりわずかに早く発火し得るため、残りを予約し直す
        _scheduleDeferredMigration();
        return;
      }
      // ignore: discarded_futures
      _runDeferredMigration();
    });
  }

  /// 待ち時間を過ぎていれば、遅らせた移行を実行します。
  ///
  /// 予約したタイマーと、5 秒ごとのキュー消化の定期処理から呼びます。失敗した
  /// 場合は旧平文 Box を残し、次の定期処理で試み直します。定期処理はこの移行を
  /// 待ってからキュー消化を始めるため、失敗し続けても再送は止まりません。移行した
  /// 場合は、移した分が保持上限を超えていないかを続けて判定します。例外は
  /// 送出しません。
  Future<void> _runDeferredMigration() async {
    if (!_hasPendingLegacyMigration ||
        !_isRunning ||
        _isStopping ||
        _deferredMigrationFuture != null ||
        _deferredMigrationRemaining > Duration.zero) {
      return;
    }

    final migration = _migrateDeferredLegacyBoxes();
    _deferredMigrationFuture = migration;
    var migrated = false;
    try {
      migrated = await migration;
    } finally {
      if (identical(_deferredMigrationFuture, migration)) {
        _deferredMigrationFuture = null;
      }
    }

    // 次の追加や 1 時間ごとの判定を待たずに、移した分の保持上限を判定する
    if (migrated && _isRunning && !_isStopping) {
      await _enforceRetentionLimits();
    }
  }

  /// 移行を待っている旧平文 Box を、キュー消化と同じ排他の中で移行します。
  ///
  /// 実行中のキュー消化が終わるのを待ち、旧 Box を空にするまで次の消化を
  /// 始めません。隔離の移行は隔離のロック、ドロップ履歴の移行は履歴のロックを、
  /// それぞれ旧 Box を空にするまで保持します。失敗した場合（ロックを取れなかった
  /// 場合を含む）は何も変えず、次の定期処理で試み直します。
  ///
  /// Returns: 1 つ以上の旧平文 Box を移行した場合は `true`。
  Future<bool> _migrateDeferredLegacyBoxes() async {
    var migrated = false;
    try {
      await _queueDrainLock.synchronized(() async {
        for (final kind in _legacyBoxNames.keys) {
          if (!_isRunning || _isStopping) {
            // 書き写しを始めていなければ、停止を待たせずに取り消す
            return;
          }
          if (_legacyBoxFor(kind) == null) {
            continue;
          }

          if (await _runWithStorageLock(
            kind,
            () => _migrateDeferredLegacyBox(kind),
          )) {
            migrated = true;
          }
        }
      }, timeout: _storageLockTimeout);
    } on TimeoutException {
      // ロックを取れなかった場合は何も変えず、次の定期処理で試み直す
    } catch (error) {
      _emitEvent(ProxyEventType.errorOccurred, '', {
        'operation': 'legacyStorageMigration',
        'error': error.toString(),
      });
    }
    return migrated;
  }

  /// 移行を待っている旧平文 Box を 1 つ移行します。対応するロックの中で呼びます。
  ///
  /// [kind] 移行する Box の種類。
  ///
  /// Returns: 移行した場合は `true`。停止中のため取り消した場合と、全削除などで
  ///   既に片付いていた場合は `false`。
  ///
  /// Throws:
  ///   * [StateError] 旧平文 Box か暗号化 Box が閉じていて移行できない場合。
  Future<bool> _migrateDeferredLegacyBox(ProxyStorageBox kind) async {
    if (!_isRunning || _isStopping) {
      return false;
    }

    final legacyBox = _legacyBoxFor(kind);
    if (legacyBox == null) {
      return false;
    }

    final targetBox = _encryptedBoxFor(kind);
    final directoryPath = _hiveDirectoryPath;
    if (targetBox == null ||
        directoryPath == null ||
        !legacyBox.isOpen ||
        !targetBox.isOpen) {
      throw StateError('Storage for ${kind.name} is not open');
    }

    _deferredMigrationCopying = true;
    try {
      await _copyLegacyBox(kind, legacyBox, targetBox);
      _setLegacyBox(kind, null);
      _pendingLegacyKeys.remove(kind);
      if (kind == ProxyStorageBox.droppedRequests) {
        _unacknowledgedDroppedCount = null;
      }
      await _closeAndDeleteLegacyBox(
        legacyBox,
        _legacyBoxNames[kind]!,
        directoryPath,
      );
      return true;
    } finally {
      _deferredMigrationCopying = false;
    }
  }

  /// 移行を待っている旧平文 Box を空にして片付けます。
  ///
  /// 全削除の API から、対応するロックの中で呼びます。
  ///
  /// [kind] 片付ける Box の種類。
  Future<void> _clearLegacyBox(ProxyStorageBox kind) async {
    final legacyBox = _legacyBoxFor(kind);
    if (legacyBox == null) {
      return;
    }

    if (legacyBox.isOpen) {
      await legacyBox.clear();
    }
    _setLegacyBox(kind, null);
    _pendingLegacyKeys.remove(kind);
    if (kind == ProxyStorageBox.droppedRequests) {
      _unacknowledgedDroppedCount = null;
    }

    final directoryPath = _hiveDirectoryPath;
    if (directoryPath != null) {
      await _closeAndDeleteLegacyBox(
        legacyBox,
        _legacyBoxNames[kind]!,
        directoryPath,
      );
    }
  }

  /// 暗号化 Box と、移行を待っている旧平文 Box の記録を保存順に並べて返します。
  ///
  /// 旧平文 Box にもある同じキーの記録は、暗号化 Box の側から外します。
  /// 処理を譲る間に移行が終わっても一覧から抜けないよう、先に両方の Box の
  /// キーと値を同期的に控えます。大量の記録で UI の isolate を止めないよう、
  /// 控えた記録を読み解く間は一定件数ごとに処理を譲ります。
  ///
  /// [kind] Box の種類。
  /// [timestampField] 保存時刻を持つ項目名。
  ///
  /// Returns: 保存順に並べた記録。
  Future<List<StoredEntry>> _collectStoredEntries(
    ProxyStorageBox kind,
    String timestampField,
  ) async {
    final snapshot = <({String key, Object? data, bool pendingMigration})>[];
    final excludedKeys = _excludedLegacyKeys(kind);

    final box = _encryptedBoxFor(kind);
    if (box != null && box.isOpen) {
      for (final key in box.keys) {
        final keyString = key.toString();
        if (!excludedKeys.contains(keyString)) {
          snapshot.add((
            key: keyString,
            data: box.get(key),
            pendingMigration: false,
          ));
        }
      }
    }

    final legacyBox = _legacyBoxFor(kind);
    if (legacyBox != null && legacyBox.isOpen) {
      for (final key in legacyBox.keys) {
        snapshot.add((
          key: key.toString(),
          data: legacyBox.get(key),
          pendingMigration: true,
        ));
      }
    }

    final entries = <StoredEntry>[];
    for (var index = 0; index < snapshot.length; index++) {
      final item = snapshot[index];
      final data = item.data;
      if (data is Map) {
        entries.add(StoredEntry.fromData(
          key: item.key,
          data: data,
          timestampField: timestampField,
          pendingMigration: item.pendingMigration,
        ));
      }

      if ((index + 1) % _storedEntryYieldInterval == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    entries.sort(compareStoredEntries);
    return entries;
  }

  /// 暗号化 Box の記録を保存順に並べて返します。
  ///
  /// 移行を待っている旧平文 Box と同じキーの記録は含めません。ロックの中で
  /// 使うため、処理を譲りません。
  ///
  /// [kind] Box の種類。
  /// [box] 対象の暗号化 Box。
  /// [timestampField] 保存時刻を持つ項目名。
  ///
  /// Returns: 保存順に並べた記録。
  List<StoredEntry> _sortedEncryptedEntries(
    ProxyStorageBox kind,
    Box box,
    String timestampField,
  ) {
    final excludedKeys = _excludedLegacyKeys(kind);
    final entries = <StoredEntry>[];
    for (final key in box.keys) {
      final keyString = key.toString();
      if (excludedKeys.contains(keyString)) {
        continue;
      }

      final data = box.get(key);
      entries.add(StoredEntry.fromData(
        key: keyString,
        data: data is Map ? data : const {},
        timestampField: timestampField,
      ));
    }

    entries.sort(compareStoredEntries);
    return entries;
  }

  /// 暗号化 Box と、移行を待っている旧平文 Box の記録の件数を返します。
  ///
  /// [kind] Box の種類。
  ///
  /// Returns: 同じキーを二重に数えない件数。開いていない Box は 0 件とします。
  int _countStoredEntries(ProxyStorageBox kind) {
    var count = 0;
    final box = _encryptedBoxFor(kind);
    if (box != null && box.isOpen) {
      count += box.length;
      final excludedKeys = _excludedLegacyKeys(kind);
      if (excludedKeys.isNotEmpty) {
        count -= excludedKeys.where(box.containsKey).length;
      }
    }

    final legacyBox = _legacyBoxFor(kind);
    if (legacyBox != null && legacyBox.isOpen) {
      count += legacyBox.length;
    }
    return count;
  }

  /// 隔離とドロップ履歴の保持上限を判定し、超えた分を取り除いてから圧縮します。
  ///
  /// 起動時、遅らせた移行の後、1 時間ごとの定期処理から呼びます。ロックを
  /// 上限時間内に取れない場合は何も変えず、次の定期処理で判定します。
  /// 例外は送出しません。
  Future<void> _enforceRetentionLimits() async {
    try {
      await _quarantineLock.synchronized(() async {
        final box = _quarantinedRequestBox;
        if (box != null && box.isOpen) {
          await _enforceQuarantineLimits(box);
        }
      }, timeout: _storageLockTimeout);
    } on TimeoutException {
      // ロックを取れなかった場合は、次の定期処理で判定する
    } catch (error) {
      _emitRetentionError(error);
    }

    try {
      await _droppedRequestLock.synchronized(() async {
        final box = _droppedRequestBox;
        if (box != null && box.isOpen) {
          await _enforceDroppedRequestLimits(box);
        }
      }, timeout: _storageLockTimeout);
    } on TimeoutException {
      // ロックを取れなかった場合は、次の定期処理で判定する
    } catch (error) {
      _emitRetentionError(error);
    }

    // 削除した記録はファイルに論理削除のフレームとして残るため、ロックの外で圧縮する
    for (final box in [_quarantinedRequestBox, _droppedRequestBox]) {
      if (box == null || !box.isOpen) {
        continue;
      }
      try {
        await box.compact();
      } catch (error) {
        _emitRetentionError(error);
      }
    }
  }

  /// 保持上限の処理の失敗をイベントで知らせます。
  ///
  /// [error] 起きたエラー。
  void _emitRetentionError(Object error) {
    _emitEvent(ProxyEventType.errorOccurred, '', {
      'operation': 'retentionLimit',
      'error': error.toString(),
    });
  }

  /// 隔離の保持上限（期間・件数・合計バイト数）を超えた分を、ドロップ履歴へ
  /// 記録してから取り除きます。隔離のロックの中で呼びます。
  ///
  /// 取り除く記録を先にすべて決めてから、履歴へまとめて記録し、隔離からまとめて
  /// 削除します。1 件ごとに履歴を読み直さないためです。
  ///
  /// [box] 隔離の暗号化 Box。
  /// [protectedKey] 追い出さないキー。直前に隔離した記録を指定します。
  Future<void> _enforceQuarantineLimits(Box box, {String? protectedKey}) async {
    final config = _config;
    if (config == null) {
      return;
    }

    final entries = _sortedEncryptedEntries(
      ProxyStorageBox.quarantine,
      box,
      'quarantinedAt',
    );
    final evictions = <_QuarantineEviction>[];
    final retained = <StoredEntry>[];

    final retention = config.quarantineRetention;
    final threshold =
        retention > Duration.zero ? DateTime.now().subtract(retention) : null;
    for (final entry in entries) {
      final savedAt = entry.savedAt;
      final isExpired = threshold != null &&
          entry.key != protectedKey &&
          savedAt != null &&
          savedAt.isBefore(threshold);
      if (isExpired) {
        evictions.add((entry: entry, dropReason: _quarantineExpiredDropReason));
      } else {
        retained.add(entry);
      }
    }

    final maxCount = config.quarantineMaxCount;
    final maxBytes = config.quarantineMaxBytes;
    var remainingCount = retained.length;
    var remainingBytes = maxBytes > 0
        ? retained.fold<int>(
            0,
            (sum, entry) => sum + _estimateQuarantinedSize(entry.data),
          )
        : 0;
    for (final entry in retained) {
      final overCount = maxCount > 0 && remainingCount > maxCount;
      final overBytes = maxBytes > 0 && remainingBytes > maxBytes;
      if (!overCount && !overBytes) {
        break;
      }
      if (entry.key == protectedKey) {
        continue;
      }

      evictions.add((entry: entry, dropReason: _quarantineLimitDropReason));
      remainingCount--;
      if (maxBytes > 0) {
        remainingBytes -= _estimateQuarantinedSize(entry.data);
      }
    }

    if (evictions.isNotEmpty) {
      await _evictQuarantinedRequests(box, evictions);
    }
  }

  /// 隔離の記録をまとめてドロップ履歴へ記録してから取り除き、イベントで知らせます。
  ///
  /// 履歴のロックを 1 回だけ取ってまとめて記録し、履歴の保持上限の判定も
  /// 1 回にします。
  ///
  /// [box] 隔離の暗号化 Box。
  /// [evictions] 取り除く記録と、履歴に残す理由。
  Future<void> _evictQuarantinedRequests(
    Box box,
    List<_QuarantineEviction> evictions,
  ) async {
    final recorded = await _recordDroppedRequests([
      for (final eviction in evictions)
        (
          data: eviction.entry.data,
          statusCode: eviction.entry.data['statusCode'] as int? ?? 0,
          dropReason: eviction.dropReason,
          errorMessage: eviction.entry.data['errorMessage'] as String? ?? '',
        ),
    ]);
    if (!recorded) {
      // 履歴へ記録できない場合は、記録の無い削除を避けるため取り除かない
      return;
    }

    await box.deleteAll(evictions.map((eviction) => eviction.entry.key));
    for (final eviction in evictions) {
      final data = eviction.entry.data;
      _emitEvent(ProxyEventType.requestDropped, data['url'] as String? ?? '', {
        'statusCode': data['statusCode'] as int? ?? 0,
        'dropReason': eviction.dropReason,
        'quarantineId': eviction.entry.key,
      });
    }
  }

  /// ドロップ履歴の保持上限（期間・件数）を超えた分を取り除きます。
  /// 履歴のロックの中で呼びます。
  ///
  /// 期間は確認済みかどうかを問わず適用し、件数は確認済みの古いものから
  /// 取り除きます。未確認の履歴は件数では取り除きません。
  ///
  /// [box] ドロップ履歴の暗号化 Box。
  Future<void> _enforceDroppedRequestLimits(Box box) async {
    final config = _config;
    if (config == null) {
      return;
    }

    final entries = _sortedEncryptedEntries(
      ProxyStorageBox.droppedRequests,
      box,
      'droppedAt',
    );
    final keysToDelete = <String>[];
    final retained = <StoredEntry>[];

    final retention = config.droppedRequestRetention;
    final threshold =
        retention > Duration.zero ? DateTime.now().subtract(retention) : null;
    for (final entry in entries) {
      final savedAt = entry.savedAt;
      if (threshold != null && savedAt != null && savedAt.isBefore(threshold)) {
        keysToDelete.add(entry.key);
      } else {
        retained.add(entry);
      }
    }

    final maxCount = config.droppedRequestMaxCount;
    var excess = maxCount > 0 ? retained.length - maxCount : 0;
    for (final entry in retained) {
      if (excess <= 0) {
        break;
      }
      if (entry.data['acknowledged'] != true) {
        continue;
      }
      keysToDelete.add(entry.key);
      excess--;
    }

    if (keysToDelete.isEmpty) {
      return;
    }
    await box.deleteAll(keysToDelete);
    _unacknowledgedDroppedCount = null;
  }

  /// 隔離する記録の大きさを、本文とヘッダの名前・値から概算します。
  ///
  /// [data] 隔離する記録。
  ///
  /// Returns: 概算のバイト数。
  int _estimateQuarantinedSize(Map data) {
    var size = 0;
    final body = data['body'];
    if (body is List) {
      size += body.length;
    }

    final headers = data['headers'];
    if (headers is Map) {
      for (final header in headers.entries) {
        size += header.key.toString().length + header.value.toString().length;
      }
    }
    return size;
  }

  /// 一覧で返すヘッダのうち、機密情報を含み得るものの値をマスクします。
  ///
  /// 名前を小文字にして `_` を `-` とみなし、[_sensitiveHeaderNames] と一致するか、
  /// [_sensitiveHeaderNameFragments] のいずれかを含む場合にマスクします。
  /// 設定されたべき等性キーのヘッダはマスクしません。
  ///
  /// [headers] 保存されているヘッダ。
  ///
  /// Returns: マスクしたヘッダ。
  Map<String, String> _maskSensitiveHeaders(Map<String, String> headers) {
    final idempotencyHeaderName = _normalizeHeaderNameForMasking(
      _config?.idempotencyHeaderName ?? _defaultIdempotencyHeaderName,
    );

    return headers.map((name, value) {
      final normalizedName = _normalizeHeaderNameForMasking(name);
      if (normalizedName == idempotencyHeaderName) {
        return MapEntry(name, value);
      }

      final isSensitive = _sensitiveHeaderNames.contains(normalizedName) ||
          _sensitiveHeaderNameFragments.any(normalizedName.contains);
      return MapEntry(name, isSensitive ? _maskedHeaderValue : value);
    });
  }

  /// マスクの判定に使うため、ヘッダ名を小文字にして `_` を `-` にそろえます。
  ///
  /// [name] ヘッダ名。
  ///
  /// Returns: 判定用の名前。
  String _normalizeHeaderNameForMasking(String name) {
    return name.toLowerCase().replaceAll('_', '-');
  }

  /// 復旧 API の本体です。初期化のロックを保持したまま実行します。
  ///
  /// ロックは再入できないため、ここから `_ensure` で始まる関数を呼んではいけません。
  ///
  /// Returns: 復旧の結果。
  Future<EncryptedStorageRecoveryResult> _runStorageRecovery() async {
    // ロックを待つ間に起動が始まった場合は、開いた Box を消さないよう何もしない
    if (_activeInstances.isNotEmpty) {
      return const EncryptedStorageRecoveryResult.rejected(
        StorageRecoveryRejection.proxyActive,
      );
    }

    if (!Hive.isAdapterRegistered(0)) {
      await Hive.initFlutter();
    }

    final portPreferenceBox = await Hive.openBox(_portPreferenceBoxName);
    _portPreferenceBox = portPreferenceBox;
    final directoryPath = _resolveHiveDirectoryPath(portPreferenceBox);

    // 起動時と同じ、時間の上限ありの照合で判定する
    final inspection = await inspectEncryptedStorage(
      directoryPath: directoryPath,
      boxNames: _encryptedBoxNames,
      keyReader: _encryptionKeyReader,
      scanTimeLimit: _storageTestHooks?.verificationTimeLimit ??
          _defaultStorageVerificationTimeLimit,
    );

    switch (inspection.keyRead.state) {
      case EncryptionKeyState.temporarilyUnavailable:
        return const EncryptedStorageRecoveryResult.rejected(
          StorageRecoveryRejection.temporarilyUnavailable,
        );
      case EncryptionKeyState.present:
        return _recoverEncryptedBoxesWithKey(directoryPath, inspection);
      case EncryptionKeyState.missing:
      case EncryptionKeyState.unreadable:
      case EncryptionKeyState.invalid:
        return _recoverEncryptedBoxesWithoutKey(directoryPath, inspection);
    }
  }

  /// 鍵を読めた場合の復旧です。鍵を残し、問題のある Box を Box ごとに扱います。
  ///
  /// Box を閉じた後は、途中で失敗しても共有していた初期化の結果を捨てて保存領域の
  /// 世代を進めます。ファイルが一部変わった状態を、他のインスタンスが古い状態の
  /// まま使い続けないためです。
  ///
  /// [directoryPath] Hive の保存先ディレクトリ。
  /// [inspection] 暗号化 Box の照合結果。
  ///
  /// Returns: 復旧の結果。
  Future<EncryptedStorageRecoveryResult> _recoverEncryptedBoxesWithKey(
    String directoryPath,
    StorageInspection inspection,
  ) async {
    final hasBusinessProblem = _encryptedBoxNames.keys.any((box) =>
        box != ProxyStorageBox.cookies &&
        failureForCheckResult(
              inspection.results[box] ?? StorageBoxCheckResult.empty,
            ) !=
            null);
    if (!hasBusinessProblem) {
      return const EncryptedStorageRecoveryResult.rejected(
        StorageRecoveryRejection.startWillSucceed,
      );
    }

    // 照合の間に始まった起動は、段階 2 の結果を使う前にこのロックを通って Box と
    // 保存領域の世代を確かめ直す（_ensureDataStage）。復旧の後に段階 1 から
    // やり直すため、利用者が同意した復旧を無駄にしないよう拒否せずに進める

    try {
      await _closeAllProxyBoxes();

      // Box を閉じた後のファイルで照合し直してから扱いを決める。照合を打ち切った
      // Box は時間の上限を設けずに走査し、作り直す位置も閉じた後のファイルから求める
      final keyCrc = hiveKeyCrc(inspection.keyRead.key!);
      final results =
          Map<ProxyStorageBox, StorageBoxCheckResult>.of(inspection.results);
      final offsets = <ProxyStorageBox, int>{};
      final rescannedBoxes = <ProxyStorageBox>{};
      for (final entry in _encryptedBoxNames.entries) {
        final initialResult = results[entry.key];
        if (initialResult != StorageBoxCheckResult.aborted &&
            initialResult != StorageBoxCheckResult.corrupted) {
          continue;
        }

        final verification = await verifyEncryptedBox(
          directoryPath: directoryPath,
          box: entry.key,
          boxName: entry.value,
          keyCrc: keyCrc,
          scanTimeLimit: null,
        );
        results[entry.key] = checkResultForVerification(verification.status);
        final offset = verification.matchingFrameOffset;
        if (offset != null) {
          offsets[entry.key] = offset;
        }
        if (initialResult == StorageBoxCheckResult.aborted) {
          rescannedBoxes.add(entry.key);
        }
      }

      final deletedBoxes = <ProxyStorageBox>{};
      final rebuiltBoxes = <ProxyStorageBox>{};
      final keptBoxes = <ProxyStorageBox>{};
      for (final entry in _encryptedBoxNames.entries) {
        final box = entry.key;
        final boxName = entry.value;
        switch (results[box]) {
          case StorageBoxCheckResult.mismatch:
            await Hive.deleteBoxFromDisk(boxName, path: directoryPath);
            deletedBoxes.add(box);
          case StorageBoxCheckResult.corrupted:
            await rebuildHiveBoxFromOffset(
              directoryPath,
              boxName,
              offsets[box]!,
            );
            rebuiltBoxes.add(box);
          case StorageBoxCheckResult.noMismatch
              when rescannedBoxes.contains(box):
            // 鍵と一致する記録が無く、開けば Hive も同じく切り詰めるため失うものは無い。
            // 残すと、再試行した start() が再び照合打ち切りで失敗し続ける
            await truncateHiveBox(directoryPath, boxName);
            rebuiltBoxes.add(box);
          default:
            // 中身の無い Box は「残した」とは扱わない
            if (inspection.contents[box] == true) {
              keptBoxes.add(box);
            }
        }
      }

      await _deleteLeftoverCompactionFiles(directoryPath);
      return EncryptedStorageRecoveryResult(
        performed: true,
        deletedBoxes: deletedBoxes,
        rebuiltBoxes: rebuiltBoxes,
        keptBoxes: keptBoxes,
      );
    } finally {
      _resetStorageStateAfterRecovery();
    }
  }

  /// 使える鍵が無い状態が続く場合の復旧です。暗号化 Box をすべて削除してから
  /// 鍵を削除します。
  ///
  /// Box を閉じた後は、途中で失敗しても共有していた初期化の結果を捨てて保存領域の
  /// 世代を進めます。
  ///
  /// [directoryPath] Hive の保存先ディレクトリ。
  /// [inspection] 暗号化 Box の照合結果。
  ///
  /// Returns: 復旧の結果。
  Future<EncryptedStorageRecoveryResult> _recoverEncryptedBoxesWithoutKey(
    String directoryPath,
    StorageInspection inspection,
  ) async {
    // Cookie Box だけに中身がある場合は、start() が破棄して続けるため消さない
    if (!inspection.hasBusinessContent) {
      return const EncryptedStorageRecoveryResult.rejected(
        StorageRecoveryRejection.startWillSucceed,
      );
    }

    // 照合の間に始まった起動は、段階 2 の結果を使う前にこのロックを通って Box と
    // 保存領域の世代を確かめ直す（_ensureDataStage）。復旧の後に段階 1 から
    // やり直すため、利用者が同意した復旧を無駄にしないよう拒否せずに進める

    try {
      await _closeAllProxyBoxes();

      final deletedBoxes = <ProxyStorageBox>{};
      for (final entry in _encryptedBoxNames.entries) {
        if (findHiveBoxFile(directoryPath, entry.value) != null) {
          deletedBoxes.add(entry.key);
        }
        await Hive.deleteBoxFromDisk(entry.value, path: directoryPath);
      }
      // 暗号化 Box を消し終えてから鍵を消し、鍵だけが無い状態を作らない
      await _keyStorage.delete(_cookieEncryptionKeyStorageKey);

      await _deleteLeftoverCompactionFiles(directoryPath);
      return EncryptedStorageRecoveryResult(
        performed: true,
        deletedBoxes: deletedBoxes,
        keyDeleted: true,
      );
    } finally {
      _resetStorageStateAfterRecovery();
    }
  }

  /// 削除や作り直しの前に、proxy の Box をすべて閉じてフィールドを `null` に戻します。
  ///
  /// 別のインスタンスが開いている暗号化 Box も、ファイルを置き換える前に閉じます。
  /// 閉じる処理は実行中の自動圧縮の終了を待ちます。
  Future<void> _closeAllProxyBoxes() async {
    final boxes = <Box?>[
      _cacheBox,
      _queueBox,
      _cookieBox,
      _portPreferenceBox,
      _webStorageBox,
      _idempotencyBox,
      _droppedRequestBox,
      _quarantinedRequestBox,
      _legacyQueueBox,
      _legacyQuarantineBox,
      _legacyDroppedRequestBox,
    ];
    for (final box in boxes) {
      if (box != null && box.isOpen) {
        await box.close();
      }
    }

    for (final boxName in _encryptedBoxNames.values) {
      if (Hive.isBoxOpen(boxName)) {
        await Hive.box(boxName).close();
      }
    }

    _cacheBox = null;
    _queueBox = null;
    _cookieBox = null;
    _portPreferenceBox = null;
    _webStorageBox = null;
    _idempotencyBox = null;
    _droppedRequestBox = null;
    _quarantinedRequestBox = null;
    _legacyQueueBox = null;
    _legacyQuarantineBox = null;
    _legacyDroppedRequestBox = null;
  }

  /// `.hive` がある暗号化 Box に残った `.hivec` を削除します。
  ///
  /// 作り直しの置き換えの前に落ちた場合の残骸です。開いている Box の自動圧縮も
  /// `.hivec` を使うため、Box をすべて閉じた後に呼びます。
  ///
  /// [directoryPath] Hive の保存先ディレクトリ。
  Future<void> _deleteLeftoverCompactionFiles(String directoryPath) async {
    for (final boxName in _encryptedBoxNames.values) {
      final hiveFile =
          File('$directoryPath${Platform.pathSeparator}$boxName.hive');
      final compactedFile =
          File('$directoryPath${Platform.pathSeparator}$boxName.hivec');
      if (await hiveFile.exists() && await compactedFile.exists()) {
        await compactedFile.delete();
      }
    }
  }

  /// 復旧の後、プロセスを再起動せずに `start()` できるよう、共有していた
  /// 初期化の結果を捨てます。
  ///
  /// ロックを待っている実行中の段階は、その実行で改めて照合するため残します。
  void _resetStorageStateAfterRecovery() {
    if (_keyStageCompleted) {
      _keyStageFuture = null;
      _keyStageCompleted = false;
    }
    if (_dataStageCompleted) {
      _dataStageFuture = null;
      _dataStageCompleted = false;
    }
    _storageEncryptionKey = null;
    _hiveDirectoryPath = null;
    _pendingLegacyKeys.clear();
    // 復旧前の件数を返さないよう、未確認件数のキャッシュを捨てる
    _unacknowledgedDroppedCount = null;
    _keyStageGeneration = null;
    // 別のインスタンスが古い鍵のまま段階 2 を進めないよう、保存領域の世代を進める
    _storageGeneration++;
  }

  /// サーバ起動時に使用するポートを解決します。
  ///
  /// 優先ポートが指定されている場合はまずそちらを試し、失敗時は自動割当にフォールバックします。
  /// 直前の成功ポートが記録されている場合は、それも優先的に試します。
  Future<HttpServer> _bindServer(
    shelf.Handler handler, {
    int? priorPort,
  }) async {
    final candidates = <int>{};

    if (_config!.port > 0) {
      candidates.add(_config!.port);
    } else {
      // 再バインドでは WebView が保持しているポートの維持を最優先にする
      if (priorPort != null && priorPort > 0) {
        candidates.add(priorPort);
      }

      if (_config!.preferredPort > 0) {
        candidates.add(_config!.preferredPort);
      }

      final persistedPort = await _loadPersistedPortForHost(_config!.host);
      if (persistedPort != null && persistedPort > 0) {
        candidates.add(persistedPort);
      }

      candidates.add(0);
    }

    final attemptedPorts = candidates.toList(growable: false);
    PortBindException? lastBindFailure;

    for (final port in attemptedPorts) {
      try {
        final server = await shelf_io.serve(
          handler,
          _config!.host,
          port,
        );
        await _persistBoundPort(server.port);
        return server;
      } on SocketException catch (e) {
        lastBindFailure = PortBindException(port, e.message);
        if (port == 0 || _config!.port > 0) {
          throw lastBindFailure;
        }
      } on OSError catch (e) {
        lastBindFailure = PortBindException(port, e.message);
        if (port == 0 || _config!.port > 0) {
          throw lastBindFailure;
        }
      }
    }

    if (lastBindFailure != null) {
      throw lastBindFailure;
    }

    throw ProxyStartException(
        'Failed to bind proxy server to any candidate port', null);
  }

  /// 指定されたホストに対して、直前に成功したポートを読み込みます。
  Future<int?> _loadPersistedPortForHost(String host) async {
    if (_portPreferenceBox == null || !_portPreferenceBox!.isOpen) {
      return null;
    }

    final storageKey = _portPreferenceStorageKey(host);
    final persistedValue = _portPreferenceBox!.get(storageKey);
    if (persistedValue is int) {
      return persistedValue;
    }
    if (persistedValue is String) {
      final parsedPort = int.tryParse(persistedValue);
      if (parsedPort != null && parsedPort > 0) {
        return parsedPort;
      }
    }
    return null;
  }

  /// 指定されたホストに対して、直前に成功したポートを保存します。
  Future<void> _persistBoundPort(int port) async {
    if (_portPreferenceBox == null || !_portPreferenceBox!.isOpen) {
      return;
    }

    await _portPreferenceBox!
        .put(_portPreferenceStorageKey(_config!.host), port);
  }

  /// ホストごとの永続化キーを生成します。
  String _portPreferenceStorageKey(String host) => 'host:$host';

  /// Cookie 用ストレージを必要時に初期化します。
  ///
  /// 保存領域の初期化の段階 1 を待ちます。Cookie を読み書きする処理（Cookie API、
  /// 上流への転送・キュー再送・ウォームアップ）から呼ばれます。`start()` も
  /// 段階 2 の前に同じ段階 1 を待つため、同時に呼ばれても鍵の生成と Box の
  /// オープンが重ならないようにします。失敗した場合は、次の呼び出しで再試行します。
  ///
  /// Returns: 利用可能な Cookie Box。
  Future<Box> _ensureCookieStorageInitialized() async {
    final cookieBox = _cookieBox;
    if (_keyStageCompleted &&
        _keyStageGeneration == _storageGeneration &&
        cookieBox != null &&
        cookieBox.isOpen) {
      return cookieBox;
    }

    return _ensureKeyStage();
  }

  /// 保存領域の初期化の段階 1（鍵と Cookie Box）を実行します。
  ///
  /// 実行中または完了済みの段階 1 があればその結果を共有します。完了後に
  /// Cookie Box かポート設定 Box が閉じられていた場合と、復旧 API が保存領域を
  /// 変えていた場合（別のインスタンスの復旧を含む）は、改めて実行します。
  /// 失敗した場合は共有する結果を捨て、次の呼び出しで再試行できるようにします。
  /// 失敗は、待っている呼び出しそれぞれの zone で投げ直します。
  ///
  /// Returns: 段階 1 で開いた Cookie Box。
  Future<Box> _ensureKeyStage() async {
    final current = _keyStageFuture;
    final isStale = _keyStageCompleted &&
        (_keyStageGeneration != _storageGeneration ||
            [_cookieBox, _portPreferenceBox]
                .any((box) => box == null || !box.isOpen));
    if (current != null && !isStale) {
      return (await current).unwrap();
    }

    late final Future<_StageOutcome<Box>> stage;
    stage = _storageInitializationLock.synchronized(() async {
      try {
        final box = await _runKeyStage();
        if (identical(_keyStageFuture, stage)) {
          _keyStageCompleted = true;
        }
        return _StageOutcome<Box>.success(box);
      } catch (error, stackTrace) {
        if (identical(_keyStageFuture, stage)) {
          _keyStageFuture = null;
        }
        return _StageOutcome<Box>.failure(error, stackTrace);
      }
    });
    _keyStageFuture = stage;
    _keyStageCompleted = false;
    return (await stage).unwrap();
  }

  /// 段階 1 の本体です。
  ///
  /// ポート設定 Box を開いて Hive の保存先を特定し、暗号化 Box を開かずに
  /// secure storage の鍵と照合して、判定表に従います（Hive は鍵が合わない Box を
  /// 開くと中身を切り詰めるため）。そのうえで Cookie Box を開き、旧平文
  /// Cookie Box を移行します。
  ///
  /// 失敗した場合は、この呼び出しで開いた Box を閉じ、フィールドを `null` に
  /// 戻してから例外を送出します。
  ///
  /// 初期化のロックを保持したまま実行されます。ロックは再入できないため、
  /// ここから `_ensure` で始まる関数や Cookie を保存する関数を呼んではいけません。
  ///
  /// Returns: 開いた Cookie Box。
  ///
  /// Throws:
  ///   * [StorageIntegrityException] 判定表で起動失敗となった場合。
  Future<Box> _runKeyStage() async {
    if (!Hive.isAdapterRegistered(0)) {
      await Hive.initFlutter();
    }

    final openedBoxes = <Box>[];
    try {
      final portPreferenceBox =
          await _openBoxTracked(_portPreferenceBoxName, openedBoxes);
      _portPreferenceBox = portPreferenceBox;
      final directoryPath = _resolveHiveDirectoryPath(portPreferenceBox);

      final inspection = await inspectEncryptedStorage(
        directoryPath: directoryPath,
        boxNames: _encryptedBoxNames,
        keyReader: _encryptionKeyReader,
        scanTimeLimit: _storageTestHooks?.verificationTimeLimit ??
            _defaultStorageVerificationTimeLimit,
      );
      final decision = decideStorageIntegrity(inspection);

      final Uint8List encryptionKey;
      switch (decision.action) {
        case StorageIntegrityAction.fail:
          throw _buildStorageIntegrityException(decision.failure!, inspection);
        case StorageIntegrityAction.open:
          encryptionKey = inspection.keyRead.key!;
        case StorageIntegrityAction.regenerateKey:
          encryptionKey = await _writeNewEncryptionKey(inspection);
        case StorageIntegrityAction.discardCookies:
          encryptionKey = inspection.keyRead.key!;
          await _discardCookieStorage(directoryPath, decision.failure!);
        case StorageIntegrityAction.discardCookiesAndRegenerateKey:
          // 書き込みに失敗した場合に何も消さないよう、鍵を先に書く
          encryptionKey = await _writeNewEncryptionKey(inspection);
          await _discardCookieStorage(directoryPath, decision.failure!);
      }

      final cookieBox = await _openBoxTracked(
        _encryptedCookieBoxName,
        openedBoxes,
        encryptionKey: encryptionKey,
      );
      await _migrateLegacyCookieBoxIfNeeded(cookieBox);

      _hiveDirectoryPath = directoryPath;
      _storageEncryptionKey = encryptionKey;
      _keyStageGeneration = _storageGeneration;
      _cookieBox = cookieBox;
      return cookieBox;
    } catch (_) {
      await _closeBoxesQuietly(openedBoxes);
      if (!(_portPreferenceBox?.isOpen ?? false)) {
        _portPreferenceBox = null;
      }
      _cookieBox = null;
      _storageEncryptionKey = null;
      rethrow;
    }
  }

  /// Box を開き、この呼び出しで新たに開いた場合は [openedBoxes] に加えます。
  ///
  /// 失敗時に閉じるのは、この呼び出しで新たに開いた Box だけにします。
  /// 他の処理やインスタンスが開いている Box を閉じないためです。
  ///
  /// [name] Box の名前。
  /// [openedBoxes] 新たに開いた Box を記録する一覧。失敗時に閉じるために使います。
  /// [encryptionKey] 暗号化 Box の場合の鍵。平文の Box では `null`。
  ///
  /// Returns: 開いた Box。既に開いている場合はその Box。
  Future<Box> _openBoxTracked(
    String name,
    List<Box> openedBoxes, {
    Uint8List? encryptionKey,
  }) async {
    final wasOpen = Hive.isBoxOpen(name);
    final box = await Hive.openBox(
      name,
      encryptionCipher:
          encryptionKey == null ? null : HiveAesCipher(encryptionKey),
    );
    if (!wasOpen) {
      openedBoxes.add(box);
    }
    return box;
  }

  /// 開いている Box のファイルの場所から、Hive の保存先ディレクトリを求めます。
  ///
  /// Hive の保存先は公開されておらず、アダプタ 0 が登録済みの場合は
  /// `initFlutter()` を呼ばないため、path_provider で求めた場所とずれ得ます。
  ///
  /// [box] 保存先にある、開いている Box。
  ///
  /// Returns: 保存先ディレクトリのパス。
  ///
  /// Throws:
  ///   * [StateError] Box のファイルの場所を取得できない場合。
  String _resolveHiveDirectoryPath(Box box) {
    final boxPath = box.path;
    if (boxPath == null) {
      throw StateError('Hive storage directory is not available');
    }
    return File(boxPath).parent.path;
  }

  /// 暗号化鍵を読み取るクラスを返します。
  EncryptionKeyReader get _encryptionKeyReader => EncryptionKeyReader(
        storage: _keyStorage,
        storageKey: _cookieEncryptionKeyStorageKey,
        rereadInterval:
            _storageTestHooks?.keyRereadInterval ?? _defaultKeyRereadInterval,
        rereadAttempts:
            _storageTestHooks?.keyRereadAttempts ?? _defaultKeyRereadAttempts,
      );

  /// 判定表で起動失敗となった場合の例外を組み立てます。
  ///
  /// [failure] 起動失敗の種別。
  /// [inspection] 暗号化 Box の照合結果。
  ///
  /// Returns: 種別と Box ごとの照合結果を持つ例外。
  StorageIntegrityException _buildStorageIntegrityException(
    StorageIntegrityFailure failure,
    StorageInspection inspection,
  ) {
    return StorageIntegrityException(
      'Encrypted storage cannot be used (${failure.name})',
      failure: failure,
      boxResults: Map.unmodifiable(inspection.results),
      error: inspection.keyRead.error,
    );
  }

  /// 新しい暗号化鍵を生成し、secure storage へ書き込みます。
  ///
  /// [inspection] 暗号化 Box の照合結果。書き込みに失敗した場合の例外に含めます。
  ///
  /// Returns: 書き込んだ鍵。
  ///
  /// Throws:
  ///   * [StorageIntegrityException] 書き込みに失敗した場合。
  Future<Uint8List> _writeNewEncryptionKey(StorageInspection inspection) async {
    final encryptionKey = _generateCookieEncryptionKey();
    try {
      await _keyStorage.write(
        _cookieEncryptionKeyStorageKey,
        base64Encode(encryptionKey),
      );
    } catch (error) {
      throw StorageIntegrityException(
        'Failed to write a new encryption key',
        failure: StorageIntegrityFailure.keyWriteFailed,
        boxResults: Map.unmodifiable(inspection.results),
        error: error,
      );
    }

    _encryptionKeyGeneratedStopwatch = Stopwatch()..start();
    // 別のインスタンスが古い鍵のまま段階 2 を進めないよう、保存領域の世代を進める
    _storageGeneration++;
    return encryptionKey;
  }

  /// 鍵と合わない Cookie の暗号化 Box を破棄し、イベントと診断情報で知らせます。
  ///
  /// イベントはブロードキャストのため、後から購読したアプリには届きません。
  /// 起動後は [getDiagnostics] で確認できます。
  ///
  /// [directoryPath] Hive の保存先ディレクトリ。
  /// [reason] 破棄する理由。
  Future<void> _discardCookieStorage(
    String directoryPath,
    StorageIntegrityFailure reason,
  ) async {
    await Hive.deleteBoxFromDisk(_encryptedCookieBoxName, path: directoryPath);
    _cookieBox = null;
    _lastCookieStorageDiscardedAt = DateTime.now();
    _lastCookieStorageDiscardReason = reason;
    _emitEvent(
      ProxyEventType.cookieStorageDiscarded,
      '',
      {'reason': reason.name},
    );
  }

  /// Cookie と業務データの暗号化に使う新しい AES-256 鍵を生成します。
  Uint8List _generateCookieEncryptionKey() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(
        _cookieEncryptionKeyLength,
        (_) => random.nextInt(256),
        growable: false,
      ),
    );
  }

  /// 既存の平文 Cookie Box を暗号化 Box へ一度だけ移行します。
  ///
  /// 暗号化 Box に同じ Cookie が既にある場合は、新しいセッションを古い値で
  /// 上書きしないよう書き写しません。移行に失敗した場合は平文 Box を継続利用せず、
  /// 例外を送出します。
  ///
  /// [encryptedCookieBox] 書き写し先の暗号化 Cookie Box。
  ///
  /// Throws:
  ///   * [CookieOperationException] 旧平文 Cookie Box を読めない、書き写せない、
  ///     または削除できなかった場合。元の例外が [Exception] なら cause に持ちます。
  Future<void> _migrateLegacyCookieBoxIfNeeded(Box encryptedCookieBox) async {
    if (!await Hive.boxExists(_legacyCookieBoxName)) {
      return;
    }

    Box? legacyCookieBox;
    try {
      legacyCookieBox = Hive.isBoxOpen(_legacyCookieBoxName)
          ? Hive.box(_legacyCookieBoxName)
          : await Hive.openBox(_legacyCookieBoxName);

      final now = DateTime.now().toUtc();
      final cookieRecords = <CookieRecord>[];
      for (final key in legacyCookieBox.keys) {
        final data = legacyCookieBox.get(key) as Map?;
        if (data == null) {
          continue;
        }

        final cookieRecord = CookieRecord.fromMap(data);
        if (!cookieRecord.isExpiredAt(now)) {
          cookieRecords.add(cookieRecord);
        }
      }

      for (final cookieRecord in cookieRecords) {
        if (encryptedCookieBox.containsKey(cookieRecord.storageKey)) {
          continue;
        }
        await encryptedCookieBox.put(
          cookieRecord.storageKey,
          cookieRecord.toMap(),
        );
      }
    } catch (e) {
      throw CookieOperationException(
        'migrateLegacy',
        'Failed to migrate legacy cookie box: $e',
        e is Exception ? e : null,
      );
    } finally {
      if (legacyCookieBox != null && legacyCookieBox.isOpen) {
        await legacyCookieBox.close();
      }
    }

    try {
      await Hive.deleteBoxFromDisk(_legacyCookieBoxName);
    } catch (e) {
      throw CookieOperationException(
        'migrateLegacy',
        'Failed to delete legacy cookie box: $e',
        e is Exception ? e : null,
      );
    }
  }

  /// ネットワーク接続状態の監視を開始します。
  ///
  /// オンライン/オフラインの切り替わりを検知し、
  /// オンライン復帰時にキューの消化を自動実行します。
  void _startConnectivityMonitoring() {
    _hasReceivedConnectivityEvent = false;
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((dynamic results) {
      _hasReceivedConnectivityEvent = true;
      _onlineDecisionSource = OnlineDecisionSource.linkLayer;

      final wasOnline = _isOnline;
      _isOnline = _resolveOnlineState(results);

      if (wasOnline != _isOnline) {
        _emitEvent(
          _isOnline
              ? ProxyEventType.networkOnline
              : ProxyEventType.networkOffline,
          '',
          {'connectivity': results.toString()},
        );

        if (_isOnline) {
          // リンク層が復帰した直後は状況が変わっている可能性が高いため即確認する
          if (_upstreamCircuitState != UpstreamCircuitState.closed) {
            _scheduleUpstreamProbe(immediate: true);
          }

          _drainQueue();
        } else {
          // リンク層が切れている間の復帰確認は無駄なため止める
          _upstreamProbeTimer?.cancel();
          _upstreamProbeTimer = null;
        }
      }
    });
  }

  /// 起動時のオンライン状態を実際の接続状態で初期化します。
  ///
  /// `onConnectivityChanged` は状態が変化したときしか通知しないため、
  /// 機内モードや圏外で起動した場合に初期値のままオンラインと誤判定します。
  /// これを防ぐため、起動時の接続状態を取得して初期値を確定します。
  ///
  /// 取得に時間がかかっても起動を止めないよう待ち時間の上限を設け、
  /// 取得できない場合は従来どおりオンラインとみなして実リクエストの結果に委ねます。
  Future<void> _initializeOnlineState() async {
    try {
      final results = await Connectivity()
          .checkConnectivity()
          .timeout(_initialConnectivityTimeout);

      // 取得を待つ間に変化イベントを受信していた場合は、より新しいイベントを優先する
      if (_hasReceivedConnectivityEvent) {
        return;
      }

      _isOnline = _resolveOnlineState(results);
      _onlineDecisionSource = OnlineDecisionSource.initial;
    } catch (e) {
      // 取得に失敗した場合も、変化イベントを受信済みならそちらを優先する
      if (_hasReceivedConnectivityEvent) {
        return;
      }

      // 取得できない環境では安全側に倒し、オンラインのまま起動を継続する
      _isOnline = true;
      _onlineDecisionSource = OnlineDecisionSource.initial;
    }
  }

  /// 接続状態の通知内容からオンラインかどうかを判定します。
  ///
  /// [results] `connectivity_plus` から受け取った接続状態。
  /// プラグインのバージョンによって [ConnectivityResult] または
  /// `List<ConnectivityResult>` のどちらかで渡されるため両方を受け付けます。
  ///
  /// Returns: オンラインと判定した場合は `true`。
  bool _resolveOnlineState(dynamic results) {
    return switch (results) {
      List list when list.isNotEmpty =>
        !list.every((r) => r == ConnectivityResult.none),
      ConnectivityResult result => result != ConnectivityResult.none,
      _ => true, // 不明な型や空の通知はフォールバックでオンラインと見なす（安全側）
    };
  }

  /// 上流へリクエストを転送できる状態かを返します。
  ///
  /// リンク層が接続済みで、かつ上流到達性のサーキットブレーカが遮断状態で
  /// ないことを条件にします。復帰確認中（halfOpen）は確認用の要求だけを
  /// 上流へ送り、通常のリクエストは待たせずにフォールバックへ回します。
  bool get _isUpstreamReachable =>
      _isOnline && _upstreamCircuitState == UpstreamCircuitState.closed;

  /// 上流到達性の判定に数えるべき失敗かを返します。
  ///
  /// 同時接続数の空き待ちによる失敗は proxy 側の混雑が原因であり、
  /// 上流の状態を表さないため除外します。
  ///
  /// [error] 発生した例外。
  ///
  /// Returns: 上流到達性の判定に数える場合は `true`。
  bool _shouldCountUpstreamFailure(Object error) {
    return _isUpstreamUnreachableError(error) &&
        error is! _UpstreamSlotTimeoutException;
  }

  /// 上流へ到達できたことを記録します。
  ///
  /// 上流がステータス行を返した時点で到達可能とみなすため、4xx や 5xx でも
  /// 成功として扱います。遮断中だった場合は遮断を解除します。
  void _recordUpstreamSuccess() {
    _lastUpstreamSuccessAt = DateTime.now();
    _consecutiveUpstreamFailures = 0;

    if (_upstreamCircuitState != UpstreamCircuitState.closed) {
      _closeUpstreamCircuit();
    }
  }

  /// 上流へ到達できなかったことを記録します。
  ///
  /// 連続失敗が [ProxyConfig.upstreamFailureThreshold] に達した場合は
  /// 遮断状態へ遷移し、以降のリクエストを待たせずにフォールバックへ回します。
  void _recordUpstreamFailure() {
    _consecutiveUpstreamFailures++;

    final threshold = _config?.upstreamFailureThreshold ?? 0;
    if (threshold <= 0 ||
        _upstreamCircuitState != UpstreamCircuitState.closed) {
      return;
    }

    if (_consecutiveUpstreamFailures >= threshold) {
      _openUpstreamCircuit();
    }
  }

  /// 上流到達性のサーキットブレーカを遮断状態にします。
  void _openUpstreamCircuit() {
    _upstreamCircuitState = UpstreamCircuitState.open;
    _upstreamProbeAttempts = 0;

    _emitEvent(ProxyEventType.upstreamCircuitOpened, '', {
      'consecutiveFailures': _consecutiveUpstreamFailures,
      'lastSuccessAt': _lastUpstreamSuccessAt?.toIso8601String(),
    });

    _scheduleUpstreamProbe();
  }

  /// 上流到達性のサーキットブレーカを通常状態へ戻します。
  void _closeUpstreamCircuit() {
    _upstreamProbeTimer?.cancel();
    _upstreamProbeTimer = null;
    _upstreamProbeAttempts = 0;
    _upstreamCircuitState = UpstreamCircuitState.closed;

    _emitEvent(ProxyEventType.upstreamCircuitClosed, '', {
      'lastSuccessAt': _lastUpstreamSuccessAt?.toIso8601String(),
    });

    // 遮断中に保留していた更新系リクエストを送信する
    // ignore: discarded_futures
    _drainQueue();
  }

  /// 上流到達性のサーキットブレーカの状態を初期化します。
  void _resetUpstreamCircuit() {
    _lastUpstreamSuccessAt = null;
    _upstreamProbeTimer?.cancel();
    _upstreamProbeTimer = null;
    _upstreamProbeAttempts = 0;
    _consecutiveUpstreamFailures = 0;
    _upstreamCircuitState = UpstreamCircuitState.closed;
  }

  /// 次回の復帰確認を予約します。
  ///
  /// [immediate] を `true` にすると待機せずに確認します。リンク層が復帰した
  /// 直後など、状況が変わった可能性が高い場合に使います。
  void _scheduleUpstreamProbe({bool immediate = false}) {
    _upstreamProbeTimer?.cancel();
    _upstreamProbeTimer = null;

    if (!_isRunning || _upstreamCircuitState == UpstreamCircuitState.closed) {
      return;
    }

    // リンク層が切れている間は確認しても失敗するため、復帰イベントを待つ
    if (!_isOnline) {
      return;
    }

    final delay =
        immediate ? Duration.zero : Duration(seconds: _upstreamProbeDelay);
    _upstreamProbeTimer = Timer(delay, () {
      // ignore: discarded_futures
      _probeUpstream();
    });
  }

  /// 現在の試行回数に対応する復帰確認の待機秒数を返します。
  int get _upstreamProbeDelay {
    final backoff = _config?.upstreamProbeBackoffSeconds;
    if (backoff == null || backoff.isEmpty) {
      return _defaultUpstreamProbeBackoffSeconds.last;
    }

    final index = _upstreamProbeAttempts;
    return index < backoff.length ? backoff[index] : backoff.last;
  }

  /// 上流の復帰を確認し、到達できた場合は遮断を解除します。
  Future<void> _probeUpstream() async {
    // 実行中（halfOpen）に再度呼ばれた場合は、確認が二重に走らないようにする
    if (!_isRunning || _upstreamCircuitState != UpstreamCircuitState.open) {
      return;
    }

    _upstreamCircuitState = UpstreamCircuitState.halfOpen;
    final reachable = await _sendUpstreamProbe();

    if (!_isRunning) {
      return;
    }

    if (reachable) {
      _recordUpstreamSuccess();
      return;
    }

    _upstreamCircuitState = UpstreamCircuitState.open;
    _upstreamProbeAttempts++;
    _scheduleUpstreamProbe();
  }

  /// 上流へ確認用の軽量リクエストを送ります。
  ///
  /// 死んだ keep-alive 接続を再利用しないよう、確認専用のクライアントを使います。
  ///
  /// Returns: 上流が応答した場合は `true`。ステータスコードは問いません。
  Future<bool> _sendUpstreamProbe() async {
    final config = _config;
    if (config == null || config.origin.isEmpty) {
      return false;
    }

    final timeout = config.upstreamProbeTimeout;
    // 本文は読み捨てるだけだが、自動解凍は共有クライアントと同じ扱いにそろえる
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false;
    try {
      final uri = _buildUpstreamUriFromParts(path: config.upstreamProbePath);
      final request = await client
          .openUrl(config.upstreamProbeMethod, uri)
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// HTTPリクエストルーティング用のRouterを作成します。
  ///
  /// 全てのHTTPメソッドとパスをキャッチし、
  /// _handleRequestメソッドに転送する設定を行います。
  ///
  /// Returns: 設定済みのRouterインスタンス。
  Router _createRouter() {
    final router = Router();

    // 稼働確認用のエンドポイント（GET / HEAD のみ、上流へは転送しない）
    router.add('GET', _healthCheckPath, _handleHealthCheck);
    router.add('HEAD', _healthCheckPath, _handleHealthCheck);

    // 状態通知用のエンドポイント（GET のみ、上流へは転送しない）
    final statusPath = _statusPath;
    if (statusPath.isNotEmpty) {
      router.add('GET', statusPath, _handleStatusRequest);
    }

    // 管理エンドポイントは既定で無効。有効時のみ登録する。
    if (_config?.enableAdminApi ?? false) {
      router.add(
          'GET', '$_adminPathPrefix/quarantine', _handleAdminQuarantineList);
      router.add('POST', '$_adminPathPrefix/quarantine/<id>/retry',
          _handleAdminQuarantineRetry);
      router.add('DELETE', '$_adminPathPrefix/quarantine/<id>',
          _handleAdminQuarantineDiscard);
    }

    // 全てのリクエストをプロキシするキャッチオールハンドラ
    router.all('/<path|.*>', _handleRequest);

    return router;
  }

  /// CORSヘッダを追加するミドルウェアを取得します。
  ///
  /// クロスオリジンリクエストを許可するためのヘッダを
  /// 全てのレスポンスに自動追加します。
  ///
  /// Returns: CORSヘッダ追加用ミドルウェア。
  shelf.Middleware get _corsMiddleware {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        final response = await innerHandler(request);

        // 内部エンドポイントは同一 origin 限定のため、全 origin へ開かない
        if (_isInternalEndpointRequest(request)) {
          return response;
        }

        return response.change(headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers':
              'Origin, Content-Type, Accept, Authorization',
          ...response.headers,
        });
      };
    };
  }

  /// グローバル例外ハンドリングミドルウェア
  ///
  /// ハンドラ内で未捕捉の例外が発生しても、コネクションを切断せずに
  /// 500レスポンスを返すことでクライアント側の `Connection closed before full header` を防ぎます。
  shelf.Middleware get _errorHandlingMiddleware {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        try {
          return await innerHandler(request);
        } catch (e) {
          return shelf.Response.internalServerError(
            body: 'Internal server error',
            headers: {
              'Content-Type': 'text/plain; charset=utf-8',
              // 再利用された接続で不完全なヘッダが見えるのを防ぐため
              // 接続を確実に閉じる。
              'Connection': 'close',
            },
          );
        }
      };
    };
  }

  /// リクエスト統計情報を収集するミドルウェアを取得します。
  ///
  /// 各リクエストの受信時に統計カウンタを更新し、
  /// イベントを発生させます。
  ///
  /// Returns: 統計情報収集用ミドルウェア。
  shelf.Middleware get _statisticsMiddleware {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        // proxy 内部のエンドポイントは統計にもイベントにも含めない
        if (_isInternalEndpointRequest(request)) {
          return innerHandler(request);
        }

        _totalRequests++;

        final proxyRequestUrl = request.requestedUri.toString();
        final resolution = _resolveNavigationTargetInternal(
          targetUrl: proxyRequestUrl,
        );

        _emitEvent(ProxyEventType.requestReceived, request.url.toString(), {
          'method': request.method,
          'userAgent': request.headers['user-agent'],
          'proxyRequestUrl': proxyRequestUrl,
          'resolvedUpstreamUrl': resolution.upstreamUri?.toString(),
          'resolvedProxyUrl': resolution.proxyUri?.toString(),
          'navigationDisposition': resolution.disposition.name,
          'navigationReason': resolution.reason.name,
          'usedLoopbackAlias': resolution.usedLoopbackAlias,
          'usedSourceUrl': resolution.usedSourceUrl,
          'isStaticResource': resolution.isStaticResource,
        });

        return await innerHandler(request);
      };
    };
  }

  /// HTTPリクエストを処理します。
  ///
  /// 静的リソース、オンライン/オフライン状態に応じて
  /// 適切なハンドラに振り分けます。
  ///
  /// [request] 処理するHTTPリクエスト。
  ///
  /// Returns: HTTPレスポンス。
  Future<shelf.Response> _handleRequest(shelf.Request request) async {
    final path = request.url.path.startsWith('/')
        ? request.url.path
        : '/${request.url.path}';

    if (_config?.enableWebStorageInheritance == true &&
        path.startsWith('/__offline_web_proxy/web_storage')) {
      return await _handleWebStorageBridgeRequest(request);
    }

    if (_isMirroredOriginPath(path)) {
      // 中継できない要求を設定済み origin へ回さない
      final rejection = _findMirroredOriginRejection(request, path);
      if (rejection != null) {
        return rejection;
      }
    } else if (_isStaticResourceServableMethod(request.method) &&
        await _isStaticResource(path)) {
      // 起動時に構築した静的リソース一覧を先に確認する。
      // GET と HEAD 以外は同名パスでも上流の処理が必要なため対象にしない。
      final staticResponse = await _serveStaticResource(request, path);
      if (staticResponse != null) {
        return staticResponse;
      }
      // 一覧にあってもアセットを読めない場合は 404 を返さず上流へ委ねる
    }

    // 接続状態と上流到達性に基づいて処理
    final response = _isUpstreamReachable
        ? await _handleOnlineRequest(request)
        : await _handleOfflineRequest(request);

    // オンラインとオフラインのどちらの経路でも同じ書き換えを通す
    return await _decorateResponseForMirroredOrigins(
      request: request,
      response: response,
    );
  }

  /// ミラー中継の要求を受け付けられない理由を判定します。
  ///
  /// [request] 受信した要求。
  /// [path] 先頭を `/` に正規化したリクエストパス。
  ///
  /// Returns: 受け付けられない場合に返す応答。受け付ける場合は `null`。
  shelf.Response? _findMirroredOriginRejection(
    shelf.Request request,
    String path,
  ) {
    if (!_isStaticResourceServableMethod(request.method)) {
      // 別 origin は資源の配信だけを想定しており、更新系はキューにも載せない
      _emitEvent(ProxyEventType.errorOccurred, request.url.toString(), {
        'phase': 'mirroredOrigin',
        'error': 'method is not allowed',
        'method': request.method,
      });
      return shelf.Response(
        HttpStatus.methodNotAllowed,
        headers: {
          'Allow': 'GET, HEAD',
          'Cache-Control': 'no-store',
        },
      );
    }

    final upstreamUri = _tryResolveMirroredUpstreamUri(
      path: path,
      query: request.url.query,
    );
    if (upstreamUri == null) {
      // 許可していない origin への中継は、設定の誤りとして追跡できるようにする
      _emitEvent(ProxyEventType.errorOccurred, request.url.toString(), {
        'phase': 'mirroredOrigin',
        'error': 'origin is not allowed',
      });
      return shelf.Response(
        HttpStatus.notFound,
        headers: {'Cache-Control': 'no-store'},
      );
    }

    return null;
  }

  /// WebStorage 継承用のブリッジリクエストを処理します。
  Future<shelf.Response> _handleWebStorageBridgeRequest(
    shelf.Request request,
  ) async {
    if (!_isAllowedWebStorageBridgeRequest(request)) {
      return shelf.Response.forbidden('web storage bridge is not allowed');
    }

    if (request.method.toUpperCase() == 'POST') {
      try {
        final body = await _readMessageBytes(request.read());
        final decoded = jsonDecode(utf8.decode(body));
        if (decoded is Map) {
          await _persistWebStorageSnapshot(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {
        // malformed body is ignored and treated as no-op
      }
      return shelf.Response.ok('ok');
    }

    try {
      final snapshot = await _loadWebStorageSnapshot();
      return shelf.Response.ok(
        jsonEncode(snapshot),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
    } catch (_) {
      return shelf.Response.internalServerError(body: 'bridge failed');
    }
  }

  /// WebStorage bridge のリクエストが許可された origin から来ているかを確認します。
  bool _isAllowedWebStorageBridgeRequest(shelf.Request request) {
    final origin = request.headers['origin'];
    if (origin == null || origin.isEmpty) {
      return true;
    }

    final configuredOrigin = _config?.origin;
    if (configuredOrigin == null || configuredOrigin.isEmpty) {
      return false;
    }

    final configuredUri = Uri.tryParse(configuredOrigin);
    if (configuredUri == null) {
      return false;
    }

    final requestOriginUri = Uri.tryParse(origin);
    if (requestOriginUri == null) {
      return false;
    }

    return configuredUri.scheme == requestOriginUri.scheme &&
        configuredUri.host == requestOriginUri.host &&
        configuredUri.port == requestOriginUri.port;
  }

  /// WebStorage スナップショットを永続化します。
  Future<void> _persistWebStorageSnapshot(Map<String, dynamic> snapshot) async {
    if (_webStorageBox == null || !_webStorageBox!.isOpen) {
      return;
    }

    await _webStorageBox!.put('snapshot', snapshot);
  }

  /// WebStorage スナップショットを読み込みます。
  Future<Map<String, dynamic>> _loadWebStorageSnapshot() async {
    if (_webStorageBox == null || !_webStorageBox!.isOpen) {
      return {};
    }

    final saved = _webStorageBox!.get('snapshot');
    if (saved is Map) {
      return Map<String, dynamic>.from(saved);
    }
    return {};
  }

  /// 指定したパスが静的リソースかどうかを判定します。
  ///
  /// 起動時に構築した静的リソース一覧に一致するかどうかを返します。
  ///
  /// [path] チェックするパス。
  ///
  /// Returns: 静的リソースの場合は `true`。
  Future<bool> _isStaticResource(String path) async {
    return _isIndexedStaticResourcePath(path);
  }

  /// 静的リソースとして配信できるメソッドかどうかを返します。
  ///
  /// [method] 判定するHTTPメソッド。
  ///
  /// Returns: `GET` または `HEAD` の場合は `true`。
  bool _isStaticResourceServableMethod(String method) {
    final normalizedMethod = method.toUpperCase();
    return normalizedMethod == 'GET' || normalizedMethod == 'HEAD';
  }

  /// 同梱アセットを静的リソースとして配信します。
  ///
  /// 一覧に一致した URL に対して、`assets/static/` 配下のファイルを返します。
  /// アプリの更新でアセットが入れ替わるため、内容から算出した `ETag` を付けて
  /// 毎回検証させます。
  ///
  /// [request] 受信したHTTPリクエスト。
  /// [path] 配信するファイルのパス。
  ///
  /// Returns: 静的リソースのHTTPレスポンス。アセットを読み込めない場合は
  ///   `null` を返し、呼び出し側で上流への転送へ委ねます。
  Future<shelf.Response?> _serveStaticResource(
    shelf.Request request,
    String path,
  ) async {
    final assetKey =
        _staticResourceAssetMap[_normalizeStaticResourceRequestPath(path)];
    if (assetKey == null) {
      return null;
    }

    final Uint8List assetBytes;
    try {
      final assetData = await rootBundle.load(assetKey);
      assetBytes = assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      );
    } catch (_) {
      // 一覧に載っていても実体を読めない場合があるため、上流解決へ戻す
      return null;
    }

    final entityTag = _resolveStaticResourceEntityTag(assetKey, assetBytes);
    final headers = <String, String>{
      'X-Static-Resource': 'true',
      'ETag': entityTag,
      // アプリ更新で内容が変わるため、WebView 側にも毎回検証させる
      'Cache-Control': 'no-cache',
    };

    if (_matchesIfNoneMatch(request, entityTag)) {
      return shelf.Response.notModified(headers: headers);
    }

    final responseHeaders = <String, String>{
      'Content-Type': _getMimeType(path),
      ...headers,
    };

    if (request.method.toUpperCase() == 'HEAD') {
      return shelf.Response.ok(null, headers: responseHeaders);
    }

    return shelf.Response.ok(assetBytes, headers: responseHeaders);
  }

  /// 静的リソースの `ETag` を返します。
  ///
  /// 同梱アセットはプロセス実行中に変化しないため、初回に算出した値を
  /// asset key ごとに保持し、以降の要求ではハッシュを計算し直しません。
  ///
  /// [assetKey] アセットの識別子。
  /// [assetBytes] アセットのバイト列。
  ///
  /// Returns: 引用符で囲んだ `ETag` の値。
  String _resolveStaticResourceEntityTag(
      String assetKey, Uint8List assetBytes) {
    return _staticResourceEntityTags.putIfAbsent(assetKey, () {
      final digest = sha256.convert(assetBytes).toString();
      return '"${digest.substring(0, 16)}"';
    });
  }

  /// `If-None-Match` が指定の `ETag` に一致するかどうかを返します。
  ///
  /// [request] 受信したHTTPリクエスト。
  /// [entityTag] 比較対象の `ETag`。
  ///
  /// Returns: 一致する場合は `true`。
  bool _matchesIfNoneMatch(shelf.Request request, String entityTag) {
    final ifNoneMatch = request.headers['if-none-match'];
    if (ifNoneMatch == null || ifNoneMatch.isEmpty) {
      return false;
    }

    return ifNoneMatch
        .split(',')
        .map((value) => value.trim())
        .any((value) => value == entityTag || value == '*');
  }

  /// 応答 HTML 内のミラー対象 origin の URL を proxy 経路へ書き換えます。
  ///
  /// 保存時ではなく応答時に書き換えます。キャッシュには上流が返したバイト列を
  /// そのまま残せるため、オンラインとオフラインのどちらの経路でも同じ変換を
  /// 通せます。設定から origin を外せば、保存済みの応答も元の URL に戻ります。
  ///
  /// 本文は `latin1` で読み書きします。URL と対象タグは ASCII の範囲に収まる
  /// ため、文字コードが何であってもバイト列をそのまま保てます。
  ///
  /// [request] 受信した要求。
  /// [response] 返却しようとしている応答。
  ///
  /// Returns: 書き換え後の応答。対象外の場合は [response] をそのまま返します。
  Future<shelf.Response> _decorateResponseForMirroredOrigins({
    required shelf.Request request,
    required shelf.Response response,
  }) async {
    if (_mirroredOrigins.isEmpty) {
      return response;
    }

    // 本文を持たない応答には書き換える対象が無い
    if (response.statusCode != HttpStatus.ok ||
        request.method.toUpperCase() == 'HEAD') {
      return response;
    }

    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().contains('text/html')) {
      return response;
    }

    // 上流が identity を無視して圧縮した本文は解釈できない
    final contentEncoding =
        (response.headers['content-encoding'] ?? '').trim().toLowerCase();
    if (contentEncoding.isNotEmpty && contentEncoding != 'identity') {
      return response;
    }

    final baseUri = _tryBuildUpstreamUriFromPathAndQuery(
      path: request.url.path,
      query: request.url.query,
    );
    if (baseUri == null) {
      return response;
    }

    final Uint8List bodyBytes;
    try {
      bodyBytes = await _readMessageBytes(response.read());
    } catch (_) {
      // 本文を読めない応答は書き換えずに諦める
      return response;
    }

    final originalBody = latin1.decode(bodyBytes, allowInvalid: true);
    final rewrittenBody = _rewriteMirroredOriginReferences(
      originalBody,
      baseUri,
    );

    // 本文は既に読み終えているため、変換が無くても組み立て直す
    var responseBytes = bodyBytes;
    if (!identical(rewrittenBody, originalBody)) {
      try {
        responseBytes = Uint8List.fromList(latin1.encode(rewrittenBody));
      } catch (_) {
        responseBytes = bodyBytes;
      }
    }

    return response.change(
      body: responseBytes,
      headers: {
        ...response.headers,
        'Content-Length': responseBytes.length.toString(),
      },
    );
  }

  /// HTML 内のミラー対象 origin の参照 URL を proxy 経路へ書き換えます。
  ///
  /// 対象タグはウォームアップの参照抽出と同じです。書き換えた資源が
  /// `warmupCache(followReferences: true)` の対象から漏れないようにするため、
  /// 判定は共通の正規表現に寄せています。
  ///
  /// [html] 応答本文。
  /// [baseUri] 相対 URL の解決に使う upstream URI。
  ///
  /// Returns: 書き換え後の HTML。対象が無い場合は [html] をそのまま返します。
  String _rewriteMirroredOriginReferences(String html, Uri baseUri) {
    final buffer = StringBuffer();
    var copiedUpTo = 0;

    for (final tagMatch in _referenceTagPattern.allMatches(html)) {
      final tagName = (tagMatch.group(1) ?? '').toLowerCase();
      final attributes = tagMatch.group(2) ?? '';

      // canonical や alternate は資源ではなく別ページを指すため書き換えない
      if (tagName == 'link' && !_isResourceLinkTag(attributes)) {
        continue;
      }

      final rewrittenAttributes =
          _rewriteMirroredOriginAttributes(attributes, baseUri);
      if (rewrittenAttributes == attributes) {
        continue;
      }

      // 属性部は必ずタグ末尾の `>` の直前で終わるため、位置を逆算できる
      final attributesEnd = tagMatch.end - 1;
      final attributesStart = attributesEnd - attributes.length;
      buffer.write(html.substring(copiedUpTo, attributesStart));
      buffer.write(rewrittenAttributes);
      copiedUpTo = attributesEnd;
    }

    if (copiedUpTo == 0) {
      return html;
    }

    buffer.write(html.substring(copiedUpTo));
    return buffer.toString();
  }

  /// タグの属性部にある参照 URL を proxy 経路へ書き換えます。
  ///
  /// [attributes] タグの属性部。
  /// [baseUri] 相対 URL の解決に使う upstream URI。
  ///
  /// Returns: 書き換え後の属性部。
  String _rewriteMirroredOriginAttributes(String attributes, Uri baseUri) {
    return attributes.replaceAllMapped(_referenceUrlPattern, (match) {
      final matchedText = match[0]!;
      final rawUrl = match.group(1) ?? match.group(2) ?? match.group(3);
      if (rawUrl == null) {
        return matchedText;
      }

      final trimmedUrl = rawUrl.trim();
      if (trimmedUrl.isEmpty) {
        return matchedText;
      }

      final proxyPath = _tryBuildMirroredProxyPathForReference(
        trimmedUrl,
        baseUri,
      );
      if (proxyPath == null) {
        return matchedText;
      }

      // 引用符や空白の書き方を保つため、値の部分だけを差し替える
      final valueStart = matchedText.lastIndexOf(trimmedUrl);
      if (valueStart < 0) {
        return matchedText;
      }

      return matchedText.substring(0, valueStart) +
          proxyPath +
          matchedText.substring(valueStart + trimmedUrl.length);
    });
  }

  /// 参照 URL がミラー対象 origin を指す場合に proxy 経路のパスを返します。
  ///
  /// [rawUrl] HTML に書かれていた URL。
  /// [baseUri] 相対 URL の解決に使う upstream URI。
  ///
  /// Returns: proxy が受け付けるパス。対象外の場合は `null`。
  String? _tryBuildMirroredProxyPathForReference(String rawUrl, Uri baseUri) {
    if (_isNonFetchableReferenceUrl(rawUrl)) {
      return null;
    }

    final Uri resolvedUri;
    try {
      resolvedUri = baseUri.resolve(rawUrl);
    } catch (_) {
      return null;
    }

    // 設定済み origin は通常の proxy パスで届くため書き換えない
    if (_isSameOriginAsConfiguredOrigin(resolvedUri)) {
      return null;
    }

    return _buildMirroredProxyPath(resolvedUri);
  }

  /// HTMLレスポンスに WebStorage 継承用スクリプトを注入します。
  Future<shelf.Response> _decorateResponseForWebStorageInheritance({
    required shelf.Request request,
    required shelf.Response response,
  }) async {
    if (_config?.enableWebStorageInheritance != true) {
      return response;
    }

    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().contains('text/html')) {
      return response;
    }

    final responseBody = await response.readAsString();
    final script = '''
<script id="__offline_web_proxy_web_storage_bridge">
window.__offline_web_proxy_web_storage_bridge = {
  snapshotUrl: '/__offline_web_proxy/web_storage/snapshot'
};
</script>
''';

    var updatedBody = responseBody;
    if (updatedBody.contains('</body>')) {
      updatedBody = updatedBody.replaceFirst(
        '</body>',
        '$script</body>',
      );
    } else if (updatedBody.contains('</html>')) {
      updatedBody = updatedBody.replaceFirst(
        '</html>',
        '$script</html>',
      );
    } else {
      updatedBody = '$updatedBody$script';
    }

    return response.change(
      body: utf8.encode(updatedBody),
      headers: {
        ...response.headers,
        'Content-Length': utf8.encode(updatedBody).length.toString(),
      },
    );
  }

  /// リクエストから上流サーバのURLを構築します。
  String _buildUpstreamUrl(shelf.Request request) {
    return _buildUpstreamUriFromParts(
      path: request.url.path,
      query: request.url.query,
    ).toString();
  }

  /// オンライン時のHTTPリクエストを処理します。
  ///
  /// キャッシュ優先でレスポンスし、ミスの場合は上流サーバに転送。
  /// GETリクエストのレスポンスはキャッシュし、
  /// 非-GETリクエストは失敗時にキューに保存します。
  ///
  /// [request] 処理するHTTPリクエスト。
  ///
  /// Returns: HTTPレスポンス。
  Future<shelf.Response> _handleOnlineRequest(shelf.Request request) async {
    final upstreamUrl = _buildUpstreamUrl(request);
    final cacheKey = _generateCacheKey(upstreamUrl);

    // NOTE: read系以外は、失敗時のキュー保存や再送のためにボディを保持する必要がある。
    // shelf.Request のストリームは一度しか読めないため、ここで一度だけ読み取り
    // 上流転送とキュー保存で共有する。
    final Uint8List? requestBodyBytes = _isReadRequestMethod(request.method)
        ? null
        : await _readMessageBytes(request.read());

    // 転送とキュー再送で同じキーを使い、timeout 後の再送を上流が重複と判別できるようにする
    final ({String value, bool suppliedByClient})? idempotency =
        _isReadRequestMethod(request.method) ||
                !(_config?.enableIdempotencyKey ?? true)
            ? null
            : _resolveIdempotencyKey(request);

    // 初回転送と再送で同じ値を送り、オフラインで行った操作の発生時刻を伝える
    final String? acceptedAt =
        _isReadRequestMethod(request.method) ? null : _resolveAcceptedAt();

    // キューへ入れない規則は転送前に一度だけ判定し、各分岐で使い回す
    final QueueExcludeRule? queueExcludeRule =
        _isReadRequestMethod(request.method)
            ? null
            : _findQueueExcludeRule(request.method, request.url.path);

    // 上流サーバに転送
    try {
      final result = await _forwardToUpstream(
        request,
        requestBodyBytes: requestBodyBytes,
        idempotencyKey: idempotency?.value,
        acceptedAt: acceptedAt,
      );

      // 上流が応答した時点で到達可能と判定する（4xx / 5xx でもサーバは生きている）
      _recordUpstreamSuccess();

      final redirectResponse = _tryBuildHandledRedirectResponse(
        request: request,
        upstreamRequestUri: result.upstreamUri,
        statusCode: result.statusCode,
        headers: result.headers,
        bodyBytes: result.bodyBytes,
      );
      if (redirectResponse != null) {
        _cacheMisses++;
        return redirectResponse;
      }

      final response = shelf.Response(
        result.statusCode,
        body: Uint8List.fromList(result.bodyBytes),
        headers: result.headers,
      );
      final finalResponse = await _decorateResponseForWebStorageInheritance(
        request: request,
        response: response,
      );

      // GETレスポンスをキャッシュ
      if (request.method == 'GET') {
        // Range要求（206）やRange付きGETをキャッシュすると
        // 同一URLの通常GET(200)のキャッシュを壊す可能性があるため避ける。
        final hasRange =
            request.headers.keys.any((k) => k.toLowerCase() == 'range');
        if (!hasRange && result.statusCode == 200) {
          // 保存できなくても応答自体は成立しているため、
          // 失敗を転送処理へ伝播させず、受け取れている応答をそのまま返す
          try {
            await _cacheResponseBytes(
              cacheKey,
              result.statusCode,
              result.headers,
              result.bodyBytes,
              allowNoStore: _resolveForceCacheAllowance(
                path: request.url.path,
                requestHeaders: request.headers,
                responseHeaders: result.headers,
                eventUrl: request.url.toString(),
              ),
            );
          } catch (e) {
            _emitEvent(ProxyEventType.errorOccurred, request.url.toString(), {
              'phase': 'cacheResponse',
              'error': e.toString(),
            });
          }
        }
      }

      // read系以外のリクエストが失敗した場合はキューに保存。
      // 除外規則に一致する場合は保存だけを行わず、上流の応答をそのまま返す。
      String? queueId;
      if (!_isReadRequestMethod(request.method) &&
          result.statusCode >= 500 &&
          queueExcludeRule == null) {
        queueId = await _queueRequest(
          request,
          bodyBytes: requestBodyBytes,
          idempotency: idempotency,
          acceptedAt: acceptedAt,
        );
      }

      _cacheMisses++;
      // read系の 4xx/5xx は upstream 応答をそのまま返し、
      // キャッシュフォールバックは timeout 時だけに限定する。
      // ボディを含む新しいレスポンスを返す
      if (queueId == null) {
        return finalResponse;
      }

      // 応答は upstream のまま返しつつ、再送予定であることを伝える
      return finalResponse.change(headers: {
        'X-Offline-Queued': '1',
        'X-Offline-Queue-Id': queueId,
      });
    } catch (e) {
      if (_shouldCountUpstreamFailure(e)) {
        _recordUpstreamFailure();
      }

      // 上流へ到達できなかった read 系だけキャッシュフォールバックを許可
      if (_isReadRequestMethod(request.method) &&
          _isUpstreamUnreachableError(e)) {
        final cachedEntry = await _loadCachedFallbackEntry(cacheKey);
        if (cachedEntry != null &&
            _shouldServeCachedFallback(cachedEntry.status)) {
          _cacheHits++;
          _emitEvent(ProxyEventType.cacheStaleUsed, request.url.toString(), {});
          return _buildCachedReadResponse(
            request,
            cachedResponse: cachedEntry.response,
            rangeEntry: cachedEntry.rangeEntry,
          );
        }

        return _buildUpstreamUnreachableResponse(request);
      } else if (!_isReadRequestMethod(request.method)) {
        if (queueExcludeRule != null) {
          // 後から送っても意味が無い更新系は、成功に見せずその場で返す
          return _buildQueueExcludedResponse(queueExcludeRule);
        }

        final queueId = await _queueRequest(
          request,
          bodyBytes: requestBodyBytes,
          idempotency: idempotency,
          acceptedAt: acceptedAt,
        );
        return _buildQueuedResponse(queueId);
      }

      return shelf.Response.internalServerError(
          body: '上流サーバエラー', headers: {'Connection': 'close'});
    }
  }

  /// 締め切りまでの残り時間を返します。
  ///
  /// 1 リクエストの待ち時間が段階ごとに積み上がらないよう、各段階の
  /// タイムアウトに使います。
  ///
  /// [deadline] リクエスト全体の締め切り。
  ///
  /// Returns: 残り時間。既に超過している場合は [Duration.zero]。
  Duration _remainingUntil(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// 要求または応答の本文をバイト列として読み出します。
  ///
  /// 本文のストリームは一度しか読めないため、読み直しが必要な処理では
  /// 呼び出し側でバイト列を保持します。shelf は要求と応答の基底クラスを
  /// 公開していないため、ストリームを受け取ります。
  ///
  /// [body] 読み出す本文のストリーム。
  ///
  /// Returns: 本文のバイト列。
  Future<Uint8List> _readMessageBytes(Stream<List<int>> body) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// read系メソッドかどうかを判定します。
  bool _isReadRequestMethod(String method) {
    final normalizedMethod = method.toUpperCase();
    return normalizedMethod == 'GET' || normalizedMethod == 'HEAD';
  }

  /// 上流へ到達できなかった失敗かどうかを判定します。
  ///
  /// 接続拒否、名前解決失敗、接続中の切断、TLS ハンドシェイク失敗、
  /// 上流応答の解析失敗、request timeout の超過を対象とします。
  /// upstream がステータス行とヘッダを返し終えた応答（4xx / 5xx を含む）は
  /// 該当しません。
  ///
  /// [error] 上流リクエストで発生した例外。
  ///
  /// Returns: 上流へ到達できなかった場合は `true`。
  bool _isUpstreamUnreachableError(Object error) {
    return error is _UpstreamSlotTimeoutException ||
        error is TimeoutException ||
        error is SocketException ||
        error is HandshakeException ||
        error is HttpException ||
        error is http.ClientException;
  }

  /// フォールバックに利用可能なキャッシュエントリを読み込みます。
  Future<
      ({
        CacheStatus status,
        shelf.Response response,
        ({
          int statusCode,
          Map<String, String> headers,
          Uint8List bodyBytes,
        })? rangeEntry,
      })?> _loadCachedFallbackEntry(String cacheKey) async {
    final data = _cacheBox?.get(cacheKey) as Map?;
    if (data == null) {
      return null;
    }

    final response = _responseFromCacheData(data);
    if (response == null) {
      return null;
    }

    return (
      status: _determineStatus(data),
      response: response,
      rangeEntry: _cachedBytesEntryFromData(data),
    );
  }

  /// キャッシュ状態がフォールバック対象かどうかを返します。
  bool _shouldServeCachedFallback(CacheStatus status) =>
      status != CacheStatus.expired;

  /// 保存済みキャッシュから read系レスポンスを構築します。
  shelf.Response _buildCachedReadResponse(
    shelf.Request request, {
    required shelf.Response cachedResponse,
    required ({
      int statusCode,
      Map<String, String> headers,
      Uint8List bodyBytes,
    })? rangeEntry,
    Map<String, String>? extraHeaders,
  }) {
    if (request.method.toUpperCase() == 'HEAD') {
      return shelf.Response(
        cachedResponse.statusCode,
        headers: {
          if (extraHeaders != null) ...extraHeaders,
          ...cachedResponse.headers,
        },
      );
    }

    if (rangeEntry != null) {
      final rangeResponse = _tryBuildRangeResponseFromCache(
        request,
        cachedHeaders: rangeEntry.headers,
        cachedBodyBytes: rangeEntry.bodyBytes,
      );
      if (rangeResponse != null) {
        return extraHeaders == null
            ? rangeResponse
            : rangeResponse.change(headers: {
                ...extraHeaders,
                ...rangeResponse.headers,
              });
      }
    }

    return extraHeaders == null
        ? cachedResponse
        : cachedResponse.change(headers: {
            ...extraHeaders,
            ...cachedResponse.headers,
          });
  }

  /// 上流へ到達できずキャッシュも使えない場合のレスポンスを返します。
  ///
  /// ページ遷移には人が読める HTML を返し、`fetch` や画像などの部品要求には
  /// [ProxyConfig.offlineMissResponse] を返します。
  ///
  /// キャッシュを使えなかったことを Web アプリ側が判別できるよう、
  /// オフライン時と同じ `X-Offline-Source: none` を付与します。リンク層は
  /// 接続済みのため `X-Offline` は付与しません。
  ///
  /// [request] 対象のHTTPリクエスト。
  ///
  /// Returns: 504 応答。HEAD の場合は本文を持ちません。
  shelf.Response _buildUpstreamUnreachableResponse(shelf.Request request) {
    if (request.method.toUpperCase() == 'HEAD') {
      return shelf.Response(HttpStatus.gatewayTimeout, headers: {
        'X-Offline-Source': 'none',
        'Connection': 'close',
      });
    }

    if (!_isNavigationRequest(request)) {
      return _buildConfiguredResponse(
        _config?.offlineMissResponse ?? _defaultOfflineMissResponse,
        extraHeaders: {
          'X-Offline-Source': 'none',
          'Connection': 'close',
        },
      );
    }

    final options =
        _buildOfflineRecoveryOptions(OfflineRecoveryPageKind.gatewayTimeout);
    final customContent = _config?.gatewayTimeoutHtml;
    final body = customContent != null && customContent.isNotEmpty
        ? applyOfflineRecoveryPlaceholder(customContent, options)
        : buildDefaultOfflineRecoveryPage(options);

    return shelf.Response(
      HttpStatus.gatewayTimeout,
      body: body,
      headers: {
        // 文字列の本文だけでは octet-stream になり、WebView が画面として扱えない場合がある
        'Content-Type': 'text/html; charset=utf-8',
        // 履歴移動で WebView が保存済みのページを再表示しないようにする
        'Cache-Control': 'no-store',
        'X-Offline-Source': 'none',
        'Connection': 'close',
      },
    );
  }

  /// オフライン時にキャッシュが使えない場合のレスポンスを返します。
  ///
  /// ページ遷移には人が読める HTML のフォールバックページを返します。
  /// `fetch` や画像などの部品要求には [ProxyConfig.offlineMissResponse] を
  /// 返します。既定では 504 と JSON を返し、200 と HTML で「成功したが
  /// 解釈できない応答」になる状態を避けます。
  ///
  /// [request] 対象のHTTPリクエスト。
  ///
  /// Returns: オフライン時のフォールバック応答。
  shelf.Response _buildOfflineCacheMissResponse(shelf.Request request) {
    if (request.method.toUpperCase() == 'HEAD') {
      return shelf.Response(HttpStatus.gatewayTimeout, headers: {
        'X-Offline': '1',
        'X-Offline-Source': 'none',
      });
    }

    if (!_isNavigationRequest(request)) {
      return _buildConfiguredResponse(
        _config?.offlineMissResponse ?? _defaultOfflineMissResponse,
        extraHeaders: {
          'X-Offline': '1',
          'X-Offline-Source': 'none',
        },
      );
    }

    return shelf.Response.ok(
      _getOfflineFallbackContent(),
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        // 履歴移動で WebView が保存済みの代替ページを再表示しないようにする
        'Cache-Control': 'no-store',
        'X-Offline': '1',
        'X-Offline-Source': 'fallback',
      },
    );
  }

  /// キューへ保存したことを伝えるレスポンスを生成します。
  ///
  /// 応答内容は [ProxyConfig.queuedResponse] で差し替えられます。既定では
  /// `202 Accepted` と JSON を返し、上流が処理した結果ではないことを
  /// Web アプリ側が判別できるようにします。判別をヘッダだけで行えるよう、
  /// `X-Offline-Queued` と `X-Offline-Queue-Id` を常に付与します。
  ///
  /// クライアント側で脆弱な接続を開いたままにするのを避けるため、
  /// オンライン経路とオフライン経路のどちらでも接続を閉じます。
  ///
  /// [queueId] 保存したキューの ID。保存できなかった場合は `null`。
  ///
  /// Returns: キュー投入を伝えるレスポンス。保存できなかった場合は 503 応答。
  shelf.Response _buildQueuedResponse(String? queueId) {
    if (queueId == null) {
      // 保存できていない状態で成功に見せると、送信されないまま失われる
      return shelf.Response(
        HttpStatus.serviceUnavailable,
        body: '{"queued":false}',
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'X-Offline-Queued': '0',
          'Connection': 'close',
        },
      );
    }

    final config = _config?.queuedResponse ?? _defaultQueuedResponse;

    return shelf.Response(
      config.statusCode,
      body: config.body,
      headers: {
        'Content-Type': config.contentType,
        'X-Offline-Queued': '1',
        'X-Offline-Queue-Id': queueId,
        'Connection': 'close',
      },
    );
  }

  /// ページ遷移（ナビゲーション）の要求かどうかを判定します。
  ///
  /// ナビゲーションには人が読める HTML を返し、`fetch` や画像などの
  /// 部品要求には Web アプリが解釈できる応答を返すために使います。
  ///
  /// [request] 判定するHTTPリクエスト。
  ///
  /// Returns: ページ遷移の要求と判断した場合は `true`。
  bool _isNavigationRequest(shelf.Request request) {
    // 現行のブラウザエンジンは全リクエストへ Sec-Fetch-Mode を付与する
    final fetchMode = request.headers['sec-fetch-mode']?.trim().toLowerCase();
    if (fetchMode != null && fetchMode.isNotEmpty) {
      return fetchMode == 'navigate';
    }

    // 付与しない環境では Accept で判断する
    final accept = request.headers['accept']?.toLowerCase() ?? '';
    return accept.contains('text/html');
  }

  /// 自動生成する応答を組み立てます。
  ///
  /// [config] 応答内容の設定。
  /// [extraHeaders] 応答へ追加するヘッダ。
  ///
  /// Returns: 設定に従ったレスポンス。
  shelf.Response _buildConfiguredResponse(
    ProxyResponseConfig config, {
    Map<String, String> extraHeaders = const {},
  }) {
    return shelf.Response(
      config.statusCode,
      body: config.body,
      headers: {
        'Content-Type': config.contentType,
        ...extraHeaders,
      },
    );
  }

  /// オフライン時のHTTPリクエストを処理します。
  ///
  /// read系リクエストはキャッシュから配信し、ミスの場合はオフラインフォールバック。
  /// read系以外のリクエストはオンライン復帰時の再送用にキューに保存します。
  ///
  /// [request] 処理するHTTPリクエスト。
  ///
  /// Returns: HTTPレスポンス。
  Future<shelf.Response> _handleOfflineRequest(shelf.Request request) async {
    if (_isReadRequestMethod(request.method)) {
      final upstreamUrl = _buildUpstreamUrl(request);
      final cacheKey = _generateCacheKey(upstreamUrl);
      final cachedEntry = await _loadCachedFallbackEntry(cacheKey);

      if (cachedEntry != null &&
          _shouldServeCachedFallback(cachedEntry.status)) {
        _cacheHits++;
        _emitEvent(ProxyEventType.cacheHit, request.url.toString(), {});
        return _buildCachedReadResponse(
          request,
          cachedResponse: cachedEntry.response,
          rangeEntry: cachedEntry.rangeEntry,
          extraHeaders: {
            'X-Offline': '1',
            'X-Offline-Source': 'cache',
            'X-Cache-Status':
                cachedEntry.status == CacheStatus.stale ? 'stale' : 'hit',
          },
        );
      }

      // オフラインフォールバックを返却
      return _buildOfflineCacheMissResponse(request);
    } else {
      final excludeRule =
          _findQueueExcludeRule(request.method, request.url.path);
      if (excludeRule != null) {
        // 後から送っても意味が無い更新系は、成功に見せずその場で返す
        return _buildQueueExcludedResponse(excludeRule);
      }

      // read系以外のリクエストをキューに保存
      final queueId = await _queueRequest(request);
      _emitEvent(ProxyEventType.requestQueued, request.url.toString(), {
        'queueId': queueId,
      });

      return _buildQueuedResponse(queueId);
    }
  }

  /// URLからキャッシュキーを生成します。
  ///
  /// URLを正規化してからSHA-256 ハッシュ値を算出し、
  /// 固定長で安全なキャッシュキーを生成します。
  ///
  /// [url] キャッシュキーを生成するURL。
  ///
  /// Returns: SHA-256ハッシュ値の16進数文字列（64文字）。
  String _generateCacheKey(String url) {
    final normalized = _normalizeUrl(url);
    // 正規化されたURLのSHA-256ハッシュを生成
    final bytes = utf8.encode(normalized);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// URLを正規化します。
  ///
  /// 大文字小文字の統一、連続スラッシュの整理など、
  /// キャッシュキーの一意性を保つための正規化を行います。
  ///
  /// [url] 正規化するURL。
  ///
  /// Returns: 正規化されたURL。
  String _normalizeUrl(String url) {
    // 安全なURL正規化:
    // - スキームとホスト部分は小文字化
    // - パス内の連続するスラッシュは1つにまとめる
    // - クエリはそのまま保持
    try {
      final uri = Uri.parse(url);
      final scheme = uri.scheme.toLowerCase();
      final authority = uri.hasAuthority ? uri.authority.toLowerCase() : '';
      final path = uri.path.replaceAll(RegExp(r'/{2,}'), '/');
      final query = uri.hasQuery ? '?${uri.query}' : '';
      return '$scheme://$authority$path$query';
    } catch (e) {
      // パースできなければ大文字小文字のみ正規化して返す
      return url.toLowerCase();
    }
  }

  /// キャッシュデータからレスポンスを復元します。
  shelf.Response? _responseFromCacheData(Map data) {
    // キャッシュデータからレスポンスを再構築
    final statusCode = data['statusCode'] as int;
    final headers = Map<String, String>.from(data['headers'] as Map);
    final body = data['body'];

    // 互換性: 旧バージョンは body を String で保存していた
    if (body is String) {
      return shelf.Response(statusCode, body: body, headers: headers);
    }
    if (body is Uint8List) {
      return shelf.Response(statusCode, body: body, headers: headers);
    }
    if (body is List<int>) {
      return shelf.Response(
        statusCode,
        body: Uint8List.fromList(body),
        headers: headers,
      );
    }

    // 未知の形式はキャッシュ不一致扱い
    return null;
  }

  /// キャッシュデータから Range 用エントリを復元します。
  ({
    int statusCode,
    Map<String, String> headers,
    Uint8List bodyBytes,
  })? _cachedBytesEntryFromData(Map data) {
    final statusCode = data['statusCode'] as int;
    final headers = Map<String, String>.from(data['headers'] as Map);
    final body = data['body'];

    if (body is Uint8List) {
      return (statusCode: statusCode, headers: headers, bodyBytes: body);
    }
    if (body is List<int>) {
      return (
        statusCode: statusCode,
        headers: headers,
        bodyBytes: Uint8List.fromList(body),
      );
    }

    // 旧バージョンの String body は Range 対応対象外
    return null;
  }

  shelf.Response? _tryBuildRangeResponseFromCache(
    shelf.Request request, {
    required Map<String, String> cachedHeaders,
    required Uint8List cachedBodyBytes,
  }) {
    String? rangeValue;
    request.headers.forEach((k, v) {
      if (k.toLowerCase() == 'range') rangeValue = v;
    });
    final range = rangeValue;
    if (range == null || range.isEmpty) return null;

    // 仕様: bytes=<start>-<end> の単一Rangeのみサポート
    final m = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range.trim());
    if (m == null) return null;

    final start = int.tryParse(m.group(1) ?? '');
    final end = int.tryParse(m.group(2) ?? '');
    if (start == null || end == null) return null;

    final total = cachedBodyBytes.length;
    if (total == 0) return null;
    if (start < 0 || end < start || start >= total) {
      return shelf.Response(416, headers: {
        'Content-Range': 'bytes */$total',
        'Accept-Ranges': 'bytes',
      });
    }

    final safeEnd = end >= total ? total - 1 : end;
    final slice = cachedBodyBytes.sublist(start, safeEnd + 1);

    final headers = Map<String, String>.from(cachedHeaders);
    headers['Accept-Ranges'] = 'bytes';
    headers['Content-Range'] = 'bytes $start-$safeEnd/$total';
    headers.removeWhere((k, _) => k.toLowerCase() == 'content-length');
    headers.removeWhere((k, _) => k.toLowerCase() == 'transfer-encoding');

    return shelf.Response(
      206,
      body: Uint8List.fromList(slice),
      headers: headers,
    );
  }

  /// キャッシュが有効かどうかを判定します。
  ///
  /// TTL、Staleポリシー、Cache-Controlヘッダなどを
  /// 参照してキャッシュの有効性を判定します。
  Future<
      ({
        int statusCode,
        Map<String, String> headers,
        List<int> bodyBytes,
        Uri upstreamUri,
      })> _forwardToUpstream(
    shelf.Request request, {
    Uint8List? requestBodyBytes,
    String? idempotencyKey,
    String? acceptedAt,
  }) async {
    if (_config?.origin.isEmpty ?? true) {
      throw Exception('No upstream origin configured');
    }

    final uri = _buildUpstreamUriFromParts(
      path: request.url.path,
      query: request.url.query,
    );

    // HttpClientを再利用する（大量リクエストでの生成コストを削減）
    final client = _getOrCreateHttpClient();

    // 待ち時間が段階ごとに積み上がらないよう、1 リクエスト全体の締め切りを決める
    final deadline =
        DateTime.now().add(_config?.requestTimeout ?? _defaultRequestTimeout);

    // 同時上流接続数を制限してネイティブ側のリソース枯渇を防ぐ
    try {
      await _upstreamSemaphore.acquire(timeout: _remainingUntil(deadline));
    } on TimeoutException catch (e) {
      // 上流の状態とは無関係な混雑のため、到達性の判定と区別できるようにする
      throw _UpstreamSlotTimeoutException(e.message ?? '同時接続数の空き待ちがタイムアウトしました');
    }

    try {
      final ioRequest = await client
          .openUrl(request.method, uri)
          .timeout(_remainingUntil(deadline));
      ioRequest.followRedirects = false;
      await _copyRequestHeaders(
        request,
        ioRequest,
        upstreamUri: uri,
        // 設定済み origin 以外へ渡すヘッダを絞る。経路ではなく行き先で
        // 判定し、どの入口から来た要求でも同じ扱いにする。
        isMirroredOrigin: !_isSameOriginAsConfiguredOrigin(uri),
      );

      // 応答を受け取れずキューへ回った場合でも同じキーで再送できるようにする
      if (idempotencyKey != null && (_config?.enableIdempotencyKey ?? true)) {
        ioRequest.headers.set(
          _config?.idempotencyHeaderName ?? _defaultIdempotencyHeaderName,
          idempotencyKey,
        );
      }

      // 初回転送と再送で同じ値を送り、受け付けた時点を上流へ伝える
      _applyAcceptedAtHeader(ioRequest, acceptedAt);

      // read系以外のリクエストの場合はボディをコピー
      if (!_isReadRequestMethod(request.method)) {
        final bytes =
            requestBodyBytes ?? await _readMessageBytes(request.read());
        if (bytes.isNotEmpty) {
          ioRequest.add(bytes);
        }
      }

      final ioResponse =
          await ioRequest.close().timeout(_remainingUntil(deadline));

      final bodyBytes = await _readResponseBytes(ioResponse, deadline);

      final headerSnapshot =
          ResponseHeaderSnapshot.fromHttpHeaders(ioResponse.headers);
      await _storeResponseCookies(
        requestUri: uri,
        setCookieHeaders: headerSnapshot.setCookieHeaders,
      );

      final sanitizedHeaders =
          _sanitizeResponseHeaders(headerSnapshot.flattenedHeaders);

      return (
        statusCode: ioResponse.statusCode,
        headers: sanitizedHeaders,
        bodyBytes: bodyBytes,
        upstreamUri: uri,
      );
    } finally {
      _upstreamSemaphore.release();
    }
  }

  /// リクエストヘッダを上流リクエストにコピーします。
  ///
  /// [request] 受信した要求。
  /// [ioRequest] 転送先の上流リクエスト。
  /// [upstreamUri] 転送先の upstream URI。
  /// [isMirroredOrigin] 設定済み origin 以外へ中継する場合は `true`。
  Future<void> _copyRequestHeaders(
    shelf.Request request,
    HttpClientRequest ioRequest, {
    required Uri upstreamUri,
    bool isMirroredOrigin = false,
  }) async {
    final connectionSpecificHeaders =
        _extractConnectionSpecificHeaders(request.headers);
    request.headers.forEach((key, value) {
      if (_shouldForwardUpstreamHeader(
        key,
        connectionSpecificHeaders: connectionSpecificHeaders,
        dropCredentialHeaders: isMirroredOrigin,
      )) {
        ioRequest.headers.set(key, value);
      }
    });

    // 別 origin へは、WebView が proxy origin 向けに送った Cookie を渡さない。
    // proxy origin の Cookie は設定済み origin のものとして扱うため。
    final mergedCookieHeader = isMirroredOrigin
        ? await _buildCookieHeaderForUri(upstreamUri)
        : await _mergeCookieHeaderForUpstream(
            upstreamUri,
            request.headers['cookie'],
          );
    if (mergedCookieHeader != null && mergedCookieHeader.isNotEmpty) {
      ioRequest.headers.set('cookie', mergedCookieHeader);
    }

    // 非圧縮レスポンスを要求
    ioRequest.headers.set('accept-encoding', 'identity');
  }

  /// キュー再送時の保存済みヘッダを上流リクエストへ反映します。
  ///
  /// WebView 由来の保存ヘッダには `host` や `connection` など再送時に
  /// 不要または禁止される値が含まれるため、通常転送と同様にサニタイズします。
  Future<void> _applyQueuedRequestHeaders(
    HttpClientRequest ioRequest, {
    required Uri upstreamUri,
    required Map<String, String> requestHeaders,
  }) async {
    final connectionSpecificHeaders =
        _extractConnectionSpecificHeaders(requestHeaders);
    requestHeaders.forEach((key, value) {
      if (_shouldForwardUpstreamHeader(
        key,
        connectionSpecificHeaders: connectionSpecificHeaders,
        dropContentLength: true,
      )) {
        ioRequest.headers.set(key, value);
      }
    });

    final mergedCookieHeader = await _mergeCookieHeaderForUpstream(
      upstreamUri,
      requestHeaders['cookie'],
    );
    if (mergedCookieHeader != null && mergedCookieHeader.isNotEmpty) {
      ioRequest.headers.set('cookie', mergedCookieHeader);
    }

    ioRequest.headers.set('accept-encoding', 'identity');
  }

  /// 上流送信用の Cookie ヘッダを構築します。
  ///
  /// Cookie Jar に保存された値を優先しつつ、Jar に存在しない Cookie は
  /// クライアント由来ヘッダから引き継ぎます。
  /// [upstreamUri] は送信先 URI です。
  /// [requestCookieHeader] はクライアント由来の Cookie ヘッダです。
  /// 戻り値は上流へ送る `Cookie` ヘッダ値です。送信対象が無い場合は `null` です。
  Future<String?> _mergeCookieHeaderForUpstream(
    Uri upstreamUri,
    String? requestCookieHeader,
  ) async {
    final jarCookieHeader = await _buildCookieHeaderForUri(upstreamUri);
    if (jarCookieHeader == null || jarCookieHeader.isEmpty) {
      return requestCookieHeader;
    }
    if (requestCookieHeader == null || requestCookieHeader.isEmpty) {
      return jarCookieHeader;
    }

    final jarCookies = _parseCookieHeaderPairs(jarCookieHeader);
    final mergedCookies = <MapEntry<String, String>>[...jarCookies];
    final jarCookieNames = jarCookies.map((entry) => entry.key).toSet();

    for (final cookie in _parseCookieHeaderPairs(requestCookieHeader)) {
      if (!jarCookieNames.contains(cookie.key)) {
        mergedCookies.add(cookie);
      }
    }

    if (mergedCookies.isEmpty) {
      return null;
    }

    return mergedCookies
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  /// `Cookie` ヘッダ文字列を name/value の連想配列に変換します。
  ///
  /// [cookieHeader] は `Cookie` ヘッダ値です。
  /// 戻り値は出現順を保持した Cookie 名と値の一覧です。
  List<MapEntry<String, String>> _parseCookieHeaderPairs(String cookieHeader) {
    final cookies = <MapEntry<String, String>>[];

    for (final segment in cookieHeader.split(';')) {
      final trimmedSegment = segment.trim();
      if (trimmedSegment.isEmpty) {
        continue;
      }

      final separatorIndex = trimmedSegment.indexOf('=');
      if (separatorIndex <= 0) {
        continue;
      }

      final name = trimmedSegment.substring(0, separatorIndex).trim();
      final value = trimmedSegment.substring(separatorIndex + 1).trim();
      if (name.isEmpty) {
        continue;
      }

      cookies.add(MapEntry(name, value));
    }

    return cookies;
  }

  /// 指定したヘッダがHop-by-Hopヘッダかどうかを判定します。
  ///
  /// HTTPプロキシでは上流サーバに転送してはいけない
  /// ヘッダを特定します。
  ///
  /// [header] チェックするヘッダ名。
  ///
  /// Returns: Hop-by-Hopヘッダの場合は `true`。
  bool _isHopByHopHeader(String header) {
    const hopByHopHeaders = [
      'connection',
      'keep-alive',
      'upgrade',
      'proxy-authenticate',
      'proxy-authorization',
      'te',
      'trailers',
      'transfer-encoding',
    ];
    return hopByHopHeaders.contains(header.toLowerCase());
  }

  /// `Connection` ヘッダが指名する hop-by-hop ヘッダ名を抽出します。
  Set<String> _extractConnectionSpecificHeaders(Map<String, String> headers) {
    final connectionHeader = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'connection')
        .map((entry) => entry.value)
        .cast<String?>()
        .firstWhere((value) => value != null && value.isNotEmpty,
            orElse: () => null);
    if (connectionHeader == null) {
      return const <String>{};
    }

    return connectionHeader
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  /// 上流へ転送するヘッダかどうかを返します。
  ///
  /// [key] 判定するヘッダ名。
  /// [connectionSpecificHeaders] `Connection` が指名するヘッダ名の一覧。
  /// [dropContentLength] `Content-Length` を落とす場合は `true`。
  /// [dropCredentialHeaders] 資格情報と要求元を伝えるヘッダを落とす場合は
  ///   `true`。設定済み origin 以外へ中継するときに使います。
  ///
  /// Returns: 転送する場合は `true`。
  bool _shouldForwardUpstreamHeader(
    String key, {
    required Set<String> connectionSpecificHeaders,
    bool dropContentLength = false,
    bool dropCredentialHeaders = false,
  }) {
    final lowerKey = key.toLowerCase();
    if (_isHopByHopHeader(key) ||
        connectionSpecificHeaders.contains(lowerKey)) {
      return false;
    }

    if (lowerKey == 'accept-encoding' ||
        lowerKey == 'host' ||
        lowerKey == 'cookie') {
      return false;
    }

    // 設定済み origin 向けの資格情報を第三者へ渡さない。`Origin` と `Referer`
    // は proxy の loopback URL を指すだけで、中継先には意味を持たない。
    if (dropCredentialHeaders &&
        (lowerKey == 'authorization' ||
            lowerKey == 'origin' ||
            lowerKey == 'referer')) {
      return false;
    }

    if (dropContentLength && lowerKey == 'content-length') {
      return false;
    }

    return true;
  }

  /// 上流レスポンスヘッダをクライアント返却/キャッシュ向けにサニタイズします。
  ///
  /// `transfer-encoding: chunked` 等をそのまま転送すると、shelf 側の実際の
  /// ボディエンコード（content-length 付き等）と矛盾してクライアントが
  /// デコードエラー（FormatException）を起こすことがあります。
  Map<String, String> _sanitizeResponseHeaders(Map<String, String> headers) {
    final sanitized = Map<String, String>.from(headers);

    const hopByHop = {
      'connection',
      'upgrade',
      'proxy-authenticate',
      'proxy-authorization',
      'te',
      'trailers',
      'transfer-encoding',
      'keep-alive',
    };
    sanitized.removeWhere((key, _) => hopByHop.contains(key.toLowerCase()));

    // shelf がボディ長/転送方式を決めるため、上流由来の値は捨てる
    sanitized.removeWhere((key, _) => key.toLowerCase() == 'content-length');

    return sanitized;
  }

  /// ヘッダ名を大文字小文字を無視して取得します。
  String? _getHeaderValueIgnoreCase(Map<String, String> headers, String name) {
    final lowerName = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lowerName) {
        return entry.value;
      }
    }
    return null;
  }

  /// ヘッダ名を大文字小文字を無視して置き換えます。
  Map<String, String> _putHeaderValueIgnoreCase(
    Map<String, String> headers,
    String name,
    String value,
  ) {
    final updated = Map<String, String>.from(headers);
    final lowerName = name.toLowerCase();
    updated.removeWhere((key, _) => key.toLowerCase() == lowerName);
    updated[name] = value;
    return updated;
  }

  /// 上流 3xx レスポンスを解決し、必要に応じて proxy 応答へ変換します。
  shelf.Response? _tryBuildHandledRedirectResponse({
    required shelf.Request request,
    required Uri upstreamRequestUri,
    required int statusCode,
    required Map<String, String> headers,
    required List<int> bodyBytes,
  }) {
    if (!_isRedirectStatusCode(statusCode)) {
      return null;
    }

    final locationHeader = _getHeaderValueIgnoreCase(headers, 'location');
    if (locationHeader == null || locationHeader.trim().isEmpty) {
      return null;
    }

    final recommendation = _recommendWebViewNavigation(
      targetUrl: locationHeader,
      sourceUrl: upstreamRequestUri.toString(),
      allowInPlace: false,
    );

    switch (recommendation.action) {
      case ProxyWebViewNavigationAction.allow:
      case ProxyWebViewNavigationAction.cancel:
        return null;
      case ProxyWebViewNavigationAction.loadProxyUrl:
        final webViewUri = recommendation.webViewUri;
        if (webViewUri == null) {
          return null;
        }
        _emitRedirectHandledEvent(
          request: request,
          upstreamRequestUri: upstreamRequestUri,
          statusCode: statusCode,
          locationHeader: locationHeader,
          recommendation: recommendation,
        );
        return shelf.Response(
          statusCode,
          body: Uint8List.fromList(bodyBytes),
          headers: _putHeaderValueIgnoreCase(
            headers,
            'location',
            webViewUri.toString(),
          ),
        );
      case ProxyWebViewNavigationAction.launchExternal:
        _emitRedirectHandledEvent(
          request: request,
          upstreamRequestUri: upstreamRequestUri,
          statusCode: statusCode,
          locationHeader: locationHeader,
          recommendation: recommendation,
        );
        return shelf.Response(
          HttpStatus.noContent,
          headers: {
            'Cache-Control': 'no-store',
            'X-Proxy-Redirect': 'external',
            'X-Proxy-Redirect-Action':
                ProxyWebViewNavigationAction.launchExternal.name,
          },
        );
    }
  }

  /// 解決済み redirect を app 側へ通知します。
  void _emitRedirectHandledEvent({
    required shelf.Request request,
    required Uri upstreamRequestUri,
    required int statusCode,
    required String locationHeader,
    required ProxyWebViewNavigationRecommendation recommendation,
  }) {
    _emitEvent(ProxyEventType.redirectHandled, request.url.toString(), {
      'method': request.method,
      'proxyRequestUrl': request.requestedUri.toString(),
      'sourceUpstreamUrl': upstreamRequestUri.toString(),
      'redirectStatusCode': statusCode,
      'locationHeader': locationHeader,
      'redirectAction': recommendation.action.name,
      'normalizedTargetUrl':
          recommendation.resolution.normalizedTargetUri?.toString(),
      'resolvedUpstreamUrl': recommendation.resolution.upstreamUri?.toString(),
      'resolvedProxyUrl': recommendation.webViewUri?.toString(),
      'externalUrl': recommendation.externalUri?.toString(),
      'navigationDisposition': recommendation.resolution.disposition.name,
      'navigationReason': recommendation.resolution.reason.name,
      'usedSourceUrl': recommendation.resolution.usedSourceUrl,
      'usedLoopbackAlias': recommendation.resolution.usedLoopbackAlias,
      'isStaticResource': recommendation.resolution.isStaticResource,
    });
  }

  /// 上流レスポンスの `Set-Cookie` を Cookie Box に保存します。
  ///
  /// 現段階では受信基盤のみを整備し、取得した Cookie を内部保存します。
  /// パースや保存に失敗してもリクエスト処理全体は継続します。
  Future<void> _storeResponseCookies({
    required Uri requestUri,
    required List<String> setCookieHeaders,
  }) async {
    if (setCookieHeaders.isEmpty) {
      return;
    }

    await _ensureCookieStorageInitialized();
    final now = DateTime.now();
    for (final setCookieHeader in setCookieHeaders) {
      try {
        final restoreEntry = CookieRestoreEntry.fromSetCookieHeader(
          setCookieHeader: setCookieHeader,
          requestUrl: requestUri.toString(),
          receivedAt: now,
        );
        await _persistCookieRecord(
          restoreEntry.toCookieRecord(restoredAt: now),
          now: now,
        );
      } catch (e) {
        _emitEvent(
          ProxyEventType.errorOccurred,
          requestUri.toString(),
          {
            'operation': 'cookieSave',
            'error': e.toString(),
          },
        );
      }
    }
  }

  /// 指定 URI に対して送信可能な Cookie レコード一覧を返します。
  ///
  /// [uri] は送信対象 URI です。
  /// 戻り値は送信順序に並んだ Cookie レコード一覧です。
  Future<List<CookieRecord>> _getCookieRecordsForUri(Uri uri) async {
    await _ensureCookieStorageInitialized();

    final now = DateTime.now().toUtc();
    final expiredKeys = <dynamic>[];
    final cookieRecords = <CookieRecord>[];

    for (final key in _cookieBox!.keys) {
      final data = _cookieBox!.get(key) as Map?;
      if (data == null) {
        continue;
      }

      final cookieRecord = CookieRecord.fromMap(data);
      if (cookieRecord.isExpiredAt(now)) {
        expiredKeys.add(key);
        continue;
      }

      if (cookieRecord.matchesUri(uri, at: now)) {
        cookieRecords.add(cookieRecord);
      }
    }

    for (final key in expiredKeys) {
      await _cookieBox!.delete(key);
    }

    cookieRecords.sort(CookieRecord.compareForRequest);
    return cookieRecords;
  }

  /// 指定 URI 向けの Cookie ヘッダ値を内部生成します。
  ///
  /// [uri] は送信対象 URI です。
  /// 戻り値は該当 Cookie がある場合の `Cookie` ヘッダ値です。
  Future<String?> _buildCookieHeaderForUri(Uri uri) async {
    final cookieRecords = await _getCookieRecordsForUri(uri);
    return buildCookieHeaderForUri(cookieRecords, uri,
        at: DateTime.now().toUtc());
  }

  /// Cookie レコード一覧を永続化します。
  ///
  /// [cookieRecords] は保存対象の Cookie レコード一覧です。
  /// [now] は期限切れ判定に使用する日時です。
  Future<void> _persistCookieRecords(
    Iterable<CookieRecord> cookieRecords, {
    required DateTime now,
  }) async {
    for (final cookieRecord in cookieRecords) {
      await _persistCookieRecord(cookieRecord, now: now);
    }
  }

  /// Cookie レコードを 1 件永続化します。
  ///
  /// [cookieRecord] は保存対象の Cookie レコードです。
  /// [now] は期限切れ判定に使用する日時です。
  Future<void> _persistCookieRecord(
    CookieRecord cookieRecord, {
    required DateTime now,
  }) async {
    final cookieBox = await _ensureCookieStorageInitialized();
    if (cookieRecord.isExpiredAt(now)) {
      await cookieBox.delete(cookieRecord.storageKey);
      return;
    }

    await cookieBox.put(cookieRecord.storageKey, cookieRecord.toMap());
  }

  /// レスポンスをキャッシュに保存します（バイト配列版）。
  ///
  /// [cacheKey] キャッシュキー。
  /// [statusCode] 上流レスポンスのステータスコード。
  /// [headers] 上流レスポンスのヘッダ。
  /// [bodyBytes] レスポンスボディのバイト配列。
  /// [allowNoStore] `Cache-Control: no-store` を無視して保存する場合は `true`。
  ///   [ProxyConfig.forceCachePaths] に一致し、かつ安全側の除外条件に
  ///   該当しない場合にのみ指定します。
  Future<void> _cacheResponseBytes(String cacheKey, int statusCode,
      Map<String, String> headers, List<int> bodyBytes,
      {bool allowNoStore = false}) async {
    final sanitizedHeaders = _sanitizeResponseHeaders(headers);
    if (!_shouldPersistResponse(statusCode, sanitizedHeaders,
        allowNoStore: allowNoStore)) {
      return;
    }
    final contentType =
        sanitizedHeaders['content-type'] ?? 'application/octet-stream';
    final data = {
      'statusCode': statusCode,
      'headers': sanitizedHeaders,
      // バイナリも含めてそのまま保存（UTF-8変換は高コストで破損も起こし得る）
      'body': Uint8List.fromList(bodyBytes),
      'createdAt': DateTime.now().toIso8601String(),
      'expiresAt': _calculateExpirationFromHeaders(
        sanitizedHeaders,
        contentType,
        ignoreUpstreamFreshness: allowNoStore,
      ).toIso8601String(),
      'contentType': contentType,
      'sizeBytes': bodyBytes.length,
    };

    await _cacheBox?.put(cacheKey, data);
  }

  /// ヘッダからキャッシュ有効期限を算出します。
  ///
  /// [headers] サニタイズ済みの上流レスポンスヘッダ。
  /// [contentType] レスポンスの Content-Type。
  /// [ignoreUpstreamFreshness] 上流の鮮度指示を使わない場合は `true`。
  ///   `no-store` を無視して保存する応答は `no-store, max-age=0` のように
  ///   保存させない意図の指示を伴うことが多く、そのまま採用すると保存直後に
  ///   stale となり、オフラインで使える期間が stale 期間だけになります。
  ///   保存可否を設定側で上書きした以上、有効期限も設定側の TTL に従います。
  ///
  /// Returns: キャッシュ有効期限の日時。
  DateTime _calculateExpirationFromHeaders(
      Map<String, String> headers, String contentType,
      {bool ignoreUpstreamFreshness = false}) {
    final now = DateTime.now();

    if (!ignoreUpstreamFreshness) {
      final cacheControl = headers['cache-control'];

      final sMaxAge = _extractCacheControlSeconds(cacheControl, 's-maxage');
      if (sMaxAge != null) {
        return now.add(Duration(seconds: sMaxAge));
      }

      final maxAge = _extractCacheControlSeconds(cacheControl, 'max-age');
      if (maxAge != null) {
        return now.add(Duration(seconds: maxAge));
      }

      final expiresHeader = headers['expires'];
      if (expiresHeader != null) {
        // `Expires: 0` のように日時として解釈できない値を返すサーバがあるため、
        // 解析に失敗しても保存処理を中断せず既定 TTL へ委ねる。
        // ここで例外が伝播すると、上流が返した 200 が転送失敗として扱われる。
        final expiresAt = _tryParseHttpDate(expiresHeader);
        if (expiresAt != null) {
          return expiresAt.isAfter(now) ? expiresAt : now;
        }
      }
    }

    // デフォルトTTLを使用
    final ttl = _resolveContentTypeDurationSeconds(
      _config?.cacheTtl,
      contentType,
      3600,
    );
    return now.add(Duration(seconds: ttl));
  }

  /// キャッシュ保存可否を判定します。
  ///
  /// [statusCode] 上流レスポンスのステータスコード。
  /// [headers] サニタイズ済みの上流レスポンスヘッダ。
  /// [allowNoStore] `Cache-Control: no-store` を無視する場合は `true`。
  ///
  /// Returns: 保存してよい場合は `true`。
  bool _shouldPersistResponse(int statusCode, Map<String, String> headers,
      {bool allowNoStore = false}) {
    if (statusCode != HttpStatus.ok) {
      return false;
    }

    if (allowNoStore) {
      return true;
    }

    final cacheControl = headers['cache-control']?.toLowerCase();
    if (cacheControl != null && cacheControl.contains('no-store')) {
      return false;
    }

    return true;
  }

  /// `no-store` を無視して保存してよいかどうかを判定します。
  ///
  /// [ProxyConfig.forceCachePaths] に一致していても、利用者ごとに異なる応答や
  /// URL だけでは復元できない応答は保存しません。指定したのにオフラインで
  /// 使えない原因を追えるよう、除外した場合は
  /// [ProxyEventType.cacheSkipped] を理由付きで発行します。
  ///
  /// [path] リクエストのパス。
  /// [requestHeaders] リクエストヘッダ。
  /// [responseHeaders] 上流レスポンスのヘッダ。
  /// [eventUrl] イベントに載せる URL。
  ///
  /// Returns: `no-store` を無視して保存してよい場合は `true`。
  bool _resolveForceCacheAllowance({
    required String path,
    required Map<String, String> requestHeaders,
    required Map<String, String> responseHeaders,
    required String eventUrl,
  }) {
    // 既定では設定が空のため、ヘッダを走査する前に打ち切る
    if (_forceCachePatterns.isEmpty) {
      return false;
    }

    // no-store が無ければ通常の保存判定で足りるため、判定も通知も行わない
    final cacheControl =
        _getHeaderValueIgnoreCase(responseHeaders, 'cache-control')
            ?.toLowerCase();
    if (cacheControl == null || !cacheControl.contains('no-store')) {
      return false;
    }

    if (!_matchesForceCachePath(path)) {
      return false;
    }

    final skipReason = _findForceCacheSkipReason(
      requestHeaders: requestHeaders,
      responseHeaders: responseHeaders,
    );
    if (skipReason != null) {
      _emitEvent(ProxyEventType.cacheSkipped, eventUrl, {
        'reason': skipReason,
      });
      return false;
    }

    return true;
  }

  /// パスが [ProxyConfig.forceCachePaths] に一致するかどうかを返します。
  ///
  /// [path] 判定するリクエストのパス。
  ///
  /// Returns: 一致する場合は `true`。
  bool _matchesForceCachePath(String path) {
    if (_forceCachePatterns.isEmpty) {
      return false;
    }

    // 照合対象はパスのみのため、クエリとフラグメントを落とす
    final pathOnly = path.split('?').first.split('#').first;
    return _forceCachePatterns.any((pattern) => pattern.matches(pathOnly));
  }

  /// 保存を見送る理由を返します。
  ///
  /// [requestHeaders] リクエストヘッダ。
  /// [responseHeaders] 上流レスポンスのヘッダ。
  ///
  /// Returns: 見送る理由。保存してよい場合は `null`。
  String? _findForceCacheSkipReason({
    required Map<String, String> requestHeaders,
    required Map<String, String> responseHeaders,
  }) {
    // セッションを端末へ残し、復元時にそのまま返してしまうため保存しない
    if (_getHeaderValueIgnoreCase(responseHeaders, 'set-cookie') != null) {
      return 'set-cookie';
    }

    // キャッシュキーは URL のみで、リクエストヘッダ差を区別できない
    final vary = _getHeaderValueIgnoreCase(responseHeaders, 'vary');
    if (vary != null && !_isAcceptEncodingOnlyVary(vary)) {
      return 'vary';
    }

    // 利用者ごとに異なる応答を共有の保存領域へ書かない
    if (_getHeaderValueIgnoreCase(requestHeaders, 'authorization') != null) {
      return 'authorization';
    }

    return null;
  }

  /// `Vary` が `Accept-Encoding` だけを指しているかどうかを返します。
  ///
  /// proxy は転送、キュー再送、ウォームアップのいずれでも上流へ
  /// `Accept-Encoding: identity` を固定で送るため、受け取る応答は常に
  /// 非圧縮の 1 種類です。`Accept-Encoding` だけを理由に保存を見送っても
  /// 守れるものが無く、圧縮を有効にしたサーバでは画面の HTML や JS が
  /// まとめて保存対象から外れてしまいます。
  ///
  /// `*` や他のヘッダ名を含む場合は、URL だけでは応答を復元できないため
  /// 従来どおり保存を見送ります。
  ///
  /// [vary] 応答の `Vary` ヘッダ値。
  ///
  /// Returns: `Accept-Encoding` だけを指している場合は `true`。
  bool _isAcceptEncodingOnlyVary(String vary) {
    final tokens = vary
        .split(',')
        .map((token) => token.trim().toLowerCase())
        .where((token) => token.isNotEmpty);

    // 値が空の Vary は差の生じる要求ヘッダを示さないため、保存を妨げない
    return tokens.every((token) => token == 'accept-encoding');
  }

  /// HTTP 日時を解析します。
  ///
  /// [value] 解析する `Expires` などのヘッダ値。
  ///
  /// Returns: 解析できた日時。解釈できない場合は `null`。
  DateTime? _tryParseHttpDate(String value) {
    try {
      return HttpDate.parse(value);
    } catch (_) {
      return null;
    }
  }

  /// Cache-Control から秒数指定ディレクティブを抽出します。
  int? _extractCacheControlSeconds(String? cacheControl, String directive) {
    if (cacheControl == null || cacheControl.isEmpty) {
      return null;
    }

    final pattern = RegExp('(?:^|,)\\s*$directive=(\\d+)');
    final match = pattern.firstMatch(cacheControl.toLowerCase());
    return int.tryParse(match?.group(1) ?? '');
  }

  /// Content-Type に対応する TTL / stale 秒数を解決します。
  int _resolveContentTypeDurationSeconds(
    Map<String, int>? settings,
    String contentType,
    int fallbackSeconds,
  ) {
    if (settings == null || settings.isEmpty) {
      return fallbackSeconds;
    }

    final normalizedContentType =
        contentType.split(';').first.trim().toLowerCase();
    final direct = settings[normalizedContentType];
    if (direct != null) {
      return direct;
    }

    final slashIndex = normalizedContentType.indexOf('/');
    if (slashIndex > 0) {
      final wildcardKey = '${normalizedContentType.substring(0, slashIndex)}/*';
      final wildcard = settings[wildcardKey];
      if (wildcard != null) {
        return wildcard;
      }
    }

    return settings['default'] ?? fallbackSeconds;
  }

  /// レスポンスのキャッシュ有効期限を算出します。
  ///
  /// Cache-Controlヘッダのmax-ageを優先し、
  /// 指定がない場合は設定ファイルのTTLを使用します。
  ///
  /// [response] 有効期限を算出するレスポンス。
  ///
  /// Returns: キャッシュ有効期限の日時。
  // 注: _calculateExpirationは未使用のためアナライザ警告を避けるために削除されました。
  // 必要に応じて_calculateExpirationFromHeadersまたは_calculateStaleExpirationを使用してください。

  /// キャッシュのStale有効期限を算出します。
  ///
  /// TTL期限切れ後でも一定期間はStaleキャッシュとして
  /// 使用可能な期限をContent-Type別に算出します。
  ///
  /// [expiresAt] Fresh 期限の日時。
  /// [contentType] コンテンツタイプ。
  ///
  /// Returns: Stale有効期限の日時。
  DateTime _calculateStaleExpiration(DateTime expiresAt, String contentType) {
    final stalePeriod = _resolveContentTypeDurationSeconds(
      _config?.cacheStale,
      contentType,
      259200,
    );
    return expiresAt.add(Duration(seconds: stalePeriod));
  }

  /// キューの再試行バックオフ秒数を計算します。
  ///
  /// [retryCount] は 1 から始まる再試行回数です。
  int _getBackoffDelay(int retryCount) {
    final List<int>? backoff = _config?.retryBackoffSeconds;
    if (backoff != null && backoff.isNotEmpty) {
      final idx = retryCount - 1;
      if (idx < backoff.length) return backoff[idx];
      return backoff.last;
    }

    // デフォルトのバックオフシーケンス（安全側）
    final defaultSeq = [1, 2, 5, 10, 20, 30];
    final idx = retryCount - 1;
    if (idx < defaultSeq.length) return defaultSeq[idx];
    return defaultSeq.last;
  }

  /// キューデータのリトライスケジュールを更新します。
  void _updateRetrySchedule(Map data) {
    final retryCount = (data['retryCount'] as int? ?? 0) + 1;
    final backoffSeconds = _getBackoffDelay(retryCount);
    data['retryCount'] = retryCount;
    data['nextRetryAt'] =
        DateTime.now().add(Duration(seconds: backoffSeconds)).toIso8601String();
  }

  /// 保存領域内で重複しない一意なキーを生成します。
  ///
  /// マイクロ秒精度のタイムスタンプへ同一マイクロ秒内の連番を付与します。
  /// ミリ秒精度のキーでは同一ミリ秒に保存したデータが上書きで失われるため、
  /// 精度と連番の両方で衝突を防ぎます。
  ///
  /// Hive はキーの辞書順で列挙するため、タイムスタンプと連番はゼロ埋めして
  /// 辞書順と時系列順を一致させます。既存キーと衝突した場合は連番を進めて
  /// 再生成するため、処理は必ず終了します。
  ///
  /// [box] 重複を確認する保存領域。`null` の場合は確認を省略します。
  /// [otherBox] あわせて重複を確認する保存領域。移行を待っている旧平文 Box を
  ///   指定し、書き写しで同じキーが重ならないようにします。
  ///
  /// Returns: 生成された一意なキー。
  String _generateUniqueStorageKey(Box? box, [Box? otherBox]) {
    while (true) {
      final microseconds = DateTime.now().microsecondsSinceEpoch;
      if (microseconds == _lastStorageKeyMicroseconds) {
        _storageKeySequence++;
      } else {
        _lastStorageKeyMicroseconds = microseconds;
        _storageKeySequence = 0;
      }

      final timestampPart =
          microseconds.toString().padLeft(_storageKeyTimestampDigits, '0');
      final sequencePart = _storageKeySequence
          .toString()
          .padLeft(_storageKeySequenceDigits, '0');
      final key = '$timestampPart-$sequencePart';

      final usedInBox = box != null && box.containsKey(key);
      final usedInOtherBox =
          otherBox != null && otherBox.isOpen && otherBox.containsKey(key);
      if (!usedInBox && !usedInOtherBox) {
        return key;
      }
    }
  }

  /// HTTPリクエストをキューに保存します。
  ///
  /// オフライン時や上流サーバエラー時に非-GETリクエストを
  /// キューに保存し、オンライン復帰時に自動再送します。
  ///
  /// [request] キューに保存するHTTPリクエスト。
  /// [bodyBytes] 既に読み取り済みのリクエストボディ。
  /// [idempotency] 転送時に決定済みのべき等性キーと、その出所。
  ///   省略した場合はこの時点で決定します。
  /// [acceptedAt] 転送時に決定済みの受付時刻。省略した場合はこの時点で決定します。
  ///
  /// Returns: 保存に使用したキュー ID。保存領域が使えない場合は `null`。
  Future<String?> _queueRequest(
    shelf.Request request, {
    List<int>? bodyBytes,
    ({String value, bool suppliedByClient})? idempotency,
    String? acceptedAt,
  }) async {
    final List<int> body;
    if (request.method == 'GET') {
      body = <int>[];
    } else {
      body = bodyBytes ?? await _readMessageBytes(request.read());
    }

    // NOTE: キュー再送は HttpClient で行うため、必ず絶対URLを保存する。
    // 旧バージョン互換のため、相対URLを保存していたデータは _sendQueuedRequest 側で補正する。
    final upstreamUrl = _buildUpstreamUrl(request);

    final queueData = {
      'url': upstreamUrl,
      'method': request.method,
      'headers': request.headers,
      'body': body,
      'queuedAt': DateTime.now().toIso8601String(),
      // 隔離からの再送でも変わらない、最初に受け付けた時点
      'acceptedAt': acceptedAt ?? _resolveAcceptedAt(),
      'retryCount': 0,
      'nextRetryAt': DateTime.now().toIso8601String(),
    };

    final box = _queueBox;
    if (box == null) {
      return null;
    }

    if (_config?.enableIdempotencyKey ?? true) {
      final resolved = idempotency ?? _resolveIdempotencyKey(request);

      // クライアントが同じキーで送り直した場合、キューへ二重に積まない。
      // 生成したキーは一致し得ないため、指定された場合だけ探索する。
      if (resolved.suppliedByClient) {
        final existingKey = _findQueuedKeyByIdempotencyKey(box, resolved.value);
        if (existingKey != null) {
          return existingKey;
        }
      }

      queueData['idempotencyKey'] = resolved.value;
    }

    final key = _generateUniqueStorageKey(box, _legacyQueueBox);
    await box.put(key, queueData);
    return key;
  }

  /// リクエストに適用するべき等性キーを決定します。
  ///
  /// クライアントが付与済みの場合はその値を尊重し、無い場合は生成します。
  ///
  /// [request] 対象のHTTPリクエスト。
  ///
  /// Returns: べき等性キーと、クライアントが指定した値かどうか。
  ({String value, bool suppliedByClient}) _resolveIdempotencyKey(
    shelf.Request request,
  ) {
    final headerName =
        _config?.idempotencyHeaderName ?? _defaultIdempotencyHeaderName;
    final supplied = request.headers[headerName]?.trim();
    if (supplied != null && supplied.isNotEmpty) {
      return (value: supplied, suppliedByClient: true);
    }

    // 同じ内容の会計が連続しても別の要求として扱えるよう、内容ではなく乱数で採番する
    final buffer = StringBuffer();
    for (var i = 0; i < 4; i++) {
      buffer.write(
        _idempotencyKeyRandom
            .nextInt(0x100000000)
            .toRadixString(16)
            .padLeft(8, '0'),
      );
    }
    return (value: buffer.toString(), suppliedByClient: false);
  }

  /// 同じべき等性キーを持つキュー項目のキーを探します。
  ///
  /// 移行を待っている旧平文キューも探します。
  ///
  /// [box] 対象のキュー保存領域。
  /// [idempotencyKey] 検索するべき等性キー。
  ///
  /// Returns: 見つかったキュー ID。無い場合は `null`。
  String? _findQueuedKeyByIdempotencyKey(Box box, String idempotencyKey) {
    for (final candidate in [box, _legacyQueueBox]) {
      if (candidate == null || !candidate.isOpen) {
        continue;
      }

      for (final key in candidate.keys) {
        final data = candidate.get(key) as Map?;
        if (data != null && data['idempotencyKey'] == idempotencyKey) {
          return key.toString();
        }
      }
    }

    return null;
  }

  /// 上流へ届いたことが確認済みのべき等性キーかどうかを返します。
  ///
  /// [idempotencyKey] 判定するべき等性キー。
  ///
  /// Returns: 送信済みとして扱う場合は `true`。
  bool _isIdempotencyKeyCompleted(String idempotencyKey) {
    final box = _idempotencyBox;
    if (box == null || !box.isOpen) {
      return false;
    }

    final completedAt = box.get(idempotencyKey) as String?;
    if (completedAt == null) {
      return false;
    }

    final parsed = DateTime.tryParse(completedAt);
    if (parsed == null) {
      return false;
    }

    final retention =
        _config?.idempotencyRetention ?? _defaultIdempotencyRetention;
    return DateTime.now().difference(parsed) < retention;
  }

  /// 上流へ届いたべき等性キーを記録します。
  ///
  /// [idempotencyKey] 記録するべき等性キー。
  Future<void> _recordIdempotencyKey(String idempotencyKey) async {
    final box = _idempotencyBox;
    if (box == null || !box.isOpen) {
      return;
    }

    await box.put(idempotencyKey, DateTime.now().toIso8601String());
  }

  /// 保持期間を過ぎたべき等性キーを削除します。
  ///
  /// エラーが発生しても例外をスローしません。
  Future<void> _purgeExpiredIdempotencyKeys() async {
    final box = _idempotencyBox;
    if (box == null || !box.isOpen) {
      return;
    }

    try {
      final retention =
          _config?.idempotencyRetention ?? _defaultIdempotencyRetention;
      final threshold = DateTime.now().subtract(retention);

      for (final key in box.keys.toList()) {
        final recordedAt = DateTime.tryParse(box.get(key) as String? ?? '');
        if (recordedAt == null || recordedAt.isBefore(threshold)) {
          await box.delete(key);
        }
      }
    } catch (e) {
      // 期限切れの削除に失敗しても運用は継続する
    }
  }

  /// 上流サーバからリソースを取得します。
  ///
  /// キャッシュの事前ウォームアップやテスト用に
  /// 特定のパスのGETリクエストを送信します。
  ///
  /// [path] 取得するリソースの相対パス。
  /// [timeout] タイムアウト秒数（デフォルト:30秒）。
  ///
  /// Returns: HTTPレスポンス。
  Future<http.Response> _fetchFromUpstream(String path, {int? timeout}) async {
    if (_config?.origin.isEmpty ?? true) {
      throw Exception('上流サーバのオリジンが設定されていません');
    }

    final uri = _buildUpstreamUriFromParts(path: path);
    final client = _getOrCreateHttpClient();

    // 転送と同じく、待ち時間が段階ごとに積み上がらないよう締め切りで管理する
    final deadline = DateTime.now().add(
      timeout != null
          ? Duration(seconds: timeout)
          : (_config?.requestTimeout ?? _defaultRequestTimeout),
    );

    try {
      final request =
          await client.getUrl(uri).timeout(_remainingUntil(deadline));
      // 転送経路と同じ値を送り、保存する応答が経路によって割れないようにする
      request.headers.set('accept-encoding', 'identity');

      // 転送経路と同じく Cookie Jar を送る。認証が必要な資源を
      // ウォームアップで取得できるようにするために必要。
      final cookieHeader = await _buildCookieHeaderForUri(uri);
      if (cookieHeader != null && cookieHeader.isNotEmpty) {
        request.headers.set('cookie', cookieHeader);
      }

      final response = await request.close().timeout(_remainingUntil(deadline));

      final bodyBytes = await (() async {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          builder.add(chunk);
        }
        return builder.takeBytes();
      })()
          .timeout(_remainingUntil(deadline));

      final headerSnapshot =
          ResponseHeaderSnapshot.fromHttpHeaders(response.headers);
      await _storeResponseCookies(
        requestUri: uri,
        setCookieHeaders: headerSnapshot.setCookieHeaders,
      );

      final sanitizedHeaders =
          _sanitizeResponseHeaders(headerSnapshot.flattenedHeaders);

      return http.Response.bytes(
        bodyBytes,
        response.statusCode,
        headers: sanitizedHeaders,
      );
    } finally {
      // 共有クライアントをここで閉じない
    }
  }

  /// バックグラウンドタスクを開始します。
  ///
  /// キューの消化、期限切れキャッシュのパージなどを
  /// 定期実行するタイマーを設定します。
  void _startBackgroundTasks() {
    // 既存タイマーがあれば止めてから再設定（再起動時の多重実行防止）
    _queueDrainTimer?.cancel();
    _cachePurgeTimer?.cancel();

    // キュー消化タイマーを開始（重複実行は _drainQueue 内でガード）
    _queueDrainTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      // ignore: discarded_futures
      _runPeriodicQueueTasks();
    });

    // キャッシュパージタイマーを開始
    _cachePurgeTimer = Timer.periodic(const Duration(hours: 1), (timer) {
      // ignore: discarded_futures
      _purgeExpiredCache();
      // ignore: discarded_futures
      _purgeExpiredIdempotencyKeys();
      // ignore: discarded_futures
      _enforceRetentionLimits();
    });

    // 鍵を生成したインスタンスでは、待ち時間の後に旧平文 Box を移行する
    _scheduleDeferredMigration();

    // 定期ヘルスチェックを設定（既定では無効）
    _startHealthCheckTimer();
  }

  /// 5 秒ごとの定期処理として、遅らせた移行とキュー消化を順に実行します。
  ///
  /// 移行はキュー消化と同じ排他を使うため、移行が終わるのを待ってから
  /// キュー消化を始めます。移行が失敗し続けても、キュー消化がこの回を
  /// 見送り続けないようにするためです。
  Future<void> _runPeriodicQueueTasks() async {
    await _runDeferredMigration();
    await _drainQueue();
  }

  /// キューに保存されたリクエストを消化します。
  ///
  /// オンライン時にキュー内のリクエストを順次上流サーバに送信し、
  /// 成功時はキューから削除、失敗時はバックオフで再試行します。
  Future<void> _drainQueue() async {
    // 停止直後にタイマーが発火した場合でも閉じたボックスへ触らない。
    // 遅らせた移行が排他を持っている間は、この回を見送る。
    final queueBox = _queueBox;
    if (!_isRunning ||
        _isStopping ||
        !_isUpstreamReachable ||
        queueBox == null ||
        !queueBox.isOpen ||
        _isDrainingQueue ||
        _queueDrainLock.isLocked) {
      return;
    }

    if (queueBox.isEmpty) {
      return;
    }

    _isDrainingQueue = true;
    try {
      await _queueDrainLock.synchronized(() async {
        final keys = _sortQueueKeysByQueuedAt(queueBox);
        for (var i = 0; i < keys.length; i++) {
          // 停止した場合や上流断を検知した場合は、残りを待たせずに打ち切る
          if (!_isRunning ||
              _isStopping ||
              !queueBox.isOpen ||
              !_isUpstreamReachable) {
            break;
          }

          await _processQueuedItem(queueBox, keys[i]);
          if (i % 10 == 0) {
            await Future.delayed(Duration.zero); // UIフリーズ防止
          }
        }
      });
    } finally {
      _isDrainingQueue = false;
    }
  }

  /// キューのキーを保存日時の昇順に並べ替えて返します。
  ///
  /// Hive はキーの辞書順で列挙するため、旧バージョンで保存したキー形式が
  /// 残っている場合は辞書順と時系列順が一致しません。仕様【5】の FIFO 保証を
  /// キー形式に依存せず維持するため、保存日時を基準に並べ替えます。
  /// 保存日時が同一の場合は、キーを時刻として読み直した値で解決します。
  /// 移行を待っている旧平文キューと同じキーは含めません。
  ///
  /// [box] 対象のキュー保存領域。
  ///
  /// Returns: 保存日時の昇順に並べ替えたキーの一覧。
  List<dynamic> _sortQueueKeysByQueuedAt(Box box) {
    return _sortedEncryptedEntries(ProxyStorageBox.queue, box, 'queuedAt')
        .map((entry) => entry.key)
        .toList();
  }

  /// キューの個別アイテムを処理します。
  ///
  /// [box] 対象のキュー保存領域。停止処理と競合しないよう呼び出し側から受け取ります。
  /// [key] 処理するキューのキー。
  Future<void> _processQueuedItem(Box box, dynamic key) async {
    final data = box.get(key) as Map?;
    if (data == null) return;

    final itemUrl = data['url'] as String? ?? '';
    final nextRetryAtValue = data['nextRetryAt'] as String?;
    if (nextRetryAtValue != null) {
      final nextRetryAt = DateTime.tryParse(nextRetryAtValue);
      if (nextRetryAt != null && DateTime.now().isBefore(nextRetryAt)) {
        return;
      }
    }

    try {
      final result = await _sendQueuedRequest(data);

      // 送信の後の保存が終わるまで stop() が Box を閉じないよう、保存中であることを示す
      final saving = Completer<void>();
      _queuedItemSaving = saving.future;
      try {
        // 送信中に stop() が実行された場合は閉じた保存領域へ書き込まない。
        // Box を閉じ始めた後は保存を始めず、キューに残して次の起動で再送する
        if (!box.isOpen || _isClosingStorage) {
          return;
        }

        if (result.success) {
          await box.delete(key);
          _recordResendResult(
            data,
            statusCode: result.statusCode,
            success: true,
            willRetry: false,
          );
          _emitEvent(ProxyEventType.queueDrained, itemUrl, {
            'statusCode': result.statusCode,
            'idempotencyKey': data['idempotencyKey'],
          });
        } else if (result.shouldDrop) {
          final reason = result.dropReason ?? 'dropped';
          final errorMessage =
              result.errorMessage ?? 'HTTP ${result.statusCode}';

          if ((_config?.dropPolicy ?? DropPolicy.quarantine) ==
              DropPolicy.quarantine) {
            // 本文ごと隔離してから取り除き、退避に失敗した場合は消さない
            final quarantine = await _quarantineRequest(
              data,
              statusCode: result.statusCode,
              reason: reason,
              errorMessage: errorMessage,
              queueBox: box,
              queueKey: key,
            );
            if (quarantine.tooLarge) {
              // 1 件で隔離の合計バイト数の上限を超えるため、本文を持たない履歴へ
              // 記録し、同じ 4xx を再試行し続けないようキューから取り除いた
              _recordResendResult(
                data,
                statusCode: result.statusCode,
                success: false,
                dropReason: reason,
                willRetry: false,
              );
              _emitEvent(ProxyEventType.requestDropped, itemUrl, {
                'statusCode': result.statusCode,
                'dropReason': _quarantineTooLargeDropReason,
              });
              return;
            }

            final quarantineId = quarantine.quarantineId;
            if (quarantineId == null) {
              // 退避できない間も 5 秒ごとに同じ 4xx を叩き続けないよう待たせる
              _updateRetrySchedule(data);
              await box.put(key, data);
              _recordResendResult(
                data,
                statusCode: result.statusCode,
                success: false,
                dropReason: reason,
                willRetry: true,
              );
              return;
            }

            // キューからは、隔離した直後に隔離のロックの中で取り除いている
            _recordResendResult(
              data,
              statusCode: result.statusCode,
              success: false,
              dropReason: reason,
              willRetry: false,
            );
            _emitEvent(ProxyEventType.requestQuarantined, itemUrl, {
              'quarantineId': quarantineId,
              'statusCode': result.statusCode,
              'reason': reason,
            });
          } else {
            // 履歴を残してから取り除き、キューから消えたのに記録が無い状態を作らない
            final recorded = await _recordDroppedRequest(
              data,
              statusCode: result.statusCode,
              dropReason: reason,
              errorMessage: errorMessage,
            );
            if (!recorded) {
              // 記録できない間も 5 秒ごとに同じ 4xx を叩き続けないよう待たせる
              _updateRetrySchedule(data);
              await box.put(key, data);
              _recordResendResult(
                data,
                statusCode: result.statusCode,
                success: false,
                dropReason: reason,
                willRetry: true,
              );
              return;
            }
            await box.delete(key);
            _recordResendResult(
              data,
              statusCode: result.statusCode,
              success: false,
              dropReason: reason,
              willRetry: false,
            );
            _emitEvent(ProxyEventType.requestDropped, itemUrl, {
              'statusCode': result.statusCode,
              'dropReason': result.dropReason,
            });
          }
        } else {
          _updateRetrySchedule(data);
          await box.put(key, data);
          _recordResendResult(
            data,
            statusCode: result.statusCode,
            success: false,
            willRetry: true,
          );
        }
      } finally {
        saving.complete();
        if (identical(_queuedItemSaving, saving.future)) {
          _queuedItemSaving = null;
        }
      }
    } catch (e) {
      if (!box.isOpen || _isClosingStorage) {
        return;
      }

      _updateRetrySchedule(data);
      await box.put(key, data);
      // 上流へ到達できなかった場合もステータス 0 として結果を残す
      _recordResendResult(
        data,
        statusCode: 0,
        success: false,
        willRetry: true,
      );
    }
  }

  /// キューされたリクエストを上流サーバに送信します。
  ///
  /// キューデータからHTTPリクエストを再構築し、
  /// 上流サーバに送信して成功判定を行います。
  ///
  /// [data] キューデータ。
  ///
  /// Returns: 送信成功時は `true`。
  Future<
      ({
        bool success,
        bool shouldDrop,
        int statusCode,
        String? dropReason,
        String? errorMessage,
      })> _sendQueuedRequest(Map data) async {
    if (_config?.origin.isEmpty ?? true) {
      return (
        success: false,
        shouldDrop: false,
        statusCode: 0,
        dropReason: null,
        errorMessage: 'No upstream origin configured',
      );
    }

    final url = data['url'] as String;
    final method = data['method'] as String;
    final headers = Map<String, String>.from(data['headers'] as Map? ?? {});
    final body = data['body'] as List<int>? ?? [];
    final idempotencyKey = data['idempotencyKey'] as String?;

    // 既に上流へ届いたことが分かっている場合は送り直さない
    if (idempotencyKey != null && _isIdempotencyKeyCompleted(idempotencyKey)) {
      return (
        success: true,
        shouldDrop: false,
        statusCode: HttpStatus.ok,
        dropReason: null,
        errorMessage: null,
      );
    }

    final client = _getOrCreateHttpClient();

    // 転送と同じく、再送 1 回あたりの待ち時間を締め切りで抑える
    final deadline =
        DateTime.now().add(_config?.requestTimeout ?? _defaultRequestTimeout);

    try {
      Uri uri = Uri.parse(url);

      // 互換性: 旧キューデータが相対URLだった場合は origin を付与
      if (!uri.isAbsolute) {
        if (_config?.origin.isEmpty ?? true) {
          return (
            success: false,
            shouldDrop: false,
            statusCode: 0,
            dropReason: null,
            errorMessage: 'No upstream origin configured',
          );
        }

        uri = _buildUpstreamUriFromParts(path: url);
      }
      final request =
          await client.openUrl(method, uri).timeout(_remainingUntil(deadline));

      await _applyQueuedRequestHeaders(
        request,
        upstreamUri: uri,
        requestHeaders: headers,
      );

      // 再送のたびに同じキーを送り、上流側で重複を判別できるようにする
      if (idempotencyKey != null) {
        request.headers.set(
          _config?.idempotencyHeaderName ?? _defaultIdempotencyHeaderName,
          idempotencyKey,
        );
      }

      // 初回転送と同じ値を送り、受け付けた時点を上流へ伝える
      _applyAcceptedAtHeader(request, _resolveQueuedAcceptedAt(data));

      if (body.isNotEmpty && method != 'GET') {
        request.add(body);
      }

      final response = await request.close().timeout(_remainingUntil(deadline));

      // 上流がステータス行を返した時点で到達可能と判定する（4xx / 5xx でもサーバは生きている）
      _recordUpstreamSuccess();

      // 本文を読み捨てないと接続が解放されず、後続の再送が空き待ちで止まる
      await _drainResponse(response, deadline);

      // 2xxステータスコードを成功とみなす
      final statusCode = response.statusCode;
      if (statusCode >= 200 && statusCode < 300) {
        if (idempotencyKey != null) {
          await _recordIdempotencyKey(idempotencyKey);
        }

        return (
          success: true,
          shouldDrop: false,
          statusCode: statusCode,
          dropReason: null,
          errorMessage: null,
        );
      }

      if (statusCode >= 400 && statusCode < 500) {
        return (
          success: false,
          shouldDrop: true,
          statusCode: statusCode,
          dropReason: '4xx_error',
          errorMessage: 'HTTP $statusCode',
        );
      }

      return (
        success: false,
        shouldDrop: false,
        statusCode: statusCode,
        dropReason: null,
        errorMessage: 'HTTP $statusCode',
      );
    } catch (e) {
      // 画面操作が無い状況でも上流断を検知できるよう、再送の失敗も判定に含める。
      // 接続確立の失敗が最も多いため、応答受信より前の例外もここで受け取る。
      if (_shouldCountUpstreamFailure(e)) {
        _recordUpstreamFailure();
      }

      return (
        success: false,
        shouldDrop: false,
        statusCode: 0,
        dropReason: null,
        errorMessage: e.toString(),
      );
    } finally {
      // 共有クライアントをここで閉じない
    }
  }

  /// 上流からの応答本文を締め切り付きで読み取ります。
  ///
  /// 締め切りを過ぎた場合は購読を打ち切って接続を破棄します。読み取りを
  /// 放置すると、応答が遅い上流に対して `HttpClient` の接続枠を占有し続け、
  /// 後続のリクエストが空き待ちで滞留します。
  ///
  /// [response] 読み取る上流応答。
  /// [deadline] リクエスト全体の締め切り。
  ///
  /// Returns: 受信した本文。
  ///
  /// Throws:
  ///   * [TimeoutException] 締め切りまでに読み切れなかった場合。
  Future<Uint8List> _readResponseBytes(
    HttpClientResponse response,
    DateTime deadline,
  ) async {
    final builder = BytesBuilder(copy: false);
    await _consumeResponseBody(response, deadline, onData: builder.add);
    return builder.takeBytes();
  }

  /// 上流からの応答本文を読み捨てて接続を解放します。
  ///
  /// 本文を読み切らないと `HttpClient` の接続が解放されず、キューの再送が
  /// `maxConnectionsPerHost` に達した時点で空き待ちのまま停止します。
  /// 応答を返した事実だけを使うため、読み切れない場合も例外にしません。
  ///
  /// [response] 読み捨てる上流応答。
  /// [deadline] リクエスト全体の締め切り。
  Future<void> _drainResponse(
    HttpClientResponse response,
    DateTime deadline,
  ) async {
    try {
      await _consumeResponseBody(response, deadline);
    } catch (_) {
      // 読み切れなくても、受信済みのステータスによる判定は続行する
    }
  }

  /// 上流からの応答本文を締め切り付きで受信します。
  ///
  /// [onData] を省略した場合は読み捨てます。締め切りを過ぎた場合や受信に
  /// 失敗した場合は購読を打ち切り、接続を破棄します。
  ///
  /// [response] 受信する上流応答。
  /// [deadline] リクエスト全体の締め切り。
  /// [onData] 受信したチャンクの受け取り先。
  ///
  /// Throws:
  ///   * [TimeoutException] 締め切りまでに受信し切れなかった場合。
  Future<void> _consumeResponseBody(
    HttpClientResponse response,
    DateTime deadline, {
    void Function(List<int> chunk)? onData,
  }) async {
    final subscription = response.listen(onData, cancelOnError: true);
    try {
      await subscription.asFuture<void>().timeout(_remainingUntil(deadline));
    } catch (_) {
      // 受信を打ち切る場合も接続を残さない
      await subscription.cancel();
      rethrow;
    }
  }

  /// 内部で再利用するHttpClientインスタンスを返却します。
  ///
  /// 共有HttpClientをインスタンスで保持し、個々のリクエストで
  /// 再生成しないようにします。アプリケーション終了時に `stop()` で
  /// `close()` します。
  ///
  /// 自動解凍は生成時に無効へ固定します。共有インスタンスのため、
  /// 利用箇所ごとに書き換えると同時実行時に互いの設定を上書きします。
  /// また解凍だけを行うと `Content-Encoding` が残ったまま本文が
  /// 非圧縮になり、そのまま保存すると復元できない組になります。
  HttpClient _getOrCreateHttpClient() {
    if (_httpClient != null) return _httpClient!;

    _httpClient = HttpClient()
      ..connectionTimeout = _config?.connectTimeout ?? _defaultConnectTimeout
      ..autoUncompress = false
      ..maxConnectionsPerHost = 50;

    return _httpClient!;
  }

  /// 期限切れキャッシュをパージします。
  /// エラーが発生しても例外をスローしません。
  Future<void> _purgeExpiredCache() async {
    try {
      await clearExpiredCache();
    } catch (e) {
      // エラーをログ出力するが例外はスローしない
    }
  }

  /// オフライン時のフォールバックHTMLコンテンツを取得します。
  ///
  /// GETリクエストでキャッシュが見つからない場合に
  /// 表示するユーザーフレンドリーなメッセージを返却します。
  /// 差し替え HTML は、目印だけを監視スクリプトへ置き換えます。
  ///
  /// Returns: オフライン用HTMLコンテンツ。
  String _getOfflineFallbackContent() {
    final options =
        _buildOfflineRecoveryOptions(OfflineRecoveryPageKind.offlineFallback);
    final customContent = _config?.offlineFallbackHtml;
    if (customContent != null && customContent.isNotEmpty) {
      return applyOfflineRecoveryPlaceholder(customContent, options);
    }

    return buildDefaultOfflineRecoveryPage(options);
  }

  /// 代替ページと 504 ページへ埋め込む監視スクリプトの設定を組み立てます。
  ///
  /// [pageKind] 埋め込み先のページの種類。
  ///
  /// Returns: 現在の設定に基づく監視スクリプトの設定。
  OfflineRecoveryScriptOptions _buildOfflineRecoveryOptions(
    OfflineRecoveryPageKind pageKind,
  ) {
    final config = _config;
    return OfflineRecoveryScriptOptions(
      pageKind: pageKind,
      statusPath: _statusPath,
      pollInterval:
          config?.autoReloadPollInterval ?? _defaultAutoReloadPollInterval,
      queueWaitTimeout: config?.autoReloadQueueWaitTimeout ??
          _defaultAutoReloadQueueWaitTimeout,
      requestTimeout: config?.requestTimeout ?? _defaultRequestTimeout,
      offlinePageAutoReload: config?.enableOfflinePageAutoReload ?? true,
      continuation: config?.enableAutoReloadContinuation ?? true,
      gatewayTimeoutAutoReload: config?.enableGatewayTimeoutAutoReload ?? false,
    );
  }

  /// プロキシイベントを発生させます。
  ///
  /// イベントストリームにイベントを送信し、リアルタイム監視や
  /// ログ出力に使用されます。ストリームが閉じている場合は無視します。
  ///
  /// [type] イベントタイプ。
  /// [url] 関連するURL。
  /// [data] 追加情報。
  void _emitEvent(ProxyEventType type, String url, Map<String, dynamic> data) {
    if (!_eventController.isClosed) {
      _eventController.add(ProxyEvent(
        type: type,
        url: url,
        timestamp: DateTime.now(),
        data: data,
      ));
    }
  }

  // ──────────────────────────────────────────────────────
  // データマッピング用ヘルパーメソッド
  // ──────────────────────────────────────────────────────

  /// HiveのマップデータをCacheEntryオブジェクトに変換します。
  ///
  /// [data] Hiveから読み込んだキャッシュデータ。
  ///
  /// Returns: 変換されたCacheEntryオブジェクト。
  CacheEntry _mapToCacheEntry(Map data) {
    return CacheEntry(
      url: data['url'] as String? ?? '',
      statusCode: data['statusCode'] as int? ?? 0,
      contentType: data['contentType'] as String? ?? '',
      createdAt: DateTime.parse(
          data['createdAt'] as String? ?? DateTime.now().toIso8601String()),
      expiresAt: DateTime.parse(
          data['expiresAt'] as String? ?? DateTime.now().toIso8601String()),
      status: _determineStatus(data),
      sizeBytes: data['sizeBytes'] as int? ?? 0,
    );
  }

  /// キャッシュデータからキャッシュ状態を判定します。
  ///
  /// TTL、Stale期限と現在時刻を比較して、
  /// キャッシュの状態を判定します。
  ///
  /// [data] キャッシュデータ。
  ///
  /// Returns: キャッシュ状態。
  CacheStatus _determineStatus(Map data) {
    final now = DateTime.now();
    final expiresAt = DateTime.parse(data['expiresAt'] as String);
    final contentType =
        data['contentType'] as String? ?? 'application/octet-stream';

    if (now.isBefore(expiresAt)) {
      return CacheStatus.fresh;
    }

    final staleUntil = _calculateStaleExpiration(expiresAt, contentType);
    if (now.isBefore(staleUntil)) {
      return CacheStatus.stale;
    }

    return CacheStatus.expired;
  }

  /// HiveのマップデータをCookieInfoオブジェクトに変換します。
  ///
  /// セキュリティのためCookie値は常にマスクされます。
  ///
  /// [data] Hiveから読み込んだCookieデータ。
  ///
  /// Returns: 変換されたCookieInfoオブジェクト。
  CookieInfo _mapToCookieInfo(Map data) {
    return CookieInfo(
      name: data['name'] as String? ?? '',
      value: '***', // セキュリティのため常に値をマスク
      domain: data['domain'] as String? ?? '',
      path: data['path'] as String? ?? '/',
      expires: data['expires'] != null
          ? DateTime.parse(data['expires'] as String)
          : null,
      secure: data['secure'] as bool? ?? false,
      sameSite: data['sameSite'] as String?,
    );
  }

  /// HiveのマップデータをQueuedRequestオブジェクトに変換します。
  ///
  /// キューに保存されたリクエスト情報をオブジェクトに再構築します。
  /// 機密情報を含み得るヘッダの値はマスクします。
  ///
  /// [data] Hiveから読み込んだキューデータ。
  /// [pendingMigration] 移行を待っている旧平文キューの項目かどうか。
  ///
  /// Returns: 変換されたQueuedRequestオブジェクト。
  QueuedRequest _mapToQueuedRequest(Map data, {bool pendingMigration = false}) {
    return QueuedRequest(
      url: data['url'] as String? ?? '',
      method: data['method'] as String? ?? 'GET',
      headers: _maskSensitiveHeaders(
        Map<String, String>.from(data['headers'] as Map? ?? {}),
      ),
      pendingMigration: pendingMigration,
      queuedAt: DateTime.parse(
          data['queuedAt'] as String? ?? DateTime.now().toIso8601String()),
      acceptedAt: DateTime.tryParse(_resolveQueuedAcceptedAt(data) ?? '') ??
          DateTime.now(),
      retryCount: data['retryCount'] as int? ?? 0,
      nextRetryAt: DateTime.parse(
          data['nextRetryAt'] as String? ?? DateTime.now().toIso8601String()),
    );
  }

  /// Hive のマップデータを DroppedRequest オブジェクトに変換します。
  ///
  /// [data] Hive から読み込んだドロップ履歴データです。
  /// [pendingMigration] 移行を待っている旧平文履歴の項目かどうかです。
  /// 戻り値は変換された [DroppedRequest] オブジェクトです。
  DroppedRequest _mapToDroppedRequest(
    Map data, {
    bool pendingMigration = false,
  }) {
    return DroppedRequest(
      pendingMigration: pendingMigration,
      url: data['url'] as String? ?? '',
      method: data['method'] as String? ?? 'GET',
      droppedAt: DateTime.parse(
        data['droppedAt'] as String? ?? DateTime.now().toIso8601String(),
      ),
      dropReason: data['dropReason'] as String? ?? 'dropped',
      statusCode: data['statusCode'] as int? ?? 0,
      errorMessage: data['errorMessage'] as String? ?? '',
      // 旧バージョンの履歴には項目が無いため、未確認として扱う
      acknowledged: data['acknowledged'] as bool? ?? false,
    );
  }

  /// 遷移先 URL を proxy / upstream / 外部のいずれかへ解決します。
  ProxyNavigationResolution _resolveNavigationTargetInternal({
    required String targetUrl,
    String? sourceUrl,
  }) {
    final trimmedTargetUrl = targetUrl.trim();
    if (trimmedTargetUrl.isEmpty) {
      return _buildNavigationResolution(
        inputUrl: targetUrl,
        disposition: ProxyNavigationDisposition.invalid,
        reason: ProxyNavigationReason.invalidUrl,
      );
    }

    final parsedTargetUri = Uri.tryParse(trimmedTargetUrl);
    if (parsedTargetUri == null) {
      return _buildNavigationResolution(
        inputUrl: targetUrl,
        disposition: ProxyNavigationDisposition.invalid,
        reason: ProxyNavigationReason.invalidUrl,
      );
    }

    final needsSourceUrl = !parsedTargetUri.hasScheme;
    Uri? resolvedSourceUri;
    var usedSourceUrl = false;
    Uri normalizedTargetUri;

    if (needsSourceUrl) {
      final trimmedSourceUrl = sourceUrl?.trim();
      if (trimmedSourceUrl == null || trimmedSourceUrl.isEmpty) {
        return _buildNavigationResolution(
          inputUrl: targetUrl,
          disposition: ProxyNavigationDisposition.unresolved,
          reason: ProxyNavigationReason.relativeUrlWithoutSource,
        );
      }

      resolvedSourceUri = _tryParseAbsoluteHttpUrl(trimmedSourceUrl);
      if (resolvedSourceUri == null) {
        return _buildNavigationResolution(
          inputUrl: targetUrl,
          disposition: ProxyNavigationDisposition.unresolved,
          reason: ProxyNavigationReason.invalidSourceUrl,
        );
      }

      normalizedTargetUri = resolvedSourceUri.resolveUri(parsedTargetUri);
      usedSourceUrl = true;
    } else {
      normalizedTargetUri = parsedTargetUri;
    }

    final scheme = normalizedTargetUri.scheme.toLowerCase();
    if (!_isHttpScheme(scheme)) {
      return _buildNavigationResolution(
        inputUrl: targetUrl,
        sourceUri: resolvedSourceUri,
        normalizedTargetUri: normalizedTargetUri,
        disposition: ProxyNavigationDisposition.external,
        reason: ProxyNavigationReason.nonHttpScheme,
        usedSourceUrl: usedSourceUrl,
      );
    }

    final targetIsProxyUrl = _isProxyEndpointUri(normalizedTargetUri);
    final usedLoopbackAlias = targetIsProxyUrl &&
        _config != null &&
        normalizedTargetUri.host.toLowerCase() != _config!.host.toLowerCase() &&
        _isLoopbackHost(normalizedTargetUri.host) &&
        _isLoopbackHost(_config!.host);

    if (targetIsProxyUrl) {
      final isStaticResource =
          _isIndexedStaticResourcePath(normalizedTargetUri.path);
      if (isStaticResource) {
        return _buildNavigationResolution(
          inputUrl: targetUrl,
          sourceUri: resolvedSourceUri,
          normalizedTargetUri: normalizedTargetUri,
          proxyUri: normalizedTargetUri,
          disposition: ProxyNavigationDisposition.localOnly,
          reason: ProxyNavigationReason.staticResource,
          usedSourceUrl: usedSourceUrl,
          usedLoopbackAlias: usedLoopbackAlias,
          isStaticResource: true,
        );
      }

      final upstreamUri = _tryBuildUpstreamUriFromPathAndQuery(
        path: normalizedTargetUri.path,
        query: normalizedTargetUri.query,
        fragment: normalizedTargetUri.fragment,
      );
      if (upstreamUri == null) {
        return _buildNavigationResolution(
          inputUrl: targetUrl,
          sourceUri: resolvedSourceUri,
          normalizedTargetUri: normalizedTargetUri,
          proxyUri: normalizedTargetUri,
          disposition: ProxyNavigationDisposition.unresolved,
          // ミラー中継のパスは origin の設定有無ではなく許可の有無で決まる
          reason: _isMirroredOriginPath(normalizedTargetUri.path)
              ? ProxyNavigationReason.outsideProxyScope
              : ProxyNavigationReason.missingConfiguredOrigin,
          usedSourceUrl: usedSourceUrl,
          usedLoopbackAlias: usedLoopbackAlias,
        );
      }

      return _buildNavigationResolution(
        inputUrl: targetUrl,
        sourceUri: resolvedSourceUri,
        normalizedTargetUri: normalizedTargetUri,
        upstreamUri: upstreamUri,
        proxyUri: normalizedTargetUri,
        disposition: ProxyNavigationDisposition.inWebView,
        reason: ProxyNavigationReason.proxyUrl,
        usedSourceUrl: usedSourceUrl,
        usedLoopbackAlias: usedLoopbackAlias,
      );
    }

    if (_isSameOriginAsConfiguredOrigin(normalizedTargetUri)) {
      final proxyUri = _buildProxyUriFromUpstreamUri(normalizedTargetUri);
      if (proxyUri == null) {
        return _buildNavigationResolution(
          inputUrl: targetUrl,
          sourceUri: resolvedSourceUri,
          normalizedTargetUri: normalizedTargetUri,
          upstreamUri: normalizedTargetUri,
          disposition: ProxyNavigationDisposition.unresolved,
          reason: ProxyNavigationReason.outsideProxyScope,
          usedSourceUrl: usedSourceUrl,
        );
      }

      return _buildNavigationResolution(
        inputUrl: targetUrl,
        sourceUri: resolvedSourceUri,
        normalizedTargetUri: normalizedTargetUri,
        upstreamUri: normalizedTargetUri,
        proxyUri: proxyUri,
        disposition: ProxyNavigationDisposition.inWebView,
        reason: ProxyNavigationReason.configuredOriginUrl,
        usedSourceUrl: usedSourceUrl,
      );
    }

    if (_isMirroredOrigin(normalizedTargetUri)) {
      final proxyUri = _buildMirroredProxyUri(normalizedTargetUri);
      if (proxyUri == null) {
        return _buildNavigationResolution(
          inputUrl: targetUrl,
          sourceUri: resolvedSourceUri,
          normalizedTargetUri: normalizedTargetUri,
          upstreamUri: normalizedTargetUri,
          disposition: ProxyNavigationDisposition.unresolved,
          reason: ProxyNavigationReason.outsideProxyScope,
          usedSourceUrl: usedSourceUrl,
        );
      }

      return _buildNavigationResolution(
        inputUrl: targetUrl,
        sourceUri: resolvedSourceUri,
        normalizedTargetUri: normalizedTargetUri,
        upstreamUri: normalizedTargetUri,
        proxyUri: proxyUri,
        disposition: ProxyNavigationDisposition.inWebView,
        reason: ProxyNavigationReason.mirroredOriginUrl,
        usedSourceUrl: usedSourceUrl,
      );
    }

    if (_isLoopbackHttpUri(normalizedTargetUri)) {
      // ポートのみが現行ポートと異なる旧 proxy URL は現行ポートへ読み替える
      final rewrittenProxyUri =
          resolveReloadUri(normalizedTargetUri.toString());
      if (rewrittenProxyUri != null) {
        return _buildNavigationResolution(
          inputUrl: targetUrl,
          sourceUri: resolvedSourceUri,
          normalizedTargetUri: normalizedTargetUri,
          upstreamUri: _tryBuildUpstreamUriFromPathAndQuery(
            path: rewrittenProxyUri.path,
            query: rewrittenProxyUri.query,
            fragment: rewrittenProxyUri.fragment,
          ),
          proxyUri: rewrittenProxyUri,
          disposition: ProxyNavigationDisposition.inWebView,
          reason: ProxyNavigationReason.stalePortUrl,
          usedSourceUrl: usedSourceUrl,
          usedLoopbackAlias: normalizedTargetUri.host.toLowerCase() !=
              _effectiveHost.toLowerCase(),
        );
      }

      return _buildNavigationResolution(
        inputUrl: targetUrl,
        sourceUri: resolvedSourceUri,
        normalizedTargetUri: normalizedTargetUri,
        disposition: ProxyNavigationDisposition.unresolved,
        reason: ProxyNavigationReason.unknownLoopbackUrl,
        usedSourceUrl: usedSourceUrl,
      );
    }

    return _buildNavigationResolution(
      inputUrl: targetUrl,
      sourceUri: resolvedSourceUri,
      normalizedTargetUri: normalizedTargetUri,
      disposition: ProxyNavigationDisposition.external,
      reason: ProxyNavigationReason.externalOrigin,
      usedSourceUrl: usedSourceUrl,
    );
  }

  /// WebView delegate 向けの推奨アクションを構築します。
  ProxyWebViewNavigationRecommendation _recommendWebViewNavigation({
    required String targetUrl,
    String? sourceUrl,
    required bool allowInPlace,
  }) {
    final resolution = _resolveNavigationTargetInternal(
      targetUrl: targetUrl,
      sourceUrl: sourceUrl,
    );

    switch (resolution.disposition) {
      case ProxyNavigationDisposition.external:
        final externalUri = resolution.normalizedTargetUri;
        if (externalUri == null) {
          return ProxyWebViewNavigationRecommendation.cancel(
            resolution: resolution,
          );
        }
        return ProxyWebViewNavigationRecommendation.launchExternal(
          resolution: resolution,
          externalUri: externalUri,
        );
      case ProxyNavigationDisposition.unresolved:
      case ProxyNavigationDisposition.invalid:
        return ProxyWebViewNavigationRecommendation.cancel(
          resolution: resolution,
        );
      case ProxyNavigationDisposition.inWebView:
      case ProxyNavigationDisposition.localOnly:
        final proxyUri = resolution.proxyUri;
        if (proxyUri == null) {
          return ProxyWebViewNavigationRecommendation.cancel(
            resolution: resolution,
          );
        }

        if (allowInPlace && _canAllowWebViewNavigationInPlace(resolution)) {
          return ProxyWebViewNavigationRecommendation.allow(
            resolution: resolution,
          );
        }

        return ProxyWebViewNavigationRecommendation.loadProxyUrl(
          resolution: resolution,
          webViewUri: proxyUri,
        );
    }
  }

  /// WebView が現在の navigation をそのまま継続できるかどうかを返します。
  bool _canAllowWebViewNavigationInPlace(
    ProxyNavigationResolution resolution,
  ) {
    final normalizedTargetUri = resolution.normalizedTargetUri;
    final proxyUri = resolution.proxyUri;
    if (normalizedTargetUri == null || proxyUri == null) {
      return false;
    }

    return normalizedTargetUri == proxyUri;
  }

  /// 解決結果オブジェクトを構築します。
  ProxyNavigationResolution _buildNavigationResolution({
    required String inputUrl,
    required ProxyNavigationDisposition disposition,
    required ProxyNavigationReason reason,
    Uri? sourceUri,
    Uri? normalizedTargetUri,
    Uri? upstreamUri,
    Uri? proxyUri,
    bool usedSourceUrl = false,
    bool usedLoopbackAlias = false,
    bool isStaticResource = false,
  }) {
    return ProxyNavigationResolution(
      inputUrl: inputUrl,
      sourceUri: sourceUri,
      normalizedTargetUri: normalizedTargetUri,
      upstreamUri: upstreamUri,
      proxyUri: proxyUri,
      disposition: disposition,
      reason: reason,
      usedSourceUrl: usedSourceUrl,
      usedLoopbackAlias: usedLoopbackAlias,
      isStaticResource: isStaticResource,
    );
  }

  /// 現在稼働中の proxy ポートを返します。
  int? get _activeProxyPort => _boundPort;

  /// HTTP または HTTPS スキームかどうかを返します。
  bool _isHttpScheme(String scheme) {
    return scheme == 'http' || scheme == 'https';
  }

  /// redirect として明示処理する HTTP ステータスかどうかを返します。
  bool _isRedirectStatusCode(int statusCode) {
    return _redirectStatusCodes.contains(statusCode);
  }

  /// URL 文字列を絶対 HTTP(S) URI として解釈します。
  Uri? _tryParseAbsoluteHttpUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return null;
    }
    if (!_isHttpScheme(uri.scheme.toLowerCase()) || uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  /// proxy の loopback エンドポイント URL かどうかを返します。
  bool _isProxyEndpointUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'http' || uri.host.isEmpty) {
      return false;
    }

    final proxyPort = _activeProxyPort;
    if (proxyPort == null || _effectivePort(uri) != proxyPort) {
      return false;
    }

    final configuredHost = _config?.host ?? '';
    if (configuredHost.isNotEmpty &&
        uri.host.toLowerCase() == configuredHost.toLowerCase()) {
      return true;
    }

    return configuredHost.isNotEmpty &&
        _isLoopbackHost(uri.host) &&
        _isLoopbackHost(configuredHost);
  }

  /// loopback ホスト名かどうかを返します。
  bool _isLoopbackHost(String host) {
    return _loopbackHosts.contains(host.toLowerCase());
  }

  /// loopback の HTTP(S) URL かどうかを返します。
  bool _isLoopbackHttpUri(Uri uri) {
    return uri.scheme.toLowerCase() == 'http' && _isLoopbackHost(uri.host);
  }

  /// 起動時に AssetManifest を走査して静的リソース一覧を構築します。
  Future<void> _initializeStaticResourceIndex() async {
    _staticResourceAssetMap.clear();
    _staticResourceEntityTags.clear();

    try {
      for (final key in await _loadStaticResourceAssetKeys()) {
        final publicPath = _toStaticResourcePublicPath(key);
        if (publicPath == null) {
          continue;
        }

        _staticResourceAssetMap.putIfAbsent(publicPath, () => key);
      }
    } catch (_) {
      // 静的資産を使わないアプリでも起動できるよう、失敗時は空一覧で継続する。
    }
  }

  /// AssetManifest から asset key 一覧を読み込みます。
  Future<Iterable<String>> _loadStaticResourceAssetKeys() async {
    try {
      final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      return assetManifest.listAssets();
    } catch (_) {
      final assetManifestJson =
          await rootBundle.loadString('AssetManifest.json');
      final decoded = jsonDecode(assetManifestJson);
      if (decoded is! Map) {
        return const <String>[];
      }
      return decoded.keys.whereType<String>();
    }
  }

  /// 起動時に構築した静的リソース一覧に存在する path かどうかを返します。
  bool _isIndexedStaticResourcePath(String path) {
    return _staticResourceAssetMap
        .containsKey(_normalizeStaticResourceRequestPath(path));
  }

  /// リクエスト path を静的リソース一覧照合用に正規化します。
  String _normalizeStaticResourceRequestPath(String path) {
    final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
    return normalizedPath.replaceAll('\\', '/');
  }

  /// asset key を proxy 公開 URL の path へ変換します。
  String? _toStaticResourcePublicPath(String assetKey) {
    for (final prefix in _staticResourceAssetPrefixes) {
      if (!assetKey.startsWith(prefix)) {
        continue;
      }

      final suffix = assetKey.substring(prefix.length).replaceAll('\\', '/');
      if (suffix.isEmpty) {
        return null;
      }

      return suffix.startsWith('/') ? suffix.substring(1) : suffix;
    }

    return null;
  }

  /// path と query から upstream URI を構築します。
  Uri _buildUpstreamUriFromParts({
    required String path,
    String query = '',
    String fragment = '',
  }) {
    final upstreamUri = _tryBuildUpstreamUriFromPathAndQuery(
      path: path,
      query: query,
      fragment: fragment,
    );
    if (upstreamUri == null) {
      // 中継のパスは origin の設定ではなく許可の有無で決まるため、
      // ウォームアップの失敗理由として区別できるようにする。
      throw StateError(
        _isMirroredOriginPath(path)
            ? 'Mirrored origin is not allowed: $path'
            : 'No upstream origin configured',
      );
    }
    return upstreamUri;
  }

  /// path と query から upstream URI を構築します。
  ///
  /// ミラー中継のパスは設定した別 origin へ、それ以外は設定済み origin へ
  /// 解決します。転送、キャッシュキー、ウォームアップ、遷移解決が同じ
  /// 対応関係を使えるよう、パスから upstream への変換はここに集約します。
  ///
  /// [path] proxy が受け取ったパス。
  /// [query] クエリ文字列。
  /// [fragment] フラグメント。
  ///
  /// Returns: upstream URI。解決できない場合は `null`。
  Uri? _tryBuildUpstreamUriFromPathAndQuery({
    required String path,
    String query = '',
    String fragment = '',
  }) {
    if (_isMirroredOriginPath(path)) {
      // 許可していない origin を設定済み origin へ素通しさせない
      return _tryResolveMirroredUpstreamUri(
        path: path,
        query: query,
        fragment: fragment,
      );
    }

    final originUri = _configuredOriginUri;
    if (originUri == null) {
      return null;
    }

    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final originBase =
        originUri.replace(query: null, fragment: null).toString();
    final baseWithoutTrailingSlash = originBase.endsWith('/')
        ? originBase.substring(0, originBase.length - 1)
        : originBase;
    final querySuffix = query.isNotEmpty ? '?$query' : '';
    final fragmentSuffix = fragment.isNotEmpty ? '#$fragment' : '';
    return Uri.parse(
      '$baseWithoutTrailingSlash$normalizedPath$querySuffix$fragmentSuffix',
    );
  }

  /// upstream URI から対応する proxy URI を構築します。
  Uri? _buildProxyUriFromUpstreamUri(Uri upstreamUri) {
    if (!_isSameOriginAsConfiguredOrigin(upstreamUri)) {
      return null;
    }

    final proxyPort = _activeProxyPort;
    if (proxyPort == null) {
      return null;
    }

    final originUri = _configuredOriginUri;
    if (originUri == null) {
      return null;
    }

    final proxyPath =
        _stripConfiguredOriginPathPrefix(upstreamUri.path, originUri.path);
    if (proxyPath == null) {
      return null;
    }

    final configuredHost =
        (_config?.host.isNotEmpty ?? false) ? _config!.host : '127.0.0.1';
    final querySuffix =
        upstreamUri.query.isNotEmpty ? '?${upstreamUri.query}' : '';
    final fragmentSuffix =
        upstreamUri.fragment.isNotEmpty ? '#${upstreamUri.fragment}' : '';
    return Uri.parse(
      'http://$configuredHost:$proxyPort$proxyPath$querySuffix$fragmentSuffix',
    );
  }

  /// ミラー対象 origin を比較用に正規化します。
  ///
  /// [origin] 設定に書かれた origin。
  ///
  /// Returns: scheme と host を小文字化し、パス以降を落とした URI。
  ///   origin として解釈できない場合は `null`。
  Uri? _tryNormalizeMirroredOrigin(String origin) {
    final trimmedOrigin = origin.trim();
    if (trimmedOrigin.isEmpty) {
      return null;
    }

    final parsedOrigin = Uri.tryParse(trimmedOrigin);
    if (parsedOrigin == null ||
        !_isHttpScheme(parsedOrigin.scheme.toLowerCase()) ||
        parsedOrigin.host.isEmpty) {
      return null;
    }

    // origin はスキーム、ホスト、ポートだけを指す。パスやクエリを許すと
    // 一致判定の意味が変わるため、含む値は設定の誤りとして扱う。
    if ((parsedOrigin.path.isNotEmpty && parsedOrigin.path != '/') ||
        parsedOrigin.hasQuery ||
        parsedOrigin.hasFragment ||
        parsedOrigin.userInfo.isNotEmpty) {
      return null;
    }

    return Uri(
      scheme: parsedOrigin.scheme.toLowerCase(),
      host: parsedOrigin.host.toLowerCase(),
      port: parsedOrigin.hasPort ? parsedOrigin.port : null,
    );
  }

  /// 指定 URI がミラー対象 origin かどうかを返します。
  ///
  /// [targetUri] 判定する URI。
  ///
  /// Returns: scheme、host、実効ポートがすべて一致する場合は `true`。
  bool _isMirroredOrigin(Uri targetUri) {
    if (_mirroredOrigins.isEmpty) {
      return false;
    }

    final scheme = targetUri.scheme.toLowerCase();
    final host = targetUri.host.toLowerCase();
    final port = _effectivePort(targetUri);

    return _mirroredOrigins.any((origin) =>
        origin.scheme == scheme &&
        origin.host == host &&
        _effectivePort(origin) == port);
  }

  /// ミラー中継のパスかどうかを返します。
  ///
  /// [path] 判定するパス。
  ///
  /// Returns: 中継用の接頭辞で始まる場合は `true`。
  bool _isMirroredOriginPath(String path) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return normalizedPath == _mirroredOriginPathPrefix ||
        normalizedPath.startsWith('$_mirroredOriginPathPrefix/');
  }

  /// ミラー中継のパスから upstream URI を復元します。
  ///
  /// [path] proxy が受け取ったパス。
  /// [query] クエリ文字列。
  /// [fragment] フラグメント。
  ///
  /// Returns: 復元した upstream URI。形式が違う場合や許可していない origin を
  ///   指す場合は `null`。
  Uri? _tryResolveMirroredUpstreamUri({
    required String path,
    String query = '',
    String fragment = '',
  }) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    if (!_isMirroredOriginPath(normalizedPath)) {
      return null;
    }

    final remainder =
        normalizedPath.substring(_mirroredOriginPathPrefix.length);
    if (!remainder.startsWith('/')) {
      return null;
    }

    final segments = remainder.substring(1).split('/');
    if (segments.length < 2 || segments[0].isEmpty || segments[1].isEmpty) {
      return null;
    }

    final String scheme;
    final String authority;
    try {
      scheme = Uri.decodeComponent(segments[0]).toLowerCase();
      authority = Uri.decodeComponent(segments[1]).toLowerCase();
    } catch (_) {
      // 壊れたパーセントエンコードは復号できない。遷移解決からも呼ばれるため、
      // 例外を投げずに対象外として扱う。
      return null;
    }

    // 3 要素目以降は元の資源のパス。区切りで分解しただけなので復号しない。
    final resourcePath =
        segments.length > 2 ? '/${segments.sublist(2).join('/')}' : '/';
    final querySuffix = query.isNotEmpty ? '?$query' : '';
    final fragmentSuffix = fragment.isNotEmpty ? '#$fragment' : '';

    final upstreamUri = Uri.tryParse(
      '$scheme://$authority$resourcePath$querySuffix$fragmentSuffix',
    );
    if (upstreamUri == null || !_isMirroredOrigin(upstreamUri)) {
      return null;
    }

    // `user@host` の形は host が一致していても認証情報として中継先へ送られる。
    // 要求元が任意に指定できるため、origin だけを指す形に限る。
    if (upstreamUri.userInfo.isNotEmpty) {
      return null;
    }

    // proxy 自身を指す中継は自分への転送になり、入れ子にすると際限なく
    // 段数が増える。設定として意味も無いため受け付けない。
    if (_isProxyEndpointUri(upstreamUri)) {
      return null;
    }

    return upstreamUri;
  }

  /// upstream URI をミラー中継のパスへ変換します。
  ///
  /// 元の origin をパスの一部として保つため、その資源が持つ相対 URL は
  /// 同じ origin 配下へ解決されます。
  ///
  /// [upstreamUri] 変換する upstream URI。
  ///
  /// Returns: proxy が受け付けるパス。ミラー対象外の場合は `null`。
  String? _buildMirroredProxyPath(Uri upstreamUri) {
    if (!_isMirroredOrigin(upstreamUri)) {
      return null;
    }

    final scheme = upstreamUri.scheme.toLowerCase();
    final host = upstreamUri.host.toLowerCase();
    final port = _effectivePort(upstreamUri);
    final authority =
        port == _defaultPortForScheme(scheme) ? host : '$host:$port';
    final resourcePath = upstreamUri.path.isEmpty ? '/' : upstreamUri.path;
    final querySuffix =
        upstreamUri.query.isNotEmpty ? '?${upstreamUri.query}' : '';
    final fragmentSuffix =
        upstreamUri.fragment.isNotEmpty ? '#${upstreamUri.fragment}' : '';

    return '$_mirroredOriginPathPrefix/$scheme/$authority'
        '$resourcePath$querySuffix$fragmentSuffix';
  }

  /// upstream URI からミラー中継の proxy URI を構築します。
  ///
  /// [upstreamUri] 変換する upstream URI。
  ///
  /// Returns: WebView へ渡せる proxy URI。構築できない場合は `null`。
  Uri? _buildMirroredProxyUri(Uri upstreamUri) {
    final proxyPath = _buildMirroredProxyPath(upstreamUri);
    if (proxyPath == null) {
      return null;
    }

    final proxyPort = _activeProxyPort;
    if (proxyPort == null) {
      return null;
    }

    final configuredHost = (_config?.host.isNotEmpty ?? false)
        ? _config!.host
        : _defaultLoopbackHost;

    return Uri.tryParse('http://$configuredHost:$proxyPort$proxyPath');
  }

  /// 取得対象にならない参照 URL かどうかを返します。
  ///
  /// [rawUrl] HTML に書かれていた URL。
  ///
  /// Returns: フラグメントや `data:` など取得できない場合は `true`。
  bool _isNonFetchableReferenceUrl(String rawUrl) {
    return rawUrl.startsWith('#') ||
        rawUrl.startsWith('data:') ||
        rawUrl.startsWith('javascript:') ||
        rawUrl.startsWith('mailto:') ||
        rawUrl.startsWith('blob:');
  }

  /// origin の base path を upstream path から取り除き proxy path を返します。
  String? _stripConfiguredOriginPathPrefix(
      String upstreamPath, String originPath) {
    final normalizedUpstreamPath = upstreamPath.isEmpty ? '/' : upstreamPath;
    final normalizedOriginPath = _normalizeOriginBasePath(originPath);
    if (normalizedOriginPath == '/') {
      return normalizedUpstreamPath.startsWith('/')
          ? normalizedUpstreamPath
          : '/$normalizedUpstreamPath';
    }

    if (normalizedUpstreamPath == normalizedOriginPath ||
        normalizedUpstreamPath == '$normalizedOriginPath/') {
      return '/';
    }

    if (!normalizedUpstreamPath.startsWith('$normalizedOriginPath/')) {
      return null;
    }

    final strippedPath =
        normalizedUpstreamPath.substring(normalizedOriginPath.length);
    return strippedPath.startsWith('/') ? strippedPath : '/$strippedPath';
  }

  /// origin の base path を比較用に正規化します。
  String _normalizeOriginBasePath(String originPath) {
    if (originPath.isEmpty || originPath == '/') {
      return '/';
    }

    return originPath.endsWith('/') && originPath.length > 1
        ? originPath.substring(0, originPath.length - 1)
        : originPath;
  }

  /// ドロップされたリクエスト履歴を保存します。
  ///
  /// [data] は元のキューデータです。
  /// [statusCode] はドロップ時の HTTP ステータスです。
  /// [dropReason] はドロップ理由です。
  /// [errorMessage] は記録する詳細メッセージです。
  ///
  /// 履歴のロックの中で記録し、保持上限を超えた分を取り除きます。上限の処理に
  /// 失敗しても、記録した結果は変えずにイベントで知らせます。
  ///
  /// Returns: 記録した場合は `true`。保存領域が使えない場合は `false`。
  ///
  /// Throws:
  ///   * [TimeoutException] 履歴のロックを上限時間内に取得できなかった場合。
  Future<bool> _recordDroppedRequest(
    Map data, {
    required int statusCode,
    required String dropReason,
    required String errorMessage,
  }) {
    return _recordDroppedRequests([
      (
        data: data,
        statusCode: statusCode,
        dropReason: dropReason,
        errorMessage: errorMessage,
      ),
    ]);
  }

  /// ドロップされたリクエスト履歴をまとめて保存します。
  ///
  /// 履歴のロックを 1 回だけ取ってまとめて書き込み、保持上限の判定も 1 回に
  /// します。上限の処理に失敗しても、記録した結果は変えずにイベントで知らせます。
  ///
  /// [records] 記録する内容（元のキューデータ、ドロップ時の HTTP ステータス、
  ///   ドロップ理由、詳細メッセージ）。
  ///
  /// Returns: 記録した場合は `true`。保存領域が使えない場合は、何も記録せずに
  ///   `false`。
  ///
  /// Throws:
  ///   * [TimeoutException] 履歴のロックを上限時間内に取得できなかった場合。
  Future<bool> _recordDroppedRequests(
    List<_DroppedRequestRecord> records,
  ) async {
    if (records.isEmpty) {
      return true;
    }

    final droppedAt = DateTime.now().toIso8601String();
    return _droppedRequestLock.synchronized(() async {
      final box = _droppedRequestBox;
      // 停止処理と競合した場合は閉じた保存領域へ書き込まない
      if (box == null || !box.isOpen) {
        return false;
      }

      final droppedEntries = <String, Map<String, Object>>{};
      for (final record in records) {
        var key = _generateUniqueStorageKey(box, _legacyDroppedRequestBox);
        while (droppedEntries.containsKey(key)) {
          key = _generateUniqueStorageKey(box, _legacyDroppedRequestBox);
        }
        droppedEntries[key] = {
          'url': record.data['url'] as String? ?? '',
          'method': record.data['method'] as String? ?? 'GET',
          'droppedAt': droppedAt,
          'dropReason': record.dropReason,
          'statusCode': record.statusCode,
          'errorMessage': record.errorMessage,
          'acknowledged': false,
        };
      }

      await box.putAll(droppedEntries);
      _unacknowledgedDroppedCount = null;

      try {
        await _enforceDroppedRequestLimits(box);
      } catch (error) {
        _emitRetentionError(error);
      }
      return true;
    }, timeout: _storageLockTimeout);
  }

  /// リクエストを隔離領域へ退避し、キューから取り除きます。
  ///
  /// 本文を含むキューデータをそのまま保持するため、原因を解消したあとに
  /// [retryQuarantinedRequest] で再送できます。隔離のロックの中で退避し、退避した
  /// 直後（保持上限の判定より前）にキューから取り除きます。ロックを待つ間に停止して
  /// キューが閉じていた場合は退避しません。キューに残したまま隔離すると、次の起動で
  /// 同じ要求を二重に隔離するためです。保持上限を超えた分はドロップ履歴へ移します。
  /// 上限の処理に失敗しても、退避した結果は変えずにイベントで知らせます。
  ///
  /// 1 件で [ProxyConfig.quarantineMaxBytes] を超える場合は、既存の隔離を
  /// 追い出さず、隔離にも入れません。本文を持たないドロップ履歴へ
  /// `quarantine_too_large` として記録してから、キューから取り除きます。
  ///
  /// [data] 退避するキューデータ。
  /// [statusCode] 上流から返されたステータスコード。
  /// [reason] 退避理由。
  /// [errorMessage] 詳細なエラーメッセージ。
  /// [queueBox] 取り除く記録があるキューの保存領域。
  /// [queueKey] 取り除く記録のキュー ID。
  ///
  /// Returns: 退避に使用した ID と、大きすぎて履歴へ記録したかどうか。
  ///   保存領域が使えない場合は、ID が `null` で記録もしていません。
  ///
  /// Throws:
  ///   * [TimeoutException] 隔離または履歴のロックを上限時間内に取得できなかった場合。
  Future<({String? quarantineId, bool tooLarge})> _quarantineRequest(
    Map data, {
    required int statusCode,
    required String reason,
    required String errorMessage,
    required Box queueBox,
    required Object queueKey,
  }) {
    return _quarantineLock.synchronized(() async {
      final box = _quarantinedRequestBox;
      // 停止処理と競合した場合は閉じた保存領域へ書き込まない
      if (box == null || !box.isOpen || !queueBox.isOpen) {
        return (quarantineId: null, tooLarge: false);
      }

      final quarantinedData = Map<String, dynamic>.from(data);
      quarantinedData['quarantinedAt'] = DateTime.now().toIso8601String();
      quarantinedData['statusCode'] = statusCode;
      quarantinedData['reason'] = reason;
      quarantinedData['errorMessage'] = errorMessage;

      final maxBytes = _config?.quarantineMaxBytes ?? 0;
      if (maxBytes > 0 &&
          _estimateQuarantinedSize(quarantinedData) > maxBytes) {
        final recorded = await _recordDroppedRequest(
          data,
          statusCode: statusCode,
          dropReason: _quarantineTooLargeDropReason,
          errorMessage: errorMessage,
        );
        if (recorded && queueBox.isOpen) {
          await queueBox.delete(queueKey);
        }
        return (quarantineId: null, tooLarge: recorded);
      }

      final key = _generateUniqueStorageKey(box, _legacyQuarantineBox);
      await box.put(key, quarantinedData);
      if (queueBox.isOpen) {
        await queueBox.delete(queueKey);
      }

      try {
        await _enforceQuarantineLimits(box, protectedKey: key);
      } catch (error) {
        _emitRetentionError(error);
      }
      return (quarantineId: key, tooLarge: false);
    }, timeout: _storageLockTimeout);
  }

  /// 隔離データを [QuarantinedRequest] へ変換します。
  ///
  /// [id] 隔離領域内での識別子。
  /// [data] 保存されている隔離データ。
  /// [pendingMigration] 移行を待っている旧平文隔離の項目かどうか。
  ///
  /// Returns: 変換した隔離リクエスト情報。
  QuarantinedRequest _mapToQuarantinedRequest(
    String id,
    Map data, {
    bool pendingMigration = false,
  }) {
    final now = DateTime.now();

    return QuarantinedRequest(
      id: id,
      pendingMigration: pendingMigration,
      url: data['url'] as String? ?? '',
      method: data['method'] as String? ?? 'GET',
      quarantinedAt:
          DateTime.tryParse(data['quarantinedAt'] as String? ?? '') ?? now,
      queuedAt: DateTime.tryParse(data['queuedAt'] as String? ?? '') ?? now,
      acceptedAt:
          DateTime.tryParse(_resolveQueuedAcceptedAt(data) ?? '') ?? now,
      reason: data['reason'] as String? ?? 'dropped',
      statusCode: data['statusCode'] as int? ?? 0,
      errorMessage: data['errorMessage'] as String? ?? '',
    );
  }

  /// ファイルパスからMIMEタイプを取得します。
  ///
  /// [path] ファイルパス。
  ///
  /// Returns: MIMEタイプ文字列。
  String _getMimeType(String path) {
    final extension = path.toLowerCase().split('.').last;

    const mimeTypes = {
      'html': 'text/html; charset=utf-8',
      'css': 'text/css; charset=utf-8',
      'js': 'application/javascript; charset=utf-8',
      'json': 'application/json; charset=utf-8',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'svg': 'image/svg+xml',
      'ico': 'image/x-icon',
      'woff': 'font/woff',
      'woff2': 'font/woff2',
      'ttf': 'font/ttf',
      'eot': 'application/vnd.ms-fontobject',
      'pdf': 'application/pdf',
      'txt': 'text/plain; charset=utf-8',
    };

    return mimeTypes[extension] ?? 'application/octet-stream';
  }
}

/// 並行性制御用のセマフォクラス。
///
/// 同時実行数を制限するために使用します。上流への同時接続数の制限と
/// ウォームアップの並列度制御に使っています。
///
/// このクラスは proxy の内部実装を目的としています。ライブラリ本体に
/// 定義しているため参照できますが、将来の版で非公開へ移す可能性があるため
/// 利用側のコードからの依存は推奨しません。
class Semaphore {
  /// 最大同時実行数。
  final int maxCount;

  /// 現在利用可能なリソース数。
  int _currentCount;

  /// 待機中のCompleterキュー。
  final Queue<Completer<void>> _waitQueue = Queue<Completer<void>>();

  /// 指定した最大同時実行数でセマフォを初期化します。
  ///
  /// [maxCount] 最大同時実行数。
  Semaphore(this.maxCount) : _currentCount = maxCount;

  /// セマフォを取得します（タイムアウト付き）。
  ///
  /// [timeout] 最大待機時間。デフォルトは30秒。
  /// リソースが利用可能な場合は即座に返却し、
  /// 利用不可な場合は待機キューに登録して待機します。
  /// タイムアウト時は例外を投げます。
  Future<void> acquire({Duration timeout = const Duration(seconds: 30)}) async {
    if (_currentCount > 0) {
      _currentCount--;
      return;
    }

    final completer = Completer<void>();
    _waitQueue.add(completer);
    try {
      await completer.future.timeout(timeout, onTimeout: () {
        // タイムアウト時はキューから削除
        _waitQueue.remove(completer);
        throw TimeoutException('セマフォの取得が${timeout.inSeconds}秒でタイムアウトしました');
      });
    } catch (e) {
      rethrow;
    }
  }

  /// セマフォを解放します。
  ///
  /// 待機中のCompleterがある場合はそれを完了させ、
  /// ない場合は利用可能リソース数を増加します。
  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeFirst();
      completer.complete();
    } else {
      _currentCount++;
    }
  }
}

/// 保存領域の初期化の段階の結果です。
///
/// 共有する Future を失敗させると、別の error zone から待つ呼び出しに失敗が
/// 伝わらず、待ったまま完了しません。そこで失敗も値として持ち、待つ側の zone で
/// 投げ直します。
class _StageOutcome<T> {
  /// 成功した結果を生成します。
  ///
  /// [value] 段階の戻り値。
  const _StageOutcome.success(this.value)
      : error = null,
        stackTrace = null;

  /// 失敗した結果を生成します。
  ///
  /// [error] 段階で起きたエラー。
  /// [stackTrace] エラーのスタックトレース。
  const _StageOutcome.failure(Object this.error, StackTrace this.stackTrace)
      : value = null;

  /// 成功した場合の戻り値。
  final T? value;

  /// 失敗した場合のエラー。
  final Object? error;

  /// 失敗した場合のスタックトレース。
  final StackTrace? stackTrace;

  /// 成功した場合は戻り値を返し、失敗した場合はエラーを投げ直します。
  ///
  /// Returns: 段階の戻り値。
  T unwrap() {
    final failure = error;
    if (failure != null) {
      Error.throwWithStackTrace(failure, stackTrace!);
    }
    return value as T;
  }
}

/// 隔離の記録を操作した結果です。
enum _QuarantineOperationResult {
  /// 操作しました。
  done,

  /// 該当する記録がありません。
  notFound,

  /// 移行を待っている旧平文 Box の記録のため、操作できません。
  pendingMigration,
}

/// ドロップ履歴へ記録する内容です。
///
/// 元のキューデータ、ドロップ時の HTTP ステータス、ドロップ理由、詳細な
/// メッセージの組です。
typedef _DroppedRequestRecord = ({
  Map data,
  int statusCode,
  String dropReason,
  String errorMessage,
});

/// 隔離から取り除く記録と、ドロップ履歴に残す理由の組です。
typedef _QuarantineEviction = ({StoredEntry entry, String dropReason});
