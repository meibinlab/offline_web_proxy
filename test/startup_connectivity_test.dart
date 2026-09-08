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

/// 起動直後のリクエストが応答するまでに許容する時間。
///
/// 受け入れ条件「機内モードで起動しても初回リクエストが 1 秒以内に
/// オフライン応答へ落ちること」に対応する。
const Duration _firstResponseBudget = Duration(seconds: 1);

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// HTTP 応答の検証に必要な要素だけを保持する型。
typedef _HttpResult = ({int statusCode, Map<String, String> headers});

/// 受信したリクエストを記録する上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      receivedPaths.add(request.uri.path);
      try {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

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

/// 実 HttpClient でリクエストを実行し、ステータスとヘッダを返す。
Future<_HttpResult> _performRequest(Uri uri, {String method = 'GET'}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    final response = await request.close();
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    await response.drain<void>();
    return (statusCode: response.statusCode, headers: headers);
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String hiveTestDirectory;

  /// `checkConnectivity()` が返す接続状態。テストごとに差し替える。
  late List<String>? initialConnectivity;

  /// `checkConnectivity()` の応答を遅延させる時間。タイムアウト検証で使う。
  Duration? initialConnectivityDelay;

  setUpAll(() {
    const pathProviderChannel =
        MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel,
            (MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        // Hive の保存先をテスト用ディレクトリに固定する
        return hiveTestDirectory;
      }
      return null;
    });

    const connectivityChannel =
        MethodChannel('dev.fluttercommunity.plus/connectivity');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectivityChannel,
            (MethodCall methodCall) async {
      if (methodCall.method == 'check') {
        final delay = initialConnectivityDelay;
        if (delay != null) {
          await Future<void>.delayed(delay);
        }
        return initialConnectivity;
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
        Directory.systemTemp.createTempSync('offline_web_proxy_startup').path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    initialConnectivity = <String>['wifi'];
    initialConnectivityDelay = null;
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

  group('起動時のオンライン判定（README「オフライン判定」）', () {
    /// 圏外で起動した場合、変化イベントを待たずにオフラインとして応答すること
    test('serves offline response when started without connectivity', () async {
      await withRealHttpClient(() async {
        initialConnectivity = <String>['none'];
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final stopwatch = Stopwatch()..start();
        final result =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));
        stopwatch.stop();

        // オフライン扱いのフォールバック応答が返ること
        expect(result.statusCode, equals(HttpStatus.ok));
        expect(result.headers['x-offline'], equals('1'));
        expect(result.headers['x-offline-source'], equals('fallback'));
        // 上流へ転送されていないこと
        expect(upstream!.receivedPaths, isEmpty);
        // 受け入れ条件どおり 1 秒以内に応答すること
        expect(stopwatch.elapsed, lessThan(_firstResponseBudget));
      });
    });

    /// 接続がある状態で起動した場合、従来どおり上流へ転送すること
    test('forwards to upstream when started with connectivity', () async {
      await withRealHttpClient(() async {
        initialConnectivity = <String>['wifi'];
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final result =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));

        // 上流の応答をそのまま返すこと
        expect(result.statusCode, equals(HttpStatus.ok));
        expect(result.headers['x-offline'], isNull);
        // 上流へ転送されていること
        expect(upstream!.receivedPaths, contains('/page'));
      });
    });

    /// 接続状態を取得できない環境では、オンラインとみなして起動を継続すること
    test('falls back to online when the initial check is unavailable',
        () async {
      await withRealHttpClient(() async {
        // 応答が上限時間を超える環境を再現する
        initialConnectivity = <String>['none'];
        initialConnectivityDelay = const Duration(seconds: 2);
        upstream = await _startMockUpstream();

        final stopwatch = Stopwatch()..start();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        stopwatch.stop();

        // 取得待ちで起動が長時間止まらないこと
        expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1500)));

        final result =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));

        // 判定できない場合は安全側のオンラインとして上流へ転送すること
        expect(result.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedPaths, contains('/page'));
      });
    });

    /// 取得が上限時間を超えた場合でも、受信済みの変化イベントを上書きしないこと
    test('keeps the connectivity event when the initial check times out',
        () async {
      await withRealHttpClient(() async {
        // 取得が上限時間を超える間にオフラインイベントが届く状況を再現する
        initialConnectivity = <String>['wifi'];
        initialConnectivityDelay = const Duration(seconds: 2);
        upstream = await _startMockUpstream();

        final startFuture = proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await _emitConnectivity(['none']);
        final port = await startFuture;

        final result =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));

        // 取得失敗時の安全側フォールバックがイベントを上書きしないこと
        expect(result.headers['x-offline'], equals('1'));
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// 起動直後に届いた変化イベントを、初期化結果が上書きしないこと
    test('keeps the connectivity event received during startup', () async {
      await withRealHttpClient(() async {
        // 初期取得はオンラインを返すが、取得中にオフラインイベントが届く状況を再現する
        initialConnectivity = <String>['wifi'];
        initialConnectivityDelay = const Duration(milliseconds: 200);
        upstream = await _startMockUpstream();

        final startFuture = proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await _emitConnectivity(['none']);
        final port = await startFuture;

        final result =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));

        // より新しい変化イベント（オフライン）が優先されること
        expect(result.headers['x-offline'], equals('1'));
        expect(upstream!.receivedPaths, isEmpty);
      });
    });
  });
}
