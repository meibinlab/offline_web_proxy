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

/// 隔離領域の保存名。退避に失敗する状況を作るために使用する。
const String _quarantinedRequestBoxName = 'proxy_quarantined_requests';

/// 再送を先送りしたと判断する最小の間隔。
///
/// 既定のバックオフ（`retryBackoffSeconds` の先頭は 1 秒）に対して、
/// 計測誤差を見込んだ下限を指定する。
const Duration _minimumBackoff = Duration(milliseconds: 900);

/// 応答するステータスコードを切り替えられる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        receivedBodies.add(body);
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

/// 実 HttpClient で更新系リクエストを実行する。
Future<void> _performPost(Uri uri, String body) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl('POST', uri);
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
        .createTempSync('offline_web_proxy_quarantine')
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

  /// 4xx で拒否される更新系リクエストを 1 件だけ隔離させる。
  ///
  /// [policy] 適用する破棄方針。
  ///
  /// Returns: proxy のポート番号。
  Future<int> queueRejectedRequest({
    DropPolicy policy = DropPolicy.quarantine,
  }) async {
    upstream = await _startMockUpstream();
    final port = await proxy.start(
      config: ProxyConfig(origin: upstream!.origin, dropPolicy: policy),
    );

    // 5xx でキューへ保存させたあと、4xx を返して再送を打ち切らせる
    upstream!.statusCode = HttpStatus.internalServerError;
    await _performPost(
      Uri.parse('http://127.0.0.1:$port/api/sales'),
      '{"total":1000}',
    );
    expect(await proxy.getQueuedRequests(), hasLength(1));

    upstream!.statusCode = HttpStatus.badRequest;
    await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
    return port;
  }

  group('隔離キュー（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// 4xx のリクエストが破棄されず隔離されること
    test('quarantines a rejected request instead of discarding it', () async {
      await withRealHttpClient(() async {
        await queueRejectedRequest();

        final quarantined = await proxy.getQuarantinedRequests();
        // 内容を確認できる形で残ること
        expect(quarantined, hasLength(1));
        expect(quarantined.single.method, equals('POST'));
        expect(quarantined.single.url, contains('/api/sales'));
        expect(quarantined.single.statusCode, equals(HttpStatus.badRequest));
        expect(quarantined.single.reason, equals('4xx_error'));

        // 隔離した場合はドロップ履歴へ二重に記録しないこと
        expect(await proxy.getDroppedRequests(), isEmpty);

        final stats = await proxy.getStats();
        // 統計から要対応の件数を検知できること
        expect(stats.quarantinedCount, equals(1));
      });
    });

    /// 隔離されたリクエストを再送できること
    test('resends a quarantined request after the cause is fixed', () async {
      await withRealHttpClient(() async {
        await queueRejectedRequest();
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined, hasLength(1));

        // 拒否の原因が解消した状態で再送する
        upstream!.statusCode = HttpStatus.ok;
        final resent =
            await proxy.retryQuarantinedRequest(quarantined.single.id);
        expect(resent, isTrue);

        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        // 本文を保持したまま上流へ送信されること
        expect(upstream!.receivedBodies, contains('{"total":1000}'));
        // 隔離領域から取り除かれること
        expect(await proxy.getQuarantinedRequests(), isEmpty);
        expect((await proxy.getStats()).quarantinedCount, equals(0));
      });
    });

    /// 隔離の発生をイベントで検知できること
    test('notifies a requestQuarantined event', () async {
      await withRealHttpClient(() async {
        final events = <ProxyEvent>[];
        final subscription = proxy.events
            .where((event) => event.type == ProxyEventType.requestQuarantined)
            .listen(events.add);
        addTearDown(subscription.cancel);

        await queueRejectedRequest();
        await _waitUntil(() async => events.isNotEmpty);

        // 隔離を運用側へ通知できること
        expect(events, hasLength(1));
        expect(events.single.url, contains('/api/sales'));
        expect(events.single.data['statusCode'], equals(HttpStatus.badRequest));
        expect(events.single.data['reason'], equals('4xx_error'));
        expect(events.single.data['quarantineId'], isNotNull);
      });
    });

    /// 該当しない ID を指定した場合は再送しないこと
    test('returns false when the quarantined id is unknown', () async {
      await withRealHttpClient(() async {
        await queueRejectedRequest();
        final receivedBefore = upstream!.receivedBodies.length;

        // 存在しない ID では再送を行わないこと
        expect(await proxy.retryQuarantinedRequest('missing-id'), isFalse);
        // 隔離されている要求は影響を受けないこと
        expect(await proxy.getQuarantinedRequests(), hasLength(1));
        expect(upstream!.receivedBodies.length, equals(receivedBefore));
      });
    });

    /// 隔離されたリクエストを一括で破棄できること
    test('clears every quarantined request at once', () async {
      await withRealHttpClient(() async {
        await queueRejectedRequest();
        expect(await proxy.getQuarantinedRequests(), hasLength(1));

        await proxy.clearQuarantinedRequests();
        expect(await proxy.getQuarantinedRequests(), isEmpty);
        expect((await proxy.getStats()).quarantinedCount, equals(0));
      });
    });

    /// 隔離されたリクエストを明示的に破棄できること
    test('discards a quarantined request on request', () async {
      await withRealHttpClient(() async {
        await queueRejectedRequest();
        final quarantined = await proxy.getQuarantinedRequests();

        final discarded =
            await proxy.discardQuarantinedRequest(quarantined.single.id);
        expect(discarded, isTrue);
        expect(await proxy.getQuarantinedRequests(), isEmpty);

        // 存在しない ID には false を返すこと
        expect(
          await proxy.discardQuarantinedRequest(quarantined.single.id),
          isFalse,
        );
      });
    });

    /// 隔離領域へ退避できない場合は、キューから取り除かずバックオフを適用すること
    test('keeps the request queued with backoff when quarantine is unavailable',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        // 5xx で再送用にキューへ保存させる
        upstream!.statusCode = HttpStatus.internalServerError;
        await _performPost(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          '{"total":1000}',
        );
        expect(await proxy.getQueuedRequests(), hasLength(1));

        // 隔離領域を閉じ、退避に失敗する状況を作る
        await Hive.box(_quarantinedRequestBoxName).close();

        // 4xx を返して再送を打ち切らせる
        upstream!.statusCode = HttpStatus.badRequest;
        await _waitUntil(() async {
          final queued = await proxy.getQueuedRequests();
          return queued.isNotEmpty && queued.single.retryCount > 0;
        });

        final queued = await proxy.getQueuedRequests();
        // 退避できない状態で消してしまわないこと
        expect(queued, hasLength(1));
        // 消化間隔ごとに同じ 4xx を叩き続けないよう、再送を先送りすること
        expect(queued.single.retryCount, greaterThan(0));
        expect(
          queued.single.nextRetryAt.difference(queued.single.queuedAt),
          greaterThanOrEqualTo(_minimumBackoff),
        );
        // 破棄したことにもしないこと
        expect(await proxy.getDroppedRequests(), isEmpty);
      });
    });

    /// 破棄方針を指定した場合は従来どおり履歴だけを残すこと
    test('keeps only a history entry when the policy is drop', () async {
      await withRealHttpClient(() async {
        await queueRejectedRequest(policy: DropPolicy.drop);

        // 隔離はされないこと
        expect(await proxy.getQuarantinedRequests(), isEmpty);

        final dropped = await proxy.getDroppedRequests();
        expect(dropped, hasLength(1));
        expect(dropped.single.statusCode, equals(HttpStatus.badRequest));
      });
    });
  });

  group('ドロップ履歴の未確認件数（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// ドロップ直後は未確認として数え、確認後は数えないこと
    test('counts dropped history until it is acknowledged', () async {
      await withRealHttpClient(() async {
        await queueRejectedRequest(policy: DropPolicy.drop);

        final beforeStats = await proxy.getStats();
        // 起動後に未確認の履歴を検知できること
        expect(beforeStats.unacknowledgedDroppedCount, equals(1));
        expect(
          (await proxy.getDroppedRequests()).single.acknowledged,
          isFalse,
        );

        final acknowledged = await proxy.acknowledgeDroppedRequests();
        expect(acknowledged, equals(1));

        final afterStats = await proxy.getStats();
        // 確認後は未確認件数から外れること
        expect(afterStats.unacknowledgedDroppedCount, equals(0));
        // 履歴自体は残ること
        expect(afterStats.droppedRequestsCount, equals(1));
        expect(
          (await proxy.getDroppedRequests()).single.acknowledged,
          isTrue,
        );
      });
    });
  });
}
