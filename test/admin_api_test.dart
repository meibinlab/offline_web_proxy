import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// パスごとに応答を差し替えられる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await utf8.decoder.bind(request).join();
        receivedPaths.add(request.uri.path);
        receivedCookies.add(request.headers.value('cookie'));

        final body = bodies[request.uri.path];
        if (body == null) {
          request.response.statusCode = statusCode;
          request.response.headers.contentType =
              ContentType('text', 'plain', charset: 'utf-8');
          request.response.write('upstream');
        } else {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = body.contentType;
          for (final value in setCookies) {
            request.response.headers.add('set-cookie', value);
          }
          request.response.write(body.content);
        }
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 上流が受信したパスの一覧。受信順に追加される。
  final List<String> receivedPaths = <String>[];

  /// 上流が受信した `Cookie` ヘッダの一覧。付与が無い場合は `null` が入る。
  final List<String?> receivedCookies = <String?>[];

  /// パスごとの応答内容。未登録のパスは [statusCode] で応答する。
  final Map<String, ({String content, ContentType contentType})> bodies = {};

  /// 応答へ付与する `Set-Cookie` の一覧。
  final List<String> setCookies = <String>[];

  /// 未登録パスへ返すステータスコード。
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

/// 実 HttpClient で要求を実行する。
///
/// [uri] は要求先、[method] は HTTP メソッド、[headers] は付与するヘッダです。
/// 戻り値はステータス、本文、および判定に使う応答ヘッダです。
Future<
    ({
      int statusCode,
      String body,
      String? allowOrigin,
      String? cacheControl,
    })> _performRequest(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  String? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.write(body);
    }
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      body: responseBody,
      allowOrigin: response.headers.value('access-control-allow-origin'),
      cacheControl: response.headers.value('cache-control'),
    );
  } finally {
    client.close(force: true);
  }
}

/// [check] が真を返すまで待機する。
///
/// [timeout] を超えた場合は待機を打ち切り、呼び出し側のアサーションに委ねます。
Future<void> _waitUntil(
  Future<bool> Function() check, {
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

  setUp(() async {
    hiveTestDirectory =
        Directory.systemTemp.createTempSync('offline_web_proxy_admin_api').path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    proxy = OfflineWebProxy();
  });

  tearDown(() async {
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
      createHttpClient: _RealHttpOverrides().createHttpClient,
    );
  }

  group('管理エンドポイント（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// 隔離されたリクエストを 1 件作る
    Future<String> quarantineOneRequest(int port) async {
      upstream!.statusCode = HttpStatus.badRequest;
      await _emitConnectivity(['none']);
      await _performRequest(
        Uri.parse('http://127.0.0.1:$port/api/sales.json'),
        method: 'POST',
        body: '{"total":1000}',
      );
      await _emitConnectivity(['wifi']);
      await _waitUntil(
          () async => (await proxy.getQuarantinedRequests()).isNotEmpty);
      return (await proxy.getQuarantinedRequests()).single.id;
    }

    /// 既定では無効で、通常の転送経路になること
    test('is disabled by default', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performRequest(
          Uri.parse(
              'http://127.0.0.1:$port/__offline_web_proxy/admin/quarantine'),
        );

        expect(upstream!.receivedPaths,
            equals(['/__offline_web_proxy/admin/quarantine']));
        // 無効な間は通常の転送経路のため、統計からも外さないこと
        expect((await proxy.getStats()).totalRequests, equals(1));
      });
    });

    /// 隔離の一覧を JSON で返すこと
    test('lists quarantined requests', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, enableAdminApi: true),
        );

        final id = await quarantineOneRequest(port);

        final response = await _performRequest(
          Uri.parse(
              'http://127.0.0.1:$port/__offline_web_proxy/admin/quarantine'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final requests = decoded['requests'] as List<dynamic>;
        expect(requests, hasLength(1));
        final entry = requests.single as Map<String, dynamic>;
        expect(entry['id'], equals(id));
        expect(entry['method'], equals('POST'));
        expect(entry['statusCode'], equals(HttpStatus.badRequest));
        expect(entry['acceptedAt'], isNotNull);
        // 本文は返さないこと
        expect(entry.containsKey('body'), isFalse);
      });
    });

    /// 再送でキューへ戻すこと
    test('retries a quarantined request', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, enableAdminApi: true),
        );

        final id = await quarantineOneRequest(port);
        upstream!.statusCode = HttpStatus.ok;

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/admin/quarantine/$id/retry'),
          method: 'POST',
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(jsonDecode(response.body)['retried'], isTrue);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(await proxy.getQuarantinedRequests(), isEmpty);
      });
    });

    /// 破棄で取り除くこと
    test('discards a quarantined request', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, enableAdminApi: true),
        );

        final id = await quarantineOneRequest(port);

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/admin/quarantine/$id'),
          method: 'DELETE',
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(jsonDecode(response.body)['discarded'], isTrue);
        expect(await proxy.getQuarantinedRequests(), isEmpty);
      });
    });

    /// 該当が無い場合は 404 を返すこと
    test('answers 404 for an unknown id', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, enableAdminApi: true),
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/admin/quarantine/missing'),
          method: 'DELETE',
        );

        expect(response.statusCode, equals(HttpStatus.notFound));
        expect(jsonDecode(response.body)['discarded'], isFalse);
      });
    });

    /// 別 origin からの操作は拒否すること
    test('refuses an operation from another origin', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, enableAdminApi: true),
        );

        final id = await quarantineOneRequest(port);

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/admin/quarantine/$id'),
          method: 'DELETE',
          headers: const {'Origin': 'https://evil.example.com'},
        );

        expect(response.statusCode, equals(HttpStatus.forbidden));
        // 破棄されていないこと
        expect(await proxy.getQuarantinedRequests(), hasLength(1));
      });
    });

    /// 全 origin へ開かないこと
    test('does not advertise a permissive cors header', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, enableAdminApi: true),
        );

        final response = await _performRequest(
          Uri.parse(
              'http://127.0.0.1:$port/__offline_web_proxy/admin/quarantine'),
        );

        expect(response.allowOrigin, isNull);
      });
    });
  });
}
