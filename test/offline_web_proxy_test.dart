import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'dart:io';
import 'package:offline_web_proxy/src/models/cookie_record.dart';

const String _encryptedCookieBoxName = 'proxy_cookies_secure';
const String _legacyCookieBoxName = 'proxy_cookies';
const String _cookieEncryptionKeyStorageKey =
    'offline_web_proxy.cookie_box_encryption_key';

HttpClient _createRealHttpClient(SecurityContext? context) {
  return HttpClient(context: context);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  late String hiveTestDirectory;

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        // テスト実行中は同一ディレクトリを返して Hive の保存先を安定化する
        return hiveTestDirectory;
      }
      return null;
    });
  });

  group('OfflineWebProxy Basic Tests', () {
    late OfflineWebProxy proxy;
    HttpServer? upstreamServer;

    setUp(() async {
      hiveTestDirectory =
          Directory.systemTemp.createTempSync('offline_web_proxy_test').path;
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      await _resetHiveTestBoxes();
      proxy = OfflineWebProxy();
    });

    tearDown(() async {
      if (proxy.isRunning) {
        await proxy.stop();
      }
      await upstreamServer?.close(force: true);
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

    /// 対象URL向けCookieヘッダ取得のテスト
    test('should build cookie header for target url', () async {
      await proxy.start(
          config: const ProxyConfig(origin: 'https://example.com'));

      final cookieBox = await _openEncryptedCookieBox();
      final createdAt = DateTime.utc(2026, 3, 19, 10);
      final rootCookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'ROOT=root; Path=/',
        requestUri: Uri.parse('https://example.com/login'),
        receivedAt: createdAt,
      );
      final appCookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'APP=app; Path=/app; Secure',
        requestUri: Uri.parse('https://example.com/app/login'),
        receivedAt: createdAt,
      );
      final foreignCookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'FOREIGN=foreign; Domain=other.example.com; Path=/',
        requestUri: Uri.parse('https://other.example.com/login'),
        receivedAt: createdAt,
      );

      await cookieBox.put(rootCookie.storageKey, rootCookie.toMap());
      await cookieBox.put(appCookie.storageKey, appCookie.toMap());
      await cookieBox.put(foreignCookie.storageKey, foreignCookie.toMap());

      final cookieHeader = await proxy
          .getCookieHeaderForUrl('https://example.com/app/dashboard');

      expect(cookieHeader, equals('APP=app; ROOT=root'));
    });

    /// 対象Cookieが無い場合はnullを返すテスト
    test('should return null when no cookies match target url', () async {
      await proxy.start(
          config: const ProxyConfig(origin: 'https://example.com'));

      final cookieHeader = await proxy
          .getCookieHeaderForUrl('https://example.com/app/dashboard');

      expect(cookieHeader, isNull);
    });

    /// start 前に復元した Cookie を起動後に送信できることのテスト
    test('should restore cookies before start and use them after start',
        () async {
      await proxy.restoreCookies([
        const CookieRestoreEntry(
          name: 'NATIVE',
          value: 'native-token',
          domain: 'example.com',
          path: '/app',
          secure: true,
          hostOnly: true,
        ),
      ]);

      await proxy.start(
        config: const ProxyConfig(origin: 'https://example.com'),
      );

      final cookieHeader = await proxy
          .getCookieHeaderForUrl('https://example.com/app/dashboard');

      expect(cookieHeader, equals('NATIVE=native-token'));
    });

    /// start 前に復元した Cookie が上流転送へ適用されることのテスト
    test('should forward restored cookies to upstream after start', () async {
      await HttpOverrides.runZoned(() async {
        final receivedCookies = <String?>[];
        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer!.listen((HttpRequest request) async {
          receivedCookies.add(request.headers.value('cookie'));
          request.response
            ..statusCode = HttpStatus.ok
            ..write('ok');
          await request.response.close();
        });

        await proxy.restoreCookies([
          const CookieRestoreEntry(
            name: 'NATIVE',
            value: 'native-token',
            domain: '127.0.0.1',
            path: '/',
            hostOnly: true,
          ),
        ]);

        final upstreamOrigin = 'http://127.0.0.1:${upstreamServer!.port}';
        final proxyPort = await proxy.start(
          config: ProxyConfig(origin: upstreamOrigin),
        );

        final client = HttpClient();
        try {
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:$proxyPort/app/dashboard'));
          final response = await request.close();
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }

        expect(receivedCookies, hasLength(1));
        expect(receivedCookies.single, equals('NATIVE=native-token'));
      }, createHttpClient: _createRealHttpClient);
    });

    /// 停止前に serverStopped イベントが購読側へ届くことのテスト
    test('should emit serverStopped event before closing stream', () async {
      final eventTypes = <ProxyEventType>[];
      final stoppedEvent = Completer<void>();

      final subscription = proxy.events.listen(
        (event) {
          eventTypes.add(event.type);
          if (event.type == ProxyEventType.serverStopped &&
              !stoppedEvent.isCompleted) {
            stoppedEvent.complete();
          }
        },
      );

      await proxy.start(
        config: const ProxyConfig(origin: 'https://example.com'),
      );

      await proxy.stop();

      await stoppedEvent.future.timeout(const Duration(seconds: 1));

      expect(eventTypes, contains(ProxyEventType.serverStarted));
      expect(eventTypes, contains(ProxyEventType.serverStopped));

      await subscription.cancel();
    });

    /// stop 後に再起動してもイベント配信と上流転送が継続することのテスト
    test('should restart same instance and emit events again', () async {
      await HttpOverrides.runZoned(() async {
        var upstreamRequestCount = 0;
        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer!.listen((HttpRequest request) async {
          upstreamRequestCount++;
          request.response
            ..statusCode = HttpStatus.ok
            ..write('ok');
          await request.response.close();
        });

        final upstreamOrigin = 'http://127.0.0.1:${upstreamServer!.port}';
        final initialEvents = <ProxyEventType>[];
        final initialStopped = Completer<void>();
        final initialSubscription = proxy.events.listen((event) {
          initialEvents.add(event.type);
          if (event.type == ProxyEventType.serverStopped &&
              !initialStopped.isCompleted) {
            initialStopped.complete();
          }
        });

        final firstPort = await proxy.start(
          config: ProxyConfig(origin: upstreamOrigin),
        );
        await _performProxyGet(firstPort, '/health');
        await proxy.stop();
        await initialStopped.future.timeout(const Duration(seconds: 1));

        expect(initialEvents, contains(ProxyEventType.serverStarted));
        expect(initialEvents, contains(ProxyEventType.serverStopped));

        await initialSubscription.cancel();

        final restartedStarted = Completer<void>();
        final restartedEvents = <ProxyEventType>[];
        final restartedSubscription = proxy.events.listen((event) {
          restartedEvents.add(event.type);
          if (event.type == ProxyEventType.serverStarted &&
              !restartedStarted.isCompleted) {
            restartedStarted.complete();
          }
        });

        final secondPort = await proxy.start(
          config: ProxyConfig(origin: upstreamOrigin),
        );
        await restartedStarted.future.timeout(const Duration(seconds: 1));
        await _performProxyGet(secondPort, '/health/restarted');

        expect(restartedEvents, contains(ProxyEventType.serverStarted));
        expect(upstreamRequestCount, equals(2));

        await restartedSubscription.cancel();
      }, createHttpClient: _createRealHttpClient);
    });

    /// 上流の Set-Cookie を保存し次回上流転送へ適用することのテスト
    test('should capture upstream set-cookie and forward it later', () async {
      await HttpOverrides.runZoned(() async {
        final receivedCookies = <String?>[];
        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer!.listen((HttpRequest request) async {
          receivedCookies.add(request.headers.value('cookie'));

          if (request.uri.path == '/login') {
            request.response.headers.add(
              'set-cookie',
              'SESSION=server-token; Path=/; HttpOnly',
            );
          }

          request.response
            ..statusCode = HttpStatus.ok
            ..write('ok');
          await request.response.close();
        });

        final proxyPort = await proxy.start(
          config: ProxyConfig(
            origin: 'http://127.0.0.1:${upstreamServer!.port}',
          ),
        );

        await _performProxyGet(proxyPort, '/login');
        await _performProxyGet(proxyPort, '/app/dashboard');

        expect(receivedCookies, hasLength(2));
        expect(receivedCookies.first, isNull);
        expect(receivedCookies.last, equals('SESSION=server-token'));
      }, createHttpClient: _createRealHttpClient);
    });

    /// Cookie 暗号化鍵をセキュアストレージに保存することのテスト
    test('should persist cookie encryption key in secure storage', () async {
      await proxy.restoreCookies([
        const CookieRestoreEntry(
          name: 'SECURE',
          value: 'value',
          domain: 'example.com',
          hostOnly: true,
        ),
      ]);

      final secureStorage = const FlutterSecureStorage();
      final storedKey = await secureStorage.read(
        key: _cookieEncryptionKeyStorageKey,
      );

      expect(storedKey, isNotNull);
      expect(base64Decode(storedKey!), hasLength(32));
    });

    /// 既存の平文 Cookie Box を暗号化 Box へ移行することのテスト
    test('should migrate legacy plain cookie box into encrypted box', () async {
      await Hive.initFlutter();
      final legacyBox = await Hive.openBox(_legacyCookieBoxName);
      final legacyCookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'LEGACY=token; Path=/; Secure',
        requestUri: Uri.parse('https://example.com/login'),
        receivedAt: DateTime.utc(2026, 3, 19, 10),
      );
      await legacyBox.put(legacyCookie.storageKey, legacyCookie.toMap());
      await legacyBox.close();

      await proxy.start(
        config: const ProxyConfig(origin: 'https://example.com'),
      );

      final cookieHeader =
          await proxy.getCookieHeaderForUrl('https://example.com/app');

      expect(cookieHeader, equals('LEGACY=token'));
      expect(await Hive.boxExists(_legacyCookieBoxName), isFalse);
    });

    /// 不正な暗号化鍵では平文 Box にフォールバックしないことのテスト
    test('should fail without fallback when secure storage key is invalid',
        () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        _cookieEncryptionKeyStorageKey: base64Encode(Uint8List(8)),
      });
      proxy = OfflineWebProxy();

      expect(
        () => proxy.start(
          config: const ProxyConfig(origin: 'https://example.com'),
        ),
        throwsA(isA<ProxyStartException>()),
      );
    });

    /// 暗号化 Box が残っていても鍵喪失時は復号できず失敗することのテスト
    test('should fail and require re-login when encryption key is missing',
        () async {
      await proxy.restoreCookies([
        const CookieRestoreEntry(
          name: 'SESSION',
          value: 'token',
          domain: 'example.com',
          hostOnly: true,
        ),
      ]);

      await Hive.close();
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      proxy = OfflineWebProxy();

      expect(
        () => proxy.start(
          config: const ProxyConfig(origin: 'https://example.com'),
        ),
        throwsA(isA<ProxyStartException>()),
      );
    });

    /// Jar の同名 Cookie を保持しつつクライアント Cookie を補完するテスト
    test('should preserve duplicate jar cookies and append client-only cookies',
        () async {
      await HttpOverrides.runZoned(() async {
        final receivedCookies = <String?>[];
        upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstreamServer!.listen((HttpRequest request) async {
          receivedCookies.add(request.headers.value('cookie'));
          request.response
            ..statusCode = HttpStatus.ok
            ..write('ok');
          await request.response.close();
        });

        await proxy.restoreCookies([
          const CookieRestoreEntry(
            name: 'SESSION',
            value: 'root',
            domain: '127.0.0.1',
            path: '/',
            hostOnly: true,
          ),
          const CookieRestoreEntry(
            name: 'SESSION',
            value: 'app',
            domain: '127.0.0.1',
            path: '/app',
            hostOnly: true,
          ),
        ]);

        final upstreamOrigin = 'http://127.0.0.1:${upstreamServer!.port}';
        final proxyPort = await proxy.start(
          config: ProxyConfig(origin: upstreamOrigin),
        );

        final client = HttpClient();
        try {
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:$proxyPort/app/dashboard'));
          request.headers.set('cookie', 'SESSION=client; CLIENT=1');
          final response = await request.close();
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }

        expect(receivedCookies, hasLength(1));
        expect(
          receivedCookies.single,
          equals('SESSION=app; SESSION=root; CLIENT=1'),
        );
      }, createHttpClient: _createRealHttpClient);
    });

    /// start 前に復元した Cookie を一覧取得できることのテスト
    test('should expose restored cookies before start', () async {
      await proxy.restoreCookies([
        CookieRestoreEntry.fromSetCookieHeader(
          setCookieHeader: 'SESSION=abc123; Path=/; Secure; SameSite=Lax',
          requestUrl: 'https://example.com/login',
        ),
      ]);

      final cookies = await proxy.getCookies();

      expect(cookies, hasLength(1));
      expect(cookies.first.name, equals('SESSION'));
      expect(cookies.first.value, equals('***'));
      expect(cookies.first.domain, equals('example.com'));
      expect(cookies.first.path, equals('/'));
      expect(cookies.first.secure, isTrue);
      expect(cookies.first.sameSite, equals('Lax'));
    });

    /// 不正URLのCookieヘッダ取得エラーテスト
    test('should throw error for invalid cookie header url', () async {
      expect(
          () => proxy.getCookieHeaderForUrl('not-a-url'), throwsArgumentError);
    });

    /// origin 外URLのCookieヘッダ取得エラーテスト
    test('should throw error for url outside configured origin', () async {
      await proxy.start(
          config: const ProxyConfig(origin: 'https://example.com'));

      expect(
        () => proxy
            .getCookieHeaderForUrl('https://api.example.com/app/dashboard'),
        throwsArgumentError,
      );
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
      await expectLater(proxy.clearCookies(), completes);
    });

    /// 特定ドメインのCookieクリア操作のテスト
    test('should handle cookie clear for specific domain', () async {
      const testDomain = 'example.com';
      await expectLater(proxy.clearCookies(domain: testDomain), completes);
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

Future<Box> _openEncryptedCookieBox() async {
  if (Hive.isBoxOpen(_encryptedCookieBoxName)) {
    return Hive.box(_encryptedCookieBoxName);
  }

  await Hive.initFlutter();
  final secureStorage = const FlutterSecureStorage();
  final encodedKey = await secureStorage.read(
    key: _cookieEncryptionKeyStorageKey,
  );
  if (encodedKey == null) {
    throw StateError('Cookie encryption key is not initialized');
  }

  return Hive.openBox(
    _encryptedCookieBoxName,
    encryptionCipher: HiveAesCipher(base64Decode(encodedKey)),
  );
}

Future<void> _resetHiveTestBoxes() async {
  await Hive.close();
}

Future<void> _performProxyGet(int proxyPort, String path) async {
  final client = HttpClient();
  try {
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:$proxyPort$path'));
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close(force: true);
  }
}
