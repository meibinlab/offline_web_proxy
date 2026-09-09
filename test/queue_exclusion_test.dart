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
        .createTempSync('offline_web_proxy_queue_exclusion')
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

  group('queueExcludePaths（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// 既定では更新系をすべてキューへ保存すること
    test('queues every update request when no rule is configured', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _emitConnectivity(['none']);
        final response = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/registers/auth.json'),
          '{"code":"0001"}',
        );

        expect(response.statusCode, equals(HttpStatus.accepted));
        expect(response.queued, equals('1'));
        expect(await proxy.getQueuedRequests(), hasLength(1));
      });
    });

    /// 一致した更新系はキューへ入れず、規則の応答を返すこと
    test('answers with the rule response instead of queueing while offline',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            queueExcludePaths: const [
              QueueExcludeRule(
                path: '/api/registers/auth.json',
                response: ProxyResponseConfig(
                  statusCode: 503,
                  contentType: 'application/json; charset=utf-8',
                  body: '{"message":"オフラインのためレジ認証できません"}',
                ),
              ),
            ],
          ),
        );

        await _emitConnectivity(['none']);
        final response = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/registers/auth.json'),
          '{"code":"0001"}',
        );

        expect(response.statusCode, equals(HttpStatus.serviceUnavailable));
        expect(response.body, contains('オフラインのためレジ認証できません'));
        // 成功と誤認されないよう、ヘッダでも判別できること
        expect(response.queued, equals('0'));
        expect(response.excluded, equals('1'));
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// 一致しないパスは従来どおりキューへ保存すること
    test('keeps queueing a path that does not match any rule', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            queueExcludePaths: const [
              QueueExcludeRule(path: '/api/registers/auth.json'),
            ],
          ),
        );

        await _emitConnectivity(['none']);
        final response = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );

        expect(response.statusCode, equals(HttpStatus.accepted));
        expect(await proxy.getQueuedRequests(), hasLength(1));
      });
    });

    /// 上流が 5xx を返した場合は応答をそのまま返し、保存だけを行わないこと
    test('returns the upstream 5xx as-is without queueing', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.internalServerError;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            queueExcludePaths: const [
              QueueExcludeRule(path: '/api/registers/auth.json'),
            ],
          ),
        );

        final response = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/registers/auth.json'),
          '{"code":"0001"}',
        );

        // 上流が応答している以上、その内容を差し替えないこと
        expect(response.statusCode, equals(HttpStatus.internalServerError));
        expect(response.queued, isNull);
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// 応答を受け取れなかった場合もキューへ入れず、規則の応答を返すこと
    test('answers with the rule response when the upstream does not respond',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            requestTimeout: const Duration(milliseconds: 300),
            // 転送の失敗で遮断されると判定経路が変わるため無効化する
            upstreamFailureThreshold: 0,
            queueExcludePaths: const [
              QueueExcludeRule(path: '/api/registers/auth.json'),
            ],
          ),
        );

        upstream!.responseDelay = const Duration(seconds: 2);
        upstream!.delayedResponseCount = 1;
        final response = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/registers/auth.json'),
          '{"code":"0001"}',
        );

        expect(response.statusCode, equals(HttpStatus.serviceUnavailable));
        expect(response.excluded, equals('1'));
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// メソッドを指定した規則は、そのメソッドにだけ適用されること
    test('applies a rule only to the methods it names', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            queueExcludePaths: const [
              QueueExcludeRule(
                path: '/api/session.json',
                methods: ['DELETE'],
              ),
            ],
          ),
        );
        final sessionUri = Uri.parse('http://127.0.0.1:$port/api/session.json');

        await _emitConnectivity(['none']);

        final deleted = await _performUpdate(sessionUri, '', method: 'DELETE');
        expect(deleted.excluded, equals('1'));
        expect(await proxy.getQueuedRequests(), isEmpty);

        final posted = await _performUpdate(sessionUri, '{}');
        expect(posted.statusCode, equals(HttpStatus.accepted));
        expect(await proxy.getQueuedRequests(), hasLength(1));
      });
    });

    /// パターン記法で複数のパスをまとめて指定できること
    test('matches a group of paths with a wildcard pattern', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            queueExcludePaths: const [
              QueueExcludeRule(path: '/api/auth/**'),
            ],
          ),
        );

        await _emitConnectivity(['none']);
        final response = await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/auth/registers/sign_in.json'),
          '{}',
        );

        expect(response.excluded, equals('1'));
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });
  });
}
