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
/// * **静的リソース配信**: バンドルされた静的アセットのローカル配信
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
import 'src/models/proxy_config.dart';
import 'src/models/proxy_event.dart';
import 'src/models/proxy_navigation_resolution.dart';
import 'src/models/proxy_stats.dart';
import 'src/models/proxy_webview_navigation_recommendation.dart';
import 'src/models/queued_request.dart';
import 'src/models/response_header_snapshot.dart';
import 'src/models/warmup_result.dart';

export 'src/exceptions/exceptions.dart';
export 'src/models/cache_entry.dart';
export 'src/models/cache_stats.dart';
export 'src/models/cookie_info.dart';
export 'src/models/cookie_restore_entry.dart';
export 'src/models/dropped_request.dart';
export 'src/models/proxy_config.dart';
export 'src/models/proxy_event.dart';
export 'src/models/proxy_navigation_resolution.dart';
export 'src/models/proxy_stats.dart';
export 'src/models/proxy_webview_navigation_recommendation.dart';
export 'src/models/queued_request.dart';
export 'src/models/warmup_result.dart';

/// キャッシュ事前更新の進捗を通知するコールバック関数。
typedef WarmupProgressCallback = void Function(int completed, int total);

/// キャッシュ事前更新でエラーが発生した際に呼ばれるコールバック関数。
typedef WarmupErrorCallback = void Function(String path, String error);

const String _encryptedCookieBoxName = 'proxy_cookies_secure';
const String _legacyCookieBoxName = 'proxy_cookies';
const String _cookieEncryptionKeyStorageKey =
    'offline_web_proxy.cookie_box_encryption_key';
