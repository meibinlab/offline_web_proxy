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

/// ログインのパス。
const String _loginPath = '/api/login.json';

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// キューからの送信を受け取った記録。
class _Replay {
  _Replay(this.body, this.cookie);

  /// 要求の本文。
  final String body;

  /// 要求の `Cookie` ヘッダ。
  final String? cookie;
}

/// ログインと、キューからの送信への応答を切り替えられる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        if (request.uri.path == _loginPath) {
          request.response
            ..statusCode = loginStatusCode
            ..headers.add('set-cookie', 'session=new; Path=/');
          if (loginStatusCode == HttpStatus.found) {
            request.response.headers.set('location', '/');
          }
          await request.response.close();
          return;
        }

        final isReplay = request.headers.value('x-offline-replay') == '1';
        if (isReplay) {
          replays.add(_Replay(body, request.headers.value('cookie')));
          final gate = replayGate;
          if (gate != null) {
            await gate.future;
          }
        }
        final statusCode = isReplay ? replayStatusFor(body) : forwardStatusCode;
        request.response.statusCode = statusCode;
        if (statusCode >= 300 && statusCode < 400) {
          request.response.headers.set('location', '/login');
        }
        request.response.write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// キューからの送信で受け取った要求。受信順に追加される。
  final List<_Replay> replays = <_Replay>[];

  /// 最初の転送に返すステータスコード。キューへ入れるため既定は 500。
  int forwardStatusCode = HttpStatus.internalServerError;

  /// キューからの送信に返すステータスコードを、本文から決める。
  int Function(String body) replayStatusFor = (_) => HttpStatus.ok;

  /// ログインに返すステータスコード。
  int loginStatusCode = HttpStatus.ok;

  /// 指定した場合、キューからの送信への応答を完了するまで待たせる。
  Completer<void>? replayGate;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 実 HttpClient で要求を実行する。
