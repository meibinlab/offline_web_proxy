import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/models/cookie_save_failure.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'support/access_token_http.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// パスごとに redirect や `Set-Cookie` を返せる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await utf8.decoder.bind(request).join();
        receivedUris.add(request.uri);

        final location = redirects[request.uri.path];
        if (location != null) {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('Location', location);
          await request.response.close();
          return;
        }

        request.response.statusCode = statusCode;
        request.response.headers.contentType =
            ContentType('text', 'plain', charset: 'utf-8');
        for (final value in setCookies) {
          request.response.headers.add('set-cookie', value);
        }
        request.response.write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 上流が受信した要求の URI。受信順に追加される。
  final List<Uri> receivedUris = <Uri>[];

  /// パスごとの redirect 先（`Location` の値）。
  final Map<String, String> redirects = <String, String>{};

  /// 応答へ付与する `Set-Cookie` の一覧。
  final List<String> setCookies = <String>[];

  /// redirect 以外へ返すステータスコード。
  int statusCode = HttpStatus.ok;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 上流サーバのモックを起動する。
Future<_MockUpstream> _startMockUpstream() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _MockUpstream(server);
}

/// connectivity_plus の状態変化イベントを擬似送信する。
///
/// [statuses] は `['none']` や `['wifi']` のような接続状態一覧です。
Future<void> _emitConnectivity(List<String> statuses) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'dev.fluttercommunity.plus/connectivity_status',
    const StandardMethodCodec().encodeSuccessEnvelope(statuses),
    (ByteData? _) {},
  );
}

/// redirect を追わずに実 HttpClient で要求を実行する。
///
/// [uri] は要求先、[method] は HTTP メソッド、[body] は本文です。
/// 戻り値はステータスと本文です。
Future<({int statusCode, String body})> _performRequest(
  Uri uri, {
  String method = 'GET',
  String? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    if (body != null) {
      request.write(body);
    }
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return (statusCode: response.statusCode, body: responseBody);
  } finally {
    client.close(force: true);
  }
}