const int _cookieEncryptionKeyLength = 32;
const String _droppedRequestBoxName = 'proxy_dropped_requests';
const Set<String> _loopbackHosts = {'127.0.0.1', 'localhost'};
const Set<String> _staticResourceExtensions = {
  '.html',
  '.css',
  '.js',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.svg',
  '.ico',
  '.woff',
  '.woff2',
  '.ttf',
  '.eot',
};

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
///   connectTimeout: Duration(seconds: 10),
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

  /// Cookie 暗号化鍵の永続化に利用するセキュアストレージ。
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// べき等性キーの永続化ボックス。
  Box? _idempotencyBox;

  /// ドロップされたリクエスト履歴の永続化ボックス。
  Box? _droppedRequestBox;

  /// 静的リソースの存在確認結果キャッシュ。
  final Map<String, bool> _staticResourceCache = {};

  /// 上流サーバへの同時接続数を制限するセマフォ。
  /// WebView が短時間に多数のリクエストを投げた場合にネイティブ側のソケット枯渇を防ぐ。
  final Semaphore _upstreamSemaphore = Semaphore(50);

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

      // ストレージを初期化
      await _initializeStorage();

      // 接続状態の監視を開始
      _startConnectivityMonitoring();

      // ルーターとミドルウェアを作成
      final router = _createRouter();
      final handler = const shelf.Pipeline()
          .addMiddleware(_errorHandlingMiddleware)
          .addMiddleware(shelf.logRequests())
          .addMiddleware(_corsMiddleware)
          .addMiddleware(_statisticsMiddleware)
          .addHandler(router.call);

      // サーバを起動
      _server = await shelf_io.serve(
        handler,
        _config!.host,
        _config!.port,
      );

      _isRunning = true;
      _startedAt = DateTime.now();

      // サーバ起動イベントを発行
      _emitEvent(ProxyEventType.serverStarted, '', {
        'port': _server!.port,
        'host': _config!.host,
      });

      // バックグラウンドタスクを開始
      _startBackgroundTasks();

      return _server!.port;
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

    try {
      _queueDrainTimer?.cancel();
      _queueDrainTimer = null;
      _cachePurgeTimer?.cancel();
      _cachePurgeTimer = null;

      await _server?.close();
      await _connectivitySubscription.cancel();

      // Hiveボックスを閉じる
      await _cacheBox?.close();
      await _queueBox?.close();
      await _cookieBox?.close();
      await _idempotencyBox?.close();
      await _droppedRequestBox?.close();

      // HTTPクライアントを閉じる
      _httpClient?.close(force: true);
      _httpClient = null;

      _isRunning = false;
      _server = null;

      _emitEvent(ProxyEventType.serverStopped, '', {});
    } catch (e) {
      throw ProxyStopException(
          'Failed to stop proxy server: $e', e is Exception ? e : null);
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
      final now = DateTime.now();
      final keysToDelete = <String>[];

      if (_cacheBox != null) {
        final keys = _cacheBox!.keys.toList(growable: false);
        for (var i = 0; i < keys.length; i++) {
          final key = keys[i];
          final entry = _cacheBox!.get(key) as Map?;
          if (entry != null) {
            final expiresAt = DateTime.parse(entry['expiresAt'] as String);
            if (now.isAfter(expiresAt)) {
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

      final now = DateTime.now();

      if (_cacheBox != null) {
        for (final key in _cacheBox!.keys) {
          final entry = _cacheBox!.get(key) as Map?;
          if (entry != null) {
            totalEntries++;
            totalSize += (entry['sizeBytes'] as int? ?? 0);

            final expiresAt = DateTime.parse(entry['expiresAt'] as String);
            final createdAt = DateTime.parse(entry['createdAt'] as String);

            if (now.isBefore(expiresAt)) {
              freshEntries++;
            } else {
              // Stale期間内かチェック
              final staleUntil = _calculateStaleExpiration(
                  createdAt, entry['contentType'] as String);
              if (now.isBefore(staleUntil)) {
                staleEntries++;
              } else {
                expiredEntries++;
              }
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
  /// [timeout] 各リクエストのタイムアウト秒数。
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
      connectTimeout: const Duration(seconds: 10),
      requestTimeout: const Duration(seconds: 60),
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
    await _ensureCookieStorageInitialized();
    _idempotencyBox = await Hive.openBox('proxy_idempotency');
    _droppedRequestBox = await Hive.openBox(_droppedRequestBoxName);
  }

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
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((dynamic results) {
      final wasOnline = _isOnline;

      // プラグインのバージョンによってConnectivityResultまたは
      // List<ConnectivityResult>のどちらかの型で送られてくる場合がある
      _isOnline = switch (results) {
        List list when list.isNotEmpty =>
          !list.every((r) => r == ConnectivityResult.none),
        ConnectivityResult result => result != ConnectivityResult.none,
        _ => true, // 不明な型の場合はフォールバックでオンラインと見なす（安全側）
      };

      if (wasOnline != _isOnline) {
        _emitEvent(
          _isOnline
              ? ProxyEventType.networkOnline
              : ProxyEventType.networkOffline,
          '',
          {'connectivity': results.toString()},
        );

        if (_isOnline) {
          _drainQueue();
        }
      }
    });
  }

  /// HTTPリクエストルーティング用のRouterを作成します。
  ///
  /// 全てのHTTPメソッドとパスをキャッチし、
  /// _handleRequestメソッドに転送する設定を行います。
  ///
  /// Returns: 設定済みのRouterインスタンス。
  Router _createRouter() {
    final router = Router();

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
    final path = request.url.path;

    // 最初に静的リソースかどうかをチェック
    if (await _isStaticResource(path)) {
      return await _serveStaticResource(path);
    }

    // オンライン/オフライン状態に基づいて処理
    if (_isOnline) {
      return await _handleOnlineRequest(request);
    } else {
      return await _handleOfflineRequest(request);
    }
  }

  /// 指定したパスが静的リソースかどうかを判定します。
  ///
  /// assets/static/フォルダ内のファイル存在をチェックし、
  /// 結果をキャッシュしてパフォーマンスを向上させます。
  ///
  /// [path] チェックするパス。
  ///
  /// Returns: 静的リソースの場合は `true`。
  Future<bool> _isStaticResource(String path) async {
    if (_staticResourceCache.containsKey(path)) {
      return _staticResourceCache[path]!;
    }

    final exists = _looksLikeStaticResourcePath(path);

    _staticResourceCache[path] = exists;
    return exists;
  }

  /// 静的リソースを配信します。
  ///
  /// assets/static/フォルダから指定したパスのファイルを
  /// 読み込んでレスポンスとして返却します。
  ///
  /// [path] 配信するファイルのパス。
  ///
  /// Returns: 静的リソースのHTTPレスポンス。
  Future<shelf.Response> _serveStaticResource(String path) async {
    try {
      // Flutterアセットバンドルから静的リソースを読み込み
      // 現在はファイルシステムアクセスはサポートしていない
      final mimeType = _getMimeType(path);

      return shelf.Response.notFound(
        '静的リソースの配信は未実装です。アセットパス: $path',
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
    final cachedResponse = await _getCachedResponse(cacheKey);

    if (cachedResponse != null && _isCacheValid(cachedResponse)) {
      _cacheHits++;
      _emitEvent(ProxyEventType.cacheHit, request.url.toString(), {});
      final rangeEntry = await _getCachedResponseBytesEntry(cacheKey);
      if (rangeEntry != null) {
        final rangeResp = _tryBuildRangeResponseFromCache(
          request,
          cachedHeaders: rangeEntry.headers,
          cachedBodyBytes: rangeEntry.bodyBytes,
        );
        if (rangeResp != null) return rangeResp;
      }
      return cachedResponse;
    }

    // NOTE: 非GETは、失敗時のキュー保存や再送のためにボディを保持する必要がある。
    // shelf.Request のストリームは一度しか読めないため、ここで一度だけ読み取り
    // 上流転送とキュー保存で共有する。
    final Uint8List? requestBodyBytes =
        request.method == 'GET' ? null : await _readRequestBodyBytes(request);

    // 上流サーバに転送
    try {
      final result = await _forwardToUpstream(
        request,
        requestBodyBytes: requestBodyBytes,
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

      // GET以外のリクエストが失敗した場合はキューに保存
      if (request.method != 'GET' && result.statusCode >= 500) {
        await _queueRequest(request, bodyBytes: requestBodyBytes);
      }

      _cacheMisses++;
      // ボディを含む新しいレスポンスを返す
      return shelf.Response(
        result.statusCode,
        body: Uint8List.fromList(result.bodyBytes),
        headers: result.headers,
      );
    } catch (e) {
      // リクエストが失敗した場合、キャッシュを試すかキューに保存
      if (request.method == 'GET' && cachedResponse != null) {
        _cacheHits++;
        _emitEvent(ProxyEventType.cacheStaleUsed, request.url.toString(), {});
        final rangeEntry = await _getCachedResponseBytesEntry(cacheKey);
        if (rangeEntry != null) {
          final rangeResp = _tryBuildRangeResponseFromCache(
            request,
            cachedHeaders: rangeEntry.headers,
            cachedBodyBytes: rangeEntry.bodyBytes,
          );
          if (rangeResp != null) return rangeResp;
        }
        return cachedResponse;
      } else if (request.method != 'GET') {
        await _queueRequest(request, bodyBytes: requestBodyBytes);
        return shelf.Response.ok('リクエストを再試行のためキューに保存しました', headers: {
          // クライアント側で脆弱な接続を開いたままにするのを避けるため
          // キューされたレスポンスでは接続を閉じる
          'Connection': 'close',
        });
      }

      return shelf.Response.internalServerError(
          body: '上流サーバエラー', headers: {'Connection': 'close'});
    }
  }

  Future<Uint8List> _readRequestBodyBytes(shelf.Request request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// オフライン時のHTTPリクエストを処理します。
  ///
  /// GETリクエストはキャッシュから配信し、ミスの場合はオフラインフォールバック。
  /// 非-GETリクエストはオンライン復帰時の再送用にキューに保存します。
  ///
  /// [request] 処理するHTTPリクエスト。
  ///
  /// Returns: HTTPレスポンス。
  Future<shelf.Response> _handleOfflineRequest(shelf.Request request) async {
    if (request.method == 'GET') {
      final upstreamUrl = _buildUpstreamUrl(request);
      final cacheKey = _generateCacheKey(upstreamUrl);
      final cachedResponse = await _getCachedResponse(cacheKey);

      if (cachedResponse != null) {
        final rangeEntry = await _getCachedResponseBytesEntry(cacheKey);
        if (rangeEntry != null) {
          final rangeResp = _tryBuildRangeResponseFromCache(
            request,
            cachedHeaders: rangeEntry.headers,
            cachedBodyBytes: rangeEntry.bodyBytes,
          );
          if (rangeResp != null) {
            _cacheHits++;
            _emitEvent(ProxyEventType.cacheHit, request.url.toString(), {});
            return rangeResp.change(headers: {
              'X-Offline': '1',
              'X-Offline-Source': 'cache',
              ...rangeResp.headers,
            });
          }
        }

        _cacheHits++;
        _emitEvent(ProxyEventType.cacheHit, request.url.toString(), {});
        return cachedResponse.change(headers: {
          'X-Offline': '1',
          'X-Offline-Source': 'cache',
          ...cachedResponse.headers,
        });
      }

      // オフラインフォールバックを返却
      return shelf.Response.ok(
        _getOfflineFallbackContent(),
        headers: {
          'Content-Type': 'text/html; charset=utf-8',
          'X-Offline': '1',
          'X-Offline-Source': 'fallback',
        },
      );
    } else {
      // GET以外のリクエストをキューに保存
      await _queueRequest(request);
      _emitEvent(ProxyEventType.requestQueued, request.url.toString(), {});

      return shelf.Response.ok('オンライン復帰時に再試行するためキューに保存しました');
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

  /// キャッシュからレスポンスを取得します。
  ///
  /// 指定したキャッシュキーに対応するデータをHiveから読み込み、
  /// shelf.Responseオブジェクトに再構築して返却します。
  ///
  /// [cacheKey] キャッシュキー。
  ///
  /// Returns: キャッシュされたレスポンス。キャッシュがない場合は `null`。
  Future<shelf.Response?> _getCachedResponse(String cacheKey) async {
    final data = _cacheBox?.get(cacheKey) as Map?;
    if (data == null) {
      return null;
    }

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

  Future<
      ({
        int statusCode,
        Map<String, String> headers,
        Uint8List bodyBytes,
      })?> _getCachedResponseBytesEntry(String cacheKey) async {
    final data = _cacheBox?.get(cacheKey) as Map?;
    if (data == null) return null;

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
  ///
  /// [response] チェックするレスポンス。
  ///
  /// Returns: キャッシュが有効な場合は `true`。
  bool _isCacheValid(shelf.Response response) {
    // Cache-ControlヘッダやAgeヘッダをチェック
    final cacheControl = response.headers['cache-control'];
    final ageHeader = response.headers['age'];

    // no-cacheやno-storeが指定されている場合は無効
    if (cacheControl != null) {
      if (cacheControl.contains('no-cache') ||
          cacheControl.contains('no-store')) {
        return false;
      }

      // max-ageとAgeヘッダで有効性をチェック
      if (cacheControl.contains('max-age=') && ageHeader != null) {
        final maxAge = int.tryParse(
                cacheControl.split('max-age=')[1].split(',')[0].trim()) ??
            0;
        final age = int.tryParse(ageHeader) ?? 0;
        return age < maxAge;
      }
    }

    // デフォルトでは有効とみなす（TTLチェックは別途実装）
    return true;
  }

  /// リクエストを上流サーバに転送します。
  ///
  /// 元のHTTPリクエストのメソッド、ヘッダ、ボディを保持したまま
  /// 上流サーバに送信し、レスポンスを取得します。
  /// Hop-by-Hopヘッダは除外されます。
  ///
  /// [request] 転送するHTTPリクエスト。
  ///
  /// Returns: ステータスコード、ヘッダ、ボディバイトを含むレコード。
  Future<({int statusCode, Map<String, String> headers, List<int> bodyBytes})>
      _forwardToUpstream(
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

    // 同時上流接続数を制限してネイティブ側のリソース枯渇を防ぐ
    await _upstreamSemaphore.acquire(timeout: const Duration(seconds: 30));

    try {
      final ioRequest = await client.openUrl(request.method, uri);
      await _copyRequestHeaders(request, ioRequest, upstreamUri: uri);

      // GET以外のリクエストの場合はボディをコピー
      if (request.method != 'GET') {
        final bytes = requestBodyBytes ?? await _readRequestBodyBytes(request);
        if (bytes.isNotEmpty) {
          ioRequest.add(bytes);
        }
      }

      final ioResponse = await ioRequest.close().timeout(
            _config?.requestTimeout ?? const Duration(seconds: 60),
          );

      final builder = BytesBuilder(copy: false);
      await for (final chunk in ioResponse) {
        builder.add(chunk);
      }
      final bodyBytes = builder.takeBytes();

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
    request.headers.forEach((key, value) {
      final lowerKey = key.toLowerCase();
      if (!_isHopByHopHeader(key) &&
          lowerKey != 'accept-encoding' &&
          lowerKey != 'host' &&
          lowerKey != 'cookie') {
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
      'upgrade',
      'proxy-authenticate',
      'proxy-authorization',
      'te',
      'trailers',
      'transfer-encoding',
    ];
    return hopByHopHeaders.contains(header.toLowerCase());
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
    // Cache-Controlヘッダに基づいて有効期限を算出
    final cacheControl = headers['cache-control'];
    if (cacheControl != null && cacheControl.contains('max-age=')) {
      final maxAge =
          int.tryParse(cacheControl.split('max-age=')[1].split(',')[0].trim());
      if (maxAge != null) {
        return DateTime.now().add(Duration(seconds: maxAge));
      }
    }

    // デフォルトTTLを使用
    final ttl =
        _config?.cacheTtl[contentType] ?? _config?.cacheTtl['default'] ?? 3600;
    return DateTime.now().add(Duration(seconds: ttl));
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
  /// [createdAt] キャッシュ作成日時。
  /// [contentType] コンテンツタイプ。
  ///
  /// Returns: Stale有効期限の日時。
  DateTime _calculateStaleExpiration(DateTime createdAt, String contentType) {
    final stalePeriod = _config?.cacheStale[contentType] ??
        _config?.cacheStale['default'] ??
        259200;
    return createdAt.add(Duration(seconds: stalePeriod));
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

  /// HTTPリクエストをキューに保存します。
  ///
  /// オフライン時や上流サーバエラー時に非-GETリクエストを
  /// キューに保存し、オンライン復帰時に自動再送します。
  ///
  /// [request] キューに保存するHTTPリクエスト。
  Future<void> _queueRequest(
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

    final key = DateTime.now().millisecondsSinceEpoch.toString();
    await _queueBox?.put(key, queueData);
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
    try {
      final request = await client.getUrl(uri).timeout(
            Duration(seconds: timeout ?? 30),
          );
      // keep-aliveを有効にする（persistentConnectionデフォルトを使用）
      request.headers.set('accept-encoding', 'gzip, deflate');

      final response = await request.close().timeout(
            Duration(seconds: timeout ?? 30),
          );

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      final bodyBytes = builder.takeBytes();

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
  }

  /// キューに保存されたリクエストを消化します。
  ///
  /// オンライン時にキュー内のリクエストを順次上流サーバに送信し、
  /// 成功時はキューから削除、失敗時はバックオフで再試行します。
  Future<void> _drainQueue() async {
    if (!_isOnline || _queueBox == null || _isDrainingQueue) {
      return;
    }

    if (_queueBox!.isEmpty) {
      return;
    }

    _isDrainingQueue = true;
    try {
      final keys = _queueBox!.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        await _processQueuedItem(keys[i]);
        if (i % 10 == 0) {
          await Future.delayed(Duration.zero); // UIフリーズ防止
        }
      }
    } finally {
      _isDrainingQueue = false;
    }
  }

  /// キューの個別アイテムを処理します。
  Future<void> _processQueuedItem(dynamic key) async {
    final data = _queueBox!.get(key) as Map?;
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
      if (result.success) {
        await _queueBox!.delete(key);
        _emitEvent(ProxyEventType.queueDrained, itemUrl, {});
      } else if (result.shouldDrop) {
        await _queueBox!.delete(key);
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
        await _queueBox!.put(key, data);
      }
    } catch (e) {
      _updateRetrySchedule(data);
      await _queueBox!.put(key, data);
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
      final request = await client.openUrl(method, uri);

      // keep-aliveを有効化（接続を閉じる指示を送らない）
      request.headers.set('accept-encoding', 'gzip, deflate');

      headers.forEach((key, value) {
        request.headers.set(key, value);
      });

      if (body.isNotEmpty && method != 'GET') {
        request.add(body);
      }

      try {
        final response = await request
            .close()
            .timeout(_config?.requestTimeout ?? const Duration(seconds: 60));

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
      ..connectionTimeout =
          _config?.connectTimeout ?? const Duration(seconds: 10)
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
    final createdAt = DateTime.parse(data['createdAt'] as String);

    if (now.isBefore(expiresAt)) {
      return CacheStatus.fresh;
    }

    final staleUntil =
        _calculateStaleExpiration(createdAt, data['contentType'] as String);
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
          _looksLikeStaticResourcePath(normalizedTargetUri.path);
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
  int? get _activeProxyPort => _server?.port;

  /// HTTP または HTTPS スキームかどうかを返します。
  bool _isHttpScheme(String scheme) {
    return scheme == 'http' || scheme == 'https';
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

  /// 静的リソースらしいパスかどうかを返します。
  bool _looksLikeStaticResourcePath(String path) {
    final lower = path.toLowerCase();
    final dotIndex = lower.lastIndexOf('.');
    final extension = dotIndex >= 0 ? lower.substring(dotIndex) : '';
    return extension.isNotEmpty &&
        _staticResourceExtensions.contains(extension);
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

    final key = droppedAt.microsecondsSinceEpoch.toString();
    await _droppedRequestBox?.put(key, droppedData);
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
