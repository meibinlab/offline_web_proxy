import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

void main() {
  group('Exception Handling Tests', () {
    late OfflineWebProxy proxy;

    setUp(() {
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    /// 無効なURL引数のテスト
    test('should throw ArgumentError for empty URL in clearCacheForUrl',
        () async {
      await expectLater(() => proxy.clearCacheForUrl(''), throwsArgumentError);
    });

    /// 無効なURL引数のテスト（スペースのみ）
    test('should throw ArgumentError for whitespace-only URL', () async {
      await expectLater(
          () => proxy.clearCacheForUrl('   '), throwsArgumentError);
    });

    /// 非常に長いURLでのテスト
    test('should handle very long URLs', () async {
      final longUrl = 'https://example.com/' + 'a' * 10000;
      await proxy.clearCacheForUrl(longUrl);
    });

    /// 特殊文字を含むURLのテスト
    test('should handle URLs with special characters', () async {
      const urls = [
        'https://example.com/path?query=value&other=test',
        'https://example.com/path#fragment',
        'https://example.com/path%20with%20spaces',
        'https://example.com/日本語',
        'https://user:pass@example.com/path',
      ];

      for (final url in urls) {
        await proxy.clearCacheForUrl(url);
      }
    });

    /// 複数の同時操作のテスト
    test('should handle multiple concurrent operations', () async {
      final futures = <Future>[];

      // 同時に複数のキャッシュクリア操作を実行
      for (int i = 0; i < 10; i++) {
        futures.add(proxy.clearCache());
        futures.add(proxy.clearExpiredCache());
        futures.add(proxy.getStats());
        futures.add(proxy.getCacheStats());
      }

      expect(() => Future.wait(futures), returnsNormally);
    });

    /// メモリ制約のテスト（大量のデータ）
    test('should handle large cache list requests', () async {
      // 大量のキャッシュエントリを要求（実際には空だが、システムの動作を確認）
      final cacheList = await proxy.getCacheList(limit: 100000);
      expect(cacheList, isA<List<CacheEntry>>());
    });

    /// ネガティブな制限値のテスト
    test('should handle negative limit values', () async {
      expect(() => proxy.getCacheList(limit: -1), returnsNormally);
      expect(() => proxy.getDroppedRequests(limit: -100), returnsNormally);
    });

    /// ゼロ制限値のテスト
    test('should handle zero limit values', () async {
      final cacheList = await proxy.getCacheList(limit: 0);
      expect(cacheList, isEmpty);

      final droppedRequests = await proxy.getDroppedRequests(limit: 0);
      expect(droppedRequests, isEmpty);
    });

    /// 大きなオフセット値のテスト
    test('should handle large offset values', () async {
      final cacheList = await proxy.getCacheList(offset: 1000000);
      expect(cacheList, isA<List<CacheEntry>>());
    });
  });

  group('Exception Classes Detailed Tests', () {
    /// ProxyStartExceptionのtoStringテスト
    test('ProxyStartException toString should include cause', () {
      final cause = Exception('Original error');
      final exception = ProxyStartException('Failed to start server', cause);

      final str = exception.toString();
      expect(str, contains('ProxyStartException'));
      expect(str, contains('Failed to start server'));
      expect(str, contains('caused by'));
      expect(str, contains('Original error'));
    });

    /// ProxyStopExceptionのテスト
    test('ProxyStopException should handle all scenarios', () {
      // 原因なしのケース
      const exception1 = ProxyStopException('Server already stopped', null);
      expect(exception1.toString(), contains('Server already stopped'));
      expect(exception1.toString(), isNot(contains('caused by')));

      // 原因ありのケース
      final cause = SocketException('Connection lost');
      final exception2 = ProxyStopException('Failed to stop gracefully', cause);
      expect(exception2.toString(), contains('Failed to stop gracefully'));
      expect(exception2.toString(), contains('caused by'));
    });

    /// PortBindExceptionのテスト
    test('PortBindException should include port number', () {
      const exception = PortBindException(8080, 'Port already in use');

      expect(exception.port, equals(8080));
      expect(exception.message, equals('Port already in use'));
      expect(exception.toString(), contains('8080'));
      expect(exception.toString(), contains('Port already in use'));
    });

    /// CacheOperationExceptionの異なる操作タイプテスト
    test('CacheOperationException should handle different operations', () {
      const operations = ['clear', 'get', 'put', 'delete', 'purge'];

      for (final operation in operations) {
        final exception =
            CacheOperationException(operation, 'Operation failed', null);

        expect(exception.operation, equals(operation));
        expect(exception.toString(),
            contains('CacheOperationException[$operation]'));
      }
    });

    /// CookieOperationExceptionのテスト
    test('CookieOperationException should handle cookie-specific errors', () {
      const exception = CookieOperationException(
        'save',
        'Failed to encrypt cookie data',
        null,
      );

      expect(exception.operation, equals('save'));
      expect(exception.message, contains('encrypt'));
      expect(exception.toString(), contains('CookieOperationException[save]'));
    });

    /// QueueOperationExceptionのテスト
    test('QueueOperationException should handle queue operations', () {
      final ioException = Exception('Disk full');
      final exception = QueueOperationException(
        'persist',
        'Failed to save queue to disk',
        ioException,
      );

      expect(exception.operation, equals('persist'));
      expect(exception.cause, equals(ioException));
      expect(exception.toString(), contains('persist'));
      expect(exception.toString(), contains('caused by'));
    });

    /// StatsOperationExceptionのテスト
    test('StatsOperationException should handle stats errors', () {
      const exception = StatsOperationException(
        'Database connection failed',
        null,
      );

      expect(exception.message, contains('Database connection'));
      expect(exception.toString(), contains('StatsOperationException'));
    });

    /// NetworkExceptionのテスト
    test('NetworkException should handle network errors', () {
      final timeoutException = TimeoutException('Request timeout');
      final exception = NetworkException(
        'Failed to connect to upstream server',
        timeoutException,
      );

      expect(exception.message, contains('upstream server'));
      expect(exception.cause, equals(timeoutException));
      expect(exception.toString(), contains('NetworkException'));
      expect(exception.toString(), contains('caused by'));
    });

    /// WarmupExceptionの詳細テスト
    test('WarmupException should include partial results', () {
      final partialResults = [
        const WarmupEntry(
          path: '/success',
          success: true,
          statusCode: 200,
          duration: Duration(milliseconds: 100),
        ),
        const WarmupEntry(
          path: '/failure',
          success: false,
          errorMessage: 'Timeout',
          duration: Duration(milliseconds: 5000),
        ),
      ];

      final exception = WarmupException(
        'Warmup completed with errors',
        partialResults,
        null,
      );

      expect(exception.message, equals('Warmup completed with errors'));
      expect(exception.partialResults, hasLength(2));
      expect(exception.partialResults[0].success, isTrue);
      expect(exception.partialResults[1].success, isFalse);
      expect(exception.toString(), contains('2 partial results'));
    });

    /// ネストした例外のテスト
    test('should handle nested exceptions', () {
      final rootCause = FormatException('Invalid JSON');
      final intermediateCause = Exception('Parse error: $rootCause');
      final topException = CacheOperationException(
        'deserialize',
        'Failed to deserialize cache entry',
        intermediateCause,
      );

      expect(topException.cause.toString(), contains('Parse error'));
      expect(topException.toString(), contains('caused by'));
    });
  });

  group('Concurrent Access Tests', () {
    late OfflineWebProxy proxy;

    setUp(() {
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    /// 同時キャッシュ操作のテスト
    test('should handle concurrent cache operations', () async {
      final futures = <Future>[];

      // 同時に異なるキャッシュ操作を実行
      futures.add(proxy.clearCache());
      futures.add(proxy.clearExpiredCache());
      futures.add(proxy.getCacheStats());
      futures.add(proxy.getCacheList());
      futures.add(proxy.clearCacheForUrl('https://example.com/1'));
      futures.add(proxy.clearCacheForUrl('https://example.com/2'));

      // すべての操作が完了することを確認
      await expectLater(Future.wait(futures), completes);
    });

    /// 同時Cookie操作のテスト
    test('should handle concurrent cookie operations', () async {
      final futures = <Future>[];

      futures.add(proxy.getCookies());
      futures.add(proxy.getCookies(domain: 'example.com'));
      futures.add(proxy.clearCookies());
      futures.add(proxy.clearCookies(domain: 'test.com'));

      await expectLater(Future.wait(futures), completes);
    });

    /// 同時統計取得のテスト
    test('should handle concurrent stats requests', () async {
      final futures = <Future>[];

      // 複数の統計リクエストを同時実行
      for (int i = 0; i < 20; i++) {
        futures.add(proxy.getStats());
        futures.add(proxy.getCacheStats());
      }

      final results = await Future.wait(futures);
      expect(results, hasLength(40));

      // すべての結果が正しい型であることを確認
      for (int i = 0; i < results.length; i += 2) {
        expect(results[i], isA<ProxyStats>());
        expect(results[i + 1], isA<CacheStats>());
      }
    });

    /// ストレステスト（大量の同時操作）
    test('should handle stress test with many concurrent operations', () async {
      final futures = <Future>[];

      // 100個の同時操作を実行
      for (int i = 0; i < 100; i++) {
        switch (i % 5) {
          case 0:
            futures.add(proxy.getStats());
            break;
          case 1:
            futures.add(proxy.getCacheStats());
            break;
          case 2:
            futures.add(proxy.getCacheList(limit: 10));
            break;
          case 3:
            futures.add(proxy.getQueuedRequests());
            break;
          case 4:
            futures.add(proxy.getCookies());
            break;
        }
      }

      // すべての操作が合理的な時間内に完了することを確認
      await expectLater(
        Future.wait(futures).timeout(Duration(seconds: 10)),
        completes,
      );
    });
  });

  group('Edge Case URL Tests', () {
    late OfflineWebProxy proxy;

    setUp(() {
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    /// 不正な形式のURLテスト
    test('should handle malformed URLs gracefully', () async {
      const malformedUrls = [
        'not-a-url',
        'http://',
        'https://',
        '://example.com',
        'ftp://example.com', // サポートされていないスキーム
        'http://[invalid-ipv6',
        'http://example.com:99999', // 無効なポート
      ];

      for (final url in malformedUrls) {
        // 例外が発生するかもしれないが、クラッシュしないことを確認
        try {
          await proxy.clearCacheForUrl(url);
        } catch (e) {
          // 例外は許可されるが、適切な型であることを確認
          expect(
              e,
              anyOf(
                isA<ArgumentError>(),
                isA<FormatException>(),
                isA<CacheOperationException>(),
              ));
        }
      }
    });

    /// 国際化ドメイン名のテスト
    test('should handle internationalized domain names', () async {
      const internationalUrls = [
        'https://日本語.example.com/path',
        'https://münchen.de/path',
        'https://москва.рф/path',
        'https://中文.test/测试',
      ];

      for (final url in internationalUrls) {
        await proxy.clearCacheForUrl(url);
      }
    });

    /// 非常に長いURLのテスト
    test('should handle extremely long URLs', () async {
      final baseUrl = 'https://example.com/';
      final veryLongPath = 'path/' * 1000; // 非常に長いパス
      final longQuery = 'param=' + 'value' * 1000; // 非常に長いクエリ

      final extremelyLongUrl = baseUrl + veryLongPath + '?' + longQuery;

      // 長いURLでもクラッシュしないことを確認
      await proxy.clearCacheForUrl(extremelyLongUrl);
    });
  });
}

/// TimeoutExceptionクラスの定義（テスト用）
class TimeoutException implements Exception {
  final String message;

  const TimeoutException(this.message);

  @override
  String toString() => 'TimeoutException: $message';
}
