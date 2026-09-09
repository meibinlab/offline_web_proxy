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
        .createTempSync('offline_web_proxy_resend_result')
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

  group('再送結果の通知（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// 再送が成功した場合に結果を通知すること
    test('reports a successful resend', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final attempts = <ProxyEvent>[];
        final drained = <ProxyEvent>[];
        proxy.events.listen((event) {
          if (event.type == ProxyEventType.queueResendAttempted) {
            attempts.add(event);
          }
          if (event.type == ProxyEventType.queueDrained) {
            drained.add(event);
          }
        });

        await _emitConnectivity(['none']);
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        await _waitUntil(() async => attempts.isNotEmpty);

        final attempt = attempts.single;
        expect(attempt.data['success'], isTrue);
        expect(attempt.data['statusCode'], equals(HttpStatus.ok));
        expect(attempt.data['willRetry'], isFalse);
        expect(attempt.data['idempotencyKey'], isNotNull);
        // 会計内容が監視経路へ流れないこと
        expect(attempt.data.containsKey('body'), isFalse);
        // JSON として読む側がタイムゾーンを誤解しないこと
        expect('${attempt.data['attemptedAt']}', endsWith('Z'));

        // 既存イベントからも結果を読めること
        expect(drained.single.data['statusCode'], equals(HttpStatus.ok));
      });
    });

    /// 4xx で隔離した場合に理由を通知すること
    test('reports the reason when the upstream rejects with 4xx', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final attempts = <ProxyEvent>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.queueResendAttempted)
            .listen(attempts.add);

        await _emitConnectivity(['none']);
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);
        await _waitUntil(() async => attempts.isNotEmpty);

        final attempt = attempts.first;
        expect(attempt.data['success'], isFalse);
        expect(attempt.data['statusCode'], equals(HttpStatus.badRequest));
        expect(attempt.data['dropReason'], equals('4xx_error'));
        expect(attempt.data['willRetry'], isFalse);
      });
    });

    /// 5xx では再試行が続くことを通知すること
    test('reports that a 5xx attempt stays queued', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.internalServerError;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final attempts = <ProxyEvent>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.queueResendAttempted)
            .listen(attempts.add);

        await _emitConnectivity(['none']);
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => attempts.isNotEmpty);

        final attempt = attempts.first;
        expect(attempt.data['success'], isFalse);
        expect(
            attempt.data['statusCode'], equals(HttpStatus.internalServerError));
        expect(attempt.data['willRetry'], isTrue);
        // 再試行のためキューへ残ること
        expect(await proxy.getQueuedRequests(), hasLength(1));
      });
    });

    /// 保持件数の上限を超えた場合は古いものから捨てること
    test('keeps only the newest results once the limit is exceeded', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _emitConnectivity(['none']);
        // 上限 20 件を超える件数を積む
        for (var index = 1; index <= 22; index++) {
          await _performUpdate(
            Uri.parse('http://127.0.0.1:$port/api/sales/$index.json'),
            '{"total":$index}',
          );
        }
        expect(await proxy.getQueuedRequests(), hasLength(22));

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        await _waitUntil(() async => proxy.recentResendResults.length >= 20);

        final results = proxy.recentResendResults;
        // 際限なく増やさず、新しいものを残すこと
        expect(results, hasLength(20));
        expect(results.last.url, endsWith('/api/sales/22.json'));
        expect(
          results.any((result) => result.url.endsWith('/api/sales/1.json')),
          isFalse,
        );
      });
    });

    /// 直近の再送結果を後から参照できること
    test('keeps the recent results available for later inspection', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        expect(proxy.recentResendResults, isEmpty);

        await _emitConnectivity(['none']);
        await _performUpdate(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          '{"total":1000}',
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        await _waitUntil(() async => proxy.recentResendResults.isNotEmpty);

        final result = proxy.recentResendResults.single;
        expect(result.success, isTrue);
        expect(result.statusCode, equals(HttpStatus.ok));
        expect(result.method, equals('POST'));
        expect(result.url, endsWith('/api/sales.json'));
      });
    });
  });
}
