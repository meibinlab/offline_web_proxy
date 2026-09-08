/// # offline_web_proxy
///
/// Flutter WebView内で動作するオフライン対応ローカルプロキシサーバ。
/// 既存のWebシステムをモバイルアプリでシームレスに動作させ、
/// オンライン/オフライン状態を意識する必要をなくします。
///
/// ## 主な機能
///
/// * **インテリジェントキャッシング**: RFC準拠のキャッシュ制御とオフライン戦略
/// * **リクエストキューイング**: オフライン時のPOST/PUT/DELETEリクエストの自動キュー
/// * **Cookie管理**: AES-256暗号化による安全なCookie永続化
/// * **静的リソース一覧**: `assets/static/` 配下を起動時に走査して proxy URL へ対応付け
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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'src/exceptions/exceptions.dart';
import 'src/models/cache_entry.dart';
import 'src/models/cache_stats.dart';
import 'src/models/cookie_header_builder.dart';
import 'src/models/cookie_info.dart';
import 'src/models/cookie_record.dart';
import 'src/models/cookie_restore_entry.dart';
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
import 'src/models/queued_request.dart';
import 'src/models/response_header_snapshot.dart';
import 'src/models/upstream_circuit_state.dart';
import 'src/models/warmup_result.dart';

export 'src/exceptions/exceptions.dart';
export 'src/lifecycle/proxy_lifecycle_guard.dart';
export 'src/models/cache_entry.dart';
export 'src/models/cache_stats.dart';
export 'src/models/cookie_info.dart';
export 'src/models/cookie_restore_entry.dart';
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
export 'src/models/queued_request.dart';
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
const String _droppedRequestBoxName = 'proxy_dropped_requests';
const Set<String> _loopbackHosts = {'127.0.0.1', 'localhost'};
const String _defaultHealthCheckPath = '/__offline_web_proxy/health';
const String _defaultLoopbackHost = '127.0.0.1';

/// 復旧の連続失敗時に挟む待機秒数。末尾の値は以降も維持されます。
const List<int> _recoveryBackoffSeconds = [0, 1, 2, 5, 10];

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

/// 上流の復帰確認で使う既定のバックオフ秒数。
/// 設定が空の場合のフォールバックとして使用します。
const List<int> _defaultUpstreamProbeBackoffSeconds = [1, 2, 5, 10, 30];

