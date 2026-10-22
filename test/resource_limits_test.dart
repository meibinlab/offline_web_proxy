import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

import 'support/access_token_http.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// ログインのパス。
const String _loginPath = '/api/login.json';

/// 更新系の要求を送るパス。
const String _recordsPath = '/api/records';

/// 本文の上限を確かめるときに指定する [ProxyConfig.maxRequestBodyBytes]。
const int _smallBodyLimit = 1024;

/// WebStorage の受け渡しで受け付ける本文の上限（5 MiB）。
const int _webStorageBodyLimit = 5 * 1024 * 1024;

/// [ProxyConfig.queueMaxBytes] に指定できる最小値（1 MiB）。
const int _minQueueBytes = 1024 * 1024;

/// secure storage に保存した暗号化鍵の名前。
const String _keyName = 'offline_web_proxy.cookie_box_encryption_key';

/// 413 応答の本文。
const String _payloadTooLargeBody =
    '{"queued":false,"error":"request_body_too_large"}';

/// 上流サーバのモック。
///
/// ログインには利用者ごとのセッションを返し、それ以外の要求には、最初の転送か
/// キューからの送信かでステータスコードを切り替えて返す。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final bytes = await request.fold<List<int>>(
          <int>[],
          (buffer, chunk) => buffer..addAll(chunk),
        );
        if (request.uri.path == _loginPath) {
          final account = (jsonDecode(utf8.decode(bytes))
              as Map<String, dynamic>)['account'] as String;
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..headers.add('set-cookie', 'session=$account; Path=/')
            ..write(jsonEncode({'ok': true}));
          await request.response.close();
          return;
        }

        final isReplay = request.headers.value('x-offline-replay') == '1';
        if (isReplay) {
          replayCount++;
        } else {
          forwardedBodyLengths.add(bytes.length);
        }
        request.response.statusCode = isReplay ? replayStatus : forwardStatus;
        request.response.write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 最初の転送で受け取った本文の長さ。受信順に追加される。
  final List<int> forwardedBodyLengths = <int>[];

  /// キューからの送信を受け取った回数。
  int replayCount = 0;

  /// 最初の転送に返すステータスコード。
  int forwardStatus = HttpStatus.ok;

  /// キューからの送信に返すステータスコード。
  int replayStatus = HttpStatus.ok;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// HTTP 応答の検証に必要な要素。
typedef _HttpResult = ({
  int statusCode,
  Map<String, String> headers,
  String body,
});

/// 実 HttpClient で要求を実行する。
///
/// [method] HTTP メソッド。
/// [uri] 送信先。
/// [body] 本文。
/// [chunked] `true` の場合は `Content-Length` を付けず chunked で送る。
/// [client] 指定した場合はそのクライアントで送り、閉じない。
/// [headers] 追加する要求ヘッダ。
///
/// Returns: 応答のステータスコード、ヘッダ、本文。
Future<_HttpResult> _send(
  String method,
  Uri uri,
  List<int> body, {
  bool chunked = false,
  HttpClient? client,
  Map<String, String> headers = const {},
}) async {
  final httpClient = client ?? HttpClient();
  try {
    final request = await httpClient.openUrl(method, uri);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    headers.forEach(request.headers.set);
    if (chunked) {
      request.headers.chunkedTransferEncoding = true;
    } else {
      request.contentLength = body.length;
    }
    request.add(body);
    final response = await request.close();
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      responseHeaders[name.toLowerCase()] = values.join(', ');
    });
    final text = await utf8.decoder.bind(response).join();
    return (
      statusCode: response.statusCode,
      headers: responseHeaders,
      body: text
    );
  } finally {
    if (client == null) {
      httpClient.close(force: true);
    }
  }
}

/// [length] バイトの本文を返す。
///
/// [length] 本文の長さ。
///
/// Returns: `a` を並べた本文。
List<int> _bodyOf(int length) => List<int>.filled(length, 0x61);

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

