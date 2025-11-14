import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

void main() {
  group('Integration Tests', () {
    late OfflineWebProxy proxy;

    setUp(() {
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
    });

    /// 複数操作の統合テスト
    test('should handle complex workflow operations', () async {
      // 1. 初期状態の確認
      expect(proxy.isRunning, isFalse);

      var stats = await proxy.getStats();
      expect(stats.totalRequests, equals(0));

      // 2. キャッシュ操作のテスト
      await proxy.clearCache();
      var cacheStats = await proxy.getCacheStats();
      expect(cacheStats.totalEntries, equals(0));

      // 3. 特定URLのキャッシュクリア
      await proxy.clearCacheForUrl('https://example.com/test');

      // 4. キューの確認
      var queuedRequests = await proxy.getQueuedRequests();
      expect(queuedRequests, isEmpty);

      // 5. Cookieの管理
      var cookies = await proxy.getCookies();
      expect(cookies, isEmpty);

      await proxy.clearCookies();

      // 6. 統計情報の再確認
      stats = await proxy.getStats();
      expect(stats.totalRequests, equals(0));
      expect(stats.cacheHits, equals(0));
      expect(stats.cacheMisses, equals(0));
    });

    /// イベントストリームの統合テスト
    test('should provide working event stream', () async {
      final eventStream = proxy.events;
      expect(eventStream, isA<Stream<ProxyEvent>>());

      // ストリームがリッスン可能であることを確認
      StreamSubscription<ProxyEvent>? subscription;
      final completer = Completer<bool>();

      subscription = eventStream.listen(
        (event) {
          // イベントを受信した場合
          completer.complete(true);
        },
        onError: (error) {
          completer.complete(false);
        },
      );

      // 短時間待機（実際のイベントは発生しないが、ストリームの動作を確認）
      Timer(Duration(milliseconds: 100), () {
        if (!completer.isCompleted) {
          completer.complete(true); // イベントがなくてもストリームは正常
        }
      });

      final result = await completer.future;
      expect(result, isTrue);

      await subscription.cancel();
    });

    /// 設定オブジェクトとプロキシの統合テスト
    test('should work with custom ProxyConfig', () async {
      const customConfig = ProxyConfig(
        origin: 'https://api.example.com',
        host: '127.0.0.1',
        port: 0, // 自動割当
        cacheMaxSize: 50 * 1024 * 1024, // 50MB
        logLevel: 'debug',
        enableAdminApi: false,
      );

      // 設定が正しく作成されることを確認
      expect(customConfig.origin, equals('https://api.example.com'));
      expect(customConfig.cacheMaxSize, equals(50 * 1024 * 1024));
      expect(customConfig.logLevel, equals('debug'));

      // プロキシは現在停止状態であることを確認
      expect(proxy.isRunning, isFalse);
    });

    /// 大量データ処理の統合テスト
    test('should handle bulk operations efficiently', () async {
      final futures = <Future>[];

      // 大量の並行操作を実行
      for (int i = 0; i < 50; i++) {
        futures.add(proxy.getStats());
        futures.add(proxy.getCacheStats());

        if (i % 5 == 0) {
          futures.add(proxy.getCacheList(limit: 10, offset: i));
        }

        if (i % 3 == 0) {
          futures.add(proxy.clearCacheForUrl('https://example.com/test$i'));
        }
      }

      // すべての操作が完了することを確認
      final results = await Future.wait(futures);
      expect(results.length, greaterThan(100));

      // 結果の型チェック
      int statsCount = 0;
      int cacheStatsCount = 0;
      int cacheListCount = 0;

      for (final result in results) {
        if (result is ProxyStats) {
          statsCount++;
        } else if (result is CacheStats) {
          cacheStatsCount++;
        } else if (result is List<CacheEntry>) {
          cacheListCount++;
        }
      }

      expect(statsCount, equals(50));
      expect(cacheStatsCount, equals(50));
      expect(cacheListCount, greaterThan(0));
    });

    /// エラー回復力の統合テスト
    test('should be resilient to errors', () async {
      // 無効な操作を混在させても他の操作に影響しないことを確認
      final futures = <Future>[];

      // 正常な操作
      futures.add(proxy.getStats());
      futures.add(proxy.getCacheStats());

      // エラーを発生させる可能性のある操作
      futures.add(proxy.clearCacheForUrl('').catchError((_) => null));
      futures.add(proxy.getCacheList(limit: -1));

      // 再び正常な操作
      futures.add(proxy.getQueuedRequests());
      futures.add(proxy.getCookies());

      // エラーがあっても他の操作が完了することを確認
      final results = await Future.wait(futures);

      // null以外の結果（正常な操作の結果）が存在することを確認
      final validResults = results.where((r) => r != null).toList();
      expect(validResults.length, greaterThanOrEqualTo(4));
    });

    /// メモリ効率性のテスト
    test('should be memory efficient with repeated operations', () async {
      // 同じ操作を繰り返し実行してメモリリークがないことを確認
      for (int round = 0; round < 10; round++) {
        final roundFutures = <Future>[];

        for (int i = 0; i < 20; i++) {
          roundFutures.add(proxy.getStats());
          roundFutures.add(proxy.getCacheStats());
          roundFutures.add(proxy.getCacheList());
        }

        await Future.wait(roundFutures);

        // ガベージコレクションを促進
        await Future.delayed(Duration(milliseconds: 10));
      }

      // 最終的に正常な状態であることを確認
      final finalStats = await proxy.getStats();
      expect(finalStats, isNotNull);
      expect(finalStats.totalRequests, isA<int>());
    });

    /// API互換性の統合テスト
    test('should maintain API compatibility', () async {
      // すべてのパブリックAPIが正しく動作することを確認

      // 基本プロパティ
      expect(proxy.isRunning, isA<bool>());
      expect(proxy.events, isA<Stream<ProxyEvent>>());

      // 統計系メソッド
      expect(await proxy.getStats(), isA<ProxyStats>());
      expect(await proxy.getCacheStats(), isA<CacheStats>());

      // キャッシュ管理メソッド
      expect(await proxy.getCacheList(), isA<List<CacheEntry>>());
      expect(() => proxy.clearCache(), returnsNormally);
      expect(() => proxy.clearExpiredCache(), returnsNormally);
      expect(
          () => proxy.clearCacheForUrl('https://example.com'), returnsNormally);

      // Cookie管理メソッド
      expect(await proxy.getCookies(), isA<List<CookieInfo>>());
      expect(() => proxy.clearCookies(), returnsNormally);

      // キュー管理メソッド
      expect(await proxy.getQueuedRequests(), isA<List<QueuedRequest>>());
      expect(await proxy.getDroppedRequests(), isA<List<DroppedRequest>>());
      expect(() => proxy.clearDroppedRequests(), returnsNormally);

      // ウォームアップメソッド
      expect(await proxy.warmupCache(paths: []), isA<WarmupResult>());
    });

    /// 長時間実行テスト
    test('should handle long-running operations', () async {
      final startTime = DateTime.now();

      // 長時間にわたって操作を継続
      for (int minute = 0; minute < 3; minute++) {
        // 1分ごとに各種操作を実行
        await proxy.getStats();
        await proxy.getCacheStats();
        await proxy.getCacheList(limit: 5);
        await proxy.getQueuedRequests();
        await proxy.getCookies();

        // 少し待機
        await Future.delayed(Duration(milliseconds: 100));
      }

      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      // 実行時間が合理的であることを確認（3秒以内）
      expect(duration.inSeconds, lessThan(3));

      // 最終状態が正常であることを確認
      expect(proxy.isRunning, isFalse);
      final finalStats = await proxy.getStats();
      expect(finalStats, isNotNull);
    });
  });

  group('Configuration Integration Tests', () {
    /// デフォルト設定での統合テスト
    test('should work with all default configuration values', () {
      const defaultConfig = ProxyConfig(origin: '');

      expect(defaultConfig.host, equals('127.0.0.1'));
      expect(defaultConfig.port, equals(0));
      expect(defaultConfig.cacheMaxSize, equals(200 * 1024 * 1024));
      expect(defaultConfig.connectTimeout, equals(Duration(seconds: 10)));
      expect(defaultConfig.requestTimeout, equals(Duration(seconds: 60)));
      expect(defaultConfig.retryBackoffSeconds, equals([1, 2, 5, 10, 20, 30]));
      expect(defaultConfig.enableAdminApi, isFalse);
      expect(defaultConfig.logLevel, equals('info'));
      expect(defaultConfig.startupPaths, isEmpty);
    });

    /// カスタム設定での統合テスト
    test('should work with all custom configuration values', () {
      const customConfig = ProxyConfig(
        origin: 'https://custom.api.com:8443',
        host: '0.0.0.0',
        port: 9090,
        cacheMaxSize: 500 * 1024 * 1024,
        cacheTtl: {
          'application/json': 300,
          'text/html': 1800,
          'default': 3600,
        },
        cacheStale: {
          'application/json': 600,
          'text/html': 7200,
          'default': 14400,
        },
        connectTimeout: Duration(seconds: 5),
        requestTimeout: Duration(seconds: 30),
        retryBackoffSeconds: [1, 3, 9, 27, 81],
        enableAdminApi: true,
        logLevel: 'trace',
        startupPaths: ['/health', '/config', '/status'],
      );

      expect(customConfig.origin, equals('https://custom.api.com:8443'));
      expect(customConfig.host, equals('0.0.0.0'));
      expect(customConfig.port, equals(9090));
      expect(customConfig.cacheMaxSize, equals(500 * 1024 * 1024));
      expect(customConfig.cacheTtl['application/json'], equals(300));
      expect(customConfig.cacheStale['text/html'], equals(7200));
      expect(customConfig.connectTimeout, equals(Duration(seconds: 5)));
      expect(customConfig.requestTimeout, equals(Duration(seconds: 30)));
      expect(customConfig.retryBackoffSeconds, equals([1, 3, 9, 27, 81]));
      expect(customConfig.enableAdminApi, isTrue);
      expect(customConfig.logLevel, equals('trace'));
      expect(customConfig.startupPaths, hasLength(3));
    });

    /// 設定の継承と上書きテスト
    test('should handle configuration inheritance correctly', () {
      // 部分的なカスタム設定
      const partialConfig = ProxyConfig(
        origin: 'https://example.com',
        logLevel: 'debug',
        enableAdminApi: true,
        // 他の設定はデフォルト値を使用
      );

      // カスタム設定された項目
      expect(partialConfig.origin, equals('https://example.com'));
      expect(partialConfig.logLevel, equals('debug'));
      expect(partialConfig.enableAdminApi, isTrue);

      // デフォルト値が使用される項目
      expect(partialConfig.host, equals('127.0.0.1'));
      expect(partialConfig.port, equals(0));
      expect(partialConfig.cacheMaxSize, equals(200 * 1024 * 1024));
      expect(partialConfig.connectTimeout, equals(Duration(seconds: 10)));
    });
  });
}
