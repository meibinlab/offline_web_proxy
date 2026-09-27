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

/// 状態通知エンドポイントの既定のパス。
const String _statusPath = '/__offline_web_proxy/status';

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// 受信件数を数え、応答を差し替えられる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await utf8.decoder.bind(request).join();
        receivedCount++;

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

  /// 上流が受信したリクエストの件数。
  int receivedCount = 0;

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

/// 実 HttpClient で、べき等性キーを付けた更新系リクエストを実行する。
///
/// [port] は proxy のポート、[idempotencyKey] は付けるキーです。
/// 戻り値はステータスと、キューへ入れたことを示す応答ヘッダです。
Future<({int statusCode, String? queued})> _performUpdate(
  int port,
  String idempotencyKey,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/api/consents.json'),
    );
    request.headers.set('Idempotency-Key', idempotencyKey);
    request.write('{"items":["a"]}');
    final response = await request.close();
    await response.drain<void>();
    return (
      statusCode: response.statusCode,
      queued: response.headers.value('x-offline-queued'),
    );
  } finally {
    client.close(force: true);
  }
}

/// 状態通知エンドポイントを、べき等性キーを指定して呼ぶ。
///
/// [port] は proxy のポート、[keys] は `idempotencyKey` に指定する値です。
/// `null` の場合はクエリを付けません。
/// 戻り値はステータス、JSON として読んだ本文、`Cache-Control` の値です。
Future<({int statusCode, Map<String, dynamic> json, String? cacheControl})>
    _queryStatus(int port, List<String>? keys) async {
  final uri = Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: _statusPath,
    queryParameters: keys == null ? null : {'idempotencyKey': keys},
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      json: jsonDecode(body) as Map<String, dynamic>,
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
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_request_status')
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

  /// 回線を切った状態でキーを付けた要求を送り、送信待ちに入れる。
  ///
  /// [port] は proxy のポート、[key] は付けるべき等性キーです。
  Future<void> enqueueOffline(int port, String key) async {
    await _emitConnectivity(['none']);
    final result = await _performUpdate(port, key);
    expect(result.queued, equals('1'));
  }

  group('要求の状態の照会（doc/specs.ja.md 【5】状態通知エンドポイント）', () {
    /// キーを指定しない場合は、従来と同じ応答を返すこと
    test('keeps the usual response without idempotencyKey', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response = await _queryStatus(port, null);

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.json.containsKey('requests'), isFalse);
        expect(response.json['queueLength'], equals(0));
      });
    });

    /// 送信待ちを受付時刻付きで返し、指定した順に、重複もそのまま、
    /// 空のキーは除き、前後の空白を除いて照合すること
    test('reports a queued request in the requested order', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        await enqueueOffline(port, 'key-1');

        final response =
            await _queryStatus(port, ['missing', 'key-1', '', ' key-1 ']);

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.cacheControl, equals('no-store'));
        // 従来の項目も同じ応答に含めること
        expect(response.json['queueLength'], equals(1));
        final requests = response.json['requests'] as List;
        expect(requests, hasLength(3));
        expect(requests[0],
            equals({'idempotencyKey': 'missing', 'state': 'unknown'}));
        for (final item in requests.skip(1).cast<Map<String, dynamic>>()) {
          expect(item['idempotencyKey'], equals('key-1'));
          expect(item['state'], equals('queued'));
          expect(item.containsKey('statusCode'), isFalse);
          final acceptedAt = item['acceptedAt'] as String;
          expect(acceptedAt, endsWith('Z'));
          expect(
            DateTime.parse(acceptedAt),
            equals(DateTime.parse(
              (await proxy.getQueuedRequests())
                  .single
                  .acceptedAt
                  .toUtc()
                  .toIso8601String(),
            )),
          );
        }
        // 照会しても送信待ちは変わらないこと
        final queued = await proxy.getQueuedRequests();
        expect(queued, hasLength(1));
        expect(queued.single.idempotencyKey, equals('key-1'));
      });
    });

    /// 送信待ちから送って上流が 2xx を返した要求は delivered になること
    test('reports a request delivered from the queue', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        await enqueueOffline(port, 'key-1');

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final response = await _queryStatus(port, ['key-1']);
        expect(
          response.json['requests'],
          equals([
            {'idempotencyKey': 'key-1', 'state': 'delivered'},
          ]),
        );
      });
    });

    /// 最初の転送で上流が受け付けた要求は記録しないため unknown になること
    test('reports unknown for a request answered on its first forward',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final result = await _performUpdate(port, 'key-1');
        expect(result.statusCode, equals(HttpStatus.ok));

        final statuses = await proxy.getRequestStatuses(['key-1']);
        expect(statuses.single.state, equals(RequestState.unknown));
      });
    });

    /// 上流の 4xx で隔離した要求を、状態コード付きで返すこと
    test('reports a quarantined request with its status code', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.conflict;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        await enqueueOffline(port, 'key-1');
        final acceptedAt =
            (await proxy.getQueuedRequests()).single.acceptedAt.toUtc();

        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);

        final status = (await proxy.getRequestStatuses(['key-1'])).single;
        expect(status.state, equals(RequestState.quarantined));
        expect(status.statusCode, equals(HttpStatus.conflict));
        expect(status.acceptedAt, equals(acceptedAt));
        expect(
          (await proxy.getQuarantinedRequests()).single.idempotencyKey,
          equals('key-1'),
        );
      });
    });

    /// 隔離の一覧（管理エンドポイント）にキーを出すこと
    test('lists the idempotency key in the admin quarantine list', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.conflict;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, enableAdminApi: true),
        );
        await enqueueOffline(port, 'key-1');
        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(
              'http://127.0.0.1:$port/__offline_web_proxy/admin/quarantine'));
          final response = await request.close();
          final json = jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, dynamic>;
          final item = (json['requests'] as List).single as Map;
          expect(item['idempotencyKey'], equals('key-1'));
        } finally {
          client.close(force: true);
        }
      });
    });

    /// dropPolicy が drop の場合、ドロップ履歴にキーと受付時刻を残し、
    /// dropped として返すこと
    test('records the key of a dropped request', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            dropPolicy: DropPolicy.drop,
          ),
        );
        await enqueueOffline(port, 'key-1');
        final acceptedAt =
            (await proxy.getQueuedRequests()).single.acceptedAt.toUtc();

        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getDroppedRequests()).isNotEmpty);

        final dropped = (await proxy.getDroppedRequests()).single;
        expect(dropped.idempotencyKey, equals('key-1'));
        expect(dropped.acceptedAt?.toUtc(), equals(acceptedAt));

        final response = await _queryStatus(port, ['key-1']);
        final item = (response.json['requests'] as List).single as Map;
        expect(item['state'], equals('dropped'));
        expect(item['statusCode'], equals(HttpStatus.badRequest));
        expect(
            DateTime.parse(item['acceptedAt'] as String), equals(acceptedAt));
      });
    });

    /// 1 件で隔離の上限を超えた要求も、キー付きで履歴に残すこと
    test('records the key of a request too large to quarantine', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, quarantineMaxBytes: 1),
        );
        await enqueueOffline(port, 'key-1');

        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getDroppedRequests()).isNotEmpty);

        final dropped = (await proxy.getDroppedRequests()).single;
        expect(dropped.dropReason, equals('quarantine_too_large'));
        expect(dropped.idempotencyKey, equals('key-1'));
        expect(
          (await proxy.getRequestStatuses(['key-1'])).single.state,
          equals(RequestState.dropped),
        );
      });
    });

    /// 隔離の件数の上限で追い出した要求も、キー付きで履歴に残すこと
    test('records the key of a request evicted from quarantine', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, quarantineMaxCount: 1),
        );
        await enqueueOffline(port, 'key-1');
        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);

        await enqueueOffline(port, 'key-2');
        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getDroppedRequests()).isNotEmpty);

        final dropped = (await proxy.getDroppedRequests()).single;
        expect(dropped.dropReason, equals('quarantine_limit'));
        expect(dropped.idempotencyKey, equals('key-1'));
        final statuses = await proxy.getRequestStatuses(['key-1', 'key-2']);
        expect(statuses.map((status) => status.state), [
          RequestState.dropped,
          RequestState.quarantined,
        ]);
      });
    });

    /// 上流が一度でも受け付けていれば、隔離に同じキーが残っていても
    /// delivered を返すこと
    test('prefers delivered over quarantined', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.conflict;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            // 転送の失敗で遮断されると再送まで進まないため無効化する
            upstreamFailureThreshold: 0,
          ),
        );
        await enqueueOffline(port, 'key-1');
        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);

        // 同じキーの要求が別に届き、最初の転送の 5xx の後、再送で受け付けられる
        upstream!
          ..statusCode = HttpStatus.ok
          ..failingResponseCount = 1;
        final result = await _performUpdate(port, 'key-1');
        expect(result.queued, equals('1'));
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(await proxy.getQuarantinedRequests(), hasLength(1));
        expect(
          (await proxy.getRequestStatuses(['key-1'])).single.state,
          equals(RequestState.delivered),
        );
      });
    });

    /// 隔離と送信待ちに同じキーがある場合は queued を返すこと
    test('prefers queued over quarantined', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.conflict;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        await enqueueOffline(port, 'key-1');
        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);

        await enqueueOffline(port, 'key-1');

        final status = (await proxy.getRequestStatuses(['key-1'])).single;
        expect(status.state, equals(RequestState.queued));
        expect(status.statusCode, isNull);
      });
    });

    /// 送信待ちから隔離へ移る途中で、unknown を返さないこと
    test('never reports unknown while a request moves to quarantine', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.conflict;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        await enqueueOffline(port, 'key-1');

        await _emitConnectivity(['wifi']);
        final observed = <RequestState>{};
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().isBefore(deadline)) {
          final state =
              (await proxy.getRequestStatuses(['key-1'])).single.state;
          observed.add(state);
          if (state == RequestState.quarantined) {
            break;
          }
          // 移す処理の各段階で照会できるよう、処理を譲りながら繰り返す
          await Future<void>.delayed(Duration.zero);
        }

        expect(observed, contains(RequestState.quarantined));
        expect(observed, isNot(contains(RequestState.unknown)));
      });
    });

    /// キーの件数と長さの上限を超えた場合は 400 を返すこと
    test('rejects too many or too long keys', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final atLimit = await _queryStatus(
          port,
          [for (var i = 0; i < 49; i++) 'key-$i', 'k' * 200],
        );
        expect(atLimit.statusCode, equals(HttpStatus.ok));
        expect(atLimit.json['requests'], hasLength(50));

        final tooMany = await _queryStatus(
          port,
          [for (var i = 0; i < 51; i++) 'key-$i'],
        );
        expect(tooMany.statusCode, equals(HttpStatus.badRequest));
        expect(tooMany.json['error'], isA<String>());

        // 空のキーは件数に数えないこと
        final withBlanks = await _queryStatus(
          port,
          [for (var i = 0; i < 50; i++) 'key-$i', '', ' '],
        );
        expect(withBlanks.statusCode, equals(HttpStatus.ok));

        final tooLong = await _queryStatus(port, ['k' * 201]);
        expect(tooLong.statusCode, equals(HttpStatus.badRequest));
        expect(tooLong.cacheControl, equals('no-store'));
      });
    });

    /// 保存領域が読めない場合は unknown ではなく 503 を返すこと
    test('answers 503 when the storage is not open', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        await Hive.box('proxy_idempotency').close();

        final response = await _queryStatus(port, ['key-1']);
        expect(response.statusCode, equals(HttpStatus.serviceUnavailable));
        expect(response.json['error'], isA<String>());
        expect(response.json.containsKey('requests'), isFalse);
        expect(response.cacheControl, equals('no-store'));

        await expectLater(
          proxy.getRequestStatuses(['key-1']),
          throwsA(isA<QueueOperationException>()),
        );

        // キーを指定しない場合は従来どおり応答すること
        expect(
            (await _queryStatus(port, null)).statusCode, equals(HttpStatus.ok));
      });
    });

    /// べき等性キーを無効にした場合は、すべて unknown になること
    test('reports unknown when idempotency keys are disabled', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            enableIdempotencyKey: false,
          ),
        );
        await enqueueOffline(port, 'key-1');

        final status = (await proxy.getRequestStatuses(['key-1'])).single;
        expect(status.state, equals(RequestState.unknown));
        expect(await proxy.getQueuedRequests(), hasLength(1));
      });
    });

    /// 保持期間を過ぎた届いた記録は unknown になること
    test('reports unknown once the delivered record expires', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        // 定期の削除より前の、保持期間（既定 24 時間）を過ぎた記録を再現する
        final box = Hive.box('proxy_idempotency');
        await box.put(
          'key-old',
          DateTime.now().subtract(const Duration(hours: 25)).toIso8601String(),
        );
        await box.put(
          'key-new',
          DateTime.now().subtract(const Duration(hours: 23)).toIso8601String(),
        );

        final statuses = await proxy.getRequestStatuses(['key-old', 'key-new']);
        expect(statuses.map((status) => status.state), [
          RequestState.unknown,
          RequestState.delivered,
        ]);
      });
    });

    /// 保持期間で隔離から移した要求も、キー付きで履歴に残すこと
    test('records the key of a request expired from quarantine', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            quarantineRetention: const Duration(seconds: 1),
          ),
        );
        await enqueueOffline(port, 'key-1');
        final acceptedAt =
            (await proxy.getQueuedRequests()).single.acceptedAt.toUtc();
        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);

        // 保持期間を過ぎてから別の要求を隔離し、上限の判定を起こす
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await enqueueOffline(port, 'key-2');
        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getDroppedRequests()).isNotEmpty);

        final dropped = (await proxy.getDroppedRequests()).single;
        expect(dropped.dropReason, equals('quarantine_expired'));
        expect(dropped.idempotencyKey, equals('key-1'));
        expect(dropped.acceptedAt?.toUtc(), equals(acceptedAt));
        expect(
          (await proxy.getRequestStatuses(['key-1'])).single.state,
          equals(RequestState.dropped),
        );
      });
    });

    /// ドロップ履歴と送信待ちに同じキーがある場合は queued を返すこと
    test('prefers queued over dropped', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            dropPolicy: DropPolicy.drop,
          ),
        );
        await enqueueOffline(port, 'key-1');
        await _emitConnectivity(['wifi']);
        await _waitUntil(
            () async => (await proxy.getDroppedRequests()).isNotEmpty);

        await enqueueOffline(port, 'key-1');

        expect(
          (await proxy.getRequestStatuses(['key-1'])).single.state,
          equals(RequestState.queued),
        );
      });
    });

    /// HEAD でも GET と同じ検査を行うこと
    test('validates keys on HEAD as well', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        Future<int> head(List<String> keys) async {
          final client = HttpClient();
          try {
            final request = await client.openUrl(
              'HEAD',
              Uri(
                scheme: 'http',
                host: '127.0.0.1',
                port: port,
                path: _statusPath,
                queryParameters: {'idempotencyKey': keys},
              ),
            );
            final response = await request.close();
            await response.drain<void>();
            return response.statusCode;
          } finally {
            client.close(force: true);
          }
        }

        expect(await head(['key-1']), equals(HttpStatus.ok));
        expect(await head(['k' * 201]), equals(HttpStatus.badRequest));
      });
    });
  });
}
