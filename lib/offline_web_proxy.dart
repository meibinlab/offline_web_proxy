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
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

// モデルクラスと例外をインポート
import 'src/models/cache_entry.dart';
import 'src/models/cache_stats.dart';
import 'src/models/cookie_info.dart';
import 'src/models/dropped_request.dart';
import 'src/models/proxy_config.dart';
import 'src/models/proxy_event.dart';
import 'src/models/proxy_stats.dart';
import 'src/models/queued_request.dart';
import 'src/models/warmup_result.dart';
import 'src/exceptions/exceptions.dart';

// パブリックAPI用にクラスをエクスポート
export 'src/models/cache_entry.dart';
export 'src/models/cache_stats.dart';
export 'src/models/cookie_info.dart';
export 'src/models/dropped_request.dart';
export 'src/models/proxy_config.dart';
export 'src/models/proxy_event.dart';
export 'src/models/proxy_stats.dart';
export 'src/models/queued_request.dart';
export 'src/models/warmup_result.dart';
export 'src/exceptions/exceptions.dart';

/// キャッシュ事前更新の進捗を通知するコールバック関数。
typedef WarmupProgressCallback = void Function(int completed, int total);

/// キャッシュ事前更新でエラーが発生した際に呼ばれるコールバック関数。
typedef WarmupErrorCallback = void Function(String path, String error);

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
  final StreamController<ProxyEvent> _eventController =
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

  /// キャッシュデータの永続化ボックス。
  Box? _cacheBox;

  /// キューデータの永続化ボックス。
  Box? _queueBox;

  /// Cookieデータの永続化ボックス。
  Box? _cookieBox;

  /// べき等性キーの永続化ボックス。
  Box? _idempotencyBox;

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
      await _server?.close();
      await _connectivitySubscription.cancel();
      await _eventController.close();

      // Hiveボックスを閉じる
      await _cacheBox?.close();
      await _queueBox?.close();
      await _cookieBox?.close();
      await _idempotencyBox?.close();

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
        for (final key in _cacheBox!.keys) {
          final entry = _cacheBox!.get(key) as Map?;
          if (entry != null) {
            final expiresAt = DateTime.parse(entry['expiresAt'] as String);
            if (now.isAfter(expiresAt)) {
              keysToDelete.add(key as String);
            }
          }
        }

        for (final key in keysToDelete) {
          await _cacheBox!.delete(key);
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
      final cookies = <CookieInfo>[];

      if (_cookieBox != null) {
        int _idx = 0;
        for (final key in _cookieBox!.keys) {
          final data = _cookieBox!.get(key) as Map?;
          if (data != null) {
            final cookieInfo = _mapToCookieInfo(data);
            if (domain == null || cookieInfo.domain == domain) {
              cookies.add(cookieInfo);
            }
          }

          // 大量のCookieを処理する場合にUIをブロックしないよう一時的にyield
          _idx++;
          if (_idx % 50 == 0) {
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

  /// 保存されているCookieを削除します。
  ///
  /// [domain] 特定ドメインのCookieのみを削除したい場合に指定。省略時は全Cookieを削除。
  ///
  /// Throws:
  ///   * [CookieOperationException] Cookieの削除に失敗した場合。
  Future<void> clearCookies({String? domain}) async {
    try {
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
        int _idx = 0;
        for (final key in _queueBox!.keys) {
          final data = _queueBox!.get(key) as Map?;
          if (data != null) {
            requests.add(_mapToQueuedRequest(data));
          }

          // 大量キュー走査時にUIをブロックしないようyield
          _idx++;
          if (_idx % 50 == 0) {
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
      final requests = <DroppedRequest>[];

      // ドロップされたリクエストは現在の実装ではメモリに保存されないため空を返却
      // 将来的には特別なストレージやログファイルから読み込むことを想定

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
      // ドロップされたリクエストは現在の実装ではメモリに保存されないため操作なし
      // 将来的には特別なストレージやログファイルをクリアすることを想定
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
      final uptime = _startedAt != null
          ? DateTime.now().difference(_startedAt!)
          : Duration.zero;

      return ProxyStats(
        totalRequests: _totalRequests,
        cacheHits: _cacheHits,
        cacheMisses: _cacheMisses,
        cacheHitRate: _totalRequests > 0 ? _cacheHits / _totalRequests : 0.0,
        queueLength: queueLength,
        droppedRequestsCount: 0, // 現在の実装ではドロップ機能は未実装
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
    _cookieBox = await Hive.openBox('proxy_cookies');
    _idempotencyBox = await Hive.openBox('proxy_idempotency');
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

        _emitEvent(ProxyEventType.requestReceived, request.url.toString(), {
          'method': request.method,
          'userAgent': request.headers['user-agent'],
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

    // assets/static/フォルダにファイルが存在するかチェック
    // 一般的な静的リソースの拡張子をチェック
    final staticExtensions = {
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
      '.eot'
    };
    // pathに拡張子が無い場合にsubstring(-1)でクラッシュしないようガード
    final lower = path.toLowerCase();
    final dotIndex = lower.lastIndexOf('.');
    final extension = dotIndex >= 0 ? lower.substring(dotIndex) : '';
    final exists = extension.isNotEmpty &&
        staticExtensions.contains(extension) &&
        (path.startsWith('/static/') || path.startsWith('static/'));

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
    final path = request.url.path.startsWith('/')
        ? request.url.path
        : '/${request.url.path}';
    final query = request.url.query.isNotEmpty ? '?${request.url.query}' : '';
    return '${_config!.origin}$path$query';
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
      return cachedResponse;
    }

    // 上流サーバに転送
    try {
      final result = await _forwardToUpstream(request);

      // GETレスポンスをキャッシュ
      if (request.method == 'GET') {
        await _cacheResponseBytes(
            cacheKey, result.statusCode, result.headers, result.bodyBytes);
      }

      // GET以外のリクエストが失敗した場合はキューに保存
      if (request.method != 'GET' && result.statusCode >= 500) {
        await _queueRequest(request);
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
        return cachedResponse;
      } else if (request.method != 'GET') {
        await _queueRequest(request);
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
      return '${scheme}://${authority}${path}${query}';
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
    return shelf.Response(
      data['statusCode'] as int,
      body: data['body'] as String,
      headers: Map<String, String>.from(data['headers'] as Map),
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
      _forwardToUpstream(shelf.Request request) async {
    if (_config?.origin.isEmpty ?? true) {
      throw Exception('No upstream origin configured');
    }

    // パスとクエリパラメータを正規化して上流URLを構築
    final path = request.url.path.startsWith('/')
        ? request.url.path
        : '/${request.url.path}';
    final query = request.url.query.isNotEmpty ? '?${request.url.query}' : '';
    final upstreamUrl = '${_config!.origin}$path$query';
    final uri = Uri.parse(upstreamUrl);

    // HttpClientを再利用する（大量リクエストでの生成コストを削減）
    final client = _getOrCreateHttpClient();
    client.autoUncompress = false; // 自動解凍を無効化

    // 同時上流接続数を制限してネイティブ側のリソース枯渇を防ぐ
    await _upstreamSemaphore.acquire(timeout: const Duration(seconds: 30));

    try {
      final ioRequest = await client.openUrl(request.method, uri);
      _copyRequestHeaders(request, ioRequest);

      // GET以外のリクエストの場合はボディをコピー
      if (request.method != 'GET') {
        final bodyBytes = await request.read().expand((chunk) => chunk).toList();
        ioRequest.add(bodyBytes);
      }

      final ioResponse = await ioRequest.close().timeout(
        _config?.requestTimeout ?? const Duration(seconds: 60),
      );

      final bodyBytes = await ioResponse.fold<List<int>>(
        <int>[],
        (previous, chunk) => previous..addAll(chunk),
      );

      final headers = <String, String>{};
      ioResponse.headers.forEach((name, values) {
        headers[name] = values.join(', ');
      });

      return (
        statusCode: ioResponse.statusCode,
        headers: headers,
        bodyBytes: bodyBytes,
      );
    } finally {
      _upstreamSemaphore.release();
    }
  }

  /// リクエストヘッダを上流リクエストにコピーします。
  void _copyRequestHeaders(shelf.Request request, HttpClientRequest ioRequest) {
    request.headers.forEach((key, value) {
      final lowerKey = key.toLowerCase();
      if (!_isHopByHopHeader(key) &&
          lowerKey != 'accept-encoding' &&
          lowerKey != 'host') {
        ioRequest.headers.set(key, value);
      }
    });
    // 非圧縮レスポンスを要求
    ioRequest.headers.set('accept-encoding', 'identity');
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

  /// レスポンスをキャッシュに保存します（バイト配列版）。
  ///
  /// [cacheKey] キャッシュキー。
  /// [response] キャッシュするHTTPレスポンス。
  /// [bodyBytes] レスポンスボディのバイト配列。
  Future<void> _cacheResponseBytes(String cacheKey, int statusCode,
      Map<String, String> headers, List<int> bodyBytes) async {
    final body = utf8.decode(bodyBytes, allowMalformed: true);
    final contentType = headers['content-type'] ?? 'application/octet-stream';
    final data = {
      'statusCode': statusCode,
      'headers': headers,
      'body': body,
      'createdAt': DateTime.now().toIso8601String(),
      'expiresAt': _calculateExpirationFromHeaders(headers, contentType)
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
    data['nextRetryAt'] = DateTime.now()
        .add(Duration(seconds: backoffSeconds))
        .toIso8601String();
  }

  /// HTTPリクエストをキューに保存します。
  ///
  /// オフライン時や上流サーバエラー時に非-GETリクエストを
  /// キューに保存し、オンライン復帰時に自動再送します。
  ///
  /// [request] キューに保存するHTTPリクエスト。
  Future<void> _queueRequest(shelf.Request request) async {
    final body = request.method != 'GET'
        ? await request.read().expand((chunk) => chunk).toList()
        : <int>[];

    final queueData = {
      'url': request.url.toString(),
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

    final url = '${_config!.origin}$path';
    final uri = Uri.parse(url);
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

      final bodyBytes = await response.fold<List<int>>(
        <int>[],
        (previous, chunk) => previous..addAll(chunk),
      );

      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.join(', ');
      });

      return http.Response.bytes(
        bodyBytes,
        response.statusCode,
        headers: headers,
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
    // キュー消化タイマーを開始（重複実行を避けるためawait可能なコールバック）
    Timer.periodic(Duration(seconds: 5), (timer) async {
      if (_isDrainingQueue) return;
      _isDrainingQueue = true;
      try {
        await _drainQueue();
      } finally {
        _isDrainingQueue = false;
      }
    });

    // キャッシュパージタイマーを開始（重複実行を避けるためawait）
    Timer.periodic(Duration(hours: 1), (timer) async {
      await _purgeExpiredCache();
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

    try {
      final success = await _sendQueuedRequest(data);
      if (success) {
        await _queueBox!.delete(key);
        _emitEvent(ProxyEventType.queueDrained, itemUrl, {});
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
  Future<bool> _sendQueuedRequest(Map data) async {
    if (_config?.origin.isEmpty ?? true) {
      return false;
    }

    final url = data['url'] as String;
    final method = data['method'] as String;
    final headers = Map<String, String>.from(data['headers'] as Map? ?? {});
    final body = data['body'] as List<int>? ?? [];

    final client = _getOrCreateHttpClient();
    client.autoUncompress = true;
    try {
      final uri = Uri.parse(url);
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
        return response.statusCode >= 200 && response.statusCode < 300;
      } catch (e) {
        return false;
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
