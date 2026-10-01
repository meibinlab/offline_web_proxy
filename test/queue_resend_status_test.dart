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

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// 上流がキューからの送信へ返す応答。
class _ReplayAnswer {
  const _ReplayAnswer(this.statusCode, {this.retryAfter});

  /// ステータスコード。
  final int statusCode;

  /// `Retry-After` ヘッダの値。付けない場合は `null`。
  final String? retryAfter;
}

/// キューからの送信を受け取った記録。
class _Replay {
  _Replay(this.body, this.receivedAt);

  /// 要求の本文。
  final String body;

  /// 受け取った日時。
  final DateTime receivedAt;
}

/// キューからの送信への応答を切り替えられる上流サーバのモック。
///
/// 最初の転送には 500 を返してキューへ入れさせ、3xx の転送先（`/redirected`）
/// へ届いた要求は [redirectedRequests] に数える。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        if (request.uri.path == '/redirected') {
          redirectedRequests++;
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
          return;
        }

        if (request.headers.value('x-offline-replay') != '1') {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
          return;
        }

        replays.add(_Replay(body, DateTime.now()));
        final answer = answerFor(body);
        request.response.statusCode = answer.statusCode;
        if (answer.statusCode >= 300 && answer.statusCode < 400) {
          request.response.headers.set('location', '/redirected');
        }
        final retryAfter = answer.retryAfter;
        if (retryAfter != null) {
          request.response.headers.set('retry-after', retryAfter);
        }
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// キューからの送信で受け取った要求。受信順に追加される。
  final List<_Replay> replays = <_Replay>[];

  /// 3xx の転送先へ届いた要求の数。
  int redirectedRequests = 0;

  /// キューからの送信への応答を、本文から決める。
  _ReplayAnswer Function(String body) answerFor =
      (_) => const _ReplayAnswer(HttpStatus.ok);

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 実 HttpClient で更新系の要求を実行する。
///
/// [method] HTTP メソッド。
/// [uri] 送信先。
/// [body] 本文。
/// [idempotencyKey] 付けるべき等性キー。
Future<void> _send(
  String method,
  Uri uri,
  String body, {
  required String idempotencyKey,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    request.headers.set('Idempotency-Key', idempotencyKey);
    request.write(body);
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close(force: true);
  }
}

