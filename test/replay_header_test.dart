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
        receivedReplay.add(request.headers[replayHeaderName]);

        var responseStatusCode = statusCode;
        if (failingResponseCount > 0) {
          // 最初の転送だけ上流が一時的に失敗する状況を再現する
          failingResponseCount--;
          responseStatusCode = HttpStatus.serviceUnavailable;
        }

        request.response
          ..statusCode = responseStatusCode
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

  /// 上流が受信した再送ヘッダの値の一覧。付与が無い場合は `null` が入る。
  ///
  /// 同名のヘッダが複数行で届いた場合も検出できるよう、すべての値を保持する。
  final List<List<String>?> receivedReplay = <List<String>?>[];

  /// 再送ヘッダとして読み取るヘッダ名。テスト中に変更できる。
  String replayHeaderName = 'X-Offline-Replay';

  /// 応答するステータスコード。テスト中に変更できる。
  int statusCode = HttpStatus.ok;

  /// `503` を返すリクエスト件数。受信順に先頭からこの件数だけ失敗させる。
  int failingResponseCount = 0;

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
        .createTempSync('offline_web_proxy_replay_header')
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

  group('キューからの送信の通知（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// 最初の転送には付けないこと
    test('does not mark the first forward', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final result = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["a"]}',
        );

        expect(result.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedReplay.single, isNull);
      });
    });

    /// read 系には付けないこと
    test('does not mark a read request', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final client = HttpClient();
        try {
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:$port/api/consents.json'));
          final response = await request.close();
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }

        expect(upstream!.receivedReplay.single, isNull);
      });
    });

    /// 回線が無いためにキューへ入れた要求の送信に付けること
    test('marks a request queued while offline', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _emitConnectivity(['none']);
        final result = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["a"]}',
        );
        expect(result.queued, equals('1'));
        // 最初の転送を行っていないこと
        expect(upstream!.receivedReplay, isEmpty);

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => upstream!.receivedReplay.isNotEmpty);

        expect(upstream!.receivedReplay.single, equals(['1']));
      });
    });

    /// 上流の 5xx でキューへ入れた要求は、送信にだけ付けること
    test('marks only the resend of a request answered with 5xx', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.failingResponseCount = 1;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            // 転送の失敗で遮断されると再送まで進まないため無効化する
            upstreamFailureThreshold: 0,
          ),
        );

        final result = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["a"]}',
        );
        expect(result.statusCode, equals(HttpStatus.serviceUnavailable));
        expect(result.queued, equals('1'));

        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final values = upstream!.receivedReplay;
        expect(values, hasLength(2));
        expect(values.first, isNull);
        expect(values.last, equals(['1']));
      });
    });

    /// 隔離からキューへ戻した要求の送信に付けること
    test('marks a request put back from quarantine', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.conflict;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _emitConnectivity(['none']);
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["a"]}',
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);
        final quarantined = (await proxy.getQuarantinedRequests()).single;

        upstream!.statusCode = HttpStatus.ok;
        expect(await proxy.retryQuarantinedRequest(quarantined.id), isTrue);
        await _waitUntil(() async => upstream!.receivedReplay.length >= 2);

        expect(
          upstream!.receivedReplay,
          equals([
            ['1'],
            ['1'],
          ]),
        );
      });
    });

    /// 画面が送った同名のヘッダは、最初の転送では取り除き、
    /// キューからの送信では proxy の値で上書きすること
    test('does not let the screen claim to be a queued request', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.failingResponseCount = 1;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            upstreamFailureThreshold: 0,
          ),
        );

        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["a"]}',
          headers: {'x-offline-REPLAY': 'forged'},
        );
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final values = upstream!.receivedReplay;
        expect(values, hasLength(2));
        expect(values.first, isNull);
        expect(values.last, equals(['1']));
      });
    });

    /// 無効にした場合は、付けることも取り除くこともしないこと
    test('neither adds nor removes the header when disabled', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            enableReplayHeader: false,
          ),
        );

        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["a"]}',
          headers: {'X-Offline-Replay': 'from-screen'},
        );

        await _emitConnectivity(['none']);
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["b"]}',
        );
        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => upstream!.receivedReplay.length >= 2);

        expect(
          upstream!.receivedReplay,
          equals([
            ['from-screen'],
            null,
          ]),
        );
      });
    });

    /// 無効にした場合は、キューへ保存した画面のヘッダもそのまま送ること
    test('keeps the screen header on a queued request when disabled', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            enableReplayHeader: false,
          ),
        );

        await _emitConnectivity(['none']);
        final result = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["a"]}',
          headers: {'X-Offline-Replay': 'from-screen'},
        );
        // 最初の転送ではなく、キューから届いたものを検証すること
        expect(result.queued, equals('1'));
        expect(upstream!.receivedReplay, isEmpty);

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => upstream!.receivedReplay.isNotEmpty);

        expect(
          upstream!.receivedReplay.single,
          equals(['from-screen']),
        );
      });
    });

    /// ヘッダ名を変更できること
    test('uses the configured header name', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.replayHeaderName = 'X-Sent-From-Queue';
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            replayHeaderName: 'X-Sent-From-Queue',
          ),
        );

        // 変更後の名前で画面が送ったヘッダも取り除くこと
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["a"]}',
          headers: {'X-Sent-From-Queue': 'forged'},
        );

        await _emitConnectivity(['none']);
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/consents.json'),
          '{"items":["b"]}',
        );
        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => upstream!.receivedReplay.length >= 2);

        expect(
          upstream!.receivedReplay,
          equals([
            null,
            ['1'],
          ]),
        );
      });
    });
  });
}
