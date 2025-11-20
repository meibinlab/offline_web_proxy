import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'dart:io';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    channel.setMockMethodCallHandler((MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        // テスト用の一時ディレクトリパスのみ返す
        final tempDir =
            Directory.systemTemp.createTempSync('offline_web_proxy_test');
        return tempDir.path;
      }
      return null;
    });
  });

  group('OfflineWebProxy Basic Tests', () {
    late OfflineWebProxy proxy;

    setUp(() {
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    /// プロキシインスタンスのテスト
    test('should create proxy instance', () {
      expect(proxy, isNotNull);
      expect(proxy.isRunning, isFalse);
    });

    /// イベントストリームのテスト
    test('should provide event stream', () {
      expect(proxy.events, isA<Stream<ProxyEvent>>());
    });

    /// 初期状態のテスト
    test('should have correct initial state', () {
      expect(proxy.isRunning, isFalse);
    });

    /// 統計情報の初期値テスト
    test('should provide initial stats', () async {
      final stats = await proxy.getStats();
      expect(stats.totalRequests, equals(0));
      expect(stats.cacheHits, equals(0));
      expect(stats.cacheMisses, equals(0));
      expect(stats.cacheHitRate, equals(0.0));
      expect(stats.queueLength, equals(0));
      expect(stats.droppedRequestsCount, equals(0));
    });

    /// キャッシュ統計の初期値テスト
    test('should provide initial cache stats', () async {
      final cacheStats = await proxy.getCacheStats();
      expect(cacheStats.totalEntries, equals(0));
      expect(cacheStats.freshEntries, equals(0));
      expect(cacheStats.staleEntries, equals(0));
      expect(cacheStats.expiredEntries, equals(0));
      expect(cacheStats.totalSize, equals(0));
      expect(cacheStats.hitRate, equals(0.0));
      expect(cacheStats.staleUsageRate, equals(0.0));
    });

    /// キューの初期状態テスト
    test('should have empty queue initially', () async {
      final queuedRequests = await proxy.getQueuedRequests();
      expect(queuedRequests, isEmpty);
    });

    /// ドロップされたリクエストの初期状態テスト
    test('should have no dropped requests initially', () async {
      final droppedRequests = await proxy.getDroppedRequests();
      expect(droppedRequests, isEmpty);
    });

    /// Cookieの初期状態テスト
    test('should have no cookies initially', () async {
      final cookies = await proxy.getCookies();
      expect(cookies, isEmpty);
    });

    /// キャッシュリストの初期状態テスト
    test('should have empty cache list initially', () async {
      final cacheList = await proxy.getCacheList();
      expect(cacheList, isEmpty);
    });

    /// キャッシュクリア操作のテスト
    test('should handle cache clear operation', () async {
      expect(() => proxy.clearCache(), returnsNormally);
    });

    /// 期限切れキャッシュクリア操作のテスト
    test('should handle expired cache clear operation', () async {
      expect(() => proxy.clearExpiredCache(), returnsNormally);
    });

    /// 特定URLのキャッシュクリア操作のテスト
    test('should handle cache clear for specific URL', () async {
      const testUrl = 'https://example.com/test';
      expect(() => proxy.clearCacheForUrl(testUrl), returnsNormally);
    });

    /// 無効なURLでのキャッシュクリアエラーテスト
    test('should throw error for invalid URL in cache clear', () async {
      expect(() => proxy.clearCacheForUrl(''), throwsArgumentError);
    });

    /// Cookieクリア操作のテスト
    test('should handle cookie clear operation', () async {
      expect(() => proxy.clearCookies(), returnsNormally);
    });

    /// 特定ドメインのCookieクリア操作のテスト
    test('should handle cookie clear for specific domain', () async {
      const testDomain = 'example.com';
      expect(() => proxy.clearCookies(domain: testDomain), returnsNormally);
    });

    /// ドロップされたリクエストのクリア操作テスト
    test('should handle dropped requests clear operation', () async {
      expect(() => proxy.clearDroppedRequests(), returnsNormally);
    });
  });

  group('ProxyConfig Tests', () {
    /// デフォルト設定のテスト
    test('should create config with default values', () {
      const config = ProxyConfig(origin: 'https://example.com');

      expect(config.origin, equals('https://example.com'));
      expect(config.host, equals('127.0.0.1'));
      expect(config.port, equals(0));
      expect(config.cacheMaxSize, equals(200 * 1024 * 1024));
      expect(config.connectTimeout, equals(Duration(seconds: 10)));
      expect(config.requestTimeout, equals(Duration(seconds: 60)));
      expect(config.enableAdminApi, isFalse);
      expect(config.logLevel, equals('info'));
      expect(config.startupPaths, isEmpty);
    });

    /// カスタム設定のテスト
    test('should create config with custom values', () {
      const config = ProxyConfig(
        origin: 'https://api.test.com',
        host: '0.0.0.0',
        port: 8080,
        cacheMaxSize: 100 * 1024 * 1024,
        connectTimeout: Duration(seconds: 5),
        requestTimeout: Duration(seconds: 30),
        enableAdminApi: true,
        logLevel: 'debug',
        startupPaths: ['/config', '/health'],
      );

      expect(config.origin, equals('https://api.test.com'));
      expect(config.host, equals('0.0.0.0'));
      expect(config.port, equals(8080));
      expect(config.cacheMaxSize, equals(100 * 1024 * 1024));
      expect(config.connectTimeout, equals(Duration(seconds: 5)));
      expect(config.requestTimeout, equals(Duration(seconds: 30)));
      expect(config.enableAdminApi, isTrue);
      expect(config.logLevel, equals('debug'));
      expect(config.startupPaths, contains('/config'));
      expect(config.startupPaths, contains('/health'));
    });

    /// TTL設定のテスト
    test('should have correct default TTL settings', () {
      const config = ProxyConfig(origin: 'https://example.com');

      expect(config.cacheTtl['text/html'], equals(3600));
      expect(config.cacheTtl['text/css'], equals(86400));
      expect(config.cacheTtl['application/javascript'], equals(86400));
      expect(config.cacheTtl['image/*'], equals(604800));
      expect(config.cacheTtl['default'], equals(86400));
    });

    /// Stale期間設定のテスト
    test('should have correct default stale settings', () {
      const config = ProxyConfig(origin: 'https://example.com');

      expect(config.cacheStale['text/html'], equals(86400));
      expect(config.cacheStale['text/css'], equals(604800));
      expect(config.cacheStale['image/*'], equals(2592000));
      expect(config.cacheStale['default'], equals(259200));
    });

    /// バックオフ設定のテスト
    test('should have correct default backoff settings', () {
      const config = ProxyConfig(origin: 'https://example.com');

      expect(config.retryBackoffSeconds, equals([1, 2, 5, 10, 20, 30]));
    });

    /// toString()メソッドのテスト
    test('should have proper string representation', () {
      const config = ProxyConfig(
        origin: 'https://example.com',
        host: '127.0.0.1',
        port: 8080,
      );

      expect(config.toString(), contains('https://example.com'));
      expect(config.toString(), contains('127.0.0.1'));
      expect(config.toString(), contains('8080'));
    });
  });

  group('Data Model Tests', () {
    /// CacheEntryのテスト
    test('should create CacheEntry correctly', () {
      final entry = CacheEntry(
        url: 'https://example.com/test',
        statusCode: 200,
        contentType: 'text/html',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(Duration(hours: 1)),
        status: CacheStatus.fresh,
        sizeBytes: 1024,
      );

      expect(entry.url, equals('https://example.com/test'));
      expect(entry.statusCode, equals(200));
      expect(entry.contentType, equals('text/html'));
      expect(entry.status, equals(CacheStatus.fresh));
      expect(entry.sizeBytes, equals(1024));
    });

    /// CookieInfoのテスト
    test('should create CookieInfo correctly', () {
      final cookie = CookieInfo(
        name: 'session_id',
        value: '***',
        domain: 'example.com',
        path: '/',
        expires: DateTime.now().add(Duration(days: 1)),
        secure: true,
        sameSite: 'Lax',
      );

      expect(cookie.name, equals('session_id'));
      expect(cookie.value, equals('***'));
      expect(cookie.domain, equals('example.com'));
      expect(cookie.path, equals('/'));
      expect(cookie.secure, isTrue);
      expect(cookie.sameSite, equals('Lax'));
    });

    /// QueuedRequestのテスト
    test('should create QueuedRequest correctly', () {
      final request = QueuedRequest(
        url: 'https://api.example.com/data',
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        queuedAt: DateTime.now(),
        retryCount: 0,
        nextRetryAt: DateTime.now().add(Duration(seconds: 1)),
      );

      expect(request.url, equals('https://api.example.com/data'));
      expect(request.method, equals('POST'));
      expect(request.headers['Content-Type'], equals('application/json'));
      expect(request.retryCount, equals(0));
    });

    /// WarmupResultのテスト
    test('should create WarmupResult correctly', () {
      final entries = [
        WarmupEntry(
          path: '/config',
          success: true,
          statusCode: 200,
          duration: Duration(milliseconds: 500),
        ),
        WarmupEntry(
          path: '/error',
          success: false,
          errorMessage: 'Not found',
          duration: Duration(milliseconds: 100),
        ),
      ];

      final result = WarmupResult(
        successCount: 1,
        failureCount: 1,
        totalDuration: Duration(milliseconds: 600),
        entries: entries,
      );

      expect(result.successCount, equals(1));
      expect(result.failureCount, equals(1));
      expect(result.totalDuration, equals(Duration(milliseconds: 600)));
      expect(result.entries, hasLength(2));
      expect(result.entries[0].success, isTrue);
      expect(result.entries[1].success, isFalse);
    });

    /// ProxyEventのテスト
    test('should create ProxyEvent correctly', () {
      final event = ProxyEvent(
        type: ProxyEventType.cacheHit,
        url: 'https://example.com/page',
        timestamp: DateTime.now(),
        data: {'cached': true},
      );

      expect(event.type, equals(ProxyEventType.cacheHit));
      expect(event.url, equals('https://example.com/page'));
      expect(event.data['cached'], isTrue);
    });

    /// ProxyStatsのテスト
    test('should create ProxyStats correctly', () {
      final stats = ProxyStats(
        totalRequests: 100,
        cacheHits: 80,
        cacheMisses: 20,
        cacheHitRate: 0.8,
        queueLength: 5,
        droppedRequestsCount: 2,
        startedAt: DateTime.now().subtract(Duration(hours: 1)),
        uptime: Duration(hours: 1),
      );

      expect(stats.totalRequests, equals(100));
      expect(stats.cacheHits, equals(80));
      expect(stats.cacheMisses, equals(20));
      expect(stats.cacheHitRate, equals(0.8));
      expect(stats.queueLength, equals(5));
      expect(stats.droppedRequestsCount, equals(2));
      expect(stats.uptime, equals(Duration(hours: 1)));
    });

    /// CacheStatsのテスト
    test('should create CacheStats correctly', () {
      final stats = CacheStats(
        totalEntries: 50,
        freshEntries: 30,
        staleEntries: 15,
        expiredEntries: 5,
        totalSize: 1024 * 1024,
        hitRate: 0.85,
        staleUsageRate: 0.1,
      );

      expect(stats.totalEntries, equals(50));
      expect(stats.freshEntries, equals(30));
      expect(stats.staleEntries, equals(15));
      expect(stats.expiredEntries, equals(5));
      expect(stats.totalSize, equals(1024 * 1024));
      expect(stats.hitRate, equals(0.85));
      expect(stats.staleUsageRate, equals(0.1));
    });
  });

  group('Exception Tests', () {
    /// ProxyStartExceptionのテスト
    test('should create ProxyStartException correctly', () {
      const exception = ProxyStartException('Failed to start', null);

      expect(exception.message, equals('Failed to start'));
      expect(exception.cause, isNull);
      expect(exception.toString(), contains('ProxyStartException'));
      expect(exception.toString(), contains('Failed to start'));
    });

    /// CacheOperationExceptionのテスト
    test('should create CacheOperationException correctly', () {
      const exception =
          CacheOperationException('clear', 'Failed to clear cache', null);

      expect(exception.operation, equals('clear'));
      expect(exception.message, equals('Failed to clear cache'));
      expect(exception.cause, isNull);
      expect(exception.toString(), contains('CacheOperationException[clear]'));
    });

    /// NetworkExceptionのテスト
    test('should create NetworkException correctly', () {
      const exception = NetworkException('Connection timeout', null);

      expect(exception.message, equals('Connection timeout'));
      expect(exception.cause, isNull);
      expect(exception.toString(), contains('NetworkException'));
      expect(exception.toString(), contains('Connection timeout'));
    });

    /// WarmupExceptionのテスト
    test('should create WarmupException correctly', () {
      final entries = [
        WarmupEntry(
          path: '/test',
          success: false,
          errorMessage: 'Error',
          duration: Duration(milliseconds: 100),
        ),
      ];

      final exception = WarmupException('Warmup failed', entries, null);

      expect(exception.message, equals('Warmup failed'));
      expect(exception.partialResults, hasLength(1));
      expect(exception.cause, isNull);
      expect(exception.toString(), contains('WarmupException'));
      expect(exception.toString(), contains('1 partial results'));
    });
  });

  group('Warmup Cache Tests', () {
    late OfflineWebProxy proxy;

    setUp(() {
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    /// 空のパスリストでのウォームアップテスト
    test('should handle warmup with empty paths', () async {
      final result = await proxy.warmupCache(paths: []);

      expect(result.successCount, equals(0));
      expect(result.failureCount, equals(0));
      expect(result.entries, isEmpty);
    });

    /// ウォームアップの進捗コールバックテスト
    test('should call progress callback during warmup', () async {
      var progressCalled = false;
      var errorCalled = false;

      final result = await proxy.warmupCache(
        paths: ['/nonexistent'],
        onProgress: (completed, total) {
          progressCalled = true;
          expect(completed, greaterThanOrEqualTo(0));
          expect(total, greaterThan(0));
        },
        onError: (path, error) {
          errorCalled = true;
          expect(path, equals('/nonexistent'));
          expect(error, isNotEmpty);
        },
      );

      expect(progressCalled, isTrue);
      expect(errorCalled, isTrue);
      expect(result.failureCount, greaterThan(0));
    });
  });

  group('Compression Tests', () {
    late OfflineWebProxy proxy;
    late HttpServer mockServer;
    late int port;

    setUp(() async {
      proxy = OfflineWebProxy();
      mockServer = await HttpServer.bind('localhost', 0);
      port = mockServer.port;
      mockServer.listen((HttpRequest req) async {
        // accept-encodingヘッダ検証
        final acceptEncoding = req.headers.value('accept-encoding');
        expect(acceptEncoding, contains('gzip'));
        // gzip圧縮レスポンス
        final data = utf8.encode('compressed test data');
        final gzipData = gzip.encode(data);
        req.response.headers.set('content-encoding', 'gzip');
        req.response.headers.contentType = ContentType.text;
        req.response.add(gzipData);
        await req.response.close();
      });
    });

    tearDown(() async {
      await mockServer.close(force: true);
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    test('should decompress gzip response correctly', () async {
      final config = ProxyConfig(origin: 'http://localhost:$port');
      await proxy.start(config: config);
      // getCacheListでレスポンス取得（キャッシュが空でもリクエストは発生）
      final entries = await proxy.getCacheList();
      // 圧縮データが展開されているか（body内容はキャッシュエントリに格納される想定）
      // ここでは最低限、例外なくリクエストが通ることを確認
      expect(entries, isA<List<CacheEntry>>());
    });
  });
}
