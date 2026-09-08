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

/// 受信したリクエストのヘッダと本文を記録する上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        receivedBodies.add(body);
        receivedIdempotencyKeys.add(request.headers.value('Idempotency-Key'));
        request.response
          ..statusCode = statusCode
          ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
          ..write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 上流が受信したリクエスト本文の一覧。受信順に追加される。
  final List<String> receivedBodies = <String>[];

  /// 上流が受信したべき等性キーの一覧。付与が無い場合は `null` が入る。
  final List<String?> receivedIdempotencyKeys = <String?>[];

  /// 応答するステータスコード。テスト中に変更できる。
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

/// 実 HttpClient で更新系リクエストを実行する。
Future<void> _performPost(
  Uri uri,
  String body, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl('POST', uri);
    headers.forEach(request.headers.set);
    request.write(body);
    final response = await request.close();
    await response.drain<void>();
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
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_idempotency')
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

  group('べき等性キー（doc/specs.ja.md 【6】Idempotency）', () {
    /// オフライン中に保存した更新系が、再送時にべき等性キーを伴うこと
    test('sends an idempotency key when a queued request is resent', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _emitConnectivity(['none']);
        await _performPost(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          '{"total":1000}',
        );
        expect(await proxy.getQueuedRequests(), hasLength(1));

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        // 上流が重複を判別できるようキーが付与されること
        expect(upstream!.receivedBodies, equals(['{"total":1000}']));
        expect(upstream!.receivedIdempotencyKeys.single, isNotNull);
        expect(upstream!.receivedIdempotencyKeys.single, isNotEmpty);
      });
    });

    /// 同じ内容の会計が連続しても、別のキーとして扱うこと
    test('assigns a distinct key to each request with the same body', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        final salesUri = Uri.parse('http://127.0.0.1:$port/api/sales');

        await _emitConnectivity(['none']);
        await _performPost(salesUri, '{"total":1000}');
        await _performPost(salesUri, '{"total":1000}');
        // 内容が同じでも別々の要求として保存されること
        expect(await proxy.getQueuedRequests(), hasLength(2));

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final keys = upstream!.receivedIdempotencyKeys;
        expect(keys, hasLength(2));
        // 片方が重複として消えないよう、キーが異なること
        expect(keys.first, isNot(equals(keys.last)));
      });
    });

    /// クライアントが指定したキーを尊重し、二重にキューへ積まないこと
    test('keeps a client supplied key and skips a duplicate submission',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        final salesUri = Uri.parse('http://127.0.0.1:$port/api/sales');

        await _emitConnectivity(['none']);
        await _performPost(
          salesUri,
          '{"total":1000}',
          headers: {'Idempotency-Key': 'sale-0001'},
        );
        await _performPost(
          salesUri,
          '{"total":1000}',
          headers: {'Idempotency-Key': 'sale-0001'},
        );

        // 同じキーの再送はキューへ二重に積まないこと
        expect(await proxy.getQueuedRequests(), hasLength(1));

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        // 上流へは 1 回だけ、指定されたキーで送信されること
        expect(upstream!.receivedBodies, hasLength(1));
        expect(upstream!.receivedIdempotencyKeys.single, equals('sale-0001'));
      });
    });

    /// 転送時とキュー再送で同じキーが送られること
    test('reuses the same key for the forwarded attempt and the resend',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        final salesUri = Uri.parse('http://127.0.0.1:$port/api/sales');

        // 上流が 5xx を返し、再送用にキューへ保存される状況を作る
        upstream!.statusCode = HttpStatus.internalServerError;
        await _performPost(
          salesUri,
          '{"total":1000}',
          headers: {'Idempotency-Key': 'sale-9999'},
        );
        expect(await proxy.getQueuedRequests(), hasLength(1));

        upstream!.statusCode = HttpStatus.ok;
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        // 転送時と再送時の両方が同じキーで送られること
        expect(upstream!.receivedIdempotencyKeys.length, greaterThan(1));
        expect(
          upstream!.receivedIdempotencyKeys.every((key) => key == 'sale-9999'),
          isTrue,
        );
      });
    });

    /// 生成したキーも転送時と再送時で一致すること
    test('reuses a generated key across the forwarded attempt and the resend',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        upstream!.statusCode = HttpStatus.internalServerError;
        await _performPost(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          '{"total":1000}',
        );

        upstream!.statusCode = HttpStatus.ok;
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final keys = upstream!.receivedIdempotencyKeys;
        // 転送時に採番したキーが再送でも使われること
        expect(keys.length, greaterThan(1));
        expect(keys.first, isNotNull);
        expect(keys.every((key) => key == keys.first), isTrue);
      });
    });

    /// 設定で無効にした場合はキーを付与しないこと
    test('omits the key when the feature is disabled', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            enableIdempotencyKey: false,
          ),
        );

        await _emitConnectivity(['none']);
        await _performPost(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          '{"total":1000}',
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        // 上流へ送信はされるが、キーは付与されないこと
        expect(upstream!.receivedBodies, hasLength(1));
        expect(upstream!.receivedIdempotencyKeys.single, isNull);
      });
    });
  });
}
