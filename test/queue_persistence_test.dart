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

/// 同時に投入する更新系リクエストの件数。
///
/// ミリ秒精度のキーでは同一ミリ秒内の保存が上書きされるため、
/// 保存漏れを検出できる程度の件数を指定する。
const int _concurrentRequestCount = 20;

/// 再送順の確認に使用する更新系リクエストの件数。
const int _orderedRequestCount = 5;

/// 連続再送の確認に使用する更新系リクエストの件数。
///
/// 共有 `HttpClient` の `maxConnectionsPerHost`（50）を超える件数にし、
/// 応答本文を読み捨てずに接続が滞留すると再送が止まることを検出する。
const int _drainRequestCount = 60;

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

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

  /// 上流が受信したリクエスト本文の一覧。受信順に追加される。
  final List<String> receivedBodies = <String>[];

  final HttpServer _server;

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

/// HTTP 応答の検証に必要な要素だけを保持する型。
typedef _HttpResult = ({int statusCode, Map<String, String> headers});

/// 実 HttpClient で更新系リクエストを実行し、ステータスコードを返す。
Future<int> _performPost(Uri uri, String body) async {
  final result = await _performPostWithHeaders(uri, body);
  return result.statusCode;
}

/// 実 HttpClient で更新系リクエストを実行し、ステータスとヘッダを返す。
Future<_HttpResult> _performPostWithHeaders(Uri uri, String body) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl('POST', uri);
    request.write(body);
    final response = await request.close();
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    await response.drain<void>();
    return (statusCode: response.statusCode, headers: headers);
  } finally {
    client.close(force: true);
  }
}

/// [check] が真を返すまで待機する。
///
/// [timeout] を超えた場合は待機を打ち切り、呼び出し側のアサーションに委ねます。
Future<void> _waitUntil(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 20),
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
    hiveTestDirectory =
        Directory.systemTemp.createTempSync('offline_web_proxy_queue').path;
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

  group('キュー保存の一意性（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// 同時に投入した更新系リクエストが 1 件も失われずキューに保存されること
    test('keeps every queued request when many are stored at once', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        // オフラインへ遷移させ、更新系リクエストがキューへ回るようにする
        await _emitConnectivity(['none']);

        final postUri = Uri.parse('http://127.0.0.1:$port/api/sales');
        await Future.wait([
          for (var i = 0; i < _concurrentRequestCount; i++)
            _performPost(postUri, '{"index":$i}'),
        ]);

        final queued = await proxy.getQueuedRequests();
        // 保存キーの衝突で上書きされず、投入件数と保存件数が一致すること
        expect(queued.length, equals(_concurrentRequestCount));
        // 全件が更新系リクエストとして保存されていること
        expect(
          queued.every((request) => request.method == 'POST'),
          isTrue,
        );
      });
    });

    /// キューが保存順（FIFO）で再送されること
    test('resends queued requests in the order they were stored', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        // オフライン中に投入順が判別できる本文で順番にキューへ保存する
        await _emitConnectivity(['none']);
        final postUri = Uri.parse('http://127.0.0.1:$port/api/sales');
        for (var i = 0; i < _orderedRequestCount; i++) {
          await _performPost(postUri, '{"index":$i}');
        }
        expect(
          (await proxy.getQueuedRequests()).length,
          equals(_orderedRequestCount),
        );

        // オンライン復帰でキューを消化させる
        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        // 上流が受信した順序が投入順と一致すること
        expect(
          upstream!.receivedBodies,
          equals([
            for (var i = 0; i < _orderedRequestCount; i++) '{"index":$i}',
          ]),
        );
      });
    });

    /// 接続数の上限を超える件数でも、キューを最後まで送り切れること
    test('drains more queued requests than the connection limit', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        // 長時間オフラインで大量に貯まった状態を再現する
        await _emitConnectivity(['none']);
        final postUri = Uri.parse('http://127.0.0.1:$port/api/sales');
        for (var i = 0; i < _drainRequestCount; i++) {
          await _performPost(postUri, '{"index":$i}');
        }
        expect(
          (await proxy.getQueuedRequests()).length,
          equals(_drainRequestCount),
        );

        // オンライン復帰でキューを消化させる
        await _emitConnectivity(['wifi']);
        // 既定のテスト時間内に判定できるよう、待機は 20 秒までとする
        await _waitUntil(
          () async => (await proxy.getQueuedRequests()).isEmpty,
        );

        // 応答本文を読み捨てて接続を解放しないと、上限に達した時点で止まる
        expect(await proxy.getQueuedRequests(), isEmpty);
        expect(upstream!.receivedBodies.length, equals(_drainRequestCount));
      });
    });

    /// 短時間に連続してドロップされた履歴が 1 件も失われず保存されること
    test('keeps every dropped request history entry', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          // 履歴だけを残す運用を検証するため、隔離ではなく破棄を指定する
          config: ProxyConfig(
            origin: upstream!.origin,
            dropPolicy: DropPolicy.drop,
          ),
        );

        // オフライン中に複数の更新系リクエストをキューへ保存する
        await _emitConnectivity(['none']);
        final postUri = Uri.parse('http://127.0.0.1:$port/api/sales');
        await Future.wait([
          for (var i = 0; i < _concurrentRequestCount; i++)
            _performPost(postUri, '{"index":$i}'),
        ]);
        expect(
          (await proxy.getQueuedRequests()).length,
          equals(_concurrentRequestCount),
        );

        // 上流が 4xx を返す状態でオンライン復帰させ、キューをドロップさせる
        upstream!.statusCode = HttpStatus.badRequest;
        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final dropped = await proxy.getDroppedRequests();
        // 履歴キーの衝突で上書きされず、ドロップ件数と履歴件数が一致すること
        expect(dropped.length, equals(_concurrentRequestCount));
        // 4xx によるドロップとして記録されていること
        expect(
          dropped.every((request) => request.dropReason == '4xx_error'),
          isTrue,
        );
      });
    });
  });

  group('キュー投入時の応答（doc/specs.ja.md 【5】キュー再送ポリシー）', () {
    /// オフライン経路とオンライン経路のどちらでも接続を閉じる指定を返すこと
    test('closes the connection on both queued responses', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        final postUri = Uri.parse('http://127.0.0.1:$port/api/sales');

        // 上流が停止した状態（オンライン経路の失敗）でキューへ回す
        await upstream!.close();
        final onlinePathResult =
            await _performPostWithHeaders(postUri, '{"index":0}');
        expect(onlinePathResult.headers['connection'], equals('close'));

        // オフラインへ遷移させ、オフライン経路でキューへ回す
        await _emitConnectivity(['none']);
        final offlinePathResult =
            await _performPostWithHeaders(postUri, '{"index":1}');
        // 経路が違ってもクライアント接続の扱いが揃っていること
        expect(offlinePathResult.headers['connection'], equals('close'));

        // どちらの経路でもキューへ保存されていること
        expect((await proxy.getQueuedRequests()).length, equals(2));
      });
    });
  });
}