/// 起動時に接続状態の取得を待つ上限時間。
/// プラットフォーム応答が遅い場合でも起動を止めないために設けています。
const Duration _initialConnectivityTimeout = Duration(milliseconds: 500);

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

  /// Cookie 暗号化鍵の永続化に利用するセキュアストレージ。
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// べき等性キーの永続化ボックス。
  Box? _idempotencyBox;

  /// ドロップされたリクエスト履歴の永続化ボックス。
  Box? _droppedRequestBox;

  /// 起動時に構築した静的リソースの proxy URL と asset key の対応表。
  final Map<String, String> _staticResourceAssetMap = {};

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

  /// プロキシサーバを起動します。
  ///
  /// [config] 設定オブジェクト。省略時はデフォルト設定を使用します。
  ///
  /// Returns: 実際に使用されるポート番号。
  ///
  /// Throws:
  ///   * [ProxyStartException] サーバ起動に失敗した場合。
  ///   * [PortBindException] ポートバインドに失敗した場合。
  Future<int> start({ProxyConfig? config}) async {
    if (_isRunning) {
      throw ProxyStartException('Proxy server is already running', null);
    }

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
      _resetRecoveryState();

      // ストレージを初期化
      await _initializeStorage();

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
          .addMiddleware(shelf.logRequests())
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
    }
  }

  /// プロキシサーバを停止します。
  ///
  /// Throws:
  ///   * [ProxyStopException] サーバ停止に失敗した場合。
  Future<void> stop() async {
    if (!_isRunning) {
      return;
    }

    // 復旧処理と同時に実行されないよう排他制御する
    await _lifecycleLock.acquire();
    if (!_isRunning) {
      _lifecycleLock.release();
      return;
    }

    Object? failure;
    try {
      _queueDrainTimer?.cancel();
      _queueDrainTimer = null;
      _cachePurgeTimer?.cancel();
      _cachePurgeTimer = null;
      _healthCheckTimer?.cancel();
      _healthCheckTimer = null;
      _upstreamProbeTimer?.cancel();
      _upstreamProbeTimer = null;

      await _server?.close();
      await _connectivitySubscription.cancel();

      // Hiveボックスを閉じる
      await _cacheBox?.close();
      await _queueBox?.close();
      await _cookieBox?.close();
      await _portPreferenceBox?.close();
      await _webStorageBox?.close();
      await _idempotencyBox?.close();
      await _droppedRequestBox?.close();

      // HTTPクライアントを閉じる
      _httpClient?.close(force: true);
      _httpClient = null;
      _staticResourceAssetMap.clear();
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
      _lifecycleLock.release();
    }

    if (failure != null) {
      throw ProxyStopException('Failed to stop proxy server: $failure',
          failure is Exception ? failure : null);
    }

    _emitEvent(ProxyEventType.serverStopped, '', {});
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

    // 死んだ keep-alive 接続を再利用しないよう、確認専用のクライアントを使う
    final client = HttpClient()..connectionTimeout = timeout;
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

  /// 稼働確認要求かどうかを返します。
  ///
  /// 稼働確認として扱うのは `GET` と `HEAD` のみです。
  bool _isHealthCheckRequest(shelf.Request request) {
    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      return false;
    }

    final requestPath = request.url.path;
    final normalizedPath =
        requestPath.startsWith('/') ? requestPath : '/$requestPath';
    return normalizedPath == _healthCheckPath;
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
    int successCount = 0;
    int failureCount = 0;

    try {
      // Process paths with concurrency control

      final semaphore = Semaphore(maxConcurrency ?? 10);
      final results =
          await Future.wait(targetPaths.asMap().entries.map((entry) async {
        final index = entry.key;
        final path = entry.value;

        await semaphore.acquire(timeout: const Duration(seconds: 30));
        try {
          final entryStartTime = DateTime.now();
          try {
            final response = await _fetchFromUpstream(path, timeout: timeout);
            if (response.statusCode == HttpStatus.ok) {
              final upstreamUri = _buildUpstreamUriFromParts(path: path);
              final cacheKey = _generateCacheKey(upstreamUri.toString());
              await _cacheResponseBytes(
                cacheKey,
                response.statusCode,
                response.headers,
                response.bodyBytes,
              );
            }
            final duration = DateTime.now().difference(entryStartTime);
            successCount++;
            return WarmupEntry(
              path: path,
              success: true,
              statusCode: response.statusCode,
              errorMessage: null,
              duration: duration,
            );
          } catch (e) {
            final duration = DateTime.now().difference(entryStartTime);
            onError?.call(path, e.toString());
            failureCount++;
            return WarmupEntry(
              path: path,
              success: false,
              statusCode: null,
              errorMessage: e.toString(),
              duration: duration,
            );
          } finally {
            // 成功・失敗問わず進捗コールバックを呼ぶ
            onProgress?.call(index + 1, targetPaths.length);
          }
        } finally {
          semaphore.release();
        }
      }));

      entries.addAll(results);

      final totalDuration = DateTime.now().difference(startTime);

      return WarmupResult(
        successCount: successCount,
        failureCount: failureCount,
        totalDuration: totalDuration,
        entries: entries,
      );
    } catch (e) {
      throw WarmupException(
          'ウォームアップに失敗しました: $e', entries, e is Exception ? e : null);
    }
  }

  /// 保存されているCookieの一覧を取得します。
  ///
  /// [domain] 特定ドメインのCookieのみを取得したい場合に指定。
  ///
  /// Returns: Cookie情報の一覧。
  ///
  /// Throws:
  ///   * [CookieOperationException] Cookieの取得に失敗した場合。
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
  ///   * [CookieOperationException] Cookie ヘッダ生成に失敗した場合。
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
  ///   * [CookieOperationException] Cookie の復元に失敗した場合。
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
    return switch (uri.scheme.toLowerCase()) {
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
  ///   * [CookieOperationException] Cookieの削除に失敗した場合。
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
  /// Returns: キューに保存されているリクエストの一覧。
  ///
  /// Throws:
  ///   * [QueueOperationException] キュー情報の取得に失敗した場合。
  Future<List<QueuedRequest>> getQueuedRequests() async {
    try {
      final requests = <QueuedRequest>[];

      if (_queueBox != null) {
        int idx = 0;
        for (final key in _queueBox!.keys) {
          final data = _queueBox!.get(key) as Map?;
          if (data != null) {
            requests.add(_mapToQueuedRequest(data));
          }

          // 大量キュー走査時にUIをブロックしないようyield
          idx++;
          if (idx % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      }

      return requests;
    } catch (e) {
      throw QueueOperationException(
          'get', 'キューされたリクエストの取得に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// キューから除外されたリクエストの履歴を取得します。
  ///
  /// [limit] 取得する最大件数。
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

      final requests = <DroppedRequest>[];

      if (_droppedRequestBox != null) {
        int idx = 0;
        for (final key in _droppedRequestBox!.keys) {
          final data = _droppedRequestBox!.get(key) as Map?;
          if (data != null) {
            requests.add(_mapToDroppedRequest(data));
            if (limit != null && requests.length >= limit) {
              break;
            }
          }

          idx++;
          if (idx % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      }

      return requests;
    } catch (e) {
      throw QueueOperationException('getDropped', 'ドロップされたリクエストの取得に失敗しました: $e',
          e is Exception ? e : null);
    }
  }

  /// ドロップされたリクエストの履歴を全て削除します。
  ///
  /// Throws:
  ///   * [QueueOperationException] 履歴の削除に失敗した場合。
  Future<void> clearDroppedRequests() async {
    try {
      await _droppedRequestBox?.clear();
    } catch (e) {
      throw QueueOperationException('clearDropped',
          'ドロップされたリクエスト履歴の削除に失敗しました: $e', e is Exception ? e : null);
    }
  }

  /// プロキシサーバの統計情報を取得します。
  ///
  /// Returns: リクエスト数、キャッシュヒット率、キュー長などの統計情報。
  ///
  /// Throws:
  ///   * [StatsOperationException] 統計情報の取得に失敗した場合。
  Future<ProxyStats> getStats() async {
    try {
      final queueLength = _queueBox?.length ?? 0;
      final droppedRequestsCount = _droppedRequestBox?.length ?? 0;
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
  /// キャッシュ、キュー、Cookie、べき等性キー用の
  /// ボックスをそれぞれ開きます。
  Future<void> _initializeStorage() async {
    _cacheBox = await Hive.openBox('proxy_cache');
    _queueBox = await Hive.openBox('proxy_queue');
    _portPreferenceBox = await Hive.openBox(_portPreferenceBoxName);
    _webStorageBox = await Hive.openBox(_webStorageBoxName);
    await _ensureCookieStorageInitialized();
    _idempotencyBox = await Hive.openBox('proxy_idempotency');
    _droppedRequestBox = await Hive.openBox(_droppedRequestBoxName);
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
  /// 戻り値は利用可能な Cookie Box です。
  Future<Box> _ensureCookieStorageInitialized() async {
    if (!Hive.isAdapterRegistered(0)) {
      await Hive.initFlutter();
    }

    if (_cookieBox != null && _cookieBox!.isOpen) {
      return _cookieBox!;
    }

    if (Hive.isBoxOpen(_encryptedCookieBoxName)) {
      _cookieBox = Hive.box(_encryptedCookieBoxName);
      return _cookieBox!;
    }

    final encryptionKey = await _getOrCreateCookieEncryptionKey();
    _cookieBox = await Hive.openBox(
      _encryptedCookieBoxName,
      encryptionCipher: HiveAesCipher(encryptionKey),
    );
    await _migrateLegacyCookieBoxIfNeeded(_cookieBox!);
    return _cookieBox!;
  }

  /// Cookie Box 用の暗号化鍵を取得または生成します。
  ///
  /// セキュアストレージの取得失敗時はフォールバックせず例外を送出します。
  Future<Uint8List> _getOrCreateCookieEncryptionKey() async {
    final storedKey = await _secureStorage.read(
      key: _cookieEncryptionKeyStorageKey,
    );
    if (storedKey != null && storedKey.isNotEmpty) {
      return _decodeCookieEncryptionKey(storedKey);
    }

    if (await Hive.boxExists(_encryptedCookieBoxName)) {
      throw StateError(
        'Cookie encryption key is missing. Existing encrypted cookies cannot be recovered.',
      );
    }

    final generatedKey = _generateCookieEncryptionKey();
    await _secureStorage.write(
      key: _cookieEncryptionKeyStorageKey,
      value: base64Encode(generatedKey),
    );
    return generatedKey;
  }

  /// Base64 文字列として保存された Cookie 暗号化鍵を復元します。
  Uint8List _decodeCookieEncryptionKey(String encodedKey) {
    final decodedKey = base64Decode(encodedKey);
    if (decodedKey.length != _cookieEncryptionKeyLength) {
      throw StateError(
        'Invalid cookie encryption key length: ${decodedKey.length}',
      );
    }

    return Uint8List.fromList(decodedKey);
  }

  /// Cookie Box 用の新しい AES-256 鍵を生成します。
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
  /// 移行に失敗した場合は平文 Box を継続利用せず、例外を送出します。
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
        await encryptedCookieBox.put(
          cookieRecord.storageKey,
          cookieRecord.toMap(),
        );
      }
    } catch (e) {
      throw StateError('Failed to migrate legacy cookie box: $e');
    } finally {
      if (legacyCookieBox != null && legacyCookieBox.isOpen) {
        await legacyCookieBox.close();
      }
    }

    await Hive.deleteBoxFromDisk(_legacyCookieBoxName);
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
    final client = HttpClient()..connectionTimeout = timeout;
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
        // 稼働確認は統計にもイベントにも含めない
        if (_isHealthCheckRequest(request)) {
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

    // 起動時に構築した静的リソース一覧を先に確認する
    if (await _isStaticResource(path)) {
      return await _serveStaticResource(path);
    }

    // 接続状態と上流到達性に基づいて処理
    if (_isUpstreamReachable) {
      return await _handleOnlineRequest(request);
    } else {
      return await _handleOfflineRequest(request);
    }
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
        final body = await _readRequestBodyBytes(request);
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

  /// 静的リソースを配信します。
  ///
  /// 一覧に一致した静的リソース URL に対してプレースホルダレスポンスを返却します。
  ///
  /// [path] 配信するファイルのパス。
  ///
  /// Returns: 静的リソースのHTTPレスポンス。
  Future<shelf.Response> _serveStaticResource(String path) async {
    try {
      final assetPath =
          _staticResourceAssetMap[_normalizeStaticResourceRequestPath(path)] ??
              path;
      final mimeType = _getMimeType(path);

      return shelf.Response.notFound(
        '静的リソースの配信は未実装です。アセットパス: $assetPath',
        headers: {
          'Content-Type': mimeType,
          'X-Static-Resource': 'true',
        },
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: '静的リソースの配信に失敗しました: $e',
      );
    }
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
        : await _readRequestBodyBytes(request);

    // 上流サーバに転送
    try {
      final result = await _forwardToUpstream(
        request,
        requestBodyBytes: requestBodyBytes,
      );

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
          await _cacheResponseBytes(
              cacheKey, result.statusCode, result.headers, result.bodyBytes);
        }
      }

      // 上流が応答した時点で到達可能と判定する（4xx / 5xx でもサーバは生きている）
      _recordUpstreamSuccess();

      // read系以外のリクエストが失敗した場合はキューに保存
      String? queueId;
      if (!_isReadRequestMethod(request.method) && result.statusCode >= 500) {
        queueId = await _queueRequest(request, bodyBytes: requestBodyBytes);
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
        final queueId =
            await _queueRequest(request, bodyBytes: requestBodyBytes);
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

  Future<Uint8List> _readRequestBodyBytes(shelf.Request request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
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
  /// [request] 対象のHTTPリクエスト。
  ///
  /// Returns: 504 応答。HEAD の場合は本文を持ちません。
  shelf.Response _buildUpstreamUnreachableResponse(shelf.Request request) {
    if (request.method.toUpperCase() == 'HEAD') {
      return shelf.Response(HttpStatus.gatewayTimeout, headers: {
        'Connection': 'close',
      });
    }

    if (!_isNavigationRequest(request)) {
      return _buildConfiguredResponse(
        _config?.offlineMissResponse ?? _defaultOfflineMissResponse,
        extraHeaders: {'Connection': 'close'},
      );
    }

    final customContent = _config?.gatewayTimeoutHtml;
    if (customContent != null && customContent.isNotEmpty) {
      return shelf.Response(
        HttpStatus.gatewayTimeout,
        body: customContent,
        headers: {
          'Content-Type': 'text/html; charset=utf-8',
          'Connection': 'close',
        },
      );
    }

    return shelf.Response(
      HttpStatus.gatewayTimeout,
      body: '上流サーバがタイムアウトしました',
      headers: {'Connection': 'close'},
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
    client.autoUncompress = false; // 自動解凍を無効化

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
      await _copyRequestHeaders(request, ioRequest, upstreamUri: uri);

      // read系以外のリクエストの場合はボディをコピー
      if (!_isReadRequestMethod(request.method)) {
        final bytes = requestBodyBytes ?? await _readRequestBodyBytes(request);
        if (bytes.isNotEmpty) {
          ioRequest.add(bytes);
        }
      }

      final ioResponse =
          await ioRequest.close().timeout(_remainingUntil(deadline));

      final bodyBytes = await (() async {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in ioResponse) {
          builder.add(chunk);
        }
        return builder.takeBytes();
      })()
          .timeout(_remainingUntil(deadline));

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
  Future<void> _copyRequestHeaders(
    shelf.Request request,
    HttpClientRequest ioRequest, {
    required Uri upstreamUri,
  }) async {
    final connectionSpecificHeaders =
        _extractConnectionSpecificHeaders(request.headers);
    request.headers.forEach((key, value) {
      if (_shouldForwardUpstreamHeader(
        key,
        connectionSpecificHeaders: connectionSpecificHeaders,
      )) {
        ioRequest.headers.set(key, value);
      }
    });

    final mergedCookieHeader = await _mergeCookieHeaderForUpstream(
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
  bool _shouldForwardUpstreamHeader(
    String key, {
    required Set<String> connectionSpecificHeaders,
    bool dropContentLength = false,
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
  /// [response] キャッシュするHTTPレスポンス。
  /// [bodyBytes] レスポンスボディのバイト配列。
  Future<void> _cacheResponseBytes(String cacheKey, int statusCode,
      Map<String, String> headers, List<int> bodyBytes) async {
    final sanitizedHeaders = _sanitizeResponseHeaders(headers);
    if (!_shouldPersistResponse(statusCode, sanitizedHeaders)) {
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
      'expiresAt':
          _calculateExpirationFromHeaders(sanitizedHeaders, contentType)
              .toIso8601String(),
      'contentType': contentType,
      'sizeBytes': bodyBytes.length,
    };

    await _cacheBox?.put(cacheKey, data);
  }

  /// ヘッダからキャッシュ有効期限を算出します。
  DateTime _calculateExpirationFromHeaders(
      Map<String, String> headers, String contentType) {
    final now = DateTime.now();
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
      final expiresAt = HttpDate.parse(expiresHeader);
      return expiresAt.isAfter(now) ? expiresAt : now;
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
  bool _shouldPersistResponse(int statusCode, Map<String, String> headers) {
    if (statusCode != HttpStatus.ok) {
      return false;
    }

    final cacheControl = headers['cache-control']?.toLowerCase();
    if (cacheControl != null && cacheControl.contains('no-store')) {
      return false;
    }

    return true;
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
  ///
  /// Returns: 生成された一意なキー。
  String _generateUniqueStorageKey(Box? box) {
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

      if (box == null || !box.containsKey(key)) {
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
  ///
  /// Returns: 保存に使用したキュー ID。保存領域が使えない場合は `null`。
  Future<String?> _queueRequest(
    shelf.Request request, {
    List<int>? bodyBytes,
  }) async {
    final List<int> body;
    if (request.method == 'GET') {
      body = <int>[];
    } else {
      body = bodyBytes ?? await _readRequestBodyBytes(request);
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
      'retryCount': 0,
      'nextRetryAt': DateTime.now().toIso8601String(),
    };

    final box = _queueBox;
    if (box == null) {
      return null;
    }

    final key = _generateUniqueStorageKey(box);
    await box.put(key, queueData);
    return key;
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
    client.autoUncompress = true;

    // 転送と同じく、待ち時間が段階ごとに積み上がらないよう締め切りで管理する
    final deadline = DateTime.now().add(
      timeout != null
          ? Duration(seconds: timeout)
          : (_config?.requestTimeout ?? _defaultRequestTimeout),
    );

    try {
      final request =
          await client.getUrl(uri).timeout(_remainingUntil(deadline));
      // keep-aliveを有効にする（persistentConnectionデフォルトを使用）
      request.headers.set('accept-encoding', 'gzip, deflate');

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
      _drainQueue();
    });

    // キャッシュパージタイマーを開始
    _cachePurgeTimer = Timer.periodic(const Duration(hours: 1), (timer) {
      // ignore: discarded_futures
      _purgeExpiredCache();
    });

    // 定期ヘルスチェックを設定（既定では無効）
    _startHealthCheckTimer();
  }

  /// キューに保存されたリクエストを消化します。
  ///
  /// オンライン時にキュー内のリクエストを順次上流サーバに送信し、
  /// 成功時はキューから削除、失敗時はバックオフで再試行します。
  Future<void> _drainQueue() async {
    // 停止直後にタイマーが発火した場合でも閉じたボックスへ触らない
    final queueBox = _queueBox;
    if (!_isRunning ||
        !_isUpstreamReachable ||
        queueBox == null ||
        !queueBox.isOpen ||
        _isDrainingQueue) {
      return;
    }

    if (queueBox.isEmpty) {
      return;
    }

    _isDrainingQueue = true;
    try {
      final keys = _sortQueueKeysByQueuedAt(queueBox);
      for (var i = 0; i < keys.length; i++) {
        // 停止した場合や上流断を検知した場合は、残りを待たせずに打ち切る
        if (!_isRunning || !queueBox.isOpen || !_isUpstreamReachable) {
          break;
        }

        await _processQueuedItem(queueBox, keys[i]);
        if (i % 10 == 0) {
          await Future.delayed(Duration.zero); // UIフリーズ防止
        }
      }
    } finally {
      _isDrainingQueue = false;
    }
  }

  /// キューのキーを保存日時の昇順に並べ替えて返します。
  ///
  /// Hive はキーの辞書順で列挙するため、旧バージョンで保存したキー形式が
  /// 残っている場合は辞書順と時系列順が一致しません。仕様【5】の FIFO 保証を
  /// キー形式に依存せず維持するため、保存日時を基準に並べ替えます。
  /// 保存日時が同一の場合はキーの辞書順で解決します。
  ///
  /// [box] 対象のキュー保存領域。
  ///
  /// Returns: 保存日時の昇順に並べ替えたキーの一覧。
  List<dynamic> _sortQueueKeysByQueuedAt(Box box) {
    final entries = <({dynamic key, DateTime queuedAt})>[];

    for (final key in box.keys) {
      final data = box.get(key) as Map?;
      final queuedAtValue = data?['queuedAt'] as String?;
      entries.add((
        key: key,
        // 保存日時が読み取れない場合は最古として扱い、再送から取り残さない
        queuedAt: DateTime.tryParse(queuedAtValue ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      ));
    }

    entries.sort((a, b) {
      final comparedAt = a.queuedAt.compareTo(b.queuedAt);
      if (comparedAt != 0) {
        return comparedAt;
      }
      return a.key.toString().compareTo(b.key.toString());
    });

    return entries.map((entry) => entry.key).toList();
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

      // 送信中に stop() が実行された場合は閉じた保存領域へ書き込まない
      if (!box.isOpen) {
        return;
      }

      if (result.success) {
        await box.delete(key);
        _emitEvent(ProxyEventType.queueDrained, itemUrl, {});
      } else if (result.shouldDrop) {
        await box.delete(key);
        await _recordDroppedRequest(
          data,
          statusCode: result.statusCode,
          dropReason: result.dropReason ?? 'dropped',
          errorMessage: result.errorMessage ?? 'HTTP ${result.statusCode}',
        );
        _emitEvent(ProxyEventType.requestDropped, itemUrl, {
          'statusCode': result.statusCode,
          'dropReason': result.dropReason,
        });
      } else {
        _updateRetrySchedule(data);
        await box.put(key, data);
      }
    } catch (e) {
      if (!box.isOpen) {
        return;
      }

      _updateRetrySchedule(data);
      await box.put(key, data);
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

    final client = _getOrCreateHttpClient();
    client.autoUncompress = true;

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

      if (body.isNotEmpty && method != 'GET') {
        request.add(body);
      }

      try {
        final response =
            await request.close().timeout(_remainingUntil(deadline));

        // 2xxステータスコードを成功とみなす
        final statusCode = response.statusCode;
        if (statusCode >= 200 && statusCode < 300) {
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
        // 画面操作が無い状況でも上流断を検知できるよう、再送の失敗も判定に含める
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
      }
    } finally {
      // 共有クライアントをここで閉じない
    }
  }

  /// 内部で再利用するHttpClientインスタンスを返却します。
  ///
  /// 共有HttpClientをインスタンスで保持し、個々のリクエストで
  /// 再生成しないようにします。アプリケーション終了時に `stop()` で
  /// `close()` します。
  HttpClient _getOrCreateHttpClient() {
    if (_httpClient != null) return _httpClient!;

    _httpClient = HttpClient()
      ..connectionTimeout = _config?.connectTimeout ?? _defaultConnectTimeout
      ..autoUncompress = true
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
  ///
  /// Returns: オフライン用HTMLコンテンツ。
  String _getOfflineFallbackContent() {
    final customContent = _config?.offlineFallbackHtml;
    if (customContent != null && customContent.isNotEmpty) {
      return customContent;
    }

    return '''
    <!DOCTYPE html>
    <html>
    <head>
      <title>オフライン</title>
      <meta charset="utf-8">
    </head>
    <body>
      <h1>オフライン中です</h1>
      <p>現在オフラインのため、リクエストされたコンテンツを表示できません。</p>
      <p>インターネット接続を確認してから再試行してください。</p>
    </body>
    </html>
    ''';
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
  ///
  /// [data] Hiveから読み込んだキューデータ。
  ///
  /// Returns: 変換されたQueuedRequestオブジェクト。
  QueuedRequest _mapToQueuedRequest(Map data) {
    return QueuedRequest(
      url: data['url'] as String? ?? '',
      method: data['method'] as String? ?? 'GET',
      headers: Map<String, String>.from(data['headers'] as Map? ?? {}),
      queuedAt: DateTime.parse(
          data['queuedAt'] as String? ?? DateTime.now().toIso8601String()),
      retryCount: data['retryCount'] as int? ?? 0,
      nextRetryAt: DateTime.parse(
          data['nextRetryAt'] as String? ?? DateTime.now().toIso8601String()),
    );
  }

  /// Hive のマップデータを DroppedRequest オブジェクトに変換します。
  ///
  /// [data] Hive から読み込んだドロップ履歴データです。
  /// 戻り値は変換された [DroppedRequest] オブジェクトです。
  DroppedRequest _mapToDroppedRequest(Map data) {
    return DroppedRequest(
      url: data['url'] as String? ?? '',
      method: data['method'] as String? ?? 'GET',
      droppedAt: DateTime.parse(
        data['droppedAt'] as String? ?? DateTime.now().toIso8601String(),
      ),
      dropReason: data['dropReason'] as String? ?? 'dropped',
      statusCode: data['statusCode'] as int? ?? 0,
      errorMessage: data['errorMessage'] as String? ?? '',
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
          reason: ProxyNavigationReason.missingConfiguredOrigin,
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
      throw StateError('No upstream origin configured');
    }
    return upstreamUri;
  }

  /// path と query から upstream URI を構築します。
  Uri? _tryBuildUpstreamUriFromPathAndQuery({
    required String path,
    String query = '',
    String fragment = '',
  }) {
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
  Future<void> _recordDroppedRequest(
    Map data, {
    required int statusCode,
    required String dropReason,
    required String errorMessage,
  }) async {
    final droppedAt = DateTime.now();
    final droppedData = {
      'url': data['url'] as String? ?? '',
      'method': data['method'] as String? ?? 'GET',
      'droppedAt': droppedAt.toIso8601String(),
      'dropReason': dropReason,
      'statusCode': statusCode,
      'errorMessage': errorMessage,
    };

    final box = _droppedRequestBox;
    // 停止処理と競合した場合は閉じた保存領域へ書き込まない
    if (box == null || !box.isOpen) {
      return;
    }

    final key = _generateUniqueStorageKey(box);
    await box.put(key, droppedData);
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
/// 同時実行数を制限するために使用します。
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