///
/// [method] HTTP メソッド。
/// [uri] 送信先。
/// [body] 本文。
/// [idempotencyKey] 指定した場合に付けるべき等性キー。
///
/// Returns: 応答のステータスコード。
Future<int> _send(
  String method,
  Uri uri,
  String body, {
  String? idempotencyKey,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    request.write(body);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
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
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_auth_pause')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    proxy = OfflineWebProxy();
    upstream = _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    events = <ProxyEvent>[];
    subscription = proxy.events.listen(events.add);
  });

  tearDown(() async {
    upstream.replayGate?.complete();
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
      createHttpClient: _RealHttpOverrides().createHttpClient,
    );
  }

  /// proxy を起動し、上流の 5xx で更新系を順にキューへ入れる。
  ///
  /// キューの送信は 5 秒ごとの定期処理で始まるため、入れている途中で送る
  /// ことがあります。
  ///
  /// [bodies] キューへ入れる要求の本文。べき等性キーは `key-<本文>` にする。
  /// [replayStatus] キューからの送信に返すステータスコード。
  /// [authRequiredStatusCodes] 認証が必要を示すステータスコード。
  /// [authResumePaths] キューを再開させるログインのパス。
  /// [dropPolicy] 取り除いた要求の扱い。
  /// [method] 要求の HTTP メソッド。
  ///
  /// Returns: proxy のポート番号。
  Future<int> startWithQueued(
    List<String> bodies, {
    required int replayStatus,
    Set<int> authRequiredStatusCodes = const {HttpStatus.unauthorized},
    List<String> authResumePaths = const [],
    DropPolicy dropPolicy = DropPolicy.quarantine,
    String method = 'POST',
  }) async {
    upstream.replayStatusFor = (_) => replayStatus;
    final port = await proxy.start(
      config: ProxyConfig(
        origin: upstream.origin,
        authRequiredStatusCodes: authRequiredStatusCodes,
        authResumePaths: authResumePaths,
        dropPolicy: dropPolicy,
        retryBackoffSeconds: const [60],
      ),
    );
    for (final body in bodies) {
      await _send(
        method,
        Uri.parse('http://127.0.0.1:$port/api/records'),
        body,
        idempotencyKey: 'key-$body',
      );
    }
    return port;
  }

  /// 一時停止のイベントを数える。
  int pauseEventCount() => events
      .where((event) => event.type == ProxyEventType.authenticationRequired)
      .length;

  /// キューを一時停止するまで待つ。
  Future<void> waitForPause({int count = 1}) async {
    await _waitUntil(() => pauseEventCount() >= count);
    expect(pauseEventCount(), equals(count));
  }

  /// 状態通知エンドポイントの応答を取得する。
  Future<Map<String, dynamic>> fetchStatus(int port) async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'
              '?idempotencyKey=key-first'));
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  group('認証待ちの一時停止（doc/specs.ja.md 【5】認証が必要な応答での一時停止）', () {
    /// 指定しない場合は、従来どおり 401 でも隔離すること
    test('quarantines a 401 when no status code is configured', () async {
      await withRealHttpClient(() async {
        await startWithQueued(
          ['first'],
          replayStatus: HttpStatus.unauthorized,
          authRequiredStatusCodes: const {},
        );

        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined.single.reason, equals('4xx_error'));
        expect(pauseEventCount(), equals(0));
        expect((await proxy.getStats()).queuePausedReason, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 指定した状態コードでは、要求を残して後続を送らずに一時停止すること
    test('keeps the request and pauses the queue', () async {
      await withRealHttpClient(() async {
        final port = await startWithQueued(
          ['first', 'second', 'third'],
          replayStatus: HttpStatus.unauthorized,
        );

        await waitForPause();

        // 先頭の 1 件だけを送り、後続は送らないこと
        expect(
            upstream.replays.map((replay) => replay.body), equals(['first']));
        final queued = await proxy.getQueuedRequests();
        expect(queued, hasLength(3));
        // 再試行回数を増やさないこと
        expect(queued.first.retryCount, equals(0));
        expect(await proxy.getQuarantinedRequests(), isEmpty);

        final event = events.singleWhere(
            (event) => event.type == ProxyEventType.authenticationRequired);
        expect(event.url, contains('/api/records'));
        expect(event.data['statusCode'], equals(HttpStatus.unauthorized));
        expect(event.data['idempotencyKey'], equals('key-first'));
        expect(event.data['queueId'], isNotNull);

        expect((await proxy.getStats()).queuePausedReason,
            equals(QueuePauseReason.authenticationRequired));
        final status = await fetchStatus(port);
        expect(status['queuePausedReason'], equals('authenticationRequired'));
        // キーごとの照会は送信待ちのまま返すこと
        expect((status['requests'] as List).single['state'], equals('queued'));

        // 定期処理が回っても送らないこと
        await Future<void>.delayed(const Duration(seconds: 6));
        expect(upstream.replays, hasLength(1));
        expect(pauseEventCount(), equals(1));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// resumeQueue() で再開し、順に送ること。また同じ応答なら再び止まること
    test('resumes with resumeQueue and pauses again on the same answer',
        () async {
      await withRealHttpClient(() async {
        await startWithQueued(
          ['first', 'second'],
          replayStatus: HttpStatus.unauthorized,
        );
        await waitForPause();
        // 後続を入れ終えてから再開する
        expect(await proxy.getQueuedRequests(), hasLength(2));

        // ログインし直しても同じ応答なら、再び一時停止すること
        await proxy.resumeQueue();
        await waitForPause(count: 2);
        expect(upstream.replays.map((replay) => replay.body),
            equals(['first', 'first']));

        upstream.replayStatusFor = (_) => HttpStatus.ok;
        await proxy.resumeQueue();
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(upstream.replays.map((replay) => replay.body),
            equals(['first', 'first', 'first', 'second']));
        expect((await proxy.getStats()).queuePausedReason, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// authResumePaths のログインが 3xx で成功したら、新しい Cookie で送ること
    test('resumes when the sign-in path succeeds with a redirect', () async {
      await withRealHttpClient(() async {
        final port = await startWithQueued(
          ['first', 'second'],
          replayStatus: HttpStatus.unauthorized,
          authResumePaths: const [_loginPath],
        );
        await waitForPause();
        expect(await proxy.getQueuedRequests(), hasLength(2));

        // 一致しないパスの成功では再開しないこと
        upstream.forwardStatusCode = HttpStatus.ok;
        await _send('POST', Uri.parse('http://127.0.0.1:$port/api/other'), '');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(upstream.replays, hasLength(1));

        upstream.replayStatusFor = (_) => HttpStatus.ok;
        upstream.loginStatusCode = HttpStatus.found;
        final loginStatus = await _send(
          'POST',
          Uri.parse('http://127.0.0.1:$port$_loginPath'),
          'user=a',
        );
        expect(loginStatus, equals(HttpStatus.found));

        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays.map((replay) => replay.body),
            equals(['first', 'first', 'second']));
        // 再開後の送信は、ログインで受け取った Cookie を使うこと
        expect(upstream.replays.last.cookie, contains('session=new'));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// ログインが失敗した（4xx）場合は再開しないこと
    test('stays paused when the sign-in fails', () async {
      await withRealHttpClient(() async {
        final port = await startWithQueued(
          ['first'],
          replayStatus: HttpStatus.unauthorized,
          authResumePaths: const [_loginPath],
        );
        await waitForPause();

        upstream.loginStatusCode = HttpStatus.unauthorized;
        await _send(
            'POST', Uri.parse('http://127.0.0.1:$port$_loginPath'), 'bad');
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(upstream.replays, hasLength(1));
        expect((await proxy.getStats()).queuePausedReason,
            equals(QueuePauseReason.authenticationRequired));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// skipPausedRequest() は先頭の 1 件を隔離し、残りを送ること
    test('skipPausedRequest quarantines the paused request', () async {
      await withRealHttpClient(() async {
        // 一時停止していなければ何もしないこと
        await startWithQueued([], replayStatus: HttpStatus.ok);
        expect(await proxy.skipPausedRequest(), isFalse);
        await proxy.stop();

        await startWithQueued(
          ['first', 'second'],
          replayStatus: HttpStatus.unauthorized,
        );
        await waitForPause();
        expect(await proxy.getQueuedRequests(), hasLength(2));
        upstream.replayStatusFor =
            (body) => body == 'first' ? HttpStatus.unauthorized : HttpStatus.ok;

        expect(await proxy.skipPausedRequest(), isTrue);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined.single.reason, equals('authentication_required'));
        expect(quarantined.single.statusCode, equals(HttpStatus.unauthorized));
        expect(quarantined.single.idempotencyKey, equals('key-first'));
        expect(upstream.replays.map((replay) => replay.body),
            equals(['first', 'second']));
        expect(
          events.where(
              (event) => event.type == ProxyEventType.requestQuarantined),
          hasLength(1),
        );
        expect((await proxy.getStats()).queuePausedReason, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// dropPolicy が drop の場合は、ドロップ履歴へ移すこと
    test('skipPausedRequest follows DropPolicy.drop', () async {
      await withRealHttpClient(() async {
        await startWithQueued(
          ['first'],
          replayStatus: HttpStatus.unauthorized,
          dropPolicy: DropPolicy.drop,
        );
        await waitForPause();

        expect(await proxy.skipPausedRequest(), isTrue);

        expect(await proxy.getQueuedRequests(), isEmpty);
        final dropped = await proxy.getDroppedRequests();
        expect(dropped.single.dropReason, equals('authentication_required'));
        expect(dropped.single.statusCode, equals(HttpStatus.unauthorized));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 1 件で隔離の上限を超える要求は、本文を持たない履歴へ移すこと
    test('skipPausedRequest records a request too large to quarantine',
        () async {
      await withRealHttpClient(() async {
        upstream.replayStatusFor = (_) => HttpStatus.unauthorized;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            authRequiredStatusCodes: const {HttpStatus.unauthorized},
            quarantineMaxBytes: 10,
          ),
        );
        await _send(
          'POST',
          Uri.parse('http://127.0.0.1:$port/api/records'),
          'a body larger than the limit',
          idempotencyKey: 'key-large',
        );
        await waitForPause();

        expect(await proxy.skipPausedRequest(), isTrue);

        expect(await proxy.getQueuedRequests(), isEmpty);
        expect(await proxy.getQuarantinedRequests(), isEmpty);
        final dropped = await proxy.getDroppedRequests();
        expect(dropped.single.dropReason, equals('quarantine_too_large'));
        expect((await proxy.getStats()).queuePausedReason, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 3xx（ログイン画面へのリダイレクト）も指定できること
    test('pauses on a configured redirect', () async {
      await withRealHttpClient(() async {
        await startWithQueued(
          ['first'],
          replayStatus: HttpStatus.found,
          authRequiredStatusCodes: const {HttpStatus.found},
          method: 'PUT',
        );

        await waitForPause();

        expect(await proxy.getQueuedRequests(), hasLength(1));
        final event = events.singleWhere(
            (event) => event.type == ProxyEventType.authenticationRequired);
        expect(event.data['statusCode'], equals(HttpStatus.found));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 送信中にログインが成功した場合は、古いセッションの応答として止めないこと
    test('does not pause for an answer to a request sent before sign-in',
        () async {
      await withRealHttpClient(() async {
        upstream.replayGate = Completer<void>();
        await startWithQueued(['first'], replayStatus: HttpStatus.unauthorized);

        await _waitUntil(() => upstream.replays.isNotEmpty);
        await proxy.resumeQueue();
        // 次の送信は止めておき、1 回目の応答だけで判定する
        final firstGate = upstream.replayGate!;
        final secondGate = Completer<void>();
        upstream.replayGate = secondGate;
        firstGate.complete();
        await _waitUntil(() => proxy.recentResendResults
            .any((result) => result.statusCode == HttpStatus.unauthorized));

        expect((await proxy.getStats()).queuePausedReason, isNull);
        expect(pauseEventCount(), equals(0));
        expect(await proxy.getQueuedRequests(), hasLength(1));

        upstream.replayGate = null;
        secondGate.complete();
        // 次の送信で同じ応答なら一時停止すること
        await waitForPause();
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 3xx と 4xx 以外の状態コードは起動時に拒否すること
    test('rejects status codes outside 300-499', () async {
      for (final statusCode in [300, 499]) {
        await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            authRequiredStatusCodes: {statusCode},
          ),
        );
        await proxy.stop();
      }
      for (final statusCode in [299, 500]) {
        await expectLater(
          proxy.start(
            config: ProxyConfig(
              origin: upstream.origin,
              authRequiredStatusCodes: {statusCode},
            ),
          ),
          throwsA(isA<ProxyStartException>().having((error) => error.message,
              'message', contains('authRequiredStatusCodes'))),
        );
      }
    });

    /// 一時停止は停止で解除し、次の起動では先頭から送り直すこと
    test('forgets the pause when the proxy stops', () async {
      await withRealHttpClient(() async {
        await startWithQueued(['first'], replayStatus: HttpStatus.unauthorized);
        await waitForPause();

        await proxy.stop();
        expect(await proxy.skipPausedRequest(), isFalse);
        await proxy.resumeQueue();

        upstream.replayStatusFor = (_) => HttpStatus.ok;
        await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            authRequiredStatusCodes: const {HttpStatus.unauthorized},
          ),
        );
        expect((await proxy.getStats()).queuePausedReason, isNull);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