/// 状態通知エンドポイントの応答を取得する。
///
/// [port] proxy のポート番号。
///
/// Returns: 応答の JSON。
Future<Map<String, dynamic>> _fetchStatus(int port) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'));
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return jsonDecode(body) as Map<String, dynamic>;
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
        .createTempSync('offline_web_proxy_resend_status')
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
  /// [bodies] キューへ入れる要求の本文。べき等性キーは `key-<本文>` にする。
  /// [answerFor] キューからの送信への応答。
  /// [method] 要求の HTTP メソッド。
  /// [authRequiredStatusCodes] 認証が必要を示すステータスコード。
  /// [retryBackoffSeconds] 再試行の待ち時間（秒）。
  ///
  /// Returns: proxy のポート番号。
  Future<int> startWithQueued(
    List<String> bodies, {
    required _ReplayAnswer Function(String body) answerFor,
    String method = 'POST',
    Set<int> authRequiredStatusCodes = const {},
    List<int> retryBackoffSeconds = const [1],
  }) async {
    upstream.answerFor = answerFor;
    final port = await proxy.start(
      config: ProxyConfig(
        origin: upstream.origin,
        retryBackoffSeconds: retryBackoffSeconds,
        authRequiredStatusCodes: authRequiredStatusCodes,
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

  /// キューが空になるまで待つ。
  Future<void> waitUntilQueueEmpty() => _waitUntil(
        () async => (await proxy.getQueuedRequests()).isEmpty,
        timeout: const Duration(seconds: 60),
      );

  group('キューからの再送の状態コード（doc/specs.ja.md 【5】再試行戦略）', () {
    /// 408 は取り除かずに再試行すること
    test('retries a request answered with 408', () async {
      await withRealHttpClient(() async {
        var answered = false;
        await startWithQueued(['first'], answerFor: (_) {
          if (answered) {
            return const _ReplayAnswer(HttpStatus.ok);
          }
          answered = true;
          return const _ReplayAnswer(HttpStatus.requestTimeout);
        });

        await waitUntilQueueEmpty();

        expect(upstream.replays, hasLength(2));
        expect(await proxy.getQuarantinedRequests(), isEmpty);
        expect(await proxy.getDroppedRequests(), isEmpty);
        final first = proxy.recentResendResults.first;
        expect(first.statusCode, equals(HttpStatus.requestTimeout));
        expect(first.willRetry, isTrue);
        expect(first.dropReason, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 429 では Retry-After まで待ち、その間は後続も送らないこと
    test('holds the whole queue until the Retry-After of a 429', () async {
      await withRealHttpClient(() async {
        var limited = false;
        final port =
            await startWithQueued(['first', 'second'], answerFor: (body) {
          if (body == 'first' && !limited) {
            limited = true;
            return const _ReplayAnswer(
              HttpStatus.tooManyRequests,
              retryAfter: '8',
            );
          }
          return const _ReplayAnswer(HttpStatus.ok);
        });

        // 控えている間は、理由と再開する時刻を統計に出すこと
        await _waitUntil(() => proxy.recentResendResults.isNotEmpty);
        final held = await proxy.getStats();
        expect(held.queuePausedReason, equals(QueuePauseReason.rateLimited));
        final resumesIn = held.queuePausedUntil!.difference(DateTime.now());
        expect(held.queuePausedUntil!.isUtc, isTrue);
        expect(resumesIn, greaterThan(const Duration(seconds: 6)));
        expect(resumesIn, lessThanOrEqualTo(const Duration(seconds: 8)));
        // 状態通知にも、理由と UTC の再開時刻を出すこと
        final status = await _fetchStatus(port);
        expect(status['queuePausedReason'], equals('rateLimited'));
        final until = status['queuePausedUntil'] as String;
        expect(until, endsWith('Z'));
        expect(DateTime.parse(until), equals(held.queuePausedUntil));

        await waitUntilQueueEmpty();

        final resumed = await proxy.getStats();
        expect(resumed.queuePausedReason, isNull);
        expect(resumed.queuePausedUntil, isNull);
        expect(await proxy.getQuarantinedRequests(), isEmpty);
        final limitedAt = upstream.replays.first.receivedAt;
        expect(upstream.replays.first.body, equals('first'));
        // 後続は Retry-After の後まで送らないこと（計測誤差を見込む）
        for (final replay in upstream.replays.skip(1)) {
          expect(
            replay.receivedAt.difference(limitedAt),
            greaterThanOrEqualTo(const Duration(milliseconds: 7500)),
          );
        }
        expect(upstream.replays.map((replay) => replay.body),
            containsAll(['first', 'second']));
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// HTTP の日時の Retry-After は、1 時間を上限にすること
    test('caps a Retry-After date at one hour', () async {
      await withRealHttpClient(() async {
        final farFuture = HttpDate.format(
            DateTime.now().toUtc().add(const Duration(hours: 5)));
        await startWithQueued(
          ['first'],
          answerFor: (_) => _ReplayAnswer(
            HttpStatus.tooManyRequests,
            retryAfter: farFuture,
          ),
        );

        await _waitUntil(() async => (await proxy.getQueuedRequests())
            .any((request) => request.retryCount > 0));

        final retried = (await proxy.getQueuedRequests()).single;
        final wait = retried.nextRetryAt.difference(DateTime.now());
        expect(wait, greaterThan(const Duration(minutes: 59)));
        expect(wait, lessThanOrEqualTo(const Duration(hours: 1)));
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 次の送信時刻までの時間を返す。
    Future<Duration> waitOfRetriedRequest() async {
      await _waitUntil(() async => (await proxy.getQueuedRequests())
          .any((request) => request.retryCount > 0));
      final retried = (await proxy.getQueuedRequests())
          .firstWhere((request) => request.retryCount > 0);
      return retried.nextRetryAt.difference(DateTime.now());
    }

    /// 桁の大きな秒数は、例外にせず 1 時間として扱うこと
    test('caps a huge Retry-After in seconds at one hour', () async {
      await withRealHttpClient(() async {
        await startWithQueued(
          ['first'],
          answerFor: (_) => const _ReplayAnswer(
            HttpStatus.tooManyRequests,
            retryAfter: '99999999999999999999',
          ),
        );

        final wait = await waitOfRetriedRequest();

        expect(wait, greaterThan(const Duration(minutes: 59)));
        expect(wait, lessThanOrEqualTo(const Duration(hours: 1)));
        final result = proxy.recentResendResults.single;
        expect(result.statusCode, equals(HttpStatus.tooManyRequests));
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 通常の待ち時間より短い Retry-After と、負の値は使わないこと
    for (final retryAfter in ['2', '-5']) {
      test('keeps the usual wait over Retry-After "$retryAfter"', () async {
        await withRealHttpClient(() async {
          await startWithQueued(
            ['first'],
            retryBackoffSeconds: const [120],
            answerFor: (_) => _ReplayAnswer(
              HttpStatus.tooManyRequests,
              retryAfter: retryAfter,
            ),
          );

          final wait = await waitOfRetriedRequest();

          expect(wait, greaterThan(const Duration(seconds: 110)));
          expect(wait, lessThanOrEqualTo(const Duration(seconds: 120)));
        });
      }, timeout: const Timeout(Duration(seconds: 90)));
    }

    /// 5xx の Retry-After は使わないこと
    test('ignores Retry-After on a 5xx', () async {
      await withRealHttpClient(() async {
        await startWithQueued(
          ['first'],
          answerFor: (_) => const _ReplayAnswer(
            HttpStatus.serviceUnavailable,
            retryAfter: '600',
          ),
        );

        final wait = await waitOfRetriedRequest();

        expect(wait, lessThanOrEqualTo(const Duration(seconds: 1)));
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 429 の控えは、停止すると解除すること
    test('forgets the 429 hold when the proxy stops', () async {
      await withRealHttpClient(() async {
        await startWithQueued(['first', 'second'], answerFor: (body) {
          return body == 'first'
              ? const _ReplayAnswer(
                  HttpStatus.tooManyRequests,
                  retryAfter: '3600',
                )
              : const _ReplayAnswer(HttpStatus.ok);
        });
        await _waitUntil(() => proxy.recentResendResults.isNotEmpty);
        expect(proxy.recentResendResults.first.statusCode,
            equals(HttpStatus.tooManyRequests));

        await proxy.stop();
        await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            retryBackoffSeconds: const [1],
          ),
        );

        // 1 件目は送信時刻を待ち、2 件目は控えずに送ること。
        // 上流が受け取ってからキューから消えるまでには間があるため、
        // キューから消えたことを待ってから確かめる
        await _waitUntil(
            () async => (await proxy.getQueuedRequests()).length == 1);
        expect(upstream.replays.map((replay) => replay.body),
            equals(['first', 'second']));
        expect(await proxy.getQueuedRequests(), hasLength(1));
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// authRequiredStatusCodes に 429 を指定した場合は、一時停止を優先すること
    test('pauses instead of holding when 429 is listed', () async {
      await withRealHttpClient(() async {
        await startWithQueued(
          ['first'],
          authRequiredStatusCodes: const {HttpStatus.tooManyRequests},
          answerFor: (_) => const _ReplayAnswer(
            HttpStatus.tooManyRequests,
            retryAfter: '3600',
          ),
        );

        await _waitUntil(() => events.any(
            (event) => event.type == ProxyEventType.authenticationRequired));

        final queued = (await proxy.getQueuedRequests()).single;
        // 一時停止では、再試行回数も次の送信時刻も変えないこと
        expect(queued.retryCount, equals(0));
        final stats = await proxy.getStats();
        expect(stats.queuePausedReason,
            equals(QueuePauseReason.authenticationRequired));
        // 認証待ちには自動で再開する時刻が無いこと
        expect(stats.queuePausedUntil, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 解釈できない Retry-After は無視して、通常の待ち時間で送り直すこと
    test('ignores an invalid Retry-After', () async {
      await withRealHttpClient(() async {
        var limited = false;
        await startWithQueued(['first'], answerFor: (_) {
          if (limited) {
            return const _ReplayAnswer(HttpStatus.ok);
          }
          limited = true;
          return const _ReplayAnswer(
            HttpStatus.tooManyRequests,
            retryAfter: 'soon',
          );
        });

        await waitUntilQueueEmpty();

        expect(upstream.replays, hasLength(2));
        final first = proxy.recentResendResults.first;
        expect(first.statusCode, equals(HttpStatus.tooManyRequests));
        expect(first.willRetry, isTrue);
        // 通常の待ち時間（1 秒）の後、次の定期処理（5 秒ごと）で送ること
        expect(
          upstream.replays[1].receivedAt
              .difference(upstream.replays[0].receivedAt),
          lessThan(const Duration(seconds: 12)),
        );
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 303 はたどらずに届いたものとみなすこと
    for (final method in ['POST', 'PUT']) {
      test('treats a 303 to $method as delivered without following it',
          () async {
        await withRealHttpClient(() async {
          await startWithQueued(
            ['first'],
            method: method,
            answerFor: (_) => const _ReplayAnswer(HttpStatus.seeOther),
          );

          await waitUntilQueueEmpty();

          expect(upstream.replays, hasLength(1));
          expect(upstream.redirectedRequests, equals(0));
          final result = proxy.recentResendResults.single;
          expect(result.statusCode, equals(HttpStatus.seeOther));
          expect(result.success, isTrue);
          final status = (await proxy.getRequestStatuses(['key-first'])).single;
          expect(status.state, equals(RequestState.delivered));
        });
      }, timeout: const Timeout(Duration(seconds: 90)));
    }

    /// authRequiredStatusCodes に 303 を指定すると、POST でも一時停止すること
    test('pauses a POST answered with a listed 303', () async {
      await withRealHttpClient(() async {
        await startWithQueued(
          ['first'],
          answerFor: (_) => const _ReplayAnswer(HttpStatus.seeOther),
          authRequiredStatusCodes: const {HttpStatus.seeOther},
        );

        await _waitUntil(() => events.any(
            (event) => event.type == ProxyEventType.authenticationRequired));

        expect(await proxy.getQueuedRequests(), hasLength(1));
        expect(upstream.redirectedRequests, equals(0));
        expect((await proxy.getStats()).queuePausedReason,
            equals(QueuePauseReason.authenticationRequired));
        final status = (await proxy.getRequestStatuses(['key-first'])).single;
        expect(status.state, equals(RequestState.queued));
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    /// 303 以外の 3xx は、従来どおりたどらずに再試行すること
    test('keeps retrying other redirects', () async {
      await withRealHttpClient(() async {
        await startWithQueued(
          ['first'],
          answerFor: (_) => const _ReplayAnswer(HttpStatus.found),
        );

        await _waitUntil(() => proxy.recentResendResults.isNotEmpty);

        final result = proxy.recentResendResults.first;
        expect(result.statusCode, equals(HttpStatus.found));
        expect(result.success, isFalse);
        expect(result.willRetry, isTrue);
        expect(upstream.redirectedRequests, equals(0));
        expect(await proxy.getQueuedRequests(), hasLength(1));
        expect(await proxy.getQuarantinedRequests(), isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
