import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// 仕様上のヘルスチェック既定パス（doc/specs.ja.md 【2】死活監視）。
const String _defaultHealthCheckPath = '/__offline_web_proxy/health';

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// HTTP 応答の検証に必要な要素だけを保持する型。
typedef _HttpResult = ({int statusCode, HttpHeaders headers, String body});

/// 上流サーバのモック。受信パスを記録し、常に 200 を返す。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      receivedPaths.add(request.uri.path);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write('upstream-ok');
      await request.response.close();
    });
  }

  final HttpServer _server;

  /// 上流が受信したリクエストパスの一覧。
  final List<String> receivedPaths = <String>[];

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

/// 接続だけ受け付けて応答を返さない上流サーバを起動する（タイムアウト検証用）。
Future<HttpServer> _startStallingUpstream() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest request) {
    // 応答を返さずタイムアウトさせる
  });
  return server;
}

/// 空きポート番号を 1 つ取得する（固定ポート指定の検証用）。
Future<int> _findFreePort() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close(force: true);
  return port;
}

/// 条件が成立するまで待機する。並列実行時のタイミング差を吸収する。
Future<bool> _waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 8),
  Duration interval = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) {
      return true;
    }
    await Future<void>.delayed(interval);
  }
  return false;
}

/// 指定ポートとは異なる空きポート番号を取得する。
Future<int> _findFreePortExcluding(int excludedPort) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    final port = await _findFreePort();
    if (port != excludedPort) {
      return port;
    }
  }
  throw StateError('空きポートを確保できませんでした');
}