/// [check] が真を返すまで待機する。
///
/// [timeout] を超えた場合は待機を打ち切り、呼び出し側のアサーションに委ねます。
Future<void> _waitUntil(
  FutureOr<bool> Function() check, {
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

/// ログインの要求本文の `account` を、応答が成功を示す場合だけ返す。
String? _resolveAccount(QueueOwnerContext context) {
  if (context.responseJson case {'ok': true}) {
    return switch (context.requestJson) {
      {'account': final String account} => account,
      _ => null,
    };
  }
  return null;
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
  late _MockUpstream upstream;
  late List<ProxyEvent> events;
  StreamSubscription<ProxyEvent>? subscription;

  setUp(() async {
    hiveTestDirectory =
        Directory.systemTemp.createTempSync('offline_web_proxy_limits').path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    proxy = trackAccessToken(OfflineWebProxy());
    upstream = _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    events = <ProxyEvent>[];
    subscription = proxy.events.listen(events.add);
  });

  tearDown(() async {
    await subscription?.cancel();
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream.close();
  });

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: AccessTokenHttpOverrides().createHttpClient,
    );
  }

  /// 更新系の要求を送る先。
  Uri recordsUri(int port) => Uri.parse('http://127.0.0.1:$port$_recordsPath');

  /// 413 応答の内容を確かめる。
  void expectPayloadTooLarge(_HttpResult result) {
    expect(result.statusCode, equals(HttpStatus.requestEntityTooLarge));
    expect(result.headers['cache-control'], equals('no-store'));
    expect(result.headers['x-offline-queued'], equals('0'));
    expect(result.headers['connection'], equals('close'));
    expect(result.body, equals(_payloadTooLargeBody));
  }

  /// キューの上限で保存しなかった 503 応答の内容を確かめる。
  void expectQueueRefused(_HttpResult result) {
    expect(result.statusCode, equals(HttpStatus.serviceUnavailable));
    expect(result.headers['x-offline-queued'], equals('0'));
    expect(result.body, equals('{"queued":false,"error":"queue_full"}'));
  }

  /// キューの上限で保存しなかったことを知らせたイベントの `limit` の一覧。
  List<Object?> queueLimitEvents() => events
      .where((event) =>
          event.type == ProxyEventType.errorOccurred &&
          event.data['phase'] == 'queueLimit')
      .map((event) => event.data['limit'])
      .toList();

  group('要求本文の上限（doc/specs.ja.md 【5】保持上限）', () {
    /// 上限ちょうどの本文は受け付け、1 バイト超えると転送せずに 413 を返すこと
    test('accepts a body at the limit and refuses one byte more', () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            maxRequestBodyBytes: _smallBodyLimit,
          ),
        );

        for (final chunked in [false, true]) {
          final accepted = await _send(
            'POST',
            recordsUri(port),
            _bodyOf(_smallBodyLimit),
            chunked: chunked,
          );
          expect(accepted.statusCode, equals(HttpStatus.ok),
              reason: 'chunked: $chunked');

          final refused = await _send(
            'POST',
            recordsUri(port),
            _bodyOf(_smallBodyLimit + 1),
            chunked: chunked,
          );
          expectPayloadTooLarge(refused);
        }

        // 上流へ届いたのは上限ちょうどの 2 件だけで、キューにも入れないこと
        expect(upstream.forwardedBodyLengths,
            equals([_smallBodyLimit, _smallBodyLimit]));
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// オフラインでも 413 を返し、キューへ入れないこと
    test('refuses a too large body offline without queueing it', () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            maxRequestBodyBytes: _smallBodyLimit,
          ),
        );
        await _emitConnectivity(['none']);

        for (final chunked in [false, true]) {
          final refused = await _send(
            'POST',
            recordsUri(port),
            _bodyOf(_smallBodyLimit + 1),
            chunked: chunked,
          );
          expectPayloadTooLarge(refused);
        }
        expect(await proxy.getQueuedRequests(), isEmpty);

        // 上限ちょうどの本文はキューへ入れること
        final queued = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(_smallBodyLimit),
        );
        expect(queued.statusCode, equals(HttpStatus.accepted));
        expect(await proxy.getQueuedRequests(), hasLength(1));
        expect(queueLimitEvents(), isEmpty);
      });
    });

    /// 本文を読み切らずに 413 を返しても、同じクライアントの後続の要求が
    /// 正しく処理されること
    test('keeps later requests of the same client working after a 413',
        () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            maxRequestBodyBytes: _smallBodyLimit,
          ),
        );

        final client = HttpClient();
        try {
          for (final chunked in [false, true]) {
            // 送り終える前に応答が返る大きさの本文で確かめる
            final refused = await _send(
              'POST',
              recordsUri(port),
              _bodyOf(256 * 1024),
              chunked: chunked,
              client: client,
            );
            expectPayloadTooLarge(refused);

            final next = await _send(
              'POST',
              recordsUri(port),
              utf8.encode('{"next":true}'),
              client: client,
            );
            expect(next.statusCode, equals(HttpStatus.ok),
                reason: 'chunked: $chunked');
          }
        } finally {
          client.close(force: true);
        }

        expect(upstream.forwardedBodyLengths, hasLength(2));
      });
    });

    /// 読み捨てる上限（16 MiB）を超える本文は読まずに接続を閉じ、その後の要求は
    /// 処理できること
    test('closes the connection for a body far beyond the limit', () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            maxRequestBodyBytes: _smallBodyLimit,
          ),
        );

        // 応答を受け取れるか、送る途中で接続を閉じられるかは送り方による
        try {
          final refused = await _send(
            'POST',
            recordsUri(port),
            _bodyOf(_smallBodyLimit + 17 * 1024 * 1024),
          );
          expectPayloadTooLarge(refused);
        } on IOException {
          // 本文を読まずに接続を閉じたため、送信が失敗した
        }

        final next = await _send(
          'POST',
          recordsUri(port),
          utf8.encode('{"next":true}'),
        );
        expect(next.statusCode, equals(HttpStatus.ok));
        expect(upstream.forwardedBodyLengths, hasLength(1));
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// WebStorage の受け渡しは、maxRequestBodyBytes と 5 MiB の小さい方を上限にすること
    test('limits the WebStorage bridge body', () async {
      await withRealHttpClient(() async {
        var port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            enableWebStorageInheritance: true,
          ),
        );
        final bridgePath = '/__offline_web_proxy/web_storage';
        var bridgeUri = Uri.parse('http://127.0.0.1:$port$bridgePath');
        // POST は proxy 自身の origin の Origin が必須
        var origin = {'origin': 'http://127.0.0.1:$port'};

        // 既定（10 MiB）より小さい 5 MiB が上限になること
        final atLimit = await _send(
          'POST',
          bridgeUri,
          _bodyOf(_webStorageBodyLimit),
          headers: origin,
        );
        expect(atLimit.statusCode, equals(HttpStatus.ok));
        final overLimit = await _send(
          'POST',
          bridgeUri,
          _bodyOf(_webStorageBodyLimit + 1),
          headers: origin,
        );
        expectPayloadTooLarge(overLimit);
        final chunkedOverLimit = await _send(
          'POST',
          bridgeUri,
          _bodyOf(_webStorageBodyLimit + 1),
          chunked: true,
          headers: origin,
        );
        expectPayloadTooLarge(chunkedOverLimit);

        // maxRequestBodyBytes の方が小さい場合はそちらが上限になること
        await proxy.stop();
        port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            enableWebStorageInheritance: true,
            maxRequestBodyBytes: _smallBodyLimit,
          ),
        );
        bridgeUri = Uri.parse('http://127.0.0.1:$port$bridgePath');
        origin = {'origin': 'http://127.0.0.1:$port'};
        final small = await _send(
          'POST',
          bridgeUri,
          _bodyOf(_smallBodyLimit),
          headers: origin,
        );
        expect(small.statusCode, equals(HttpStatus.ok));
        final tooLarge = await _send(
          'POST',
          bridgeUri,
          _bodyOf(_smallBodyLimit + 1),
          headers: origin,
        );
        expectPayloadTooLarge(tooLarge);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('キューの上限（doc/specs.ja.md 【5】保持上限）', () {
    /// 件数の上限に達した後の要求は保存せず、503 とイベントで知らせること
    test('refuses a request beyond queueMaxCount', () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream.origin, queueMaxCount: 2),
        );
        await _emitConnectivity(['none']);

        for (var i = 0; i < 2; i++) {
          final queued = await _send(
            'POST',
            recordsUri(port),
            utf8.encode('{"index":$i}'),
          );
          expect(queued.statusCode, equals(HttpStatus.accepted));
        }

        final refused = await _send(
          'POST',
          recordsUri(port),
          utf8.encode('{"index":2}'),
        );
        expectQueueRefused(refused);
        expect(await proxy.getQueuedRequests(), hasLength(2));
        expect(queueLimitEvents(), equals(['count']));

        // 保存しなかった要求を投入として知らせないこと
        expect(
          events.where((event) => event.type == ProxyEventType.requestQueued),
          hasLength(2),
        );
      });
    });

    /// 合計サイズの上限を超える要求と、1 件で上限を超える要求を保存しないこと
    test('refuses a request beyond queueMaxBytes', () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            queueMaxBytes: _minQueueBytes,
          ),
        );
        await _emitConnectivity(['none']);

        // 1 件で上限を超える要求は、キューが空でも保存しないこと
        final single = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(_minQueueBytes + 1),
        );
        expectQueueRefused(single);
        expect(await proxy.getQueuedRequests(), isEmpty);

        final first = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(_minQueueBytes ~/ 2),
        );
        expect(first.statusCode, equals(HttpStatus.accepted));

        // 合わせると上限を超える要求は保存しないこと
        final second = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(_minQueueBytes ~/ 2),
        );
        expectQueueRefused(second);

        // 空きに収まる要求は保存すること
        final small = await _send(
          'POST',
          recordsUri(port),
          utf8.encode('{"small":true}'),
        );
        expect(small.statusCode, equals(HttpStatus.accepted));

        expect(await proxy.getQueuedRequests(), hasLength(2));
        expect(queueLimitEvents(), equals(['bytes', 'bytes']));
      });
    });

    /// 上流の 5xx でキューへ入れられない場合は、上流の応答をそのまま返すこと
    test('returns the upstream 5xx when the queue is full', () async {
      await withRealHttpClient(() async {
        upstream
          ..forwardStatus = HttpStatus.internalServerError
          ..replayStatus = HttpStatus.internalServerError;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            queueMaxCount: 1,
            retryBackoffSeconds: const [60],
          ),
        );

        final queued =
            await _send('POST', recordsUri(port), utf8.encode('{"i":0}'));
        expect(queued.statusCode, equals(HttpStatus.internalServerError));
        expect(queued.headers['x-offline-queued'], equals('1'));

        final refused =
            await _send('POST', recordsUri(port), utf8.encode('{"i":1}'));
        expect(refused.statusCode, equals(HttpStatus.internalServerError));
        expect(refused.headers['x-offline-queued'], isNull);
        expect(await proxy.getQueuedRequests(), hasLength(1));
        expect(queueLimitEvents(), equals(['count']));
      });
    });

    /// 再起動の後も、保存済みの要求の大きさを数えて上限を判定すること
    test('counts the stored bytes again after a restart', () async {
      await withRealHttpClient(() async {
        // キューから送っても成功させず、再起動の後も残す
        upstream.replayStatus = HttpStatus.internalServerError;
        final config = ProxyConfig(
          origin: upstream.origin,
          queueMaxBytes: _minQueueBytes,
          retryBackoffSeconds: const [60],
        );
        var port = await proxy.start(config: config);
        await _emitConnectivity(['none']);
        final first = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(_minQueueBytes * 3 ~/ 5),
        );
        expect(first.statusCode, equals(HttpStatus.accepted));

        await proxy.stop();
        port = await proxy.start(config: config);
        await _emitConnectivity(['none']);
        expect(await proxy.getQueuedRequests(), hasLength(1));

        final second = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(_minQueueBytes * 3 ~/ 5),
        );
        expectQueueRefused(second);
        expect(queueLimitEvents(), equals(['bytes']));

        final small = await _send(
          'POST',
          recordsUri(port),
          utf8.encode('{"small":true}'),
        );
        expect(small.statusCode, equals(HttpStatus.accepted));
      });
    });

    /// 起動時に上限を超えていても既存の要求は消さず、新しい要求だけを断ること
    test('keeps stored requests that exceed a lowered limit', () async {
      await withRealHttpClient(() async {
        upstream.replayStatus = HttpStatus.internalServerError;
        var port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            retryBackoffSeconds: const [60],
          ),
        );
        await _emitConnectivity(['none']);
        for (var i = 0; i < 3; i++) {
          final queued = await _send(
            'POST',
            recordsUri(port),
            utf8.encode('{"index":$i}'),
          );
          expect(queued.statusCode, equals(HttpStatus.accepted));
        }

        await proxy.stop();
        port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            queueMaxCount: 1,
            retryBackoffSeconds: const [60],
          ),
        );
        await _emitConnectivity(['none']);
        expect(await proxy.getQueuedRequests(), hasLength(3));

        final refused = await _send(
          'POST',
          recordsUri(port),
          utf8.encode('{"index":3}'),
        );
        expectQueueRefused(refused);
        expect(await proxy.getQueuedRequests(), hasLength(3));
      });
    });
  });

  group('キューから取り除いた後の投入（doc/specs.ja.md 【5】保持上限）', () {
    /// 件数の上限 1 で 1 件をキューへ入れ、次の 1 件が断られることを確かめる。
    ///
    /// Returns: proxy のポート番号。
    Future<int> fillQueue(ProxyConfig config) async {
      final port = await proxy.start(config: config);
      await _emitConnectivity(['none']);
      final queued =
          await _send('POST', recordsUri(port), utf8.encode('{"first":1}'));
      expect(queued.statusCode, equals(HttpStatus.accepted));
      final refused =
          await _send('POST', recordsUri(port), utf8.encode('{"second":1}'));
      expectQueueRefused(refused);
      return port;
    }

    /// オフラインへ戻して 1 件を投入し、受け付けられることを確かめる。
    Future<void> expectQueueAcceptsAgain(int port) async {
      await _emitConnectivity(['none']);
      final again =
          await _send('POST', recordsUri(port), utf8.encode('{"again":1}'));
      expect(again.statusCode, equals(HttpStatus.accepted));
      expect(await proxy.getQueuedRequests(), hasLength(1));
    }

    /// 再送に成功して取り除いた後に、再び投入できること
    test('accepts again after a successful resend', () async {
      await withRealHttpClient(() async {
        final port = await fillQueue(
          ProxyConfig(origin: upstream.origin, queueMaxCount: 1),
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replayCount, equals(1));

        await expectQueueAcceptsAgain(port);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 隔離とドロップで取り除いた後に、再び投入できること
    for (final policy in [DropPolicy.quarantine, DropPolicy.drop]) {
      test('accepts again after the request is removed by ${policy.name}',
          () async {
        await withRealHttpClient(() async {
          upstream.replayStatus = HttpStatus.badRequest;
          final port = await fillQueue(
            ProxyConfig(
              origin: upstream.origin,
              queueMaxCount: 1,
              dropPolicy: policy,
            ),
          );

          await _emitConnectivity(['wifi']);
          await _waitUntil(
              () async => (await proxy.getQueuedRequests()).isEmpty);
          if (policy == DropPolicy.quarantine) {
            expect(await proxy.getQuarantinedRequests(), hasLength(1));
          } else {
            expect(await proxy.getDroppedRequests(), hasLength(1));
          }

          await expectQueueAcceptsAgain(port);
        });
      }, timeout: const Timeout(Duration(seconds: 90)));
    }

    /// 一時停止させた要求を取り除いた後に、再び投入できること
    test('accepts again after skipPausedRequest()', () async {
      await withRealHttpClient(() async {
        upstream.replayStatus = HttpStatus.unauthorized;
        final port = await fillQueue(
          ProxyConfig(
            origin: upstream.origin,
            queueMaxCount: 1,
            authRequiredStatusCodes: const {HttpStatus.unauthorized},
          ),
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async =>
            (await proxy.getStats()).queuePausedReason ==
            QueuePauseReason.authenticationRequired);
        expect(await proxy.skipPausedRequest(), isTrue);
        expect(await proxy.getQueuedRequests(), isEmpty);

        await expectQueueAcceptsAgain(port);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 別の利用者のログインで owner_changed として取り除いた後に、再び投入できること
    test('accepts again after the owner changed', () async {
      await withRealHttpClient(() async {
        upstream.replayStatus = HttpStatus.unauthorized;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            queueMaxCount: 1,
            authRequiredStatusCodes: const {HttpStatus.unauthorized},
            authResumePaths: const [_loginPath],
            queueOwnerResolver: _resolveAccount,
          ),
        );
        final loginUri = Uri.parse('http://127.0.0.1:$port$_loginPath');
        final alice = await _send(
            'POST', loginUri, utf8.encode(jsonEncode({'account': 'alice'})));
        expect(alice.statusCode, equals(HttpStatus.ok));

        await _emitConnectivity(['none']);
        final queued =
            await _send('POST', recordsUri(port), utf8.encode('{"first":1}'));
        expect(queued.statusCode, equals(HttpStatus.accepted));
        expectQueueRefused(
          await _send('POST', recordsUri(port), utf8.encode('{"second":1}')),
        );

        // 認証待ちで止めてから別の利用者でログインする
        await _emitConnectivity(['wifi']);
        await _waitUntil(() async =>
            (await proxy.getStats()).queuePausedReason ==
            QueuePauseReason.authenticationRequired);
        final bob = await _send(
            'POST', loginUri, utf8.encode(jsonEncode({'account': 'bob'})));
        expect(bob.statusCode, equals(HttpStatus.ok));
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined.single.reason, equals('owner_changed'));

        await expectQueueAcceptsAgain(port);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 隔離から戻した要求は、件数の上限で断らないこと
    test('moves a quarantined request back even when the queue is full',
        () async {
      await withRealHttpClient(() async {
        upstream.replayStatus = HttpStatus.badRequest;
        final port = await fillQueue(
          ProxyConfig(origin: upstream.origin, queueMaxCount: 1),
        );
        await _emitConnectivity(['wifi']);
        // 隔離へ書き込んでからキューから消す。キューに残っている間は件数の
        // 上限で次の投入を断るため、両方を待つ
        await _waitUntil(() async =>
            (await proxy.getQuarantinedRequests()).isNotEmpty &&
            (await proxy.getQueuedRequests()).isEmpty);

        await _emitConnectivity(['none']);
        final queued =
            await _send('POST', recordsUri(port), utf8.encode('{"third":1}'));
        expect(queued.statusCode, equals(HttpStatus.accepted));

        final id = (await proxy.getQuarantinedRequests()).single.id;
        expect(await proxy.retryQuarantinedRequest(id), isTrue);
        expect(await proxy.getQueuedRequests(), hasLength(2));
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 保存領域の復旧で消えたキューへ、再び投入できること
    test('accepts again after recoverEncryptedStorage()', () async {
      await withRealHttpClient(() async {
        final config = ProxyConfig(origin: upstream.origin, queueMaxCount: 1);
        var port = await fillQueue(config);
        await proxy.stop();

        // 鍵を壊して起動できなくし、復旧 API で暗号化 Box を削除させる
        await const FlutterSecureStorage().write(key: _keyName, value: 'x');
        await expectLater(
          proxy.start(config: config),
          throwsA(isA<StorageIntegrityException>()),
        );
        final recovery = await proxy.recoverEncryptedStorage();
        expect(recovery.performed, isTrue);

        port = await proxy.start(config: config);
        expect(await proxy.getQueuedRequests(), isEmpty);
        await expectQueueAcceptsAgain(port);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('キューの上限の境界と同時の投入（doc/specs.ja.md 【5】保持上限）', () {
    /// 同時に届いた要求が、件数の上限を超えて保存されないこと
    test('stores only up to queueMaxCount among concurrent requests', () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream.origin, queueMaxCount: 1),
        );
        await _emitConnectivity(['none']);

        final results = await Future.wait([
          for (var i = 0; i < 5; i++)
            _send('POST', recordsUri(port), utf8.encode('{"index":$i}')),
        ]);

        final accepted = results
            .where((result) => result.statusCode == HttpStatus.accepted)
            .toList();
        final refused = results
            .where((result) => result.statusCode != HttpStatus.accepted)
            .toList();
        expect(accepted, hasLength(1));
        expect(refused, hasLength(4));
        refused.forEach(expectQueueRefused);
        expect(await proxy.getQueuedRequests(), hasLength(1));
        expect(queueLimitEvents(), equals(List.filled(4, 'count')));
      });
    });

    /// 満杯でも、同じべき等性キーで送り直した要求は既存のキュー ID で受け付けること
    test('accepts a resend with the same idempotency key when full', () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream.origin, queueMaxCount: 1),
        );
        await _emitConnectivity(['none']);
        const keyHeader = {'Idempotency-Key': 'same-key'};

        final first = await _send(
          'POST',
          recordsUri(port),
          utf8.encode('{"first":1}'),
          headers: keyHeader,
        );
        expect(first.statusCode, equals(HttpStatus.accepted));

        final again = await _send(
          'POST',
          recordsUri(port),
          utf8.encode('{"first":1}'),
          headers: keyHeader,
        );
        expect(again.statusCode, equals(HttpStatus.accepted));
        expect(again.headers['x-offline-queue-id'],
            equals(first.headers['x-offline-queue-id']));
        expect(await proxy.getQueuedRequests(), hasLength(1));
        expect(queueLimitEvents(), isEmpty);
      });
    });

    /// オフラインで queueExcludePaths に一致する要求は、本文が上限を超えても
    /// 本文を読まずに除外の応答を返すこと
    test('answers an excluded request without reading a too large body',
        () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            maxRequestBodyBytes: _smallBodyLimit,
            queueExcludePaths: const [QueueExcludeRule(path: _recordsPath)],
          ),
        );
        await _emitConnectivity(['none']);

        final excluded = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(_smallBodyLimit + 1),
        );
        expect(excluded.statusCode, equals(HttpStatus.serviceUnavailable));
        expect(excluded.body, equals('{"queued":false,"offline":true}'));
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// chunked の本文が上限を 16 MiB より多く超えた場合は読むのをやめ、
    /// その後の要求は処理できること
    test('stops reading a chunked body far beyond the limit', () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            maxRequestBodyBytes: _smallBodyLimit,
          ),
        );

        // 応答を受け取れるか、送る途中で接続を閉じられるかは送り方による
        try {
          final refused = await _send(
            'POST',
            recordsUri(port),
            _bodyOf(_smallBodyLimit + 17 * 1024 * 1024),
            chunked: true,
          );
          expectPayloadTooLarge(refused);
        } on IOException {
          // 読むのをやめて接続を閉じたため、送信が失敗した
        }

        final next = await _send(
          'POST',
          recordsUri(port),
          utf8.encode('{"next":true}'),
        );
        expect(next.statusCode, equals(HttpStatus.ok));
        expect(upstream.forwardedBodyLengths, hasLength(1));
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// 合計が queueMaxBytes ちょうどになる要求は保存し、1 バイト超える要求は
    /// 保存しないこと
    test('accepts a request that fills queueMaxBytes exactly', () async {
      await withRealHttpClient(() async {
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            queueMaxBytes: _minQueueBytes,
          ),
        );
        await _emitConnectivity(['none']);

        // 本文の長さの桁をそろえ、Content-Length の値の長さを変えない
        const firstBodyLength = 100000;
        final first = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(firstBodyLength),
        );
        expect(first.statusCode, equals(HttpStatus.accepted));

        // 保存された URL とヘッダから、本文以外の大きさを求める
        final stored = (await proxy.getQueuedRequests()).single;
        var overhead = utf8.encode(stored.url).length;
        stored.headers.forEach((name, value) {
          // 値を伏せたヘッダがあると大きさを求められない
          expect(value, isNot(equals('***')), reason: name);
          overhead += utf8.encode(name).length + utf8.encode(value).length;
        });
        final firstSize = overhead + firstBodyLength;
        final remainingBody = _minQueueBytes - firstSize - overhead;
        expect(remainingBody.toString().length,
            equals(firstBodyLength.toString().length));

        final over = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(remainingBody + 1),
        );
        expectQueueRefused(over);

        final exact = await _send(
          'POST',
          recordsUri(port),
          _bodyOf(remainingBody),
        );
        expect(exact.statusCode, equals(HttpStatus.accepted));
        expect(await proxy.getQueuedRequests(), hasLength(2));
        expect(queueLimitEvents(), equals(['bytes']));
      });
    });
  });

  group('上限の設定の検証（doc/specs.ja.md 【20】設定一覧）', () {
    /// 範囲外の値では起動しないこと
    for (final entry in <String, ProxyConfig Function(String origin)>{
      'maxRequestBodyBytes below 1024': (origin) =>
          ProxyConfig(origin: origin, maxRequestBodyBytes: 1023),
      'maxRequestBodyBytes above 256 MiB': (origin) => ProxyConfig(
          origin: origin, maxRequestBodyBytes: 256 * 1024 * 1024 + 1),
      'queueMaxCount below 1': (origin) =>
          ProxyConfig(origin: origin, queueMaxCount: 0),
      'queueMaxCount above 100000': (origin) =>
          ProxyConfig(origin: origin, queueMaxCount: 100001),
      'queueMaxBytes below 1 MiB': (origin) =>
          ProxyConfig(origin: origin, queueMaxBytes: _minQueueBytes - 1),
      'queueMaxBytes above 1 GiB': (origin) =>
          ProxyConfig(origin: origin, queueMaxBytes: 1024 * 1024 * 1024 + 1),
    }.entries) {
      test('refuses to start with ${entry.key}', () async {
        await expectLater(
          proxy.start(config: entry.value(upstream.origin)),
          throwsA(isA<ProxyStartException>()),
        );
        expect(proxy.isRunning, isFalse);
      });
    }

    /// 範囲の両端の値では起動すること
    test('starts with the bounds of each range', () async {
      for (final config in [
        ProxyConfig(
          origin: upstream.origin,
          maxRequestBodyBytes: 1024,
          queueMaxCount: 1,
          queueMaxBytes: _minQueueBytes,
        ),
        ProxyConfig(
          origin: upstream.origin,
          maxRequestBodyBytes: 256 * 1024 * 1024,
          queueMaxCount: 100000,
          queueMaxBytes: 1024 * 1024 * 1024,
        ),
      ]) {
        await proxy.start(config: config);
        expect(proxy.isRunning, isTrue);
        await proxy.stop();
      }
    });

    /// 既定値が設計どおりであること
    test('uses the documented defaults', () {
      const config = ProxyConfig(origin: 'https://example.com');
      expect(config.maxRequestBodyBytes, equals(10 * 1024 * 1024));
      expect(config.queueMaxCount, equals(1000));
      expect(config.queueMaxBytes, equals(50 * 1024 * 1024));
    });
  });
}
