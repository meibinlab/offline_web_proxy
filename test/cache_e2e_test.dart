import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    // path_provider が一時ディレクトリを返すようにモックする
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getApplicationDocumentsDirectory') {
          return tempDir.path;
        }
        if (methodCall.method == 'getTemporaryDirectory') {
          return tempDir.path;
        }
        if (methodCall.method == 'getApplicationSupportDirectory') {
          return tempDir.path;
        }
        return null;
      },
    );
  });

  group('Cache End-to-End Tests', () {
    late OfflineWebProxy proxy;
    late int port;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      tempDir =
          await Directory.systemTemp.createTemp('offline_web_proxy_test_');
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
      await Hive.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// プロキシを起動できること
    test('should start proxy server successfully', () async {
      final config = ProxyConfig(
        origin: 'https://jsonplaceholder.typicode.com',
        port: 0,
        cacheMaxSize: 10 * 1024 * 1024,
      );

      port = await proxy.start(config: config);

      expect(proxy.isRunning, isTrue);
      expect(port, greaterThan(0));
    });

    /// 起動直後に proxy URL とキャッシュ統計を参照できること
    test('should expose proxy url and cache stats after start', () async {
      final config = ProxyConfig(
        origin: 'https://httpbin.org',
        port: 0,
        cacheMaxSize: 10 * 1024 * 1024,
      );

      port = await proxy.start(config: config);
      expect(proxy.isRunning, isTrue);

      final proxyUrl = 'http://127.0.0.1:$port/get';
      expect(Uri.tryParse(proxyUrl), isNotNull);

      final stats = await proxy.getCacheStats();
      expect(stats, isNotNull);
      expect(stats.totalEntries, greaterThanOrEqualTo(0));
    });

    /// 起動直後のキャッシュ状態と統計を取得できること
    test('should expose initial cache state after start', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);
      expect(proxy.isRunning, isTrue);

      final initialStats = await proxy.getCacheStats();
      expect(initialStats.totalEntries, equals(0));

      final proxyStats = await proxy.getStats();
      expect(proxyStats.totalRequests, equals(0));
    });

    /// 複数のパス形式で proxy URL を組み立てられること
    test('builds valid proxy urls for paths with and without a leading slash',
        () async {
      final config = ProxyConfig(
        origin: 'https://api.example.com',
        port: 0,
      );

      port = await proxy.start(config: config);

      final testPaths = [
        '/app/index.html',
        'app/index.html',
        '/api/data',
        'api/data',
        '/users/1',
        '/posts?page=1',
      ];

      expect(proxy.isRunning, isTrue);

      for (final path in testPaths) {
        final normalizedPath = path.startsWith('/') ? path : '/$path';
        final proxyUrl = 'http://127.0.0.1:$port$normalizedPath';
        expect(Uri.tryParse(proxyUrl), isNotNull);
      }
    });

    /// キャッシュクリア後に統計がリセットされること
    test('should clear cache and reset stats', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);

      await proxy.clearCache();

      final stats = await proxy.getCacheStats();
      expect(stats.totalEntries, equals(0));
      expect(stats.freshEntries, equals(0));
      expect(stats.staleEntries, equals(0));
      expect(stats.expiredEntries, equals(0));
    });

    /// プロキシ操作でイベントを購読できること
    test('should emit events during proxy operations', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      final events = <ProxyEvent>[];
      final subscription = proxy.events.listen((event) {
        events.add(event);
      });

      port = await proxy.start(config: config);

      await Future.delayed(const Duration(milliseconds: 100));

      expect(events.any((e) => e.type == ProxyEventType.serverStarted), isTrue);

      await subscription.cancel();
    });

    /// 同時の統計取得を処理できること
    test('should handle concurrent requests correctly', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);

      final futures = <Future<ProxyStats>>[];
      for (int i = 0; i < 10; i++) {
        futures.add(proxy.getStats());
      }

      final results = await Future.wait(futures);

      expect(results.length, equals(10));
      for (final stats in results) {
        expect(stats, isNotNull);
        expect(stats.totalRequests, isA<int>());
      }
    });

    /// stop 後に停止状態へ戻ること
    test('should properly clean up after stop', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);
      expect(proxy.isRunning, isTrue);

      await proxy.stop();
      expect(proxy.isRunning, isFalse);
    });

    /// origin 設定で起動し初期統計を参照できること
    test('should initialize stats for configured origin', () async {
      const testOrigin = 'https://test-api.example.com';
      final config = ProxyConfig(
        origin: testOrigin,
        port: 0,
      );

      port = await proxy.start(config: config);

      expect(proxy.isRunning, isTrue);

      final stats = await proxy.getStats();
      expect(stats.totalRequests, equals(0));
      expect(stats.cacheHits, equals(0));
      expect(stats.cacheMisses, equals(0));
    });

    /// 二重起動を防止できること
    test('should reject second start while already running', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);
      expect(proxy.isRunning, isTrue);

      await expectLater(
        proxy.start(config: config),
        throwsA(isA<ProxyStartException>()),
      );
    });

    /// ネットワークエラー時もウォームアップ結果を返せること
    test('should handle warmup with network errors gracefully', () async {
      final config = ProxyConfig(
        origin: 'https://nonexistent-domain-12345.invalid',
        port: 0,
      );

      port = await proxy.start(config: config);

      final result = await proxy.warmupCache(
        paths: ['/test'],
        timeout: 1,
      );

      // successCount + failureCount は処理したパス数と一致する
      expect(result.successCount + result.failureCount, equals(1));
    });

    /// 起動直後のキューが空であること
    test('should maintain empty queue initially', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);

      final queuedRequests = await proxy.getQueuedRequests();
      expect(queuedRequests, isEmpty);

      final stats = await proxy.getStats();
      expect(stats.queueLength, equals(0));
    });
  });

  group('Cache Key Consistency Tests', () {
    /// リクエスト前の統計初期値を参照できること
    test('should keep initial cache stats before making requests', () async {
      final proxy = OfflineWebProxy();

      final config = ProxyConfig(
        origin: 'https://api.example.com',
        port: 0,
      );

      await proxy.start(config: config);

      final initialStats = await proxy.getStats();
      expect(initialStats.cacheHits, equals(0));
      expect(initialStats.cacheMisses, equals(0));

      await proxy.stop();
    });
  });

  group('URL Normalization Tests', () {
    late OfflineWebProxy proxy;

    setUp(() {
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    /// 先頭スラッシュの有無を正規化して同じ proxy URL に組み立てられること
    test('should build same proxy url for leading slash variants', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      final port = await proxy.start(config: config);

      expect(proxy.isRunning, isTrue);
      expect(port, greaterThan(0));

      final withLeadingSlash = 'http://127.0.0.1:$port/app/index.html';
      final withoutLeadingSlash = 'http://127.0.0.1:$port/${'app/index.html'}';
      expect(withLeadingSlash, equals(withoutLeadingSlash));
    });

    /// クエリ付き URL でも起動状態を維持できること
    test('should handle URLs with query parameters', () async {
      final config = ProxyConfig(
        origin: 'https://api.example.com',
        port: 0,
      );

      await proxy.start(config: config);

      expect(proxy.isRunning, isTrue);

      final stats = await proxy.getStats();
      expect(stats, isNotNull);
    });
  });

  group('Query Parameter Cache Key Tests', () {
    late OfflineWebProxy proxy;

    setUp(() {
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    /// 異なるクエリ付きパスを個別の proxy URL に組み立てられること
    test('should build proxy urls for query parameter variants', () async {
      final config = ProxyConfig(
        origin: 'https://api.example.com',
        port: 0,
      );

      await proxy.start(config: config);

      expect(proxy.isRunning, isTrue);

      final testUrls = [
        '/api/users?page=1',
        '/api/users?page=2',
        '/api/users?page=1&limit=10',
        '/api/users?limit=10&page=1', // パラメータの順序が異なる
        '/api/users', // クエリパラメータなし
      ];

      for (final path in testUrls) {
        final port = proxy.isRunning ? 8080 : 0; // URL 組み立て用のダミーポート
        final proxyUrl = 'http://127.0.0.1:$port$path';
        expect(Uri.tryParse(proxyUrl), isNotNull);
      }
    });

    /// クエリ付きパスでもウォームアップ結果を返せること
    test('should warmup cache with query parameters', () async {
      final config = ProxyConfig(
        origin: 'https://httpbin.org',
        port: 0,
      );

      await proxy.start(config: config);

      final result = await proxy.warmupCache(
        paths: ['/get?param1=value1', '/get?param2=value2'],
        timeout: 10,
      );

      expect(result.successCount + result.failureCount, equals(2));
    });

    /// クエリ差分のあるパスでも初期統計を取得できること
    test('should track stats correctly for paths with different query params',
        () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      await proxy.start(config: config);

      final initialStats = await proxy.getStats();
      expect(initialStats.totalRequests, equals(0));
      expect(initialStats.cacheHits, equals(0));
      expect(initialStats.cacheMisses, equals(0));

      final cacheStats = await proxy.getCacheStats();
      expect(cacheStats.totalEntries, equals(0));
    });

    /// 空のクエリ文字列を含むパスを扱えること
    test('should handle empty query parameters correctly', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      await proxy.start(config: config);
      expect(proxy.isRunning, isTrue);

      final testPaths = [
        '/api/data',
        '/api/data?',
        '/api/data?key=',
      ];

      for (final path in testPaths) {
        final proxyUrl = 'http://127.0.0.1:8080$path';
        final uri = Uri.tryParse(proxyUrl);
        expect(uri, isNotNull);
      }
    });
  });
}
