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

/// テストで使用する上流到達不能の連続失敗しきい値。
const int _failureThreshold = 2;

/// 本文を送り切らない応答で通知する Content-Length。
///
/// 実際に書き込む本文より大きくし、クライアントを受信待ちのままにする。
const int _partialBodyContentLength = 1000;

/// 接続の解放を確認するために発行するリクエスト件数。
///
/// 共有 `HttpClient` の `maxConnectionsPerHost`（50）を超える件数にし、
/// 受信途中の接続が解放されないと後続が空き待ちになることを検出する。
const int _connectionLimitProbeCount = 51;

/// 遮断後のリクエストが応答するまでに許容する時間。
///
/// 受け入れ条件「リンク層は up だが上流が落ちている環境で、WebView が
/// 数十秒無反応にならないこと」に対応する。
const Duration _shortCircuitBudget = Duration(seconds: 1);

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// HTTP 応答の検証に必要な要素だけを保持する型。
typedef _HttpResult = ({int statusCode, Map<String, String> headers});

/// 応答を停止させられる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      receivedPaths.add(request.uri.path);
      try {
        await request.drain<void>();
        if (hangs) {
          // 応答を返さずに保持し、上流が無反応な状態を再現する
          _hungResponses.add(request.response);
          return;
        }
        final location = redirectLocation;
        if (location != null) {
          // 上流が redirect を返す状態を再現する
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, location);
          await request.response.close();
          return;
        }
        if (sendsPartialBody) {
          // ヘッダだけ返して本文を送り切らず、受信途中で止まる状態を再現する
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType =
                ContentType('text', 'html', charset: 'utf-8')
            ..headers.contentLength = _partialBodyContentLength
            ..write('partial');
          await request.response.flush();
          _hungResponses.add(request.response);
          return;
        }
        request.response
          ..statusCode = statusCode
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 応答を返さずに保持しているレスポンスの一覧。
  final List<HttpResponse> _hungResponses = <HttpResponse>[];

  /// 上流が受信したリクエストパスの一覧。
  final List<String> receivedPaths = <String>[];

  /// 応答するステータスコード。テスト中に変更できる。
  int statusCode = HttpStatus.ok;

  /// `true` の間は応答を返さずに保持する。
  bool hangs = false;

  /// `true` の間はヘッダだけ返し、本文を送り切らずに保持する。
  bool sendsPartialBody = false;

  /// 値を設定している間は 302 と `Location` を返す。
  String? redirectLocation;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 保持していた応答を破棄し、上流サーバを停止する。
  Future<void> close() async {
    for (final response in _hungResponses) {
      try {
        await response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    }
    _hungResponses.clear();
    await _server.close(force: true);
  }
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

/// 実 HttpClient でリクエストを実行し、ステータスとヘッダを返す。
Future<_HttpResult> _performRequest(
  Uri uri, {
  String method = 'GET',
  bool followRedirects = true,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    request.followRedirects = followRedirects;
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
    const pathProviderChannel =
        MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel,
            (MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        // Hive の保存先をテスト用ディレクトリに固定する
        return hiveTestDirectory;
      }
      return null;
    });

    const connectivityChannel =
        MethodChannel('dev.fluttercommunity.plus/connectivity');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectivityChannel,
            (MethodCall methodCall) async {
      // リンク層は常に接続済みとして扱い、上流到達性だけを検証する
      if (methodCall.method == 'check') {
        return <String>['wifi'];
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
        Directory.systemTemp.createTempSync('offline_web_proxy_circuit').path;
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

  /// 上流が無反応な状態を作る設定を返す。
  ProxyConfig hangingConfig(String origin) {
    return ProxyConfig(
      origin: origin,
      upstreamFailureThreshold: _failureThreshold,
      // 無反応な上流を短時間で失敗と判定する
      requestTimeout: const Duration(milliseconds: 300),
      connectTimeout: const Duration(milliseconds: 300),
      upstreamProbeTimeout: const Duration(milliseconds: 300),
      upstreamProbeBackoffSeconds: const [1],
    );
  }

  group('上流到達性のサーキットブレーカ（doc/specs.ja.md 【10】オフライン応答）', () {
    /// 上流が無反応な場合、しきい値到達後は待たずにフォールバックへ落ちること
    test('short-circuits requests after consecutive unreachable attempts',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(config: hangingConfig(upstream!.origin));
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        // 上流を無反応にし、しきい値の回数だけ待たされる
        upstream!.hangs = true;
        for (var i = 0; i < _failureThreshold; i++) {
          await _performRequest(pageUri);
        }

        final diagnostics = await proxy.getDiagnostics();
        // 連続失敗で遮断状態へ遷移していること
        expect(
          diagnostics.upstreamCircuitState,
          equals(UpstreamCircuitState.open),
        );

        final receivedBefore = upstream!.receivedPaths.length;
        final stopwatch = Stopwatch()..start();
        final result = await _performRequest(pageUri);
        stopwatch.stop();

        // 遮断後はオフライン扱いの応答を即座に返すこと
        expect(result.headers['x-offline'], equals('1'));
        expect(stopwatch.elapsed, lessThan(_shortCircuitBudget));
        // 上流へは転送されていないこと
        expect(upstream!.receivedPaths.length, equals(receivedBefore));
      });
    });

    /// 遮断中の更新系リクエストが待たされずにキューへ入ること
    test('queues updates without waiting while the circuit is open', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(config: hangingConfig(upstream!.origin));
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        upstream!.hangs = true;
        for (var i = 0; i < _failureThreshold; i++) {
          await _performRequest(pageUri);
        }

        final stopwatch = Stopwatch()..start();
        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          method: 'POST',
        );
        stopwatch.stop();

        // 待たされずに応答が返ること
        expect(stopwatch.elapsed, lessThan(_shortCircuitBudget));
        // キュー投入として判別できる応答であること
        expect(result.statusCode, equals(HttpStatus.accepted));
        expect(result.headers['x-offline-queued'], equals('1'));
        // 再送用にキューへ保存されていること
        expect((await proxy.getQueuedRequests()).length, equals(1));
      });
    });

    /// 上流が応答を再開したら、復帰確認により転送が再開されること
    test('closes the circuit once the upstream answers again', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(config: hangingConfig(upstream!.origin));
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        upstream!.hangs = true;
        for (var i = 0; i < _failureThreshold; i++) {
          await _performRequest(pageUri);
        }
        expect(
          (await proxy.getDiagnostics()).upstreamCircuitState,
          equals(UpstreamCircuitState.open),
        );

        // 上流の応答を再開し、復帰確認の成功を待つ
        upstream!.hangs = false;
        await _waitUntil(() async {
          final diagnostics = await proxy.getDiagnostics();
          return diagnostics.upstreamCircuitState ==
              UpstreamCircuitState.closed;
        });

        final diagnostics = await proxy.getDiagnostics();
        // 遮断が解除され、失敗回数と最終到達日時が更新されていること
        expect(
          diagnostics.upstreamCircuitState,
          equals(UpstreamCircuitState.closed),
        );
        expect(diagnostics.consecutiveUpstreamFailures, equals(0));
        expect(diagnostics.lastUpstreamSuccessAt, isNotNull);

        // 転送が再開されること
        final result = await _performRequest(pageUri);
        expect(result.statusCode, equals(HttpStatus.ok));
        expect(result.headers['x-offline'], isNull);
      });
    });

    /// 上流が応答している限り、4xx や 5xx では遮断しないこと
    test('keeps the circuit closed while the upstream returns errors',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(config: hangingConfig(upstream!.origin));
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        // 上流はエラーを返すが応答自体は行う
        upstream!.statusCode = HttpStatus.internalServerError;
        for (var i = 0; i < _failureThreshold + 2; i++) {
          final result = await _performRequest(pageUri);
          // upstream の応答をそのまま返すこと
          expect(result.statusCode, equals(HttpStatus.internalServerError));
        }

        final diagnostics = await proxy.getDiagnostics();
        // サーバは生きているため遮断しないこと
        expect(
          diagnostics.upstreamCircuitState,
          equals(UpstreamCircuitState.closed),
        );
        expect(diagnostics.consecutiveUpstreamFailures, equals(0));
      });
    });

    /// 画面操作が無くても、キュー再送の失敗で遮断されること
    test('opens the circuit from failed queue resends', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        // 再送 1 回の失敗で遮断されるようにし、待ち時間を短くする
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            upstreamFailureThreshold: 1,
            requestTimeout: const Duration(milliseconds: 300),
            connectTimeout: const Duration(milliseconds: 300),
            upstreamProbeTimeout: const Duration(milliseconds: 300),
            upstreamProbeBackoffSeconds: const [1],
          ),
        );
        final salesUri = Uri.parse('http://127.0.0.1:$port/api/sales');

        // 応答する上流に対して更新系を送り、5xx でキューへ保存させる
        upstream!.statusCode = HttpStatus.internalServerError;
        await _performRequest(salesUri, method: 'POST');
        expect((await proxy.getQueuedRequests()).length, equals(1));

        // 上流を無反応にし、再送の失敗だけで遮断されるまで待つ
        upstream!.hangs = true;
        await _waitUntil(() async {
          final diagnostics = await proxy.getDiagnostics();
          return diagnostics.upstreamCircuitState == UpstreamCircuitState.open;
        });

        final diagnostics = await proxy.getDiagnostics();
        // 再送の失敗も上流断の判定材料になること
        expect(
          diagnostics.upstreamCircuitState,
          equals(UpstreamCircuitState.open),
        );
        // 再送対象はキューに残っていること
        expect((await proxy.getQueuedRequests()).length, equals(1));
      });
    });

    /// 接続そのものができない再送でも遮断されること
    test('opens the circuit when queued resends cannot connect', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            upstreamFailureThreshold: 1,
            requestTimeout: const Duration(milliseconds: 300),
            connectTimeout: const Duration(milliseconds: 300),
            upstreamProbeTimeout: const Duration(milliseconds: 300),
            upstreamProbeBackoffSeconds: const [1],
          ),
        );
        final salesUri = Uri.parse('http://127.0.0.1:$port/api/sales');

        // 応答する上流に対して更新系を送り、5xx でキューへ保存させる
        upstream!.statusCode = HttpStatus.internalServerError;
        await _performRequest(salesUri, method: 'POST');
        expect((await proxy.getQueuedRequests()).length, equals(1));

        // 上流を停止し、接続拒否で再送が失敗する状態にする
        await upstream!.close();
        upstream = null;

        await _waitUntil(() async {
          final diagnostics = await proxy.getDiagnostics();
          return diagnostics.upstreamCircuitState == UpstreamCircuitState.open;
        });

        final diagnostics = await proxy.getDiagnostics();
        // 接続を確立できない失敗も上流断の判定材料になること
        expect(
          diagnostics.upstreamCircuitState,
          equals(UpstreamCircuitState.open),
        );
        expect(
          diagnostics.consecutiveUpstreamFailures,
          greaterThanOrEqualTo(1),
        );
        // 再送対象は失われずキューに残ること
        expect((await proxy.getQueuedRequests()).length, equals(1));
      });
    });

    /// リンク層が切断されている間は復帰確認を行わないこと
    test('stops probing while the link layer is offline', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(config: hangingConfig(upstream!.origin));
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        upstream!.hangs = true;
        for (var i = 0; i < _failureThreshold; i++) {
          await _performRequest(pageUri);
        }
        expect(
          (await proxy.getDiagnostics()).upstreamCircuitState,
          equals(UpstreamCircuitState.open),
        );

        // リンク層の切断を通知したうえで、上流の応答を再開させる
        await _emitConnectivity(['none']);
        upstream!.hangs = false;
        // 通知の直前に発行済みの確認が届き切るのを待ってから基準を取る
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final receivedBefore = upstream!.receivedPaths.length;

        // バックオフ（1 秒）を超えて待っても確認が行われないこと
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(upstream!.receivedPaths.length, equals(receivedBefore));
        expect(
          (await proxy.getDiagnostics()).upstreamCircuitState,
          equals(UpstreamCircuitState.open),
        );

        // リンク層の復帰を契機に確認を再開し、遮断が解除されること
        await _emitConnectivity(['wifi']);
        await _waitUntil(() async {
          final diagnostics = await proxy.getDiagnostics();
          return diagnostics.upstreamCircuitState ==
              UpstreamCircuitState.closed;
        });
        expect(
          (await proxy.getDiagnostics()).upstreamCircuitState,
          equals(UpstreamCircuitState.closed),
        );
        expect(upstream!.receivedPaths.length, greaterThan(receivedBefore));
      });
    });

    /// 上流が redirect を返した場合も到達成功として記録すること
    test('records upstream success from a redirect response', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(config: hangingConfig(upstream!.origin));
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        // 連続失敗を 1 回だけ作る（しきい値 2 のため遮断はしない）
        upstream!.hangs = true;
        await _performRequest(pageUri);
        expect(
          (await proxy.getDiagnostics()).consecutiveUpstreamFailures,
          equals(1),
        );

        // 上流が redirect を返しても、応答している以上は到達可能とみなすこと
        upstream!.hangs = false;
        upstream!.redirectLocation = '/moved';
        await _performRequest(pageUri, followRedirects: false);

        final diagnostics = await proxy.getDiagnostics();
        expect(diagnostics.consecutiveUpstreamFailures, equals(0));
        expect(diagnostics.lastUpstreamSuccessAt, isNotNull);
      });
    });

    /// キュー再送の成功も到達成功として記録すること
    test('records upstream success from a queue resend', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            // 遮断させず、連続失敗回数の推移だけを検証する
            upstreamFailureThreshold: 0,
            requestTimeout: const Duration(milliseconds: 300),
            connectTimeout: const Duration(milliseconds: 300),
          ),
        );
        final salesUri = Uri.parse('http://127.0.0.1:$port/api/sales');

        // 5xx でキューへ保存させる
        upstream!.statusCode = HttpStatus.internalServerError;
        await _performRequest(salesUri, method: 'POST');
        expect((await proxy.getQueuedRequests()).length, equals(1));

        // 上流を無反応にし、再送の失敗を記録させる
        upstream!.hangs = true;
        await _waitUntil(() async =>
            (await proxy.getDiagnostics()).consecutiveUpstreamFailures > 0);
        expect(
          (await proxy.getDiagnostics()).consecutiveUpstreamFailures,
          greaterThan(0),
        );

        // 応答を再開すれば、再送の成功で連続失敗が解消されること
        upstream!.hangs = false;
        upstream!.statusCode = HttpStatus.ok;
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        final diagnostics = await proxy.getDiagnostics();
        expect(diagnostics.consecutiveUpstreamFailures, equals(0));
        expect(diagnostics.lastUpstreamSuccessAt, isNotNull);
      });
    });

    /// 遮断中はウォームアップが上流へ要求しないこと
    test('skips warmup while the circuit is open', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: hangingConfig(upstream!.origin));
        final pageUri = Uri.parse(
          'http://127.0.0.1:${proxy.port}/page',
        );

        upstream!.hangs = true;
        for (var i = 0; i < _failureThreshold; i++) {
          await _performRequest(pageUri);
        }
        expect(
          (await proxy.getDiagnostics()).upstreamCircuitState,
          equals(UpstreamCircuitState.open),
        );

        final result = await proxy.warmupCache(
          paths: const ['/warmup-a', '/warmup-b'],
        );

        // 待たずに失敗として返し、上流へは要求しないこと
        expect(result.successCount, equals(0));
        expect(result.failureCount, equals(2));
        expect(upstream!.receivedPaths, isNot(contains('/warmup-a')));
        expect(upstream!.receivedPaths, isNot(contains('/warmup-b')));
      });
    });

    /// しきい値 0 を指定した場合はサーキットブレーカが働かないこと
    test('never opens the circuit when the threshold is zero', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            upstreamFailureThreshold: 0,
            requestTimeout: const Duration(milliseconds: 300),
            connectTimeout: const Duration(milliseconds: 300),
          ),
        );
        final pageUri = Uri.parse('http://127.0.0.1:$port/page');

        upstream!.hangs = true;
        for (var i = 0; i < _failureThreshold + 2; i++) {
          await _performRequest(pageUri);
        }

        final diagnostics = await proxy.getDiagnostics();
        // 無効化時は従来どおり毎回上流へ転送すること
        expect(
          diagnostics.upstreamCircuitState,
          equals(UpstreamCircuitState.closed),
        );
        expect(upstream!.receivedPaths.length, equals(_failureThreshold + 2));
      });
    });
  });

  group('リクエスト全体の締め切り（doc/specs.ja.md 【15】タイムアウト／リトライ既定値）', () {
    /// 無反応な上流に対して、1 リクエストの待ち時間が締め切り内に収まること
    test('bounds one request by the configured deadline', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            // 遮断で早期に返らないよう、サーキットブレーカは無効にする
            upstreamFailureThreshold: 0,
            requestTimeout: const Duration(seconds: 1),
          ),
        );

        upstream!.hangs = true;
        final stopwatch = Stopwatch()..start();
        await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));
        stopwatch.stop();

        // ヘッダ待ちと本文待ちが積み上がらず、締め切り内で打ち切られること
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      });
    });

    /// 本文の受信を打ち切った接続が解放され、後続のリクエストを妨げないこと
    test('releases connections when the body cannot be read in time', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            // 遮断で転送を止めず、接続の解放だけを検証する
            upstreamFailureThreshold: 0,
            requestTimeout: const Duration(milliseconds: 200),
            connectTimeout: const Duration(milliseconds: 200),
          ),
        );

        // 接続数の上限を超える回数、本文の受信を締め切りで打ち切らせる
        upstream!.sendsPartialBody = true;
        for (var i = 0; i < _connectionLimitProbeCount; i++) {
          await _performRequest(Uri.parse('http://127.0.0.1:$port/slow/$i'));
        }

        // 上流が正常に応答する状態へ戻す
        upstream!.sendsPartialBody = false;
        final stopwatch = Stopwatch()..start();
        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
        );
        stopwatch.stop();

        // 打ち切った接続が残っていると、空き待ちで転送できず 504 になる
        expect(result.statusCode, equals(HttpStatus.ok));
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      });
    });
  });
}
