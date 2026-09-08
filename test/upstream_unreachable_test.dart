import 'dart:async';
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

/// HTTP 応答の検証に必要な要素だけを保持する型。
typedef _HttpResult = ({int statusCode, String body});

/// ページ遷移としてリクエストするためのヘッダ。
///
/// ブラウザエンジンが付与するヘッダを再現し、HTML のフォールバック応答を
/// 受け取る経路を検証するために使用する。
const Map<String, String> _navigationHeaders = {
  'Sec-Fetch-Mode': 'navigate',
  'Accept': 'text/html',
};

/// 応答内容を切り替えられる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      receivedPaths.add(request.uri.path);
      try {
        await request.drain<void>();
        request.response
          ..statusCode = statusCode
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..write(body);
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 応答するステータスコード。テスト中に変更できる。
  int statusCode = HttpStatus.ok;

  /// 応答する本文。テスト中に変更できる。
  String body = 'upstream-v1';

  /// 上流が受信したリクエストパスの一覧。
  final List<String> receivedPaths = <String>[];

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

/// 誰もバインドしていないポート番号を取得する（到達不能な origin 用）。
Future<int> _findClosedPort() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close(force: true);
  return port;
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

/// 実 HttpClient でリクエストを実行し、ステータスと本文を返す。
Future<_HttpResult> _performRequest(
  Uri uri, {
  String method = 'GET',
  String? body,
  Map<String, String> headers = const {},
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
    return (statusCode: response.statusCode, body: responseBody);
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
        .createTempSync('offline_web_proxy_unreachable')
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

  group('上流到達不能時のフォールバック（doc/specs.ja.md 【8】フォールバック利用条件）', () {
    /// 上流へ接続できない場合、保存済みキャッシュを代替応答として返すこと
    test('serves cached response when the upstream connection fails', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        final online = await _performRequest(pageUri);
        // 上流稼働中は upstream の応答を返すこと
        expect(online.statusCode, equals(HttpStatus.ok));
        expect(online.body, equals('upstream-v1'));

        // 上流プロセスが落ちた状態（接続拒否）を再現する
        await upstream!.close();

        final fallback = await _performRequest(pageUri);
        // キャッシュを代替応答として返すこと
        expect(fallback.statusCode, equals(HttpStatus.ok));
        expect(fallback.body, equals('upstream-v1'));
      });
    });

    /// 代替キャッシュが無い場合は 504 を返すこと
    test('returns 504 when no cached entry is available', () async {
      await withRealHttpClient(() async {
        final closedPort = await _findClosedPort();
        final port = await proxy.start(
          config: ProxyConfig(origin: 'http://127.0.0.1:$closedPort'),
        );

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/never-cached'),
        );

        // 代替できるキャッシュが無い場合は 504 を返すこと
        expect(result.statusCode, equals(HttpStatus.gatewayTimeout));
      });
    });

    /// 504 の本文を gatewayTimeoutHtml で差し替えられること
    test('applies gatewayTimeoutHtml to the connection failure response',
        () async {
      await withRealHttpClient(() async {
        final closedPort = await _findClosedPort();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: 'http://127.0.0.1:$closedPort',
            gatewayTimeoutHtml: '<html>unreachable</html>',
          ),
        );

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/never-cached'),
          headers: _navigationHeaders,
        );

        // ページ遷移にはアプリ側が指定した本文で応答すること
        expect(result.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(result.body, equals('<html>unreachable</html>'));
      });
    });

    /// HEAD は本文を持たない 504 を返すこと
    test('returns 504 without a body for HEAD', () async {
      await withRealHttpClient(() async {
        final closedPort = await _findClosedPort();
        final port = await proxy.start(
          config: ProxyConfig(origin: 'http://127.0.0.1:$closedPort'),
        );

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/never-cached'),
          method: 'HEAD',
        );

        // HEAD ではステータスのみを返すこと
        expect(result.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(result.body, isEmpty);
      });
    });

    /// 上流が応答した 5xx はそのまま返し、キャッシュへ切り替えないこと
    test('passes through an upstream 5xx without using the cache', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        // まずキャッシュを作る
        final cached = await _performRequest(pageUri);
        expect(cached.statusCode, equals(HttpStatus.ok));

        upstream!.statusCode = HttpStatus.internalServerError;
        upstream!.body = 'upstream-error';

        final result = await _performRequest(pageUri);
        // upstream が応答している場合はキャッシュへ切り替えないこと
        expect(result.statusCode, equals(HttpStatus.internalServerError));
        expect(result.body, equals('upstream-error'));
      });
    });

    /// 上流が応答した 4xx はそのまま返すこと
    test('passes through an upstream 4xx without using the cache', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        final cached = await _performRequest(pageUri);
        expect(cached.statusCode, equals(HttpStatus.ok));

        upstream!.statusCode = HttpStatus.notFound;
        upstream!.body = 'not-found';

        final result = await _performRequest(pageUri);
        // 4xx もそのまま返すこと
        expect(result.statusCode, equals(HttpStatus.notFound));
        expect(result.body, equals('not-found'));
      });
    });

    /// オフライン時のフォールバック HTML をアプリ側の文言へ差し替えられること
    test('offlineFallbackHtml replaces the offline response body', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            offlineFallbackHtml: '<html>offline-page</html>',
          ),
        );

        final wentOffline = Completer<void>();
        final subscription = proxy.events.listen((ProxyEvent event) {
          if (event.type == ProxyEventType.networkOffline &&
              !wentOffline.isCompleted) {
            wentOffline.complete();
          }
        });

        // 接続状態をオフラインへ変化させる
        await _emitConnectivity(<String>['none']);
        await wentOffline.future.timeout(const Duration(seconds: 5));

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/never-cached'),
          headers: _navigationHeaders,
        );
        await subscription.cancel();

        // ページ遷移にはオフライン応答として指定した HTML を返すこと
        expect(result.statusCode, equals(HttpStatus.ok));
        expect(result.body, equals('<html>offline-page</html>'));
      });
    });

    /// 更新系リクエストは接続失敗時にキューへ保存すること
    test('queues a mutating request when the upstream is unreachable',
        () async {
      await withRealHttpClient(() async {
        final closedPort = await _findClosedPort();
        final port = await proxy.start(
          config: ProxyConfig(origin: 'http://127.0.0.1:$closedPort'),
        );

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/submit'),
          method: 'POST',
          body: 'payload',
        );

        // キュー保存として受け付けること
        expect(result.statusCode, equals(HttpStatus.accepted));
        // キューに 1 件保存されること
        expect(await proxy.getQueuedRequests(), hasLength(1));
      });
    });
  });
}
