import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';

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

/// ログインした利用者ごとにセッションを返す上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        if (request.uri.path == _loginPath) {
          if (!loginReceived.isCompleted) {
            loginReceived.complete();
          }
          final gate = loginGate;
          if (gate != null) {
            await gate.future;
          }
          // GET のログインはクエリで、それ以外は JSON の本文で利用者を受け取る
          final account = request.method == 'GET'
              ? request.uri.queryParameters['account']!
              : (jsonDecode(body) as Map<String, dynamic>)['account'] as String;
          request.response
            ..statusCode =
                request.method == 'GET' ? HttpStatus.found : HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..headers.add('set-cookie', 'session=$account; Path=/')
            ..write(jsonEncode({'ok': loginSucceeds}));
          await request.response.close();
          return;
        }

        final isReplay = request.headers.value('x-offline-replay') == '1';
        if (isReplay) {
          replays.add(_Replay(body, request.headers.value('cookie')));
        }
        request.response.statusCode =
            isReplay ? replayStatusFor(body) : forwardStatusCode;
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

  /// ログインの応答本文の `ok` に入れる値。
  bool loginSucceeds = true;

  /// 指定した場合、ログインへの応答を完了するまで待たせる。
  Completer<void>? loginGate;

  /// ログインを受け取ったときに完了する。待つ前に作り直す。
  Completer<void> loginReceived = Completer<void>();

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
    request.headers.contentType = ContentType.json;
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
        Directory.systemTemp.createTempSync('offline_web_proxy_owner').path;
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
    final gate = upstream.loginGate;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
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

  /// proxy を起動する。
  ///
  /// [resolver] 持ち主の判定関数。
  /// [dropPolicy] 取り除いた要求の扱い。
  /// [retryBackoffSeconds] 再送の間隔。
  ///
  /// Returns: proxy のポート番号。
  Future<int> startProxy({
    QueueOwnerResolver? resolver = _resolveAccount,
    DropPolicy dropPolicy = DropPolicy.quarantine,
    List<int> retryBackoffSeconds = const [60],
  }) {
    return proxy.start(
      config: ProxyConfig(
        origin: upstream.origin,
        authRequiredStatusCodes: const {HttpStatus.unauthorized},
        authResumePaths: const [_loginPath],
        queueOwnerResolver: resolver,
        dropPolicy: dropPolicy,
        retryBackoffSeconds: retryBackoffSeconds,
      ),
    );
  }

  /// proxy を通してログインする。
  Future<void> signIn(int port, String account) async {
    final status = await _send(
      'POST',
      Uri.parse('http://127.0.0.1:$port$_loginPath'),
      jsonEncode({'account': account}),
    );
    expect(status, equals(HttpStatus.ok));
  }

  /// 上流の 5xx で、更新系を順にキューへ入れる。
  Future<void> enqueue(int port, List<String> bodies) async {
    for (final body in bodies) {
      await _send(
        'POST',
        Uri.parse('http://127.0.0.1:$port/api/records'),
        body,
        idempotencyKey: 'key-$body',
      );
    }
  }

  /// 認証待ちで一時停止するまで待つ。
  Future<void> waitForPause({int count = 1}) async {
    await _waitUntil(() =>
        events
            .where(
                (event) => event.type == ProxyEventType.authenticationRequired)
            .length >=
        count);
    expect((await proxy.getStats()).queuePausedReason,
        equals(QueuePauseReason.authenticationRequired));
  }

  /// 状態通知エンドポイントの応答を取得する。
  Future<Map<String, dynamic>> fetchStatus(int port) async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'
              '?idempotencyKey=key-photo'));
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  /// A がログインして 3 件をキューへ入れ、セッション切れで一時停止させる。
  ///
  /// Returns: proxy のポート番号。
  Future<int> queueForUserAAndPause({
    QueueOwnerResolver? resolver = _resolveAccount,
    DropPolicy dropPolicy = DropPolicy.quarantine,
  }) async {
    upstream.replayStatusFor = (_) => HttpStatus.unauthorized;
    final port = await startProxy(resolver: resolver, dropPolicy: dropPolicy);
    await signIn(port, 'alice');
    await enqueue(port, ['photo', 'vehicle', 'home']);
    await waitForPause();
    expect(await proxy.getQueuedRequests(), hasLength(3));
    expect(upstream.replays.map((replay) => replay.body), equals(['photo']));
    return port;
  }

  group('送信待ちの持ち主（doc/specs.ja.md 【5】送信待ちの持ち主）', () {
    /// 別の利用者がログインした場合は、1 件も送らずに owner_changed で隔離すること
    test('quarantines every request of another owner after a sign-in',
        () async {
      await withRealHttpClient(() async {
        final port = await queueForUserAAndPause();
        upstream.replayStatusFor = (_) => HttpStatus.ok;

        await signIn(port, 'bob');
        // キューから消した後で再送結果を記録するため、結果がそろうまで待つ
        await _waitUntil(() async =>
            (await proxy.getQueuedRequests()).isEmpty &&
            proxy.recentResendResults
                    .where((result) => result.dropReason == 'owner_changed')
                    .length ==
                3);

        // 一時停止の前に送った 1 件のほかは、上流へ送らないこと
        expect(upstream.replays, hasLength(1));
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined, hasLength(3));
        for (final request in quarantined) {
          expect(request.reason, equals('owner_changed'));
          expect(request.statusCode, equals(0));
          expect(request.errorMessage, equals('Queue owner changed'));
        }
        expect(
          quarantined.map((request) => request.idempotencyKey).toSet(),
          equals({'key-photo', 'key-vehicle', 'key-home'}),
        );

        final quarantineEvents = events
            .where((event) => event.type == ProxyEventType.requestQuarantined)
            .toList();
        expect(quarantineEvents, hasLength(3));
        for (final event in quarantineEvents) {
          expect(event.data['reason'], equals('owner_changed'));
          expect(event.data['statusCode'], equals(0));
        }
        final results = proxy.recentResendResults
            .where((result) => result.dropReason == 'owner_changed');
        expect(results, hasLength(3));
        expect(results.every((result) => !result.willRetry), isTrue);
        expect((await proxy.getStats()).queuePausedReason, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 同じ利用者がログインし直した場合は、今までどおり新しいセッションで送ること
    test('sends the requests when the same owner signs in again', () async {
      await withRealHttpClient(() async {
        final port = await queueForUserAAndPause();
        upstream.replayStatusFor = (_) => HttpStatus.ok;

        await signIn(port, 'alice');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(upstream.replays.map((replay) => replay.body),
            equals(['photo', 'photo', 'vehicle', 'home']));
        expect(upstream.replays.last.cookie, contains('session=alice'));
        expect(await proxy.getQuarantinedRequests(), isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 判定関数を設定しない場合は、0.24.0 と同じく別の利用者のセッションでも送ること
    test('keeps the previous behaviour without a resolver', () async {
      await withRealHttpClient(() async {
        final port = await queueForUserAAndPause(resolver: null);
        upstream.replayStatusFor = (_) => HttpStatus.ok;

        await signIn(port, 'bob');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(upstream.replays.map((replay) => replay.body),
            equals(['photo', 'photo', 'vehicle', 'home']));
        expect(upstream.replays.last.cookie, contains('session=bob'));
        expect(await proxy.getQuarantinedRequests(), isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 一時停止していないときのログインでも、別の持ち主の要求は送らないこと
    test('moves requests of another owner when the queue is not paused',
        () async {
      await withRealHttpClient(() async {
        // 503 で再試行の待ちに入れ、一時停止させずにキューへ残す
        upstream.replayStatusFor = (_) => HttpStatus.serviceUnavailable;
        final port = await startProxy(retryBackoffSeconds: const [1]);
        await signIn(port, 'alice');
        await enqueue(port, ['photo']);
        await _waitUntil(() => upstream.replays.isNotEmpty);
        expect((await proxy.getStats()).queuePausedReason, isNull);

        upstream.replayStatusFor = (_) => HttpStatus.ok;
        final replaysBeforeSignIn = upstream.replays.length;
        await signIn(port, 'bob');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(upstream.replays, hasLength(replaysBeforeSignIn));
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined.single.reason, equals('owner_changed'));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 判定関数が null を返した場合は、持ち主を変えずに今までどおり再開すること
    test('keeps the owner when the resolver returns null', () async {
      await withRealHttpClient(() async {
        final port = await queueForUserAAndPause();

        // パスワードの誤りを 200 で返すサーバ
        upstream.loginSucceeds = false;
        await signIn(port, 'bob');
        // 再開して先頭を送り直し、同じ 401 で再び一時停止すること
        await waitForPause(count: 2);
        expect(await proxy.getQuarantinedRequests(), isEmpty);
        expect(await proxy.getQueuedRequests(), hasLength(3));

        // 持ち主は A のままのため、A のログインで送ること
        upstream.loginSucceeds = true;
        upstream.replayStatusFor = (_) => HttpStatus.ok;
        await signIn(port, 'alice');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(await proxy.getQuarantinedRequests(), isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 判定関数が例外を投げた場合は、キューを止め、再開すると隔離すること
    test('pauses the queue when the resolver throws', () async {
      await withRealHttpClient(() async {
        var shouldThrow = false;
        String? resolver(QueueOwnerContext context) {
          if (shouldThrow) {
            throw StateError('broken resolver');
          }
          return _resolveAccount(context);
        }

        final port = await queueForUserAAndPause(resolver: resolver);
        upstream.replayStatusFor = (_) => HttpStatus.ok;

        shouldThrow = true;
        await signIn(port, 'bob');
        expect((await proxy.getStats()).queuePausedReason,
            equals(QueuePauseReason.ownerUnresolved));
        final error = events
            .singleWhere((event) => event.type == ProxyEventType.errorOccurred);
        expect(error.data['phase'], equals('queueOwnerResolve'));
        // 例外の文字列には本文の抜粋が入り得るため、型の名前だけを載せること
        expect(error.data['error'], equals('StateError'));
        expect(error.url, contains('api/login.json'));

        // 定期処理が回っても送らないこと。skipPausedRequest() の対象外であること
        await Future<void>.delayed(const Duration(seconds: 6));
        expect(upstream.replays, hasLength(1));
        expect(await proxy.skipPausedRequest(), isFalse);

        // 再開すると、別の持ち主として隔離すること
        await proxy.resumeQueue();
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays, hasLength(1));
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined, hasLength(3));
        expect(
            quarantined.every((request) => request.reason == 'owner_changed'),
            isTrue);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 隔離から送り直しても、持ち主を引き継いで別の利用者のセッションでは送らないこと
    test('keeps the owner when a quarantined request is retried', () async {
      await withRealHttpClient(() async {
        final port = await queueForUserAAndPause();
        upstream.replayStatusFor = (_) => HttpStatus.ok;
        await signIn(port, 'bob');
        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).length == 3);

        // B のログイン中は、送り直しても再び隔離すること
        final first = (await proxy.getQuarantinedRequests()).first;
        expect(await proxy.retryQuarantinedRequest(first.id), isTrue);
        await _waitUntil(() async =>
            (await proxy.getQueuedRequests()).isEmpty &&
            (await proxy.getQuarantinedRequests()).length == 3);
        expect(upstream.replays, hasLength(1));
        expect(await proxy.getQuarantinedRequests(), hasLength(3));

        // A がログインし直せば送れること
        await signIn(port, 'alice');
        final retried = (await proxy.getQuarantinedRequests()).first;
        expect(await proxy.retryQuarantinedRequest(retried.id), isTrue);
        await _waitUntil(() async => upstream.replays.length == 2);
        expect(upstream.replays.last.cookie, contains('session=alice'));
        expect(await proxy.getQuarantinedRequests(), hasLength(2));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// dropPolicy が drop の場合は、ドロップ履歴へ owner_changed で記録すること
    test('follows DropPolicy.drop', () async {
      await withRealHttpClient(() async {
        final port = await queueForUserAAndPause(dropPolicy: DropPolicy.drop);
        upstream.replayStatusFor = (_) => HttpStatus.ok;

        await signIn(port, 'bob');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(upstream.replays, hasLength(1));
        expect(await proxy.getQuarantinedRequests(), isEmpty);
        final dropped = await proxy.getDroppedRequests();
        expect(dropped, hasLength(3));
        expect(
            dropped.every((request) => request.dropReason == 'owner_changed'),
            isTrue);
        expect(dropped.every((request) => request.statusCode == 0), isTrue);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 現在の持ち主は起動し直しても引き継ぎ、ログイン前に入れた要求にも残すこと
    test('restores the current owner after a restart', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await signIn(port, 'alice');
        await proxy.stop();

        upstream.replayStatusFor = (_) => HttpStatus.unauthorized;
        final restartedPort = await startProxy();
        await enqueue(restartedPort, ['photo']);
        await waitForPause();

        upstream.replayStatusFor = (_) => HttpStatus.ok;
        await signIn(restartedPort, 'bob');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(upstream.replays, hasLength(1));
        expect((await proxy.getQuarantinedRequests()).single.reason,
            equals('owner_changed'));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 別の鍵で保存した持ち主は捨て、持ち主が分からないものとして扱うこと
    test('discards an owner stored with another key', () async {
      await withRealHttpClient(() async {
        await Hive.initFlutter();
        final preferences = await Hive.openBox('proxy_port_preferences');
        await preferences.put('queue_owner', {
          'owner': 'stale',
          'keyId': '0000000000000000',
        });
        await preferences.close();

        upstream.replayStatusFor = (_) => HttpStatus.unauthorized;
        final port = await startProxy();
        await enqueue(port, ['photo']);
        await waitForPause();

        // 持ち主が分からない要求は、今までどおり送ること
        upstream.replayStatusFor = (_) => HttpStatus.ok;
        await signIn(port, 'bob');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays, hasLength(2));
        expect(upstream.replays.last.cookie, contains('session=bob'));
        expect(await proxy.getQuarantinedRequests(), isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 持ち主が分からない要求（ログインより前に入れた要求）は今までどおり送ること
    test('sends a request queued before anyone signed in', () async {
      await withRealHttpClient(() async {
        upstream.replayStatusFor = (_) => HttpStatus.unauthorized;
        final port = await startProxy();
        await enqueue(port, ['photo']);
        await waitForPause();

        upstream.replayStatusFor = (_) => HttpStatus.ok;
        await signIn(port, 'bob');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays, hasLength(2));
        expect(await proxy.getQuarantinedRequests(), isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// ログインの転送中は、キューから新しく送らないこと
    test('holds the queue while a sign-in is forwarded', () async {
      await withRealHttpClient(() async {
        upstream.replayStatusFor = (_) => HttpStatus.serviceUnavailable;
        final port = await startProxy(retryBackoffSeconds: const [1]);
        await signIn(port, 'alice');
        await enqueue(port, ['photo']);
        await _waitUntil(() => upstream.replays.isNotEmpty);

        upstream.replayStatusFor = (_) => HttpStatus.ok;
        upstream.loginGate = Completer<void>();
        final replaysBeforeSignIn = upstream.replays.length;
        final signInB = signIn(port, 'bob');

        // 再試行の時刻を過ぎ、定期処理が回っても送らないこと
        await Future<void>.delayed(const Duration(seconds: 7));
        expect(upstream.replays, hasLength(replaysBeforeSignIn));
        expect(await proxy.getQueuedRequests(), hasLength(1));

        upstream.loginGate!.complete();
        await signInB;
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays, hasLength(replaysBeforeSignIn));
        expect((await proxy.getQuarantinedRequests()).single.reason,
            equals('owner_changed'));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 持ち主は HMAC で保存し、識別子をイベントや状態通知に出さないこと
    test('never stores or reports the identifier as given', () async {
      await withRealHttpClient(() async {
        final port = await queueForUserAAndPause();
        upstream.replayStatusFor = (_) => HttpStatus.ok;
        await signIn(port, 'bob');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final status = await fetchStatus(port);
        expect(jsonEncode(status), isNot(contains('alice')));
        expect(jsonEncode(status), isNot(contains('bob')));
        for (final event in events) {
          expect(event.data.toString(), isNot(contains('alice')));
          expect(event.data.toString(), isNot(contains('bob')));
        }
        await proxy.stop();

        final preferences = await Hive.openBox('proxy_port_preferences');
        final stored = preferences.get('queue_owner') as Map;
        await preferences.close();
        expect(stored['owner'], matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(stored['signInPending'], isFalse);
        expect(stored.toString(), isNot(contains('bob')));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// クエリの % 表記が壊れたログインは、キューへ入れず、持ち主も変えないこと
    ///
    /// shelf が要求を受け付ける前に 400 で断るため、上流へも届かない。
    test('ignores a sign-in whose query cannot be decoded', () async {
      await withRealHttpClient(() async {
        final port = await queueForUserAAndPause();
        upstream.replayStatusFor = (_) => HttpStatus.ok;

        final status = await _send(
          'POST',
          Uri.parse('http://127.0.0.1:$port$_loginPath?next=%E3%81'),
          jsonEncode({'account': 'bob'}),
        );
        expect(status, equals(HttpStatus.badRequest));
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(upstream.replays, hasLength(1));
        expect(await proxy.getQueuedRequests(), hasLength(3));
        expect((await proxy.getStats()).queuePausedReason,
            equals(QueuePauseReason.authenticationRequired));

        // その後の正しいログインでは、持ち主を比べて隔離すること
        await signIn(port, 'bob');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays, hasLength(1));
        expect(await proxy.getQuarantinedRequests(), hasLength(3));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 判定できずに止めている間は、null を返すログインでは再開しないこと
    test('stays paused for an unresolved owner when the resolver returns null',
        () async {
      await withRealHttpClient(() async {
        var shouldThrow = false;
        String? resolver(QueueOwnerContext context) {
          if (shouldThrow) {
            throw StateError('broken resolver');
          }
          return _resolveAccount(context);
        }

        final port = await queueForUserAAndPause(resolver: resolver);
        upstream.replayStatusFor = (_) => HttpStatus.ok;
        shouldThrow = true;
        await signIn(port, 'bob');
        expect((await proxy.getStats()).queuePausedReason,
            equals(QueuePauseReason.ownerUnresolved));

        shouldThrow = false;
        upstream.loginSucceeds = false;
        await signIn(port, 'bob');
        await Future<void>.delayed(const Duration(seconds: 6));
        expect((await proxy.getStats()).queuePausedReason,
            equals(QueuePauseReason.ownerUnresolved));
        expect(upstream.replays, hasLength(1));
        expect(await proxy.getQueuedRequests(), hasLength(3));

        // 持ち主が決まるログインで再開すること
        upstream.loginSucceeds = true;
        await signIn(port, 'alice');
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays.last.cookie, contains('session=alice'));
        expect(await proxy.getQuarantinedRequests(), isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// ログインの転送中に終了した場合は、起動し直した後に前の持ち主として送らないこと
    test('treats a sign-in interrupted by a restart as an unknown owner',
        () async {
      await withRealHttpClient(() async {
        await queueForUserAAndPause();
        await proxy.stop();

        // Cookie を保存した後、持ち主を保存する前に終了した状態を作る
        final preferences = await Hive.openBox('proxy_port_preferences');
        final stored =
            Map<String, dynamic>.from(preferences.get('queue_owner') as Map);
        await preferences
            .put('queue_owner', {...stored, 'signInPending': true});
        await preferences.close();

        upstream.replayStatusFor = (_) => HttpStatus.ok;
        await startProxy();
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(upstream.replays, hasLength(1));
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined, hasLength(3));
        expect(
            quarantined.every((request) => request.reason == 'owner_changed'),
            isTrue);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// GET のログイン（3xx で成功）でも、持ち主を決めて比べること
    test('resolves a sign-in sent with GET and answered with a redirect',
        () async {
      await withRealHttpClient(() async {
        final port = await queueForUserAAndPause(
          resolver: (context) => context.method == 'GET'
              ? context.queryParameters['account']
              : _resolveAccount(context),
        );
        upstream.replayStatusFor = (_) => HttpStatus.ok;

        final client = HttpClient();
        try {
          final request = await client.getUrl(
              Uri.parse('http://127.0.0.1:$port$_loginPath?account=bob'));
          request.followRedirects = false;
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, equals(HttpStatus.found));
        } finally {
          client.close(force: true);
        }

        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays, hasLength(1));
        expect(await proxy.getQuarantinedRequests(), hasLength(3));
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// ログインの転送中に停止した場合も、起動し直した後に前の持ち主として送らないこと
    test('does not send under a sign-in interrupted by stop()', () async {
      await withRealHttpClient(() async {
        await queueForUserAAndPause();
        upstream.replayStatusFor = (_) => HttpStatus.ok;
        upstream.loginGate = Completer<void>();
        upstream.loginReceived = Completer<void>();

        final port = proxy.port!;
        final signInB = _send(
          'POST',
          Uri.parse('http://127.0.0.1:$port$_loginPath'),
          jsonEncode({'account': 'bob'}),
        ).catchError((Object _) => -1);
        await upstream.loginReceived.future;
        // 停止し終えてからログインの応答を返し、持ち主を保存できない状態にする
        await proxy.stop();
        upstream.loginGate!.complete();
        // 閉じたキューへは書き込まず、キューへ入れられなかったことを返すこと
        // （接続が先に切れた場合は -1）
        expect(await signInB, anyOf(equals(HttpStatus.serviceUnavailable), -1));

        // ログインを転送中であることが残っていること
        final preferences = await Hive.openBox('proxy_port_preferences');
        final stored = preferences.get('queue_owner') as Map;
        await preferences.close();
        expect(stored['signInPending'], isTrue);
        // 停止した後は、保存できなかったことを知らせないこと
        expect(
            events.where((event) =>
                event.type == ProxyEventType.errorOccurred &&
                event.data['phase'] == 'queueOwnerPersist'),
            isEmpty);

        await startProxy();
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays, hasLength(1));
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined, hasLength(3));
        expect(
            quarantined.every((request) => request.reason == 'owner_changed'),
            isTrue);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 送信を始めた後にログインが始まった場合は、本文を送らずに中断すること
    test('cancels a resend when a sign-in starts before its body is sent',
        () async {
      final reachedBody = Completer<void>();
      final releaseBody = Completer<void>();
      proxy = OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(
          beforeQueuedRequestSent: () async {
            if (!reachedBody.isCompleted) {
              reachedBody.complete();
              await releaseBody.future;
            }
          },
        ),
      );
      await subscription?.cancel();
      subscription = proxy.events.listen(events.add);

      await withRealHttpClient(() async {
        // ログインを済ませてからキューへ入れるまで、送信の始まりを遅らせる
        upstream.forwardStatusCode = HttpStatus.internalServerError;
        final port = await startProxy();
        await signIn(port, 'alice');
        await enqueue(port, ['photo']);
        await reachedBody.future;

        // 送信の途中で B のログインを始め、終わらせる
        await signIn(port, 'bob');
        releaseBody.complete();

        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(upstream.replays, isEmpty);
        expect((await proxy.getQuarantinedRequests()).single.reason,
            equals('owner_changed'));
        // 中断した送信は、失敗として数えないこと
        expect(
            proxy.recentResendResults
                .where((result) => result.dropReason == null),
            isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('持ち主の判定関数の設定', () {
    /// ログインのパスが無いと持ち主が決まらないため、起動時に拒否すること
    test('rejects a resolver without authResumePaths', () async {
      await expectLater(
        proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            queueOwnerResolver: _resolveAccount,
          ),
        ),
        throwsA(isA<ProxyStartException>().having(
            (error) => error.message, 'message', contains('authResumePaths'))),
      );
      expect(proxy.isRunning, isFalse);
    });
  });

  group('QueueOwnerContext', () {
    /// 要求と応答の本文を JSON とフォームとして読めること
    test('reads JSON and form bodies', () {
      final context = QueueOwnerContext(
        method: 'POST',
        path: _loginPath,
        requestHeaders: const {
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        requestBody: utf8.encode('account=%E3%81%82&remember=1'),
        statusCode: HttpStatus.ok,
        responseHeaders: const {'content-type': 'application/json'},
        responseBody: utf8.encode('{"ok":true}'),
      );

      expect(
          context.requestFormFields, equals({'account': 'あ', 'remember': '1'}));
      expect(context.requestJson, isNull);
      expect(context.responseJson, equals({'ok': true}));
      expect(context.requestHeader('content-type'),
          startsWith('application/x-www-form-urlencoded'));
      expect(
          context.responseHeader('Content-Type'), equals('application/json'));
      expect(context.responseHeader('x-missing'), isNull);
      // 本文には資格情報が入るため、文字列表現に含めないこと
      expect(context.toString(), isNot(contains('account')));
    });

    /// フォーム以外の本文はフィールドとして読まないこと
    test('returns no form fields for other content types', () {
      final context = QueueOwnerContext(
        method: 'POST',
        path: _loginPath,
        requestHeaders: const {'content-type': 'application/json'},
        requestBody: utf8.encode('{"account":"A"}'),
        statusCode: HttpStatus.ok,
      );

      expect(context.requestFormFields, isEmpty);
      expect(context.requestJson, equals({'account': 'A'}));

      // % の表記が壊れたフォームは、例外にせず空として返すこと
      final broken = QueueOwnerContext(
        method: 'POST',
        path: _loginPath,
        requestHeaders: const {
          'content-type': 'application/x-www-form-urlencoded'
        },
        requestBody: utf8.encode('account=%zz'),
        statusCode: HttpStatus.ok,
      );
      expect(broken.requestFormFields, isEmpty);
      expect(context.responseJson, isNull);
    });
  });
}
