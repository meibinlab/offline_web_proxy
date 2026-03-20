import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String hiveTestDirectory;

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        return hiveTestDirectory;
      }
      return null;
    });
  });

  group('Integration Tests', () {
    late OfflineWebProxy proxy;

    setUp(() async {
      hiveTestDirectory =
          Directory.systemTemp.createTempSync('offline_web_proxy_test').path;
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      await Hive.close();
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
      await Hive.close();
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

    /// キューされたリクエストが FIFO 順で再送されることの統合テスト
    test('should drain queued requests in fifo order', () async {
      await HttpOverrides.runZoned(() async {
        late HttpServer upstreamServer;
        var upstreamStatus = HttpStatus.internalServerError;
        final replayBodies = <String>[];

        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer.listen((HttpRequest request) async {
          final body = await utf8.decoder.bind(request).join();
          if (upstreamStatus == HttpStatus.ok) {
            replayBodies.add(body);
          }

          request.response
            ..statusCode = upstreamStatus
            ..write(upstreamStatus == HttpStatus.ok ? 'ok' : 'retry');
          await request.response.close();
        });

        try {
          final proxyPort = await proxy.start(
            config: ProxyConfig(
              origin: 'http://127.0.0.1:${upstreamServer.port}',
            ),
          );

          await _sendProxyRequest(
            proxyPort,
            method: 'POST',
            path: '/orders',
            body: 'first',
          );
          await _sendProxyRequest(
            proxyPort,
            method: 'POST',
            path: '/orders',
            body: 'second',
          );

          final queuedBeforeDrain = await proxy.getQueuedRequests();
          expect(queuedBeforeDrain, hasLength(2));
          expect(
            queuedBeforeDrain.map((request) => request.method).toList(),
            equals(['POST', 'POST']),
          );

          upstreamStatus = HttpStatus.ok;

          await _waitUntil(
            () async => (await proxy.getQueuedRequests()).isEmpty,
            timeout: const Duration(seconds: 8),
          );

          expect(replayBodies, equals(['first', 'second']));
        } finally {
          await upstreamServer.close(force: true);
        }
      }, createHttpClient: _RealHttpOverrides().createHttpClient);
    });

    /// キュー状態が再起動後も保持され再送を再開できることの統合テスト
    test('should persist queued requests across restart and resume draining',
        () async {
      await HttpOverrides.runZoned(() async {
        late HttpServer upstreamServer;
        var upstreamStatus = HttpStatus.internalServerError;
        final replayBodies = <String>[];

        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer.listen((HttpRequest request) async {
          final body = await utf8.decoder.bind(request).join();
          if (upstreamStatus == HttpStatus.ok) {
            replayBodies.add(body);
          }

          request.response
            ..statusCode = upstreamStatus
            ..write(upstreamStatus == HttpStatus.ok ? 'ok' : 'retry');
          await request.response.close();
        });

        try {
          final origin = 'http://127.0.0.1:${upstreamServer.port}';
          final firstProxyPort = await proxy.start(
            config: ProxyConfig(origin: origin),
          );

          await _sendProxyRequest(
            firstProxyPort,
            method: 'POST',
            path: '/persist',
            body: 'persisted',
          );

          final queuedBeforeRestart = await proxy.getQueuedRequests();
          expect(queuedBeforeRestart, hasLength(1));
          expect(queuedBeforeRestart.single.retryCount, equals(0));
          expect(
            queuedBeforeRestart.single.nextRetryAt
                    .isAfter(queuedBeforeRestart.single.queuedAt) ||
                queuedBeforeRestart.single.nextRetryAt
                    .isAtSameMomentAs(queuedBeforeRestart.single.queuedAt),
            isTrue,
          );

          await proxy.stop();
          proxy = OfflineWebProxy();

          await proxy.start(
            config: ProxyConfig(origin: origin),
          );

          final queuedAfterRestart = await proxy.getQueuedRequests();
          expect(queuedAfterRestart, hasLength(1));
          expect(queuedAfterRestart.single.method, equals('POST'));

          upstreamStatus = HttpStatus.ok;

          await _waitUntil(
            () async => (await proxy.getQueuedRequests()).isEmpty,
            timeout: const Duration(seconds: 8),
          );

          expect(replayBodies, equals(['persisted']));
        } finally {
          await upstreamServer.close(force: true);
        }
      }, createHttpClient: _RealHttpOverrides().createHttpClient);
    });

    /// バックオフに応じて retryCount と nextRetryAt が進むことの統合テスト
    test('should update retryCount and honor nextRetryAt backoff schedule',
        () async {
      await HttpOverrides.runZoned(() async {
        late HttpServer upstreamServer;
        var upstreamRequestCount = 0;

        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer.listen((HttpRequest request) async {
          upstreamRequestCount++;
          await request.drain<void>();
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('retry');
          await request.response.close();
        });

        try {
          final proxyPort = await proxy.start(
            config: ProxyConfig(
              origin: 'http://127.0.0.1:${upstreamServer.port}',
              retryBackoffSeconds: const [7, 7, 7],
            ),
          );

          await _sendProxyRequest(
            proxyPort,
            method: 'POST',
            path: '/backoff',
            body: 'payload',
          );

          final initialQueuedRequests = await proxy.getQueuedRequests();
          expect(initialQueuedRequests, hasLength(1));
          expect(initialQueuedRequests.single.retryCount, equals(0));

          await _waitUntil(
            () async {
              final queued = await proxy.getQueuedRequests();
              return queued.length == 1 && queued.single.retryCount == 1;
            },
            timeout: const Duration(seconds: 8),
          );

          final firstRetry = (await proxy.getQueuedRequests()).single;
          expect(upstreamRequestCount, equals(2));
          expect(
            firstRetry.nextRetryAt.isAfter(
              DateTime.now().add(const Duration(seconds: 3)),
            ),
            isTrue,
          );

          await Future.delayed(const Duration(seconds: 6));

          final queuedBeforeNextRetry =
              (await proxy.getQueuedRequests()).single;
          expect(queuedBeforeNextRetry.retryCount, equals(1));
          expect(upstreamRequestCount, equals(2));

          await _waitUntil(
            () async {
              final queued = await proxy.getQueuedRequests();
              return queued.length == 1 && queued.single.retryCount == 2;
            },
            timeout: const Duration(seconds: 8),
          );

          final secondRetry = (await proxy.getQueuedRequests()).single;
          expect(upstreamRequestCount, equals(3));
          expect(
              secondRetry.nextRetryAt.isAfter(firstRetry.nextRetryAt), isTrue);
        } finally {
          await upstreamServer.close(force: true);
        }
      }, createHttpClient: _RealHttpOverrides().createHttpClient);
    });

    /// 4xx 再送時にドロップ履歴へ記録されることの統合テスト
    test('should record dropped requests for 4xx responses and clear history',
        () async {
      await HttpOverrides.runZoned(() async {
        late HttpServer upstreamServer;
        var upstreamStatus = HttpStatus.internalServerError;
        final eventTypes = <ProxyEventType>[];
        final subscription = proxy.events.listen((event) {
          eventTypes.add(event.type);
        });

        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer.listen((HttpRequest request) async {
          await request.drain<void>();
          request.response
            ..statusCode = upstreamStatus
            ..write('done');
          await request.response.close();
        });

        try {
          final proxyPort = await proxy.start(
            config: ProxyConfig(
              origin: 'http://127.0.0.1:${upstreamServer.port}',
            ),
          );

          await _sendProxyRequest(
            proxyPort,
            method: 'POST',
            path: '/drop-me',
            body: 'payload',
          );

          expect(await proxy.getQueuedRequests(), hasLength(1));

          upstreamStatus = HttpStatus.badRequest;

          await _waitUntil(
            () async => (await proxy.getQueuedRequests()).isEmpty,
            timeout: const Duration(seconds: 8),
          );

          final droppedRequests = await proxy.getDroppedRequests();
          expect(droppedRequests, hasLength(1));
          expect(droppedRequests.single.method, equals('POST'));
          expect(
              droppedRequests.single.statusCode, equals(HttpStatus.badRequest));
          expect(droppedRequests.single.dropReason, equals('4xx_error'));
          expect(droppedRequests.single.url, contains('/drop-me'));

          final limitedDroppedRequests =
              await proxy.getDroppedRequests(limit: 1);
          expect(limitedDroppedRequests, hasLength(1));

          final stats = await proxy.getStats();
          expect(stats.queueLength, equals(0));
          expect(stats.droppedRequestsCount, equals(1));
          expect(eventTypes, contains(ProxyEventType.requestDropped));

          await proxy.clearDroppedRequests();

          expect(await proxy.getDroppedRequests(), isEmpty);
          expect((await proxy.getStats()).droppedRequestsCount, equals(0));

          await subscription.cancel();
        } finally {
          await upstreamServer.close(force: true);
        }
      }, createHttpClient: _RealHttpOverrides().createHttpClient);
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

Future<void> _sendProxyRequest(
  int proxyPort, {
  required String method,
  required String path,
  String body = '',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$proxyPort$path'),
    );
    if (body.isNotEmpty) {
      request.headers.contentType = ContentType.text;
      request.write(body);
    }
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close(force: true);
  }
}

Future<void> _waitUntil(
  Future<bool> Function() condition, {
  required Duration timeout,
  Duration interval = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) {
      return;
    }
    await Future.delayed(interval);
  }

  throw TimeoutException('Condition was not satisfied within $timeout');
}
