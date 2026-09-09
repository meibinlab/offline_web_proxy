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
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_status_endpoint')
        .path;
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

  group('状態エンドポイント（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// 既定のパスで状態を JSON として返すこと
    test('reports the proxy state as json', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        expect(decoded['isOnline'], isA<bool>());
        expect(decoded['onlineDecisionSource'], isA<String>());
        expect(decoded['isUpstreamReachable'], isA<bool>());
        expect(decoded['upstreamCircuitState'], isA<String>());
        expect(decoded['queueLength'], equals(0));
        expect(decoded['quarantinedCount'], equals(0));
        expect(decoded['unacknowledgedDroppedCount'], equals(0));
        expect(decoded['recentResendResults'], isEmpty);
        // 状態は都度変わるため WebView 側にも保存させないこと
        expect(response.cacheControl, equals('no-store'));
      });
    });

    /// 上流へ転送せず、統計にも計上しないこと
    test('is answered locally and excluded from statistics', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );

        expect(upstream!.receivedPaths, isEmpty);
        expect((await proxy.getStats()).totalRequests, equals(0));
      });
    });

    /// 未送信件数を Web 側から確認できること
    test('reports the queue length so the page can block a settlement',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _emitConnectivity(['none']);
        await _performRequest(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          method: 'POST',
          body: '{"total":1000}',
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );

        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        expect(decoded['queueLength'], equals(1));
        expect(decoded['isOnline'], isFalse);
      });
    });

    /// 全 origin へ開かないこと
    test('does not advertise a permissive cors header', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );

        expect(response.allowOrigin, isNull);
      });
    });

    /// 別 origin からの要求は拒否すること
    test('refuses a request from another origin', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
          headers: const {'Origin': 'https://evil.example.com'},
        );

        expect(response.statusCode, equals(HttpStatus.forbidden));
      });
    });

    /// 自身の origin からの要求は許可すること
    test('allows a request from the proxy origin', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
          headers: {'Origin': 'http://127.0.0.1:$port'},
        );

        expect(response.statusCode, equals(HttpStatus.ok));
      });
    });

    /// loopback の別表記でも同じ proxy として許可すること
    test('allows a loopback origin written as localhost', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
          headers: {'Origin': 'http://localhost:$port'},
        );

        // 127.0.0.1 と localhost は同じ proxy を指す
        expect(response.statusCode, equals(HttpStatus.ok));
      });
    });

    /// 空文字を指定すると無効になり、通常の転送経路になること
    test('is disabled by an empty path', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, statusPath: ''),
        );

        await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );

        expect(
            upstream!.receivedPaths, equals(['/__offline_web_proxy/status']));
      });
    });

    /// パスを変更できること
    test('uses the configured path', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            statusPath: '/internal/proxy_status',
          ),
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/internal/proxy_status'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// 使用できない値は起動時に拒否すること
    test('rejects a path that cannot be used', () async {
      upstream = await _startMockUpstream();

      expect(
        () => proxy.start(
          config: ProxyConfig(origin: upstream!.origin, statusPath: 'status'),
        ),
        throwsA(isA<ProxyStartException>()),
      );
    });

    /// 稼働確認パスと重複する指定は拒否すること
    test('rejects a path that collides with the health check path', () async {
      upstream = await _startMockUpstream();

      expect(
        () => proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            statusPath: '/__offline_web_proxy/health',
          ),
        ),
        throwsA(isA<ProxyStartException>()),
      );
    });
  });
}
