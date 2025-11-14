import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

void main() {
  group('Data Models Edge Cases', () {
    /// CacheEntryのエッジケーステスト
    test('CacheEntry should handle edge case values', () {
      final now = DateTime.now();
      final pastTime = now.subtract(Duration(hours: 1));

      final entry = CacheEntry(
        url: '',
        statusCode: 0,
        contentType: '',
        createdAt: pastTime,
        expiresAt: now,
        status: CacheStatus.expired,
        sizeBytes: 0,
      );

      expect(entry.url, isEmpty);
      expect(entry.statusCode, equals(0));
      expect(entry.contentType, isEmpty);
      expect(entry.status, equals(CacheStatus.expired));
      expect(entry.sizeBytes, equals(0));
      expect(entry.createdAt.isBefore(entry.expiresAt), isTrue);
    });

    /// CookieInfoのオプショナルフィールドテスト
    test('CookieInfo should handle null optional fields', () {
      const cookie = CookieInfo(
        name: 'test',
        value: 'masked',
        domain: 'example.com',
        path: '/',
        expires: null, // セッションCookie
        secure: false,
        sameSite: null, // SameSite指定なし
      );

      expect(cookie.name, equals('test'));
      expect(cookie.expires, isNull);
      expect(cookie.sameSite, isNull);
      expect(cookie.secure, isFalse);
    });

    /// QueuedRequestの空ヘッダーテスト
    test('QueuedRequest should handle empty headers', () {
      final now = DateTime.now();

      final request = QueuedRequest(
        url: 'https://example.com',
        method: 'GET',
        headers: {}, // 空のヘッダー
        queuedAt: now,
        retryCount: 5,
        nextRetryAt: now.add(Duration(minutes: 10)),
      );

      expect(request.headers, isEmpty);
      expect(request.retryCount, equals(5));
    });

    /// DroppedRequestのテスト
    test('DroppedRequest should handle all error types', () {
      final now = DateTime.now();

      final request = DroppedRequest(
        url: 'https://api.example.com/endpoint',
        method: 'POST',
        droppedAt: now,
        dropReason: '4xx_error',
        statusCode: 404,
        errorMessage: 'Not Found',
      );

      expect(request.url, equals('https://api.example.com/endpoint'));
      expect(request.method, equals('POST'));
      expect(request.dropReason, equals('4xx_error'));
      expect(request.statusCode, equals(404));
      expect(request.errorMessage, equals('Not Found'));
    });

    /// WarmupEntryの失敗ケーステスト
    test('WarmupEntry should handle failure cases', () {
      const entry = WarmupEntry(
        path: '/api/fail',
        success: false,
        statusCode: null, // 失敗時はnull
        errorMessage: 'Connection refused',
        duration: Duration(milliseconds: 5000), // タイムアウト
      );

      expect(entry.success, isFalse);
      expect(entry.statusCode, isNull);
      expect(entry.errorMessage, equals('Connection refused'));
      expect(entry.duration.inMilliseconds, equals(5000));
    });

    /// ProxyEventの全イベントタイプテスト
    test('ProxyEvent should support all event types', () {
      final eventTypes = [
        ProxyEventType.serverStarted,
        ProxyEventType.serverStopped,
        ProxyEventType.requestReceived,
        ProxyEventType.cacheHit,
        ProxyEventType.cacheMiss,
        ProxyEventType.cacheStaleUsed,
        ProxyEventType.requestQueued,
        ProxyEventType.queueDrained,
        ProxyEventType.requestDropped,
        ProxyEventType.networkOnline,
        ProxyEventType.networkOffline,
        ProxyEventType.cacheCleared,
        ProxyEventType.errorOccurred,
      ];

      for (final eventType in eventTypes) {
        final event = ProxyEvent(
          type: eventType,
          url: 'https://example.com',
          timestamp: DateTime.now(),
          data: {'test': true},
        );

        expect(event.type, equals(eventType));
        expect(event.data['test'], isTrue);
      }
    });

    /// CacheStatusの全状態テスト
    test('CacheStatus should have all states defined', () {
      const statuses = [
        CacheStatus.fresh,
        CacheStatus.stale,
        CacheStatus.expired,
      ];

      for (final status in statuses) {
        final entry = CacheEntry(
          url: 'https://example.com',
          statusCode: 200,
          contentType: 'text/html',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(Duration(hours: 1)),
          status: status,
          sizeBytes: 1024,
        );

        expect(entry.status, equals(status));
      }
    });

    /// 統計情報のゼロ値テスト
    test('Stats should handle zero values correctly', () {
      final proxyStats = ProxyStats(
        totalRequests: 0,
        cacheHits: 0,
        cacheMisses: 0,
        cacheHitRate: 0.0,
        queueLength: 0,
        droppedRequestsCount: 0,
        startedAt: DateTime.now(),
        uptime: Duration.zero,
      );

      expect(proxyStats.totalRequests, equals(0));
      expect(proxyStats.cacheHitRate, equals(0.0));
      expect(proxyStats.uptime, equals(Duration.zero));

      const cacheStats = CacheStats(
        totalEntries: 0,
        freshEntries: 0,
        staleEntries: 0,
        expiredEntries: 0,
        totalSize: 0,
        hitRate: 0.0,
        staleUsageRate: 0.0,
      );

      expect(cacheStats.totalEntries, equals(0));
      expect(cacheStats.hitRate, equals(0.0));
      expect(cacheStats.staleUsageRate, equals(0.0));
    });

    /// 大きな数値の統計情報テスト
    test('Stats should handle large values correctly', () {
      const maxInt = 9223372036854775807; // 64-bit max int
      const largeSize = 1099511627776; // 1TB

      final proxyStats = ProxyStats(
        totalRequests: maxInt,
        cacheHits: maxInt ~/ 2,
        cacheMisses: maxInt ~/ 2,
        cacheHitRate: 0.5,
        queueLength: 1000000,
        droppedRequestsCount: 100000,
        startedAt: DateTime.now().subtract(Duration(days: 365)),
        uptime: Duration(days: 365),
      );

      expect(proxyStats.totalRequests, equals(maxInt));
      expect(proxyStats.uptime, equals(Duration(days: 365)));

      const cacheStats = CacheStats(
        totalEntries: 1000000,
        freshEntries: 500000,
        staleEntries: 300000,
        expiredEntries: 200000,
        totalSize: largeSize,
        hitRate: 0.95,
        staleUsageRate: 0.05,
      );

      expect(cacheStats.totalSize, equals(largeSize));
      expect(cacheStats.hitRate, equals(0.95));
    });
  });

  group('ProxyConfig Edge Cases', () {
    /// 極端な設定値のテスト
    test('should handle extreme configuration values', () {
      final config = ProxyConfig(
        origin:
            'https://very-long-domain-name-for-testing-purposes.example.com:65535/very/long/path/with/many/segments',
        host: '0.0.0.0',
        port: 65535,
        cacheMaxSize: 0, // キャッシュ無効
        connectTimeout: Duration(milliseconds: 1),
        requestTimeout: Duration(hours: 24),
        retryBackoffSeconds: [1, 2, 4, 8, 16, 32, 64, 128, 256, 512],
        enableAdminApi: true,
        logLevel: 'trace',
        startupPaths: List.generate(100, (i) => '/path$i'), // 大量のパス
      );

      expect(config.origin, contains('very-long-domain-name'));
      expect(config.port, equals(65535));
      expect(config.cacheMaxSize, equals(0));
      expect(config.connectTimeout, equals(Duration(milliseconds: 1)));
      expect(config.requestTimeout, equals(Duration(hours: 24)));
      expect(config.retryBackoffSeconds, hasLength(10));
      expect(config.startupPaths, hasLength(100));
    });

    /// 空の設定値テスト
    test('should handle empty configuration values', () {
      const config = ProxyConfig(
        origin: '', // 空のオリジン（通常は無効だが型上は可能）
        cacheTtl: {}, // 空のTTL設定
        cacheStale: {}, // 空のStale設定
        retryBackoffSeconds: [], // 空のバックオフ
        startupPaths: [], // 空のパス
      );

      expect(config.origin, isEmpty);
      expect(config.cacheTtl, isEmpty);
      expect(config.cacheStale, isEmpty);
      expect(config.retryBackoffSeconds, isEmpty);
      expect(config.startupPaths, isEmpty);
    });

    /// カスタムTTL設定のテスト
    test('should handle custom TTL and stale configurations', () {
      const customTtl = {
        'application/json': 300, // 5分
        'text/xml': 1800, // 30分
        'application/pdf': 2592000, // 30日
        'video/*': 604800, // 7日
      };

      const customStale = {
        'application/json': 3600, // 1時間
        'text/xml': 86400, // 1日
        'application/pdf': 7776000, // 90日
        'video/*': 2592000, // 30日
      };

      const config = ProxyConfig(
        origin: 'https://example.com',
        cacheTtl: customTtl,
        cacheStale: customStale,
      );

      expect(config.cacheTtl['application/json'], equals(300));
      expect(config.cacheTtl['video/*'], equals(604800));
      expect(config.cacheStale['application/pdf'], equals(7776000));
    });

    /// 特殊文字を含むオリジンURLのテスト
    test('should handle origins with special characters', () {
      const origins = [
        'https://api-v2.example-site.com:8443',
        'http://localhost:3000',
        'https://127.0.0.1:8080',
        'https://[::1]:8080', // IPv6
        'https://test.中文.com', // 国際化ドメイン名
      ];

      for (final origin in origins) {
        final config = ProxyConfig(origin: origin);
        expect(config.origin, equals(origin));
      }
    });
  });
}
