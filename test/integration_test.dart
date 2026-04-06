import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
  'assets/static/app.css': ['assets/static/app.css'],
  'assets/static/css/app.css': ['assets/static/css/app.css'],
  'assets/static/js/vendor/runtime.js': ['assets/static/js/vendor/runtime.js'],
  'packages/offline_web_proxy/assets/static/pkg/package.css': [
    'packages/offline_web_proxy/assets/static/pkg/package.css',
  ],
};

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

    const stringCodec = StringCodec();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (ByteData? message) async {
      final assetKey = stringCodec.decodeMessage(message);
      if (assetKey == 'AssetManifest.json') {
        return stringCodec.encodeMessage(jsonEncode(_mockAssetManifest));
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

    /// 複数の基本操作を連続して処理できること
    test(
        'keeps cache, queue, cookie, and stats APIs usable across sequential admin operations',
        () async {
      expect(proxy.isRunning, isFalse);

      var stats = await proxy.getStats();
      expect(stats.totalRequests, equals(0));

      await proxy.clearCache();
      var cacheStats = await proxy.getCacheStats();
      expect(cacheStats.totalEntries, equals(0));

      await proxy.clearCacheForUrl('https://example.com/test');

      var queuedRequests = await proxy.getQueuedRequests();
      expect(queuedRequests, isEmpty);

      var cookies = await proxy.getCookies();
      expect(cookies, isEmpty);

      await proxy.clearCookies();

      stats = await proxy.getStats();
      expect(stats.totalRequests, equals(0));
      expect(stats.cacheHits, equals(0));
      expect(stats.cacheMisses, equals(0));
    });

    /// イベントストリームを購読できること
    test('should provide working event stream', () async {
      final eventStream = proxy.events;
      expect(eventStream, isA<Stream<ProxyEvent>>());

      StreamSubscription<ProxyEvent>? subscription;
      final completer = Completer<ProxyEvent>();

      subscription = eventStream.listen(
        (event) {
          if (event.type == ProxyEventType.serverStarted &&
              !completer.isCompleted) {
            completer.complete(event);
          }
        },
        onError: (error) {
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        },
      );

      await proxy.start(
        config: const ProxyConfig(origin: 'https://example.com'),
      );

      final event = await completer.future.timeout(const Duration(seconds: 1));
      expect(event.type, equals(ProxyEventType.serverStarted));

      await subscription.cancel();
    });

    /// カスタム ProxyConfig を保持できること
    test('should work with custom ProxyConfig', () async {
      const customConfig = ProxyConfig(
        origin: 'https://api.example.com',
        host: '127.0.0.1',
        port: 0, // 自動割当
        cacheMaxSize: 50 * 1024 * 1024, // 50MB
        logLevel: 'debug',
        enableAdminApi: false,
      );

      expect(customConfig.origin, equals('https://api.example.com'));
      expect(customConfig.cacheMaxSize, equals(50 * 1024 * 1024));
      expect(customConfig.logLevel, equals('debug'));

      expect(proxy.isRunning, isFalse);
    });

    /// 多数の API 呼び出しを並行処理できること
    test('should handle bulk operations efficiently', () async {
      final futures = <Future>[];

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

      final results = await Future.wait(futures);
      expect(results.length, greaterThan(100));

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

    /// 一部のエラーがあっても他の操作を継続できること
    test('returns successful results from unaffected APIs when some calls fail',
        () async {
      final futures = <Future>[];

      futures.add(proxy.getStats());
      futures.add(proxy.getCacheStats());

      futures.add(proxy.clearCacheForUrl('').catchError((_) => null));
      futures.add(proxy.getCacheList(limit: -1));

      futures.add(proxy.getQueuedRequests());
      futures.add(proxy.getCookies());

      final results = await Future.wait(futures);

      final validResults = results.where((r) => r != null).toList();
      expect(validResults.length, greaterThanOrEqualTo(4));
    });

    /// 同種の操作を繰り返しても安定して処理できること
    test('should remain stable with repeated operations', () async {
      for (int round = 0; round < 10; round++) {
        final roundFutures = <Future>[];

        for (int i = 0; i < 20; i++) {
          roundFutures.add(proxy.getStats());
          roundFutures.add(proxy.getCacheStats());
          roundFutures.add(proxy.getCacheList());
        }

        await Future.wait(roundFutures);

        await Future.delayed(Duration(milliseconds: 10));
      }

      final finalStats = await proxy.getStats();
      expect(finalStats, isNotNull);
      expect(finalStats.totalRequests, isA<int>());
    });

    /// パブリック API を一通り呼び出せること
    test('should call public APIs without asynchronous errors', () async {
      expect(proxy.isRunning, isA<bool>());
      expect(proxy.events, isA<Stream<ProxyEvent>>());

      expect(await proxy.getStats(), isA<ProxyStats>());
      expect(await proxy.getCacheStats(), isA<CacheStats>());

      expect(await proxy.getCacheList(), isA<List<CacheEntry>>());
      await expectLater(proxy.clearCache(), completes);
      await expectLater(proxy.clearExpiredCache(), completes);
      await expectLater(
        proxy.clearCacheForUrl('https://example.com'),
        completes,
      );

      expect(await proxy.getCookies(), isA<List<CookieInfo>>());
      await expectLater(proxy.clearCookies(), completes);

      expect(await proxy.getQueuedRequests(), isA<List<QueuedRequest>>());
      expect(await proxy.getDroppedRequests(), isA<List<DroppedRequest>>());
      await expectLater(proxy.clearDroppedRequests(), completes);

      expect(await proxy.warmupCache(paths: []), isA<WarmupResult>());
    });

    /// 連続実行でも短時間で安定して完了すること
    test('should handle long-running operations', () async {
      final startTime = DateTime.now();

      for (int minute = 0; minute < 3; minute++) {
        await proxy.getStats();
        await proxy.getCacheStats();
        await proxy.getCacheList(limit: 5);
        await proxy.getQueuedRequests();
        await proxy.getCookies();

        await Future.delayed(Duration(milliseconds: 100));
      }

      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      expect(duration.inSeconds, lessThan(3));

      expect(proxy.isRunning, isFalse);
      final finalStats = await proxy.getStats();
      expect(finalStats, isNotNull);
    });

    /// オンライン時は既存キャッシュがあっても upstream 応答を優先すること
    test(
        'should prefer upstream response for online get requests even with cache',
        () async {
      await HttpOverrides.runZoned(() async {
        late HttpServer upstreamServer;
        var requestCount = 0;
        var responseBody = '{"version":1}';
        var responseDelay = Duration.zero;

        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer.listen((HttpRequest request) async {
          requestCount++;
          if (responseDelay > Duration.zero) {
            await Future<void>.delayed(responseDelay);
          }

          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(responseBody);
          await request.response.close();
        });

        try {
          final proxyPort = await proxy.start(
            config: ProxyConfig(
              origin: 'http://127.0.0.1:${upstreamServer.port}',
              requestTimeout: const Duration(milliseconds: 300),
            ),
          );

          final firstResponse =
              await _performProxyRequest(proxyPort, '/api/online-preferred');
          expect(firstResponse.statusCode, equals(HttpStatus.ok));
          expect(firstResponse.body, equals('{"version":1}'));

          final seededCacheStats = await proxy.getCacheStats();
          expect(seededCacheStats.totalEntries, equals(1));

          responseBody = '{"version":2}';
          responseDelay = const Duration(milliseconds: 100);

          final secondResponse =
              await _performProxyRequest(proxyPort, '/api/online-preferred');

          expect(secondResponse.statusCode, equals(HttpStatus.ok));
          expect(secondResponse.body, equals('{"version":2}'));
          expect(secondResponse.headers.value('x-offline-source'), isNull);
          expect(requestCount, equals(2));

          final stats = await proxy.getStats();
          expect(stats.cacheHits, equals(0));
          expect(stats.cacheMisses, equals(2));
        } finally {
          await upstreamServer.close(force: true);
        }
      }, createHttpClient: _RealHttpOverrides().createHttpClient);
    });

    /// requestTimeout 超過時だけ cached fallback を返すこと
    test('should fallback to cached get response only after request timeout',
        () async {
      await HttpOverrides.runZoned(() async {
        late HttpServer upstreamServer;
        var requestCount = 0;
        var responseBody = '{"source":"seeded"}';
        var responseDelay = Duration.zero;
        final eventTypes = <ProxyEventType>[];
        final subscription = proxy.events.listen((event) {
          eventTypes.add(event.type);
        });

        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer.listen((HttpRequest request) async {
          requestCount++;
          if (responseDelay > Duration.zero) {
            await Future<void>.delayed(responseDelay);
          }

          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(responseBody);
          await request.response.close();
        });

        try {
          final proxyPort = await proxy.start(
            config: ProxyConfig(
              origin: 'http://127.0.0.1:${upstreamServer.port}',
              requestTimeout: const Duration(milliseconds: 100),
            ),
          );

          final seededResponse =
              await _performProxyRequest(proxyPort, '/api/timeout-fallback');
          expect(seededResponse.statusCode, equals(HttpStatus.ok));
          expect(seededResponse.body, equals('{"source":"seeded"}'));

          final seededCacheStats = await proxy.getCacheStats();
          expect(seededCacheStats.totalEntries, equals(1));

          responseBody = '{"source":"late-upstream"}';
          responseDelay = const Duration(milliseconds: 300);

          final fallbackResponse =
              await _performProxyRequest(proxyPort, '/api/timeout-fallback');

          expect(fallbackResponse.statusCode, equals(HttpStatus.ok));
          expect(fallbackResponse.body, equals('{"source":"seeded"}'));
          expect(fallbackResponse.headers.value('x-offline-source'), isNull);
          expect(requestCount, equals(2));
          expect(eventTypes, contains(ProxyEventType.cacheStaleUsed));

          final stats = await proxy.getStats();
          expect(stats.cacheHits, equals(1));
          expect(stats.cacheMisses, equals(1));
        } finally {
          await subscription.cancel();
          await upstreamServer.close(force: true);
        }
      }, createHttpClient: _RealHttpOverrides().createHttpClient);
    });

    /// upstream 4xx/5xx では cached fallback へ切り替えないこと
    test(
        'should return upstream 4xx and 5xx responses as-is without falling back to cached get response',
        () async {
      await HttpOverrides.runZoned(() async {
        late HttpServer upstreamServer;
        var requestCount = 0;
        var responseStatus = HttpStatus.ok;
        var responseBody = '{"source":"seeded"}';
        final eventTypes = <ProxyEventType>[];
        final subscription = proxy.events.listen((event) {
          eventTypes.add(event.type);
        });

        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer.listen((HttpRequest request) async {
          requestCount++;
          request.response
            ..statusCode = responseStatus
            ..headers.contentType = ContentType.json
            ..write(responseBody);
          await request.response.close();
        });

        try {
          final proxyPort = await proxy.start(
            config: ProxyConfig(
              origin: 'http://127.0.0.1:${upstreamServer.port}',
              requestTimeout: const Duration(milliseconds: 500),
            ),
          );

          final seededResponse =
              await _performProxyRequest(proxyPort, '/api/error-no-fallback');
          expect(seededResponse.statusCode, equals(HttpStatus.ok));
          expect(seededResponse.body, equals('{"source":"seeded"}'));

          final seededCacheStats = await proxy.getCacheStats();
          expect(seededCacheStats.totalEntries, equals(1));

          responseStatus = HttpStatus.notFound;
          responseBody = '{"error":"not-found"}';

          final clientErrorResponse =
              await _performProxyRequest(proxyPort, '/api/error-no-fallback');

          expect(clientErrorResponse.statusCode, equals(HttpStatus.notFound));
          expect(clientErrorResponse.body, equals('{"error":"not-found"}'));
          expect(
              clientErrorResponse.body, isNot(equals('{"source":"seeded"}')));
          expect(clientErrorResponse.headers.value('x-offline-source'), isNull);

          final cacheStatsAfter4xx = await proxy.getCacheStats();
          expect(cacheStatsAfter4xx.totalEntries, equals(1));

          responseStatus = HttpStatus.serviceUnavailable;
          responseBody = '{"error":"unavailable"}';

          final serverErrorResponse =
              await _performProxyRequest(proxyPort, '/api/error-no-fallback');

          expect(serverErrorResponse.statusCode,
              equals(HttpStatus.serviceUnavailable));
          expect(serverErrorResponse.body, equals('{"error":"unavailable"}'));
          expect(
              serverErrorResponse.body, isNot(equals('{"source":"seeded"}')));
          expect(serverErrorResponse.headers.value('x-offline-source'), isNull);

          final cacheStatsAfter5xx = await proxy.getCacheStats();
          expect(cacheStatsAfter5xx.totalEntries, equals(1));

          expect(requestCount, equals(3));
          expect(eventTypes, isNot(contains(ProxyEventType.cacheStaleUsed)));

          final stats = await proxy.getStats();
          expect(stats.cacheHits, equals(0));
          expect(stats.cacheMisses, equals(3));
        } finally {
          await subscription.cancel();
          await upstreamServer.close(force: true);
        }
      }, createHttpClient: _RealHttpOverrides().createHttpClient);
    });

    /// キューされたリクエストが FIFO 順で再送されること
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

    /// ブラウザ由来ヘッダを含む POST がキュー再送で消化されること
    test('should drain queued requests with browser style headers', () async {
      await HttpOverrides.runZoned(() async {
        late HttpServer upstreamServer;
        var upstreamStatus = HttpStatus.serviceUnavailable;
        final replayBodies = <String>[];
        final replayConnectionHeaders = <String?>[];
        final replayAcceptEncodingHeaders = <String?>[];
        final replayCookieHeaders = <String?>[];
        final replayHostHeaders = <String?>[];
        final replayDebugHeaders = <String?>[];

        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer.listen((HttpRequest request) async {
          final body = await utf8.decoder.bind(request).join();
          if (upstreamStatus == HttpStatus.ok) {
            replayBodies.add(body);
            replayConnectionHeaders.add(request.headers.value('connection'));
            replayAcceptEncodingHeaders
                .add(request.headers.value('accept-encoding'));
            replayCookieHeaders.add(request.headers.value('cookie'));
            replayHostHeaders.add(request.headers.host);
            replayDebugHeaders.add(request.headers.value('x-debug'));
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

          await _sendRawProxyRequest(
            proxyPort,
            method: 'POST',
            path: '/echo',
            body: 'hello-queue',
            headers: const {
              'Connection': 'keep-alive, x-debug',
              'Accept-Encoding': 'gzip, deflate',
              'Cookie': 'SESSION=abc123',
              'Origin': 'http://127.0.0.1',
              'Referer': 'http://127.0.0.1/context',
              'X-Debug': 'leak-me',
            },
          );

          final queuedBeforeDrain = await proxy.getQueuedRequests();
          expect(queuedBeforeDrain, hasLength(1));

          upstreamStatus = HttpStatus.ok;

          await _waitUntil(
            () async => (await proxy.getQueuedRequests()).isEmpty,
            timeout: const Duration(seconds: 8),
          );

          expect(replayBodies, equals(['hello-queue']));
          expect(replayConnectionHeaders, equals([null]));
          expect(replayAcceptEncodingHeaders, equals(['identity']));
          expect(replayCookieHeaders, equals(['SESSION=abc123']));
          expect(replayHostHeaders, equals(['127.0.0.1']));
          expect(replayDebugHeaders, equals([null]));
        } finally {
          await upstreamServer.close(force: true);
        }
      }, createHttpClient: _RealHttpOverrides().createHttpClient);
    });

    /// キュー状態が再起動後も保持され再送を再開できること
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

    /// バックオフに応じて retryCount と nextRetryAt が進むこと
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

    /// 4xx 再送時にドロップ履歴へ記録されること
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
    /// デフォルト設定を保持できること
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

    /// カスタム設定を保持できること
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

    /// 部分指定の設定でも既定値を補完できること
    test('should handle configuration inheritance correctly', () {
      const partialConfig = ProxyConfig(
        origin: 'https://example.com',
        logLevel: 'debug',
        enableAdminApi: true,
      );

      expect(partialConfig.origin, equals('https://example.com'));
      expect(partialConfig.logLevel, equals('debug'));
      expect(partialConfig.enableAdminApi, isTrue);

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

Future<({int statusCode, HttpHeaders headers, String body})>
    _performProxyRequest(
  int proxyPort,
  String path, {
  String method = 'GET',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$proxyPort$path'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      headers: response.headers,
      body: body,
    );
  } finally {
    client.close(force: true);
  }
}

Future<void> _sendRawProxyRequest(
  int proxyPort, {
  required String method,
  required String path,
  required String body,
  required Map<String, String> headers,
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort);
  try {
    final buffer = StringBuffer()
      ..writeln('$method $path HTTP/1.1')
      ..writeln('Host: 127.0.0.1:$proxyPort')
      ..writeln('Content-Type: text/plain; charset=utf-8')
      ..writeln('Content-Length: ${utf8.encode(body).length}');

    headers.forEach((key, value) {
      buffer.writeln('$key: $value');
    });

    buffer
      ..writeln()
      ..write(body);

    socket.add(utf8.encode(buffer.toString()));
    await socket.flush();
    await socket.first.timeout(const Duration(seconds: 5));
  } finally {
    await socket.close();
    socket.destroy();
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
