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

/// 受信内容を記録し、応答を差し替えられる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        receivedBodies.add(body);
        receivedPaths.add(request.uri.path);
        receivedAcceptedAt.add(request.headers.value(acceptedAtHeaderName));
        receivedIdempotencyKeys.add(request.headers.value('Idempotency-Key'));

        if (delayedResponseCount > 0) {
          // 応答が届く前に proxy 側が打ち切る状況を再現する
          delayedResponseCount--;
          await Future<void>.delayed(responseDelay);
        }

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

  /// 上流が受信したパスの一覧。受信順に追加される。
  final List<String> receivedPaths = <String>[];

  /// 上流が受信した受付時刻ヘッダの一覧。付与が無い場合は `null` が入る。
  final List<String?> receivedAcceptedAt = <String?>[];

  /// 上流が受信したべき等性キーの一覧。付与が無い場合は `null` が入る。
  final List<String?> receivedIdempotencyKeys = <String?>[];

  /// 受付時刻として読み取るヘッダ名。テスト中に変更できる。
  String acceptedAtHeaderName = 'X-Offline-Accepted-At';

  /// 応答するステータスコード。テスト中に変更できる。
  int statusCode = HttpStatus.ok;

  /// 応答を遅らせるリクエスト件数。受信順に先頭からこの件数だけ遅延させる。
  int delayedResponseCount = 0;

  /// [delayedResponseCount] 件のリクエストに対して応答を遅らせる時間。
  Duration responseDelay = Duration.zero;

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
///
/// [uri] は要求先、[method] は HTTP メソッド、[body] は本文です。
/// 戻り値はステータス、本文、および判別用の応答ヘッダです。
Future<
    ({
      int statusCode,
      String body,
      String? queued,
      String? excluded,
    })> _performUpdate(
  Uri uri,
  String body, {
  String method = 'POST',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    request.write(body);
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      body: responseBody,
      queued: response.headers.value('x-offline-queued'),
      excluded: response.headers.value('x-offline-excluded'),
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
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_accepted_at')
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

  group('受付時刻ヘッダ（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// 初回転送に受付時刻が付与されること
    test('sends the accepted time on the first forward', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );

        final acceptedAt = upstream!.receivedAcceptedAt.single;
        expect(acceptedAt, isNotNull);
        // タイムゾーンの解釈が割れないよう UTC で送ること
        expect(acceptedAt, endsWith('Z'));
        expect(DateTime.tryParse(acceptedAt!), isNotNull);
      });
    });

    /// read 系には付与しないこと
    test('does not send the accepted time for a read request', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final client = HttpClient();
        try {
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:$port/api/sales.json'));
          final response = await request.close();
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }

        expect(upstream!.receivedAcceptedAt.single, isNull);
      });
    });

    /// 応答を受け取れなかった転送と、その再送で同じ値を送ること
    test('reuses the accepted time when the forwarded attempt times out',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            requestTimeout: const Duration(milliseconds: 300),
            // 転送の失敗で遮断されると再送まで進まないため無効化する
            upstreamFailureThreshold: 0,
          ),
        );

        upstream!.responseDelay = const Duration(seconds: 2);
        upstream!.delayedResponseCount = 1;
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );
        expect(await proxy.getQueuedRequests(), hasLength(1));

        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final values = upstream!.receivedAcceptedAt;
        expect(values.length, greaterThan(1));
        expect(values.first, isNotNull);
        // 復帰後に採番し直すと、業務上の発生時刻が失われる
        expect(values.every((value) => value == values.first), isTrue);
      });
    });

    /// 隔離からの再送でも最初に受け付けた時刻を保つこと
    test('keeps the accepted time across a quarantine retry', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _emitConnectivity(['none']);
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);

        final quarantined = (await proxy.getQuarantinedRequests()).single;
        // 隔離中も最初に受け付けた時点を保持していること
        expect(quarantined.acceptedAt.isAfter(DateTime(2020)), isTrue);

        upstream!.statusCode = HttpStatus.ok;
        expect(await proxy.retryQuarantinedRequest(quarantined.id), isTrue);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final values = upstream!.receivedAcceptedAt;
        expect(values.length, equals(2));
        expect(values.first, isNotNull);
        expect(values.last, equals(values.first));
      });
    });

    /// 無効にした場合は付与しないこと
    test('omits the header when the feature is disabled', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            enableAcceptedAtHeader: false,
          ),
        );

        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );

        expect(upstream!.receivedAcceptedAt.single, isNull);
      });
    });

    /// ヘッダ名を変更できること
    test('uses the configured header name', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.acceptedAtHeaderName = 'X-Business-Occurred-At';
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            acceptedAtHeaderName: 'X-Business-Occurred-At',
          ),
        );

        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );

        expect(upstream!.receivedAcceptedAt.single, isNotNull);
      });
    });

    /// 受付時刻を持たない旧データは、キュー保存時刻で補うこと
    test('falls back to the queued time for data saved before this feature',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();

        // 旧バージョンが保存した、acceptedAt を持たないキューデータを、
        // 暗号化したキューに再現する（平文からの移行は別のテストで扱う）
        final encryptionKey = List<int>.generate(32, (index) => index);
        FlutterSecureStorage.setMockInitialValues(<String, String>{
          'offline_web_proxy.cookie_box_encryption_key':
              base64Encode(encryptionKey),
        });
        await Hive.initFlutter();
        final queuedAt = DateTime.now().subtract(const Duration(hours: 9));
        final queueBox = await Hive.openBox(
          'proxy_queue_secure',
          encryptionCipher: HiveAesCipher(encryptionKey),
        );
        await queueBox.put('0001757000000000000-000000', <String, dynamic>{
          'url': '${upstream!.origin}/api/sales.json',
          'method': 'POST',
          'headers': <String, String>{},
          'body': utf8.encode('{"total":1000}'),
          'queuedAt': queuedAt.toIso8601String(),
          'retryCount': 0,
          'nextRetryAt': DateTime.now().toIso8601String(),
        });
        await queueBox.close();

        await proxy.start(config: ProxyConfig(origin: upstream!.origin));
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final acceptedAt = upstream!.receivedAcceptedAt.single;
        expect(acceptedAt, isNotNull);
        expect(
          DateTime.parse(acceptedAt!).toUtc(),
          equals(queuedAt.toUtc()),
        );
      });
    });
  });
}