/// [check] が真を返すまで待機する。
///
/// [timeout] を超えた場合は待機を打ち切り、呼び出し側のアサーションに委ねます。
Future<void> _waitUntil(
  FutureOr<bool> Function() check, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// redirectHandled の `data` のうち、既定でクエリとフラグメントを除く URL 項目の名前。
///
/// `externalUrl` はアプリが外部で開くための値で、設定によらず完全な URL の
/// まま載せるため含めない。
const List<String> _queryStrippedRedirectUrlKeys = [
  'proxyRequestUrl',
  'sourceUpstreamUrl',
  'locationHeader',
  'normalizedTargetUrl',
  'resolvedUpstreamUrl',
  'resolvedProxyUrl',
];

/// 応答本文を保存する暗号化 Box の名前。保存の失敗を作るために使用する。
const String _cacheBodyBoxName = 'proxy_cache_body_secure';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String hiveTestDirectory;

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        // Hive の保存先をテスト用ディレクトリに固定する
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

  late OfflineWebProxy proxy;
  _MockUpstream? upstream;
  late List<ProxyEvent> events;
  StreamSubscription<ProxyEvent>? subscription;

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_information_exposure')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    proxy = trackAccessToken(OfflineWebProxy());
    events = <ProxyEvent>[];
    subscription = proxy.events.listen(events.add);
  });

  tearDown(() async {
    await subscription?.cancel();
    subscription = null;
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream?.close();
    upstream = null;
  });

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: AccessTokenHttpOverrides().createHttpClient,
    );
  }

  /// [type] の最初のイベントが届くまで待って返す。
  Future<ProxyEvent> waitForEvent(ProxyEventType type) async {
    await _waitUntil(() => events.any((event) => event.type == type));
    return events.firstWhere((event) => event.type == type);
  }

  group('要求ログ（doc/specs.ja.md 【18】ログ・監視）', () {
    /// 要求ログにクエリの値を出さず、クエリがあることだけを `?…` で示すこと
    test('does not print the query string', () async {
      final lines = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) {
          lines.add(message);
        }
      };
      try {
        await withRealHttpClient(() async {
          upstream = await _startMockUpstream();
          final port = await proxy.start(
            config: ProxyConfig(origin: upstream!.origin),
          );

          final response = await _performRequest(
            Uri.parse('http://127.0.0.1:$port/search?q=secret-term&otp=99'),
          );
          expect(response.statusCode, equals(HttpStatus.ok));
        });
      } finally {
        debugPrint = originalDebugPrint;
      }

      final requestLines =
          lines.where((line) => line.contains('/search')).toList();
      expect(requestLines, hasLength(1));
      expect(requestLines.single, contains('GET'));
      expect(requestLines.single, contains('[200]'));
      expect(requestLines.single, endsWith('/search?…'));
      expect(lines.join('\n'), isNot(contains('secret-term')));
      expect(lines.join('\n'), isNot(contains('otp=')));
    });

    /// クエリの無い要求は `?…` を付けずにパスだけを出すこと
    test('prints the path alone when there is no query', () async {
      final lines = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) {
          lines.add(message);
        }
      };
      try {
        await withRealHttpClient(() async {
          upstream = await _startMockUpstream();
          final port = await proxy.start(
            config: ProxyConfig(origin: upstream!.origin),
          );

          await _performRequest(Uri.parse('http://127.0.0.1:$port/plain'));
        });
      } finally {
        debugPrint = originalDebugPrint;
      }

      expect(
        lines.where((line) => line.contains('/plain')).single,
        endsWith(' /plain'),
      );
    });
  });

  group('要求ログの例外（doc/specs.ja.md 【18】ログ・監視）', () {
    /// 処理中の例外は型名だけを出し、例外の文言とクエリを出さずに送出し直すこと
    test('prints only the exception type when handling throws', () async {
      final lines = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) {
          lines.add(message);
        }
      };
      final handler = proxy.requestLoggingMiddlewareForTesting()(
        (shelf.Request request) => throw StateError('secret-message token=abc'),
      );
      try {
        await expectLater(
          Future.sync(
            () => handler(
              shelf.Request(
                'GET',
                Uri.parse('http://127.0.0.1:8080/page?token=abc'),
              ),
            ),
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        debugPrint = originalDebugPrint;
      }

      expect(lines, hasLength(1));
      expect(lines.single, contains('GET'));
      expect(lines.single, contains('[ERROR StateError]'));
      expect(lines.single, endsWith('/page?…'));
      expect(lines.single, isNot(contains('secret-message')));
      expect(lines.single, isNot(contains('token=abc')));
    });
  });

  group('イベントの URL（doc/specs.ja.md 【18】ログ・監視）', () {
    /// 既定では requestReceived の url と URL 項目からクエリを除くこと
    test('removes the query from requestReceived by default', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page?token=abc'),
        );
        final event = await waitForEvent(ProxyEventType.requestReceived);

        expect(event.url, equals('page'));
        expect(event.data['proxyRequestUrl'],
            equals('http://127.0.0.1:$port/page'));
        expect(event.data['resolvedUpstreamUrl'],
            equals('${upstream!.origin}/page'));
        expect(event.data['resolvedProxyUrl'], isNot(contains('?')));
        expect(event.toString(), isNot(contains('token=abc')));
        // 上流へはクエリをそのまま送ること
        expect(upstream!.receivedUris.single.query, equals('token=abc'));
      });
    });

    /// includeQueryInEvents: true ならクエリを残すこと
    test('keeps the query in requestReceived when enabled', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            includeQueryInEvents: true,
          ),
        );

        await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page?token=abc'),
        );
        final event = await waitForEvent(ProxyEventType.requestReceived);

        expect(event.url, equals('page?token=abc'));
        expect(event.data['proxyRequestUrl'],
            equals('http://127.0.0.1:$port/page?token=abc'));
        expect(event.data['resolvedUpstreamUrl'],
            equals('${upstream!.origin}/page?token=abc'));
      });
    });

    /// 既定では redirectHandled の URL 項目すべてからクエリとフラグメントを除くこと
    test('removes the query and fragment from redirectHandled by default',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.redirects['/login/callback'] =
            '/home?code=one-time-code#section';
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/login/callback?state=s1'),
        );
        final event = await waitForEvent(ProxyEventType.redirectHandled);

        // WebView へ返す Location はクエリを保つこと
        expect(response.statusCode, equals(HttpStatus.found));
        expect(event.url, equals('login/callback'));
        expect(event.data['proxyRequestUrl'],
            equals('http://127.0.0.1:$port/login/callback'));
        expect(event.data['sourceUpstreamUrl'],
            equals('${upstream!.origin}/login/callback'));
        expect(event.data['locationHeader'], equals('/home'));
        for (final key in _queryStrippedRedirectUrlKeys) {
          final value = event.data[key] as String?;
          if (value != null) {
            expect(value, isNot(contains('?')), reason: key);
            expect(value, isNot(contains('#')), reason: key);
          }
        }
        expect(event.data['resolvedProxyUrl'],
            equals('http://127.0.0.1:$port/home'));
        expect(event.toString(), isNot(contains('one-time-code')));
      });
    });

    /// includeQueryInEvents: true なら redirectHandled の URL 項目にクエリを残すこと
    test('keeps the query in redirectHandled when enabled', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.redirects['/login/callback'] =
            '/home?code=one-time-code#section';
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            includeQueryInEvents: true,
          ),
        );

        await _performRequest(
          Uri.parse('http://127.0.0.1:$port/login/callback?state=s1'),
        );
        final event = await waitForEvent(ProxyEventType.redirectHandled);

        expect(event.url, equals('login/callback?state=s1'));
        expect(event.data['proxyRequestUrl'], contains('?state=s1'));
        expect(event.data['sourceUpstreamUrl'], contains('?state=s1'));
        expect(event.data['locationHeader'],
            equals('/home?code=one-time-code#section'));
        expect(event.data['resolvedProxyUrl'], contains('code=one-time-code'));
        expect(
          event.data['resolvedUpstreamUrl'],
          contains('code=one-time-code'),
        );
      });
    });

    // 外部起動の行き先ごとにテストを分ける
    const externalTargets = <String, ({String location, String stripped})>{
      'https': (
        location:
            'https://www.google.com/maps/search/?api=1&query=Tokyo+Station',
        stripped: 'https://www.google.com/maps/search/',
      ),
      'mailto': (
        location: 'mailto:support@example.com?subject=Receipt%20123',
        stripped: 'mailto:support@example.com',
      ),
      'geo': (
        location: 'geo:35.681236,139.767125?q=Tokyo+Station',
        stripped: 'geo:35.681236,139.767125',
      ),
    };
    for (final target in externalTargets.entries) {
      /// 外部起動の externalUrl は、アプリが起動先を知る唯一の値のため既定でも
      /// クエリを含む完全な URL のままにし、locationHeader からは除くこと
      test('keeps the full externalUrl by default (${target.key})', () async {
        await withRealHttpClient(() async {
          upstream = await _startMockUpstream();
          upstream!.redirects['/launch'] = target.value.location;
          final port = await proxy.start(
            config: ProxyConfig(origin: upstream!.origin),
          );

          final response = await _performRequest(
            Uri.parse('http://127.0.0.1:$port/launch'),
          );
          final event = await waitForEvent(ProxyEventType.redirectHandled);

          expect(response.statusCode, equals(HttpStatus.noContent));
          expect(event.data['redirectAction'],
              equals(ProxyWebViewNavigationAction.launchExternal.name));
          expect(event.data['externalUrl'], equals(target.value.location));
          expect(event.data['locationHeader'], equals(target.value.stripped));
        });
      });
    }
  });

  group('再送結果のクエリ（doc/specs.ja.md 【5】状態通知）', () {
    /// 送信待ちを作り、再送結果が 1 件記録されるまで待つ。
    ///
    /// [port] proxy のポート。
    Future<void> queueAndResend(int port) async {
      await _emitConnectivity(['none']);
      final queued = await _performRequest(
        Uri.parse('http://127.0.0.1:$port/api/sales.json?ticket=T-123'),
        method: 'POST',
        body: '{"total":1000}',
      );
      expect(queued.statusCode, equals(HttpStatus.accepted));

      await _emitConnectivity(['wifi']);
      await _waitUntil(() => proxy.recentResendResults.isNotEmpty);
      expect(proxy.recentResendResults, hasLength(1));
    }

    /// 状態通知の recentResendResults はクエリを含まず、Dart API は完全な URL を返すこと
    test('removes the query from the status endpoint only', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await queueAndResend(port);

        final status = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );
        final decoded = jsonDecode(status.body) as Map<String, dynamic>;
        final results = decoded['recentResendResults'] as List<dynamic>;
        final resultUrl = (results.single as Map<String, dynamic>)['url'];
        expect(resultUrl, equals('${upstream!.origin}/api/sales.json'));
        expect(status.body, isNot(contains('T-123')));

        // Dart API はクエリを含む完全な URL のまま
        expect(
          proxy.recentResendResults.single.url,
          equals('${upstream!.origin}/api/sales.json?ticket=T-123'),
        );

        // イベントは既定でクエリを除くこと
        final attempt = await waitForEvent(
          ProxyEventType.queueResendAttempted,
        );
        expect(attempt.url, equals('${upstream!.origin}/api/sales.json'));
        expect(
            attempt.data['url'], equals('${upstream!.origin}/api/sales.json'));
      });
    });

    /// includeQueryInEvents: true でもイベントだけがクエリを持ち、状態通知は除いたままにすること
    test('keeps the status endpoint without the query when events include it',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            includeQueryInEvents: true,
          ),
        );

        await queueAndResend(port);

        final status = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );
        expect(status.body, isNot(contains('T-123')));

        final attempt = await waitForEvent(
          ProxyEventType.queueResendAttempted,
        );
        expect(attempt.data['url'],
            equals('${upstream!.origin}/api/sales.json?ticket=T-123'));
      });
    });
  });

  group('応答の保存失敗の通知（doc/specs.ja.md 【18】ログ・監視）', () {
    /// 例外の文言を載せず、型名と区分だけを載せること
    test('reports only the type name and the reason', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        await proxy.cacheReady;

        // 保存領域が使えない状況を作る（容量不足や停止処理との競合に相当）
        await Hive.lazyBox(_cacheBodyBoxName).close();

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page?ticket=SECRET-TICKET'),
        );
        expect(response.statusCode, equals(HttpStatus.ok));
        await _waitUntil(() => events.any((event) =>
            event.type == ProxyEventType.errorOccurred &&
            event.data['phase'] == 'cacheResponse'));

        final event = events.firstWhere((event) =>
            event.type == ProxyEventType.errorOccurred &&
            event.data['phase'] == 'cacheResponse');
        expect(event.data.keys.toSet(), equals({'phase', 'error', 'reason'}));
        expect(event.data['reason'], equals(storageFailureEventReason));
        // 型名だけで、例外の文言（Box 名など）を含まないこと
        expect(event.data['error'], matches(RegExp(r'^[A-Za-z_][\w<>, ]*$')));
        // イベントの URL は shelf の要求の URL（先頭の / なし）からクエリを除いたもの
        expect(event.url, equals('page'));
        expect(event.toString(), isNot(contains('SECRET-TICKET')));
      });
    });
  });

  group('Cookie 保存失敗の通知（doc/specs.ja.md 【18】ログ・監視）', () {
    /// 解釈の失敗と、それ以外（保存領域の失敗など）を区分すること
    test('classifies the failure reason', () {
      expect(cookieSaveFailureReason(const FormatException('bad')),
          equals('invalidSetCookie'));
      expect(cookieSaveFailureReason(ArgumentError('bad')),
          equals('invalidSetCookie'));
      expect(cookieSaveFailureReason(HiveError('box closed')),
          equals('storageFailure'));
      expect(cookieSaveFailureReason(StateError('closed')),
          equals('storageFailure'));
    });

    /// 保存できない Set-Cookie の値をイベントに載せないこと
    test('does not include the Set-Cookie value in the event', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.setCookies.add('=SECRET-SESSION-VALUE; Path=/');
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performRequest(Uri.parse('http://127.0.0.1:$port/page?x=1'));
        await _waitUntil(() => events.any((event) =>
            event.type == ProxyEventType.errorOccurred &&
            event.data['operation'] == 'cookieSave'));

        final event = events.firstWhere((event) =>
            event.type == ProxyEventType.errorOccurred &&
            event.data['operation'] == 'cookieSave');
        expect(event.data['error'], equals('FormatException'));
        expect(event.data['reason'], equals('invalidSetCookie'));
        expect(event.url, equals('${upstream!.origin}/page'));
        expect(event.toString(), isNot(contains('SECRET-SESSION-VALUE')));
        expect(
          jsonEncode(event.data),
          isNot(contains('SECRET-SESSION-VALUE')),
        );
      });
    });
  });
}
