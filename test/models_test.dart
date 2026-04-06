import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/models/cookie_header_builder.dart';
import 'package:offline_web_proxy/src/models/cookie_record.dart';
import 'package:offline_web_proxy/src/models/response_header_snapshot.dart';

void main() {
  group('Data Models Edge Cases', () {
    /// CacheEntry が境界値を保持できること
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

    /// CookieInfo が null のオプショナル項目を保持できること
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

    /// CookieRecord が host-only Cookie の既定値を導出できること
    test('CookieRecord should derive host-only cookie defaults', () {
      final record = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'JSESSIONID=abc123; Path=/app; HttpOnly',
        requestUri: Uri.parse('https://example.com/app/login'),
        receivedAt: DateTime.utc(2026, 3, 19, 10),
      );

      expect(record.name, equals('JSESSIONID'));
      expect(record.value, equals('abc123'));
      expect(record.domain, equals('example.com'));
      expect(record.path, equals('/app'));
      expect(record.httpOnly, isTrue);
      expect(record.hostOnly, isTrue);
      expect(record.expires, isNull);
    });

    /// CookieRecord が Max-Age を Expires より優先できること
    test('CookieRecord should prioritize max-age over expires', () {
      final receivedAt = DateTime.utc(2026, 3, 19, 10);
      final record = CookieRecord.fromSetCookieHeader(
        setCookieHeader:
            'SESSION=xyz; Expires=Wed, 20 Mar 2026 10:00:00 GMT; Max-Age=60; Secure; SameSite=Lax',
        requestUri: Uri.parse('https://example.com/login'),
        receivedAt: receivedAt,
      );

      expect(record.secure, isTrue);
      expect(record.sameSite, equals('Lax'));
      expect(record.expires, equals(receivedAt.add(Duration(seconds: 60))));
    });

    /// CookieRecord が host-only と domain Cookie を正しく判定できること
    test('CookieRecord should match host-only and domain cookies correctly',
        () {
      final hostOnlyCookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'HOST=1; Path=/',
        requestUri: Uri.parse('https://example.com/login'),
        receivedAt: DateTime.utc(2026, 3, 19, 10),
      );
      final domainCookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'DOMAIN=1; Domain=example.com; Path=/',
        requestUri: Uri.parse('https://example.com/login'),
        receivedAt: DateTime.utc(2026, 3, 19, 10),
      );

      expect(hostOnlyCookie.matchesDomain('example.com'), isTrue);
      expect(hostOnlyCookie.matchesDomain('api.example.com'), isFalse);
      expect(domainCookie.matchesDomain('example.com'), isTrue);
      expect(domainCookie.matchesDomain('api.example.com'), isTrue);
      expect(domainCookie.matchesDomain('other.example.org'), isFalse);
    });

    /// CookieRecord がパス一致を正しく判定できること
    test('CookieRecord should evaluate path matching correctly', () {
      final cookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'SESSION=1; Path=/app',
        requestUri: Uri.parse('https://example.com/app/login'),
        receivedAt: DateTime.utc(2026, 3, 19, 10),
      );

      expect(cookie.matchesPath('/app'), isTrue);
      expect(cookie.matchesPath('/app/settings'), isTrue);
      expect(cookie.matchesPath('/application'), isFalse);
      expect(cookie.matchesPath('/other'), isFalse);
    });

    /// CookieRecord が期限切れとセキュア属性の不一致を除外できること
    test('CookieRecord should reject expired and insecure URI mismatches', () {
      final now = DateTime.utc(2026, 3, 19, 10);
      final secureCookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'SECURE=1; Path=/; Secure; Max-Age=60',
        requestUri: Uri.parse('https://example.com/login'),
        receivedAt: now,
      );
      final expiredCookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'EXPIRED=1; Path=/; Max-Age=0',
        requestUri: Uri.parse('https://example.com/login'),
        receivedAt: now,
      );

      expect(
        secureCookie.matchesUri(Uri.parse('https://example.com/api'), at: now),
        isTrue,
      );
      expect(
        secureCookie.matchesUri(Uri.parse('http://example.com/api'), at: now),
        isFalse,
      );
      expect(
        expiredCookie.matchesUri(Uri.parse('https://example.com/api'), at: now),
        isFalse,
      );
    });

    /// CookieRestoreEntry が Set-Cookie 文字列を復元できること
    test('CookieRestoreEntry should parse set-cookie strings', () {
      final receivedAt = DateTime.utc(2026, 3, 19, 10);
      final entry = CookieRestoreEntry.fromSetCookieHeader(
        setCookieHeader:
            'SESSION=abc; Path=/app; Secure; HttpOnly; SameSite=Lax',
        requestUrl: 'https://example.com/app/login',
        receivedAt: receivedAt,
      );

      final cookieRecord = entry.toCookieRecord();

      expect(cookieRecord.name, equals('SESSION'));
      expect(cookieRecord.value, equals('abc'));
      expect(cookieRecord.domain, equals('example.com'));
      expect(cookieRecord.path, equals('/app'));
      expect(cookieRecord.secure, isTrue);
      expect(cookieRecord.httpOnly, isTrue);
      expect(cookieRecord.sameSite, equals('Lax'));
      expect(cookieRecord.hostOnly, isTrue);
      expect(cookieRecord.createdAt, equals(receivedAt));
    });

    /// CookieRestoreEntry が構造化属性を保持したまま変換できること
    test('CookieRestoreEntry should preserve structured attributes', () {
      final createdAt = DateTime.utc(2026, 3, 19, 11);
      final entry = CookieRestoreEntry(
        name: 'NATIVE',
        value: 'token',
        domain: 'Example.COM',
        path: 'app',
        secure: true,
        httpOnly: true,
        sameSite: 'Strict',
        hostOnly: true,
        createdAt: createdAt,
      );

      final cookieRecord = entry.toCookieRecord();

      expect(cookieRecord.domain, equals('example.com'));
      expect(cookieRecord.path, equals('/app'));
      expect(cookieRecord.secure, isTrue);
      expect(cookieRecord.httpOnly, isTrue);
      expect(cookieRecord.sameSite, equals('Strict'));
      expect(cookieRecord.hostOnly, isTrue);
      expect(cookieRecord.createdAt, equals(createdAt));
    });

    /// Cookie ヘッダーが一致条件と並び順を反映できること
    test('buildCookieHeaderForUri should filter and sort matching cookies', () {
      final now = DateTime.utc(2026, 3, 19, 10);
      final cookies = <CookieRecord>[
        CookieRecord.fromSetCookieHeader(
          setCookieHeader: 'ROOT=root; Path=/',
          requestUri: Uri.parse('https://example.com/'),
          receivedAt: now.add(Duration(minutes: 1)),
        ),
        CookieRecord.fromSetCookieHeader(
          setCookieHeader: 'APP=app; Path=/app',
          requestUri: Uri.parse('https://example.com/app/login'),
          receivedAt: now,
        ),
        CookieRecord.fromSetCookieHeader(
          setCookieHeader: 'SECURE=secure; Path=/app; Secure',
          requestUri: Uri.parse('https://example.com/app/login'),
          receivedAt: now,
        ),
        CookieRecord.fromSetCookieHeader(
          setCookieHeader: 'OTHER=other; Domain=other.com; Path=/',
          requestUri: Uri.parse('https://other.com/'),
          receivedAt: now,
        ),
      ];

      final httpsHeader = buildCookieHeaderForUri(
        cookies,
        Uri.parse('https://example.com/app/dashboard'),
        at: now,
      );
      final httpHeader = buildCookieHeaderForUri(
        cookies,
        Uri.parse('http://example.com/app/dashboard'),
        at: now,
      );

      expect(httpsHeader, equals('APP=app; SECURE=secure; ROOT=root'));
      expect(httpHeader, equals('APP=app; ROOT=root'));
    });

    /// ResponseHeaderSnapshot が生の Set-Cookie を保持できること
    test('ResponseHeaderSnapshot should preserve raw set-cookie values', () {
      final snapshot = ResponseHeaderSnapshot.fromRawHeaders({
        'content-type': ['text/plain'],
        'set-cookie': [
          'A=1; Path=/',
          'B=2; Path=/; HttpOnly',
        ],
      });

      expect(snapshot.flattenedHeaders['content-type'], equals('text/plain'));
      expect(snapshot.flattenedHeaders['set-cookie'],
          equals('A=1; Path=/, B=2; Path=/; HttpOnly'));
      expect(snapshot.setCookieHeaders, hasLength(2));
      expect(snapshot.setCookieHeaders.first, equals('A=1; Path=/'));
      expect(snapshot.setCookieHeaders.last, equals('B=2; Path=/; HttpOnly'));
    });

    /// QueuedRequest が空ヘッダーを保持できること
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

    /// DroppedRequest がエラー情報を保持できること
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

    /// WarmupEntry が失敗結果を保持できること
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

    /// ProxyEvent が全イベントタイプを扱えること
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

    /// CacheStatus の全状態を扱えること
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

    /// 統計情報がゼロ値を保持できること
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

    /// 統計情報が大きな値を保持できること
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
    /// ProxyConfig が極端な設定値を保持できること
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

    /// ProxyConfig が空の設定値を保持できること
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

    /// ProxyConfig がカスタム TTL と stale 設定を保持できること
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

    /// ProxyConfig が特殊文字を含む origin を保持できること
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