/// 実 HttpClient で GET を実行し、ステータス、ヘッダ、本文を返す。
Future<_HttpResult> _performGet(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      headers: response.headers,
      body: body,
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
    hiveTestDirectory =
        Directory.systemTemp.createTempSync('offline_web_proxy_recovery').path;
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

  /// アプリ再起動でポートが変わった状況を再現する。
  ///
  /// 一度起動して停止し、直前のバインドポートを永続化させたうえで、
  /// 別のポートで起動し直す。読み替え対象ポートの仕様
  /// （doc/specs.ja.md 【2】旧ポート URL の読み替え）に合わせた前提条件を作る。
  ///
  /// Returns: 旧ポートと現行ポート。
  Future<({int stalePort, int currentPort})> restartWithChangedPort() async {
    final origin = upstream!.origin;
    final stalePort = await proxy.start(config: ProxyConfig(origin: origin));
    await proxy.stop();

    final currentPort = await _findFreePortExcluding(stalePort);
    await proxy.start(config: ProxyConfig(origin: origin, port: currentPort));

    return (stalePort: stalePort, currentPort: currentPort);
  }

  group('死活監視（doc/specs.ja.md 【2】死活監視）', () {
    /// ヘルスチェックパスが 204 と no-store を返すこと
    test('health check path responds with 204 and no-store', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final result = await _performGet(
          Uri.parse('http://127.0.0.1:$port$_defaultHealthCheckPath'),
        );

        // 稼働確認は本文を持たない 204 で応答すること
        expect(result.statusCode, equals(HttpStatus.noContent));
        // 稼働確認結果がキャッシュされないこと
        expect(result.headers.value('cache-control'), equals('no-store'));
      });
    });

    /// ヘルスチェック要求が上流へ転送されないこと
    test('health check request is not forwarded upstream', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performGet(
          Uri.parse('http://127.0.0.1:$port$_defaultHealthCheckPath'),
        );

        // 上流には 1 件も届かないこと
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// ヘルスチェック要求が統計に計上されないこと
    test('health check request is excluded from statistics', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final before = await proxy.getStats();
        await _performGet(
          Uri.parse('http://127.0.0.1:$port$_defaultHealthCheckPath'),
        );
        final after = await proxy.getStats();

        // 稼働確認では総リクエスト数が増えないこと
        expect(after.totalRequests, equals(before.totalRequests));
      });
    });

    /// healthCheckPath を変更した場合、その指定パスで応答すること
    test('health check path is configurable', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            healthCheckPath: '/__custom_health',
          ),
        );

        final custom = await _performGet(
          Uri.parse('http://127.0.0.1:$port/__custom_health'),
        );

        // 指定したパスが稼働確認として扱われること
        expect(custom.statusCode, equals(HttpStatus.noContent));

        final defaultPath = await _performGet(
          Uri.parse('http://127.0.0.1:$port$_defaultHealthCheckPath'),
        );

        // 既定パスは通常のリクエストとして上流へ転送されること
        expect(defaultPath.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedPaths, contains(_defaultHealthCheckPath));
      });
    });

    /// 稼働中は probe() が true を返すこと
    test('probe returns true while the server responds', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        // 実応答が得られること
        expect(await proxy.probe(), isTrue);
      });
    });

    /// ソケット死亡状態では probe() が false、isRunning は true のままであること
    test('probe returns false for a dead socket while isRunning stays true',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));
        await proxy.closeServerSocketForTesting();

        // 実応答が無いことを検知できること
        expect(await proxy.probe(), isFalse);
        // 内部フラグは稼働中のままであること（フラグでは死亡を検知できない）
        expect(proxy.isRunning, isTrue);
      });
    });

    /// 未起動時は probe() が false を返すこと
    test('probe returns false before start', () async {
      await withRealHttpClient(() async {
        // 起動前は稼働確認が失敗すること
        expect(await proxy.probe(), isFalse);
      });
    });
  });

  group('ポート公開（doc/specs.ja.md 【20】接続復旧）', () {
    /// 稼働中の port と baseUri が実際のバインド先を示すこと
    test('port and baseUri expose the bound endpoint', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        // start() の戻り値と一致すること
        expect(proxy.port, equals(port));
        // WebView が読み込むベース URI を組み立てられること
        expect(proxy.baseUri, equals(Uri.parse('http://127.0.0.1:$port')));
      });
    });

    /// 未起動時と停止後は port と baseUri が null であること
    test('port and baseUri are null while stopped', () async {
      await withRealHttpClient(() async {
        // 起動前は未確定であること
        expect(proxy.port, isNull);
        expect(proxy.baseUri, isNull);

        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));
        await proxy.stop();

        // 停止後も未確定に戻ること
        expect(proxy.port, isNull);
        expect(proxy.baseUri, isNull);
      });
    });
  });

  group('自動復旧（doc/specs.ja.md 【2】ソケット死亡と自動復旧）', () {
    /// 応答がある場合は再バインドしないこと
    test('ensureRunning keeps the server when it responds', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final result = await proxy.ensureRunning();

        // 応答があるため再バインド不要と判定されること
        expect(result.cause, equals(ProxyRecoveryCause.healthy));
        expect(result.restarted, isFalse);
        // ポートは変化しないこと
        expect(result.port, equals(port));
        expect(result.portChanged, isFalse);
        // ポート変化が無い場合は再読込先を示さないこと
        expect(result.reloadUri, isNull);
      });
    });

    /// ソケット死亡時に同一ポートで再バインドして復旧すること
    test('ensureRunning rebinds a dead socket on the same port', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final fixedPort = await _findFreePort();
        await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, port: fixedPort),
        );
        await proxy.closeServerSocketForTesting();

        final result = await proxy.ensureRunning(
          probeTimeout: const Duration(milliseconds: 300),
        );

        // 応答が無いため再バインドされること
        expect(result.cause, equals(ProxyRecoveryCause.socketDead));
        expect(result.restarted, isTrue);
        // 固定ポート指定のためポートは維持されること
        expect(result.port, equals(fixedPort));
        expect(result.portChanged, isFalse);
        // 復旧後は実応答が得られること
        expect(await proxy.probe(), isTrue);
      });
    });

    /// force 指定時は応答があっても再バインドすること
    test('ensureRunning with force rebinds even when healthy', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final fixedPort = await _findFreePort();
        await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, port: fixedPort),
        );

        final result = await proxy.ensureRunning(force: true);

        // 稼働確認結果にかかわらず再バインドされること
        expect(result.restarted, isTrue);
        // 再バインド後も応答が得られること
        expect(await proxy.probe(), isTrue);
      });
    });

    /// 未起動時は notStarted を返し再バインドしないこと
    test('ensureRunning reports notStarted before start', () async {
      await withRealHttpClient(() async {
        final result = await proxy.ensureRunning();

        // start() 前は復旧対象外であること
        expect(result.cause, equals(ProxyRecoveryCause.notStarted));
        expect(result.restarted, isFalse);
        expect(result.port, isNull);
      });
    });

    /// 再バインドしても永続化領域が維持されること
    test('ensureRunning keeps persisted cache across a rebind', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        // キャッシュを 1 件作る
        await _performGet(Uri.parse('http://127.0.0.1:$port/page'));
        final before = await proxy.getCacheList();
        expect(before, isNotEmpty);

        await proxy.closeServerSocketForTesting();
        await proxy.ensureRunning(
          probeTimeout: const Duration(milliseconds: 300),
        );

        // 再バインド後もキャッシュを読み出せること（Hive を閉じないこと）
        final after = await proxy.getCacheList();
        expect(after.length, equals(before.length));
      });
    });

    /// 復旧成功時に serverRecovered イベントを発行すること
    test('ensureRunning emits serverRecovered on recovery', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        final recovered = Completer<ProxyEvent>();
        final subscription = proxy.events.listen((ProxyEvent event) {
          if (event.type == ProxyEventType.serverRecovered &&
              !recovered.isCompleted) {
            recovered.complete(event);
          }
        });

        await proxy.closeServerSocketForTesting();
        await proxy.ensureRunning(
          probeTimeout: const Duration(milliseconds: 300),
        );

        final event = await recovered.future.timeout(
          const Duration(seconds: 5),
        );
        await subscription.cancel();

        // 復旧の判定種別が通知されること
        expect(event.data['cause'], equals(ProxyRecoveryCause.socketDead.name));
        // 復旧後のポートと実行回数が通知されること
        expect(event.data['newPort'], equals(proxy.port));
        expect(event.data['restartCount'], equals(1));
      });
    });
  });

  group('復旧試行の抑制（doc/specs.ja.md 【2】復旧試行の抑制）', () {
    /// 同時に要求しても再バインドは 1 回だけ実行されること
    test('concurrent ensureRunning calls share a single rebind', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));
        await proxy.closeServerSocketForTesting();

        const probeTimeout = Duration(milliseconds: 300);
        final results = await Future.wait<ProxyRecoveryResult>([
          proxy.ensureRunning(probeTimeout: probeTimeout),
          proxy.ensureRunning(probeTimeout: probeTimeout),
          proxy.ensureRunning(probeTimeout: probeTimeout),
        ]);

        // 3 回要求しても再バインドは 1 回に集約されること
        final diagnostics = await proxy.getDiagnostics();
        expect(diagnostics.restartCount, equals(1));
        // いずれの呼び出しも同じ復旧結果を受け取ること
        expect(
          results.map((ProxyRecoveryResult r) => r.port).toSet().length,
          equals(1),
        );
      });
    });

    /// 上限超過時は再バインドせず recoveryFailed を返すこと
    test('ensureRunning stops rebinding after the per-minute limit', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            maxRestartAttemptsPerMinute: 1,
          ),
        );

        final first = await proxy.ensureRunning(force: true);
        // 上限内の 1 回目は再バインドされること
        expect(first.restarted, isTrue);

        final second = await proxy.ensureRunning(force: true);
        // 上限を超えた 2 回目は再バインドを行わないこと
        expect(second.cause, equals(ProxyRecoveryCause.recoveryFailed));
        expect(second.restarted, isFalse);
      });
    });

    /// 上限超過時に serverUnavailable イベントを発行すること
    test('ensureRunning emits serverUnavailable when the limit is exceeded',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            maxRestartAttemptsPerMinute: 1,
          ),
        );

        final unavailable = Completer<ProxyEvent>();
        final subscription = proxy.events.listen((ProxyEvent event) {
          if (event.type == ProxyEventType.serverUnavailable &&
              !unavailable.isCompleted) {
            unavailable.complete(event);
          }
        });

        await proxy.ensureRunning(force: true);
        await proxy.ensureRunning(force: true);

        final event = await unavailable.future.timeout(
          const Duration(seconds: 5),
        );
        await subscription.cancel();

        // 復旧できなかった理由が通知されること
        expect(
          event.data['cause'],
          equals(ProxyRecoveryCause.recoveryFailed.name),
        );
      });
    });

    /// 復旧処理中に stop() が完了した場合は復旧を中止すること
    test('recovery is aborted when stop completes during recovery', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));
        await proxy.closeServerSocketForTesting();

        // 稼働確認の待機中に停止を完了させる
        final recovery = proxy.ensureRunning(
          probeTimeout: const Duration(milliseconds: 500),
        );
        await proxy.stop();
        final result = await recovery;

        // 復旧は中止され失敗として返ること
        expect(result.cause, equals(ProxyRecoveryCause.recoveryFailed));
        expect(result.restarted, isFalse);
        // 停止状態が維持されること（再バインドしたソケットを残さないこと）
        expect(proxy.isRunning, isFalse);
        expect(proxy.port, isNull);
      });
    });

    /// 再バインドに失敗した場合は recoveryFailed と失敗内容を返すこと
    test('ensureRunning reports recoveryFailed when the port is occupied',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final fixedPort = await _findFreePort();
        await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, port: fixedPort),
        );

        await proxy.closeServerSocketForTesting();
        // 復旧先ポートを他のサーバが占有した状態を作る
        final occupier = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          fixedPort,
        );

        try {
          final result = await proxy.ensureRunning(
            probeTimeout: const Duration(milliseconds: 300),
          );

          // 再バインドできないことを結果で表現すること（例外は投げない）
          expect(result.cause, equals(ProxyRecoveryCause.recoveryFailed));
          expect(result.restarted, isFalse);
          expect(result.error, isNotNull);
        } finally {
          await occupier.close(force: true);
        }
      });
    });
  });

  group('旧ポート URL の読み替え（doc/specs.ja.md 【2】旧ポート URL の読み替え）',
      () {
    /// 現行ポートと一致する URL はそのまま返すこと
    test('resolveReloadUri keeps a URL that already uses the current port',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final resolved =
            proxy.resolveReloadUri('http://127.0.0.1:$port/app/index.html');

        // 読み替え不要な URL は変化しないこと
        expect(resolved, equals(Uri.parse('http://127.0.0.1:$port/app/index.html')));
      });
    });

    /// ポートのみ異なる URL を現行ポートへ読み替え、パス以降を保持すること
    test('resolveReloadUri rewrites a stale port and keeps path, query, and '
        'fragment', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final ports = await restartWithChangedPort();
        final port = ports.currentPort;
        final stalePort = ports.stalePort;

        final resolved = proxy.resolveReloadUri(
          'http://127.0.0.1:$stalePort/app/index.html?a=1#top',
        );

        // ポートだけが現行値へ置き換わること
        expect(resolved?.port, equals(port));
        // パス、クエリ、フラグメントが保持されること
        expect(resolved?.path, equals('/app/index.html'));
        expect(resolved?.query, equals('a=1'));
        expect(resolved?.fragment, equals('top'));
      });
    });

    /// localhost 表記のホストを設定ホストへ正規化すること
    test('resolveReloadUri normalizes the loopback host to the configured host',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final ports = await restartWithChangedPort();
        final port = ports.currentPort;
        final stalePort = ports.stalePort;

        final resolved =
            proxy.resolveReloadUri('http://localhost:$stalePort/app');

        // 設定ホストの表記へ揃えること
        expect(resolved?.host, equals('127.0.0.1'));
        expect(resolved?.port, equals(port));
      });
    });

    /// 対象外の URL は null を返すこと
    test('resolveReloadUri returns null for out-of-scope URLs', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        // loopback 以外のホストは対象外であること
        expect(proxy.resolveReloadUri('http://example.com/app'), isNull);
        // http 以外のスキームは対象外であること
        expect(proxy.resolveReloadUri('https://127.0.0.1:9999/app'), isNull);
        // 解析できない文字列は対象外であること
        expect(proxy.resolveReloadUri('::::'), isNull);
        // このインスタンスが使っていないポートは対象外であること
        final unknownPort = await _findFreePortExcluding(proxy.port!);
        expect(
          proxy.resolveReloadUri('http://127.0.0.1:$unknownPort/app'),
          isNull,
        );
      });
    });

    /// 停止中は現行ポートが不明なため null を返すこと
    test('resolveReloadUri returns null while stopped', () async {
      await withRealHttpClient(() async {
        // 起動前は読み替え先が決まらないこと
        expect(proxy.resolveReloadUri('http://127.0.0.1:8787/app'), isNull);
      });
    });
  });

  group('遷移判定の stalePortUrl（doc/specs.ja.md 【2】旧ポート URL の読み替え）',
      () {
    /// ポートのみ異なる loopback URL が stalePortUrl として解決されること
    test('resolveNavigationTarget reports stalePortUrl for a stale port',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final ports = await restartWithChangedPort();
        final port = ports.currentPort;
        final stalePort = ports.stalePort;

        final resolution = proxy.resolveNavigationTarget(
          targetUrl: 'http://127.0.0.1:$stalePort/app',
        );

        // 解決不能ではなく旧ポート URL として扱うこと
        expect(resolution.reason, equals(ProxyNavigationReason.stalePortUrl));
        // WebView 内で扱う遷移として解決すること
        expect(
          resolution.disposition,
          equals(ProxyNavigationDisposition.inWebView),
        );
        // 現行ポートの proxy URL が得られること
        expect(resolution.proxyUri?.port, equals(port));
      });
    });

    /// 旧ポート URL の遷移では現行ポートの読み込みを推奨すること
    test('recommendMainFrameNavigation recommends loading the current port',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final ports = await restartWithChangedPort();
        final port = ports.currentPort;
        final stalePort = ports.stalePort;

        final recommendation = proxy.recommendMainFrameNavigation(
          targetUrl: 'http://127.0.0.1:$stalePort/app',
        );

        // proxy URL の読み込みを推奨すること
        expect(
          recommendation.action,
          equals(ProxyWebViewNavigationAction.loadProxyUrl),
        );
        // 読み込み先が現行ポートであること
        expect(recommendation.webViewUri?.port, equals(port));
      });
    });

    /// 停止中の loopback URL は解決不能のままであること（回帰確認）
    test('resolveNavigationTarget keeps unknownLoopbackUrl while stopped',
        () async {
      await withRealHttpClient(() async {
        final resolution = proxy.resolveNavigationTarget(
          targetUrl: 'http://127.0.0.1:8787/app',
        );

        // 現行ポート不明では読み替えできないこと
        expect(
          resolution.reason,
          equals(ProxyNavigationReason.unknownLoopbackUrl),
        );
      });
    });
  });

  group('WebView エラーからの復旧（doc/specs.ja.md 【2】WebView エラーからの復旧）',
      () {
    /// proxy 宛の失敗でソケット死亡時に復旧し、失敗 URL を再読込先に返すこと
    test('recoverFromWebResourceError recovers a dead socket for a proxy URL',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final fixedPort = await _findFreePort();
        await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, port: fixedPort),
        );
        await proxy.closeServerSocketForTesting();

        final result = await proxy.recoverFromWebResourceError(
          errorCode: -1004,
          failingUrl: 'http://127.0.0.1:$fixedPort/app',
        );

        // 応答が無いため再バインドされること
        expect(result.cause, equals(ProxyRecoveryCause.socketDead));
        expect(result.restarted, isTrue);
        // 失敗した URL を再読込先として返すこと
        expect(
          result.reloadUri,
          equals(Uri.parse('http://127.0.0.1:$fixedPort/app')),
        );
      });
    });

    /// ポートのみ異なる失敗 URL は読み替えのみで再バインドしないこと
    test('recoverFromWebResourceError rewrites a stale port without rebinding',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final ports = await restartWithChangedPort();
        final port = ports.currentPort;
        final stalePort = ports.stalePort;

        final result = await proxy.recoverFromWebResourceError(
          failingUrl: 'http://127.0.0.1:$stalePort/app',
        );

        // サーバは応答しているため再バインドは不要であること
        expect(result.cause, equals(ProxyRecoveryCause.stalePort));
        expect(result.restarted, isFalse);
        // 現行ポートへ読み替えた URL を返すこと
        expect(result.reloadUri?.port, equals(port));
      });
    });

    /// proxy と無関係な失敗では何もしないこと
    test('recoverFromWebResourceError ignores unrelated URLs', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        final external = await proxy.recoverFromWebResourceError(
          failingUrl: 'https://example.com/page',
        );

        // 外部サイトの失敗は復旧対象外であること
        expect(external.cause, equals(ProxyRecoveryCause.unrelated));
        expect(external.restarted, isFalse);
        expect(external.reloadUri, isNull);

        final missing = await proxy.recoverFromWebResourceError();

        // 失敗 URL が不明な場合も復旧対象外であること
        expect(missing.cause, equals(ProxyRecoveryCause.unrelated));
      });
    });

    /// isMainFrame は復旧判定に影響しないこと
    test('recoverFromWebResourceError recovers for subresource failures too',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final fixedPort = await _findFreePort();
        await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, port: fixedPort),
        );
        await proxy.closeServerSocketForTesting();

        final result = await proxy.recoverFromWebResourceError(
          failingUrl: 'http://127.0.0.1:$fixedPort/app.css',
          isMainFrame: false,
        );

        // メインフレーム以外の失敗でも proxy 宛なら復旧すること
        expect(result.restarted, isTrue);
      });
    });
  });

  group('診断情報（doc/specs.ja.md 【20】接続復旧）', () {
    /// 起動直後の診断情報が現行状態を示すこと
    test('getDiagnostics reports the running state after start', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, preferredPort: 0),
        );

        final diagnostics = await proxy.getDiagnostics();

        // 稼働状態とポートが取得できること
        expect(diagnostics.isRunning, isTrue);
        expect(diagnostics.port, equals(port));
        // 起動直後は再バインドが行われていないこと
        expect(diagnostics.restartCount, equals(0));
        // 起動日時が記録されること
        expect(diagnostics.startedAt, isNotNull);
      });
    });

    /// 稼働確認の実施結果が記録されること
    test('getDiagnostics records the last probe result', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        await proxy.probe();
        final diagnostics = await proxy.getDiagnostics();

        // 最終稼働確認の日時と結果が記録されること
        expect(diagnostics.lastProbeAt, isNotNull);
        expect(diagnostics.lastProbeSucceeded, isTrue);
      });
    });

    /// 再バインドの実施内容が記録されること
    test('getDiagnostics records the rebind outcome', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));
        await proxy.closeServerSocketForTesting();
        await proxy.ensureRunning(
          probeTimeout: const Duration(milliseconds: 300),
        );

        final diagnostics = await proxy.getDiagnostics();

        // 再バインド回数が加算されること
        expect(diagnostics.restartCount, equals(1));
        // 直近の復旧種別が記録されること
        expect(
          diagnostics.lastRecoveryCause,
          equals(ProxyRecoveryCause.socketDead),
        );
      });
    });
  });

  group('設定既定値（doc/specs.ja.md 【20】ProxyConfig）', () {
    /// 復旧関連設定の既定値が仕様どおりであること
    test('recovery settings use the documented defaults', () {
      const config = ProxyConfig(origin: 'https://example.com');

      // ヘルスチェックパスの既定値
      expect(config.healthCheckPath, equals(_defaultHealthCheckPath));
      // 定期ヘルスチェックは既定で無効
      expect(config.healthCheckInterval, equals(Duration.zero));
      // アイドルタイムアウトの既定値
      expect(config.serverIdleTimeout, equals(const Duration(seconds: 120)));
      // 1 分あたりの再バインド上限の既定値
      expect(config.maxRestartAttemptsPerMinute, equals(5));
      // フォールバック HTML は既定で内蔵ページ
      expect(config.offlineFallbackHtml, isNull);
      expect(config.gatewayTimeoutHtml, isNull);
    });

    /// 明示指定した値が保持されること
    test('recovery settings keep explicit values', () {
      const config = ProxyConfig(
        origin: 'https://example.com',
        healthCheckPath: '/__health',
        healthCheckInterval: Duration(seconds: 30),
        serverIdleTimeout: Duration(seconds: 5),
        maxRestartAttemptsPerMinute: 2,
        offlineFallbackHtml: '<html>offline</html>',
        gatewayTimeoutHtml: '<html>timeout</html>',
      );

      // 指定値がそのまま保持されること
      expect(config.healthCheckPath, equals('/__health'));
      expect(config.healthCheckInterval, equals(const Duration(seconds: 30)));
      expect(config.serverIdleTimeout, equals(const Duration(seconds: 5)));
      expect(config.maxRestartAttemptsPerMinute, equals(2));
      expect(config.offlineFallbackHtml, equals('<html>offline</html>'));
      expect(config.gatewayTimeoutHtml, equals('<html>timeout</html>'));
    });
  });

  group('フォールバック応答の差し替え（doc/specs.ja.md 【20】ProxyConfig）', () {
    /// タイムアウト応答の本文を差し替えられること
    test('gatewayTimeoutHtml replaces the timeout response body', () async {
      await withRealHttpClient(() async {
        final stalling = await _startStallingUpstream();
        try {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: 'http://127.0.0.1:${stalling.port}',
              requestTimeout: const Duration(milliseconds: 300),
              gatewayTimeoutHtml: '<html>timeout-page</html>',
            ),
          );

          final result =
              await _performGet(Uri.parse('http://127.0.0.1:$port/slow'));

          // タイムアウト時は 504 を返すこと
          expect(result.statusCode, equals(HttpStatus.gatewayTimeout));
          // 指定した HTML が本文になること
          expect(result.body, equals('<html>timeout-page</html>'));
        } finally {
          await stalling.close(force: true);
        }
      });
    });
  });

  group('定期ヘルスチェック（doc/specs.ja.md 【2】定期ヘルスチェック）', () {
    /// 間隔を設定した場合はソケット死亡後に自動復旧すること
    test('periodic health check recovers a dead socket automatically',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            healthCheckInterval: const Duration(milliseconds: 200),
          ),
        );

        await proxy.closeServerSocketForTesting();

        // 定期確認により、明示的な復旧要求なしで復旧すること
        final recovered = await _waitUntil(
          () => proxy.probe(timeout: const Duration(milliseconds: 500)),
        );
        expect(recovered, isTrue);
      });
    });

    /// 既定（無効）では自動復旧しないこと
    test('periodic health check stays disabled by default', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        await proxy.closeServerSocketForTesting();
        await Future<void>.delayed(const Duration(milliseconds: 800));

        // 自動復旧が動作しないこと（明示的な復旧要求が必要）
        expect(await proxy.probe(), isFalse);
      });
    });
  });

  group('アイドルタイムアウト（doc/specs.ja.md 【2】keep-alive とアイドルタイムアウト）',
      () {
    /// 設定時間を超えた keep-alive 接続がサーバ側から切断されること
    test('serverIdleTimeout closes an idle keep-alive connection', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            serverIdleTimeout: const Duration(seconds: 1),
          ),
        );

        final socket = await Socket.connect('127.0.0.1', port);
        final closed = Completer<void>();
        socket.listen(
          (_) {},
          onDone: () {
            if (!closed.isCompleted) {
              closed.complete();
            }
          },
          onError: (Object _) {
            if (!closed.isCompleted) {
              closed.complete();
            }
          },
        );

        socket.write('GET $_defaultHealthCheckPath HTTP/1.1\r\n'
            'Host: 127.0.0.1:$port\r\n'
            'Connection: keep-alive\r\n\r\n');
        await socket.flush();

        // アイドル時間を超えるとサーバから切断されること
        await expectLater(
          closed.future.timeout(const Duration(seconds: 5)),
          completes,
        );
        socket.destroy();
      });
    });
  });

  group('設定値の検証（doc/specs.ja.md 【2】死活監視）', () {
    /// ルート記法を含む healthCheckPath は起動時に拒否されること
    test('start rejects a healthCheckPath containing route syntax', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();

        // パスパラメータ記法は業務ルートを奪う恐れがあるため拒否すること
        await expectLater(
          proxy.start(
            config: ProxyConfig(
              origin: upstream!.origin,
              healthCheckPath: '/api/<id>',
            ),
          ),
          throwsA(isA<ProxyStartException>()),
        );
        // 起動に失敗した状態が残らないこと
        expect(proxy.isRunning, isFalse);
      });
    });

    /// 相対パスの healthCheckPath は起動時に拒否されること
    test('start rejects a healthCheckPath without a leading slash', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();

        // `/` 始まりでないパスは拒否すること
        await expectLater(
          proxy.start(
            config: ProxyConfig(
              origin: upstream!.origin,
              healthCheckPath: 'health',
            ),
          ),
          throwsA(isA<ProxyStartException>()),
        );
      });
    });

    /// ヘルスチェックパスへの POST は上流へ転送されること
    test('health check path forwards non-read methods upstream', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final result = await _performGet(
          Uri.parse('http://127.0.0.1:$port$_defaultHealthCheckPath'),
        );
        // GET は稼働確認として 204 を返すこと
        expect(result.statusCode, equals(HttpStatus.noContent));

        final client = HttpClient();
        try {
          final request = await client.postUrl(
            Uri.parse('http://127.0.0.1:$port$_defaultHealthCheckPath'),
          );
          request.write('payload');
          final response = await request.close();
          await response.drain<void>();
          // POST は稼働確認として扱わず上流へ転送すること
          expect(response.statusCode, equals(HttpStatus.ok));
        } finally {
          client.close(force: true);
        }

        expect(upstream!.receivedPaths, contains(_defaultHealthCheckPath));
      });
    });
  });

  group('復旧結果と診断の整合（doc/specs.ja.md 【2】ソケット死亡と自動復旧）', () {
    /// 停止推定時間が他の復旧結果へ引き継がれないこと
    test('downtimeMs is not carried over to later recovery results', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        await proxy.closeServerSocketForTesting();
        final withDowntime = await proxy.ensureRunning(
          probeTimeout: const Duration(milliseconds: 300),
          downtime: const Duration(seconds: 30),
        );
        // 渡された停止推定時間が結果に反映されること
        expect(withDowntime.downtimeMs, equals(30000));

        final withoutDowntime = await proxy.ensureRunning(
          probeTimeout: const Duration(milliseconds: 300),
        );
        // 次の復旧結果へは引き継がれないこと
        expect(withoutDowntime.downtimeMs, isNull);

        final diagnostics = await proxy.getDiagnostics();
        // 診断情報は最後に渡された値を保持すること
        expect(diagnostics.lastDowntimeMs, equals(30000));
      });
    });

    /// 上限を 0 にした場合は常に復旧を行わないこと
    test('a zero restart limit disables rebinding', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            maxRestartAttemptsPerMinute: 0,
          ),
        );
        await proxy.closeServerSocketForTesting();

        final result = await proxy.ensureRunning(
          probeTimeout: const Duration(milliseconds: 300),
        );

        // 再バインドを行わず失敗として返すこと
        expect(result.cause, equals(ProxyRecoveryCause.recoveryFailed));
        expect(result.restarted, isFalse);
      });
    });

    /// 再バインド失敗が連続した場合は待機してから再試行すること
    test('consecutive failures wait before the next rebind attempt', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final fixedPort = await _findFreePort();
        await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, port: fixedPort),
        );

        await proxy.closeServerSocketForTesting();
        // 復旧先ポートを占有して再バインドを失敗させる
        final occupier = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          fixedPort,
        );

        try {
          final first = await proxy.ensureRunning(
            probeTimeout: const Duration(milliseconds: 300),
          );
          // 1 回目は待機なしで失敗すること
          expect(first.cause, equals(ProxyRecoveryCause.recoveryFailed));

          final stopwatch = Stopwatch()..start();
          final second = await proxy.ensureRunning(
            probeTimeout: const Duration(milliseconds: 300),
          );
          stopwatch.stop();

          // 2 回目は 1 秒の待機を挟むこと
          expect(second.cause, equals(ProxyRecoveryCause.recoveryFailed));
          expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900));
        } finally {
          await occupier.close(force: true);
        }
      });
    });

    /// 停止後も診断情報が保持されること
    test('getDiagnostics keeps recovery history after stop', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));
        await proxy.closeServerSocketForTesting();
        await proxy.ensureRunning(
          probeTimeout: const Duration(milliseconds: 300),
        );
        await proxy.stop();

        final diagnostics = await proxy.getDiagnostics();

        // 停止しても再バインド回数と復旧種別を参照できること
        expect(diagnostics.isRunning, isFalse);
        expect(diagnostics.restartCount, equals(1));
        expect(
          diagnostics.lastRecoveryCause,
          equals(ProxyRecoveryCause.socketDead),
        );
      });
    });

    /// 永続化された直前のバインドポートを診断情報から取得できること
    test('getDiagnostics reports the persisted port', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final diagnostics = await proxy.getDiagnostics();

        // 現在のバインドポートが永続化されていること
        expect(diagnostics.persistedPort, equals(port));
      });
    });

    /// 復旧結果と診断情報が内容を読み取れる文字列を返すこと
    test('recovery models expose readable toString output', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        final result = await proxy.ensureRunning();
        // 判定種別を含む文字列であること
        expect(result.toString(), contains('ProxyRecoveryResult'));
        expect(result.toString(), contains(ProxyRecoveryCause.healthy.name));

        final diagnostics = await proxy.getDiagnostics();
        // ポート情報を含む文字列であること
        expect(diagnostics.toString(), contains('ProxyDiagnostics'));
        expect(diagnostics.toString(), contains('${proxy.port}'));
      });
    });
  });

  group('ライフサイクル連動（doc/specs.ja.md 【2】アプリライフサイクル連動）', () {
    /// 復帰時にソケット死亡を検知して復旧を通知すること
    test('guard recovers and notifies on resume', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        final recovered = Completer<ProxyRecoveryResult>();
        final guard = ProxyLifecycleGuard(
          proxy: proxy,
          probeTimeout: const Duration(milliseconds: 300),
          onRecovered: (ProxyRecoveryResult result) {
            if (!recovered.isCompleted) {
              recovered.complete(result);
            }
          },
        );

        await proxy.closeServerSocketForTesting();
        guard.didChangeAppLifecycleState(AppLifecycleState.paused);
        guard.didChangeAppLifecycleState(AppLifecycleState.resumed);

        final result = await recovered.future.timeout(
          const Duration(seconds: 5),
        );

        // 再バインドが発生したことを通知すること
        expect(result.restarted, isTrue);
        // 停止推定時間が記録されること
        expect(result.downtimeMs, isNotNull);
      });
    });

    /// 正常時は復旧通知を行わないこと
    test('guard does not notify while the server responds', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        var recoveredCount = 0;
        final guard = ProxyLifecycleGuard(
          proxy: proxy,
          probeTimeout: const Duration(milliseconds: 300),
          onRecovered: (ProxyRecoveryResult _) => recoveredCount++,
        );

        guard.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // 応答があるため通知されないこと
        expect(recoveredCount, equals(0));
      });
    });

    /// 復旧できなかった場合は失敗を通知すること
    test('guard notifies failure when recovery is not possible', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            maxRestartAttemptsPerMinute: 0,
          ),
        );

        final failed = Completer<ProxyRecoveryResult>();
        final guard = ProxyLifecycleGuard(
          proxy: proxy,
          probeTimeout: const Duration(milliseconds: 300),
          onRecovered: (ProxyRecoveryResult _) {},
          onFailed: (ProxyRecoveryResult result) {
            if (!failed.isCompleted) {
              failed.complete(result);
            }
          },
        );

        await proxy.closeServerSocketForTesting();
        guard.didChangeAppLifecycleState(AppLifecycleState.resumed);

        final result = await failed.future.timeout(const Duration(seconds: 5));

        // 復旧不能を通知すること
        expect(result.cause, equals(ProxyRecoveryCause.recoveryFailed));
      });
    });

    /// currentUrlProvider を指定した場合は現行ポートへ読み替えた URL を通知すること
    test('guard rewrites the current URL for reload', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final ports = await restartWithChangedPort();
        final stalePort = ports.stalePort;

        final recovered = Completer<ProxyRecoveryResult>();
        final guard = ProxyLifecycleGuard(
          proxy: proxy,
          probeTimeout: const Duration(milliseconds: 300),
          currentUrlProvider: () => 'http://127.0.0.1:$stalePort/app',
          onRecovered: (ProxyRecoveryResult result) {
            if (!recovered.isCompleted) {
              recovered.complete(result);
            }
          },
        );

        await proxy.closeServerSocketForTesting();
        guard.didChangeAppLifecycleState(AppLifecycleState.resumed);

        final result = await recovered.future.timeout(
          const Duration(seconds: 5),
        );

        // 表示中 URL を現行ポートへ読み替えて通知すること
        expect(result.reloadUri?.port, equals(proxy.port));
        expect(result.reloadUri?.path, equals('/app'));
      });
    });
  });
}
