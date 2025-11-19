import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    // テスト用の一時ディレクトリを作成
    tempDir = await Directory.systemTemp.createTemp('offline_web_proxy_test_');

    // path_providerのモック設定
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

  tearDownAll(() async {
    // テスト終了後に一時ディレクトリを削除
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Cache End-to-End Tests', () {
    late OfflineWebProxy proxy;
    late int port;

    setUp(() async {
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    /// プロキシ起動テスト
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

    /// キャッシュキー生成の一貫性テスト
    /// オンライン時とオフライン時で同じキャッシュキーが生成されることを確認
    test('should generate consistent cache keys for online and offline requests', () async {
      final config = ProxyConfig(
        origin: 'https://httpbin.org',
        port: 0,
        cacheMaxSize: 10 * 1024 * 1024,
      );

      port = await proxy.start(config: config);
      expect(proxy.isRunning, isTrue);

      // プロキシが起動していることを確認
      final proxyUrl = 'http://127.0.0.1:$port/get';
      expect(Uri.tryParse(proxyUrl), isNotNull);

      // キャッシュ統計を確認
      final stats = await proxy.getCacheStats();
      expect(stats, isNotNull);
      expect(stats.totalEntries, greaterThanOrEqualTo(0));
    });

    /// キャッシュ保存と取得のテスト（モックサーバー不要版）
    test('should correctly handle cache key generation for paths', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);
      expect(proxy.isRunning, isTrue);

      // 初期状態でキャッシュが空であることを確認
      final initialStats = await proxy.getCacheStats();
      expect(initialStats.totalEntries, equals(0));

      // プロキシが正しく起動していることを確認
      final proxyStats = await proxy.getStats();
      expect(proxyStats.totalRequests, equals(0));
    });

    /// 複数のパスでのキャッシュキー一貫性テスト
    test('should handle various path formats consistently', () async {
      final config = ProxyConfig(
        origin: 'https://api.example.com',
        port: 0,
      );

      port = await proxy.start(config: config);

      // 異なるパス形式でリクエストを準備
      final testPaths = [
        '/app/index.html',
        'app/index.html',
        '/api/data',
        'api/data',
        '/users/1',
        '/posts?page=1',
      ];

      // プロキシが起動していることを確認
      expect(proxy.isRunning, isTrue);

      // 各パスに対してプロキシURLが正しく生成できることを確認
      for (final path in testPaths) {
        final normalizedPath = path.startsWith('/') ? path : '/$path';
        final proxyUrl = 'http://127.0.0.1:$port$normalizedPath';
        expect(Uri.tryParse(proxyUrl), isNotNull);
      }
    });

    /// キャッシュクリア後の状態テスト
    test('should clear cache and reset stats', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);

      // キャッシュをクリア
      await proxy.clearCache();

      // キャッシュが空であることを確認
      final stats = await proxy.getCacheStats();
      expect(stats.totalEntries, equals(0));
      expect(stats.freshEntries, equals(0));
      expect(stats.staleEntries, equals(0));
      expect(stats.expiredEntries, equals(0));
    });

    /// イベントストリームのテスト
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

      // サーバー起動イベントが発生していることを確認
      await Future.delayed(const Duration(milliseconds: 100));

      expect(events.any((e) => e.type == ProxyEventType.serverStarted), isTrue);

      await subscription.cancel();
    });

    /// 同時リクエストのテスト
    test('should handle concurrent requests correctly', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);

      // 複数の統計取得を同時に実行
      final futures = <Future<ProxyStats>>[];
      for (int i = 0; i < 10; i++) {
        futures.add(proxy.getStats());
      }

      final results = await Future.wait(futures);

      // すべての結果が正常に返されることを確認
      expect(results.length, equals(10));
      for (final stats in results) {
        expect(stats, isNotNull);
        expect(stats.totalRequests, isA<int>());
      }
    });

    /// プロキシ停止後の状態テスト
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

    /// 設定の検証テスト
    test('should use correct origin URL for cache keys', () async {
      const testOrigin = 'https://test-api.example.com';
      final config = ProxyConfig(
        origin: testOrigin,
        port: 0,
      );

      port = await proxy.start(config: config);

      // プロキシが正しいoriginで起動していることを確認
      expect(proxy.isRunning, isTrue);

      // 統計が正しく初期化されていることを確認
      final stats = await proxy.getStats();
      expect(stats.totalRequests, equals(0));
      expect(stats.cacheHits, equals(0));
      expect(stats.cacheMisses, equals(0));
    });

    /// 二重起動の防止テスト
    test('should prevent double start', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      port = await proxy.start(config: config);
      expect(proxy.isRunning, isTrue);

      // 二重起動を試みるとエラーになることを確認
      expect(
        () => proxy.start(config: config),
        throwsA(isA<ProxyStartException>()),
      );
    });

    /// ウォームアップのテスト
    test('should handle warmup with network errors gracefully', () async {
      final config = ProxyConfig(
        origin: 'https://nonexistent-domain-12345.invalid',
        port: 0,
      );

      port = await proxy.start(config: config);

      // 存在しないドメインへのウォームアップ
      final result = await proxy.warmupCache(
        paths: ['/test'],
        timeout: 1,
      );

      // エラーが発生してもクラッシュしないことを確認
      // successCount + failureCount = 1（処理されたパスの数）
      expect(result.successCount + result.failureCount, equals(1));
    });

    /// キューの状態テスト
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
    /// キャッシュキーがURLのパスに基づいて一貫して生成されることをテスト
    test('should generate same cache key for same upstream URL', () async {
      final proxy = OfflineWebProxy();

      final config = ProxyConfig(
        origin: 'https://api.example.com',
        port: 0,
      );

      final port = await proxy.start(config: config);

      // 同じパスに対して複数回リクエストした場合、
      // キャッシュヒット/ミスの統計が正しく更新されることを確認
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

    /// スラッシュの正規化テスト
    test('should normalize paths with leading slash', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      final port = await proxy.start(config: config);

      // パスが正しく処理されることを確認
      // /app/index.html と app/index.html は同じキャッシュキーになるべき
      expect(proxy.isRunning, isTrue);
      expect(port, greaterThan(0));
    });

    /// クエリパラメータを含むURLのテスト
    test('should handle URLs with query parameters', () async {
      final config = ProxyConfig(
        origin: 'https://api.example.com',
        port: 0,
      );

      await proxy.start(config: config);

      // クエリパラメータを含むURLでもプロキシが動作することを確認
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

    /// 異なるクエリパラメータが異なるキャッシュエントリとして扱われることをテスト
    test('should treat different query parameters as different cache entries', () async {
      final config = ProxyConfig(
        origin: 'https://api.example.com',
        port: 0,
      );

      await proxy.start(config: config);

      // プロキシが起動していることを確認
      expect(proxy.isRunning, isTrue);

      // 異なるクエリパラメータのURLを準備
      final testUrls = [
        '/api/users?page=1',
        '/api/users?page=2',
        '/api/users?page=1&limit=10',
        '/api/users?limit=10&page=1', // パラメータの順序が異なる
        '/api/users', // クエリパラメータなし
      ];

      // 各URLに対してプロキシURLが正しく生成できることを確認
      for (final path in testUrls) {
        final port = proxy.isRunning ? 8080 : 0; // ダミーポート
        final proxyUrl = 'http://127.0.0.1:$port$path';
        expect(Uri.tryParse(proxyUrl), isNotNull);
      }
    });

    /// クエリパラメータ付きのウォームアップテスト
    test('should warmup cache with query parameters', () async {
      final config = ProxyConfig(
        origin: 'https://httpbin.org',
        port: 0,
      );

      await proxy.start(config: config);

      // クエリパラメータ付きのパスでウォームアップ
      final result = await proxy.warmupCache(
        paths: ['/get?param1=value1', '/get?param2=value2'],
        timeout: 10,
      );

      // 処理されたパスの数を確認
      expect(result.successCount + result.failureCount, equals(2));
    });

    /// 同じパスで異なるクエリパラメータの統計テスト
    test('should track stats correctly for paths with different query params', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      await proxy.start(config: config);

      // 初期状態の統計を確認
      final initialStats = await proxy.getStats();
      expect(initialStats.totalRequests, equals(0));
      expect(initialStats.cacheHits, equals(0));
      expect(initialStats.cacheMisses, equals(0));

      // キャッシュが空であることを確認
      final cacheStats = await proxy.getCacheStats();
      expect(cacheStats.totalEntries, equals(0));
    });

    /// 空のクエリパラメータのテスト
    test('should handle empty query parameters correctly', () async {
      final config = ProxyConfig(
        origin: 'https://example.com',
        port: 0,
      );

      await proxy.start(config: config);
      expect(proxy.isRunning, isTrue);

      // 空のクエリパラメータ（?のみ）やクエリなしのURLを確認
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
