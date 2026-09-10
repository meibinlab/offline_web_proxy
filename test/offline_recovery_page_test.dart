import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/pages/offline_recovery_page.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// ページ遷移としてリクエストするためのヘッダ。
const Map<String, String> _navigationHeaders = {
  'Sec-Fetch-Mode': 'navigate',
  'Accept': 'text/html',
};

/// 既定のページが持つ再試行ボタン。
const String _retryButton =
    '<button type="button" onclick="location.reload()">再試行</button>';

/// 監視スクリプトの `<script>` 要素の開始タグ。
const String _scriptOpenTag = '<script data-offline-web-proxy="recovery">';

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// HTTP 応答の検証に必要な要素だけを保持する型。
typedef _HttpResult = ({
  int statusCode,
  Map<String, String> headers,
  String body,
});

/// 受信したリクエストを記録する上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      receivedPaths.add(request.uri.path);
      try {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
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
///
/// Returns: 起動した上流サーバのモック。
Future<_MockUpstream> _startMockUpstream() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _MockUpstream(server);
}

/// 誰もバインドしていないポート番号を取得する（到達不能な origin 用）。
///
/// Returns: 使用されていないポート番号。
Future<int> _findClosedPort() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close(force: true);
  return port;
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

/// 実 HttpClient でリクエストを実行し、応答内容を返す。
///
/// [uri] は要求先、[method] は HTTP メソッド、[headers] は付与するヘッダです。
///
/// Returns: ステータス、小文字化した応答ヘッダ、本文。
Future<_HttpResult> _performRequest(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    final response = await request.close();
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      responseHeaders[name.toLowerCase()] = values.join(', ');
    });
    final responseBody = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      headers: responseHeaders,
      body: responseBody,
    );
  } finally {
    client.close(force: true);
  }
}

/// 要求行を加工せずにページ遷移の GET を送り、応答を返す。
///
/// `Uri` は `[` や小文字の 16 進を正規化するため、ブラウザが送る要求行を
/// そのまま再現する目的でソケットへ直接書き込む。
///
/// [port] は proxy のポート番号です。[target] は要求行に書くパスとクエリです。
///
/// Returns: ステータスと本文。ヘッダは返さない。
Future<_HttpResult> _performRawNavigation(int port, String target) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final lineBreak = String.fromCharCodes(const [13, 10]);
  try {
    socket.write(
      'GET $target HTTP/1.1$lineBreak'
      'Host: 127.0.0.1:$port$lineBreak'
      'Sec-Fetch-Mode: navigate$lineBreak'
      'Accept: text/html$lineBreak'
      'Connection: close$lineBreak$lineBreak',
    );
    await socket.flush();

    final bytes = <int>[];
    await for (final chunk in socket) {
      bytes.addAll(chunk);
    }

    final text = utf8.decode(bytes, allowMalformed: true);
    final statusCode = int.parse(text.split(' ')[1]);
    final separator = '$lineBreak$lineBreak';
    final bodyStart = text.indexOf(separator);
    return (
      statusCode: statusCode,
      headers: const <String, String>{},
      body: bodyStart < 0 ? '' : text.substring(bodyStart + separator.length),
    );
  } finally {
    socket.destroy();
  }
}

/// 本文に含まれる監視スクリプトの要素の数を返す。
///
/// [body] は応答本文です。
///
/// Returns: 監視スクリプトの要素の数。
int _countScripts(String body) {
  return _scriptOpenTag.allMatches(body).length;
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
        .createTempSync('offline_web_proxy_recovery_page')
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

  /// オフライン状態の proxy を起動し、ポート番号を返す。
  ///
  /// [config] は上流の origin 以外の設定を加えるための変換です。
  ///
  /// Returns: 起動した proxy のポート番号。
  Future<int> startOfflineProxy({
    ProxyConfig Function(String origin)? config,
  }) async {
    upstream = await _startMockUpstream();
    final origin = upstream!.origin;
    final port = await proxy.start(
      config: config?.call(origin) ?? ProxyConfig(origin: origin),
    );
    await _emitConnectivity(['none']);
    return port;
  }

  /// オフライン状態の proxy を起動し、代替ページを取得する。
  ///
  /// [config] は上流の origin 以外の設定を加えるための変換です。
  ///
  /// Returns: 代替ページの応答。
  Future<_HttpResult> fetchOfflinePage({
    ProxyConfig Function(String origin)? config,
  }) async {
    final port = await startOfflineProxy(config: config);
    return _performRequest(
      Uri.parse('http://127.0.0.1:$port/orders'),
      headers: _navigationHeaders,
    );
  }

  /// 上流へ到達できない proxy を起動し、504 ページを取得する。
  ///
  /// [config] は上流の origin 以外の設定を加えるための変換です。
  ///
  /// Returns: 504 ページの応答。
  Future<_HttpResult> fetchGatewayTimeoutPage({
    ProxyConfig Function(String origin)? config,
  }) async {
    final closedPort = await _findClosedPort();
    final origin = 'http://127.0.0.1:$closedPort';
    final port = await proxy.start(
      config: config?.call(origin) ?? ProxyConfig(origin: origin),
    );

    return _performRequest(
      Uri.parse('http://127.0.0.1:$port/never-cached'),
      headers: _navigationHeaders,
    );
  }

  group('既定の応答ページ（doc/specs.ja.md 【10】オフライン応答）', () {
    /// 既定の代替ページに再試行ボタンと監視スクリプトが入ること
    test('embeds a retry button and the recovery script in the offline page',
        () async {
      await withRealHttpClient(() async {
        final result = await fetchOfflinePage();

        expect(result.statusCode, equals(HttpStatus.ok));
        expect(
          result.headers['content-type'],
          equals('text/html; charset=utf-8'),
        );
        // 履歴移動で保存済みの代替ページを再表示させないこと
        expect(result.headers['cache-control'], equals('no-store'));
        expect(result.headers['x-offline-source'], equals('fallback'));
        expect(result.body, contains(_retryButton));
        expect(result.body, contains('接続が戻ると自動で再読み込みします。'));
        expect(_countScripts(result.body), equals(1));
        expect(result.body, contains('"pageKind":"offlineFallback"'));
        expect(
          result.body,
          contains('"statusPath":"/__offline_web_proxy/status"'),
        );
        expect(result.body, contains('"pollIntervalMs":3000'));
        expect(result.body, contains('"queueWaitTimeoutMs":10000'));
        expect(result.body, contains('"offlinePageAutoReload":true'));
        expect(result.body, contains('"continuation":true'));
        expect(result.body, contains('"gatewayTimeoutAutoReload":false'));
      });
    });

    /// 既定の 504 ページを HTML として返すこと
    test('answers the default gateway timeout page as html', () async {
      await withRealHttpClient(() async {
        final result = await fetchGatewayTimeoutPage();

        expect(result.statusCode, equals(HttpStatus.gatewayTimeout));
        // 文字列の本文だけでは octet-stream になり、WebView が表示しないため
        expect(
          result.headers['content-type'],
          equals('text/html; charset=utf-8'),
        );
        expect(result.headers['cache-control'], equals('no-store'));
        expect(result.headers['x-offline-source'], equals('none'));
        expect(result.body, contains('<h1>上流サーバがタイムアウトしました</h1>'));
        expect(result.body, contains(_retryButton));
        // 継続復帰のために監視スクリプトを入れること
        expect(_countScripts(result.body), equals(1));
        expect(result.body, contains('"pageKind":"gatewayTimeout"'));
        expect(result.body, isNot(contains('接続が戻ると自動で再読み込みします。')));
      });
    });

    /// statusPath を無効にするとスクリプトを入れず、ボタンだけを残すこと
    test('omits the script when the status path is disabled', () async {
      await withRealHttpClient(() async {
        final offlinePage = await fetchOfflinePage(
          config: (origin) => ProxyConfig(origin: origin, statusPath: ''),
        );

        expect(offlinePage.body, contains(_retryButton));
        expect(_countScripts(offlinePage.body), equals(0));
        expect(
          offlinePage.body,
          isNot(contains('接続が戻ると自動で再読み込みします。')),
        );
      });

      await proxy.stop();
      await withRealHttpClient(() async {
        final gatewayPage = await fetchGatewayTimeoutPage(
          config: (origin) => ProxyConfig(origin: origin, statusPath: ''),
        );

        expect(gatewayPage.body, contains(_retryButton));
        expect(_countScripts(gatewayPage.body), equals(0));
      });
    });

    /// 自動復帰をすべて無効にするとスクリプトを入れないこと
    test('omits the script when every auto reload setting is disabled',
        () async {
      ProxyConfig disabled(String origin) {
        return ProxyConfig(
          origin: origin,
          enableOfflinePageAutoReload: false,
          enableAutoReloadContinuation: false,
          enableGatewayTimeoutAutoReload: false,
        );
      }

      await withRealHttpClient(() async {
        final offlinePage = await fetchOfflinePage(config: disabled);
        expect(_countScripts(offlinePage.body), equals(0));
      });

      await proxy.stop();
      await withRealHttpClient(() async {
        final gatewayPage = await fetchGatewayTimeoutPage(config: disabled);
        expect(_countScripts(gatewayPage.body), equals(0));
      });
    });

    /// 代替ページの自動復帰だけを無効にしても 504 ページには入ること
    test('keeps the script in the gateway page for continuation', () async {
      ProxyConfig continuationOnly(String origin) {
        return ProxyConfig(
          origin: origin,
          enableOfflinePageAutoReload: false,
        );
      }

      await withRealHttpClient(() async {
        final offlinePage = await fetchOfflinePage(config: continuationOnly);
        expect(_countScripts(offlinePage.body), equals(0));
      });

      await proxy.stop();
      await withRealHttpClient(() async {
        final gatewayPage =
            await fetchGatewayTimeoutPage(config: continuationOnly);
        expect(_countScripts(gatewayPage.body), equals(1));
        expect(gatewayPage.body, contains('"offlinePageAutoReload":false'));
      });
    });

    /// 504 ページの監視中からの自動再読込だけを有効にしても入ること
    test('embeds the script in the gateway page when only monitoring is on',
        () async {
      await withRealHttpClient(() async {
        final result = await fetchGatewayTimeoutPage(
          config: (origin) => ProxyConfig(
            origin: origin,
            enableOfflinePageAutoReload: false,
            enableAutoReloadContinuation: false,
            enableGatewayTimeoutAutoReload: true,
          ),
        );

        expect(_countScripts(result.body), equals(1));
        expect(result.body, contains('"gatewayTimeoutAutoReload":true'));
      });
    });

    /// 代替ページの自動復帰だけが有効でも、目印の処理のため 504 ページに入ること
    test('embeds the script in the gateway page to process the marker',
        () async {
      await withRealHttpClient(() async {
        final result = await fetchGatewayTimeoutPage(
          config: (origin) => ProxyConfig(
            origin: origin,
            enableAutoReloadContinuation: false,
          ),
        );

        expect(_countScripts(result.body), equals(1));
        expect(result.body, contains('"continuation":false'));
        expect(result.body, contains('"gatewayTimeoutAutoReload":false'));
      });
    });

    /// 設定した値をスクリプトへ埋め込むこと
    test('embeds the configured values into the script', () async {
      await withRealHttpClient(() async {
        final result = await fetchGatewayTimeoutPage(
          config: (origin) => ProxyConfig(
            origin: origin,
            statusPath: '/internal/proxy_status',
            autoReloadPollInterval: const Duration(milliseconds: 1500),
            autoReloadQueueWaitTimeout: Duration.zero,
            enableGatewayTimeoutAutoReload: true,
            requestTimeout: const Duration(seconds: 7),
          ),
        );

        expect(
          result.body,
          contains('"statusPath":"/internal/proxy_status"'),
        );
        expect(result.body, contains('"pollIntervalMs":1500'));
        expect(result.body, contains('"queueWaitTimeoutMs":0'));
        expect(result.body, contains('"gatewayTimeoutAutoReload":true'));
        // timeOrigin を使えない場合の有効時間と遷移を待つ時間は
        // requestTimeout + 30 秒になること
        expect(result.body, contains('"fallbackMarkerWindowMs":37000'));
        expect(result.body, contains('"navigationGraceMs":37000'));
      });
    });

    /// 起動条件を URL に依存させないため、正規化される URL でもスクリプトが入ること
    test('embeds the script for a raw url with brackets and lowercase hex',
        () async {
      await withRealHttpClient(() async {
        final port = await startOfflineProxy();

        final result = await _performRawNavigation(
          port,
          '/items/%7euser?q[name_cont]=foo&page[number]=2',
        );

        expect(result.statusCode, equals(HttpStatus.ok));
        expect(_countScripts(result.body), equals(1));
      });
    });
  });

  group('差し替え HTML の目印（doc/specs.ja.md 【10】オフライン応答）', () {
    /// 目印が複数ある場合は最初の目印にだけスクリプトを入れること
    test('inserts the script only at the first marker', () async {
      await withRealHttpClient(() async {
        final result = await fetchOfflinePage(
          config: (origin) => ProxyConfig(
            origin: origin,
            offlineFallbackHtml: '<html><body>offline'
                '${ProxyConfig.recoveryScriptPlaceholder}'
                '<p>again</p>${ProxyConfig.recoveryScriptPlaceholder}'
                '</body></html>',
          ),
        );

        expect(result.headers['cache-control'], equals('no-store'));
        // 同じページで複数のスクリプトが連続回数を打ち消し合わないこと
        expect(_countScripts(result.body), equals(1));
        expect(
          result.body.indexOf(_scriptOpenTag),
          lessThan(result.body.indexOf('<p>again</p>')),
        );
        expect(
          result.body,
          isNot(contains(ProxyConfig.recoveryScriptPlaceholder)),
        );
        // 差し替え HTML には既定のボタンを足さないこと
        expect(result.body, isNot(contains(_retryButton)));
      });
    });

    /// 目印が無い差し替え HTML はそのまま返すこと
    test('returns the offline fallback html unchanged without a marker',
        () async {
      await withRealHttpClient(() async {
        final result = await fetchOfflinePage(
          config: (origin) => ProxyConfig(
            origin: origin,
            offlineFallbackHtml: '<html>offline-page</html>',
          ),
        );

        expect(result.body, equals('<html>offline-page</html>'));
      });
    });

    /// 入れる条件を満たさない場合は目印を空文字へ置き換えること
    test('removes the marker when the script is not embedded', () async {
      await withRealHttpClient(() async {
        final result = await fetchOfflinePage(
          config: (origin) => ProxyConfig(
            origin: origin,
            enableOfflinePageAutoReload: false,
            offlineFallbackHtml: '<html><body>offline'
                '${ProxyConfig.recoveryScriptPlaceholder}</body></html>',
          ),
        );

        expect(result.body, equals('<html><body>offline</body></html>'));
      });
    });

    /// gatewayTimeoutHtml の目印も置き換えること
    test('replaces the marker in the gateway timeout html', () async {
      await withRealHttpClient(() async {
        final result = await fetchGatewayTimeoutPage(
          config: (origin) => ProxyConfig(
            origin: origin,
            gatewayTimeoutHtml: '<html><body>unreachable'
                '${ProxyConfig.recoveryScriptPlaceholder}</body></html>',
          ),
        );

        expect(result.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(
          result.headers['content-type'],
          equals('text/html; charset=utf-8'),
        );
        expect(_countScripts(result.body), equals(1));
        expect(result.body, contains('"pageKind":"gatewayTimeout"'));
      });
    });

    /// gatewayTimeoutHtml でも、入れる条件を満たさない場合は目印を取り除くこと
    test('removes the marker in the gateway timeout html when not embedded',
        () async {
      await withRealHttpClient(() async {
        final result = await fetchGatewayTimeoutPage(
          config: (origin) => ProxyConfig(
            origin: origin,
            statusPath: '',
            gatewayTimeoutHtml: '<html><body>unreachable'
                '${ProxyConfig.recoveryScriptPlaceholder}</body></html>',
          ),
        );

        expect(result.body, equals('<html><body>unreachable</body></html>'));
      });
    });
  });

  group('監視スクリプトの組み立て', () {
    /// 監視スクリプトの設定を組み立てる。
    ///
    /// [pollInterval] は状態通知を読む間隔です。
    ///
    /// Returns: 代替ページ向けの設定。
    OfflineRecoveryScriptOptions options({
      Duration pollInterval = const Duration(seconds: 3),
    }) {
      return OfflineRecoveryScriptOptions(
        pageKind: OfflineRecoveryPageKind.offlineFallback,
        statusPath: '/__offline_web_proxy/status',
        pollInterval: pollInterval,
        queueWaitTimeout: const Duration(seconds: 10),
        requestTimeout: const Duration(seconds: 20),
        offlinePageAutoReload: true,
        continuation: true,
        gatewayTimeoutAutoReload: false,
      );
    }

    /// 埋め込む値の中の閉じタグでスクリプトが終わらないこと
    test('escapes characters that could end the script element', () {
      final lineSeparator = String.fromCharCode(0x2028);
      final paragraphSeparator = String.fromCharCode(0x2029);
      final value = <String, Object>{
        'text': '</script><!--$lineSeparator$paragraphSeparator',
      };

      final encoded = encodeOfflineRecoveryScriptValue(value);

      expect(encoded, isNot(contains('<')));
      expect(encoded, isNot(contains(lineSeparator)));
      expect(encoded, isNot(contains(paragraphSeparator)));
      // エスケープしても同じ値として読めること
      expect(jsonDecode(encoded), equals(value));
    });

    /// スクリプトを通常のインラインスクリプトとして入れること
    test('builds a plain inline script without module or defer', () {
      final script = buildOfflineRecoveryScript(options());

      expect(script, startsWith(_scriptOpenTag));
      expect(script, endsWith('</script>'));
      expect(script, isNot(contains('type="module"')));
      expect(script, isNot(contains('defer')));
      // 実行時の readyState で起動を判定すること
      expect(script, contains("document.readyState !== 'loading'"));
      // 同じページでの二重起動を防ぐこと
      expect(script, contains('__offlineWebProxyRecoveryStarted'));
      // 画面から始まった遷移を打ち消さないこと
      expect(script, contains("addEventListener('beforeunload'"));
    });

    /// 下限より短い監視間隔は下限へ丸めて埋め込むこと
    test('clamps a poll interval below the minimum', () {
      final script = buildOfflineRecoveryScript(
        options(pollInterval: const Duration(microseconds: 500)),
      );

      expect(script, contains('"pollIntervalMs":100'));
    });
  });

  group('設定値（doc/specs.ja.md 【20】API リファレンス）', () {
    /// 既定値が方針どおりであること
    test('uses the documented defaults', () {
      const config = ProxyConfig(origin: 'https://example.com');

      expect(config.enableOfflinePageAutoReload, isTrue);
      expect(config.enableAutoReloadContinuation, isTrue);
      expect(config.enableGatewayTimeoutAutoReload, isFalse);
      expect(config.autoReloadPollInterval, equals(const Duration(seconds: 3)));
      expect(
        config.autoReloadQueueWaitTimeout,
        equals(const Duration(seconds: 10)),
      );
      expect(
        ProxyConfig.recoveryScriptPlaceholder,
        equals('<!--offline-web-proxy:recovery-->'),
      );
    });

    /// 監視間隔が範囲外の場合は起動時に拒否すること
    test('rejects a poll interval outside the accepted range', () async {
      final intervals = [
        const Duration(seconds: -1),
        Duration.zero,
        const Duration(microseconds: 500),
        const Duration(milliseconds: 99),
        const Duration(hours: 24, milliseconds: 1),
      ];

      for (final interval in intervals) {
        await expectLater(
          proxy.start(
            config: ProxyConfig(
              origin: 'https://example.com',
              autoReloadPollInterval: interval,
            ),
          ),
          throwsA(isA<ProxyStartException>()),
          reason: 'interval: $interval',
        );
      }
    });

    /// 範囲の端の監視間隔は受け付けること
    test('accepts a poll interval at either end of the range', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();

        for (final interval in [
          const Duration(milliseconds: 100),
          const Duration(hours: 24),
        ]) {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: upstream!.origin,
              autoReloadPollInterval: interval,
            ),
          );
          expect(port, greaterThan(0), reason: 'interval: $interval');
          await proxy.stop();
        }
      });
    });

    /// 再送を待つ上限時間が負の場合は起動時に拒否すること
    test('rejects a negative queue wait timeout', () async {
      await expectLater(
        proxy.start(
          config: const ProxyConfig(
            origin: 'https://example.com',
            autoReloadQueueWaitTimeout: Duration(seconds: -1),
          ),
        ),
        throwsA(isA<ProxyStartException>()),
      );
    });

    /// 再送を待たない指定（0）は受け付けること
    test('accepts a zero queue wait timeout', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            autoReloadQueueWaitTimeout: Duration.zero,
          ),
        );

        expect(port, greaterThan(0));
      });
    });

    /// 状態通知の JSON の項目を変えないこと
    test('keeps the status json fields unchanged', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );

        final decoded = jsonDecode(result.body) as Map<String, dynamic>;
        expect(
          decoded.keys.toSet(),
          equals({
            'isOnline',
            'onlineDecisionSource',
            'isUpstreamReachable',
            'upstreamCircuitState',
            'queueLength',
            'quarantinedCount',
            'unacknowledgedDroppedCount',
            'recentResendResults',
          }),
        );
      });
    });
  });

  group('要求ログ', () {
    /// proxy を起動し、要求ログとして出力された行を集める。
    ///
    /// [config] は起動に使う設定です。[logs] は出力された行の格納先です。
    ///
    /// Returns: 起動したポート番号。
    Future<int> startCapturingLogs(ProxyConfig config, List<String> logs) {
      return runZoned(
        () => proxy.start(config: config),
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
            logs.add(line);
          },
        ),
      );
    }

    /// 出力された行のうち、指定したパスとメソッドを含むものの数を返す。
    ///
    /// [logs] は出力された行です。[method] は HTTP メソッド、[path] はパスです。
    ///
    /// Returns: 該当する行の数。
    int countLogLines(List<String> logs, String method, String path) {
      return logs
          .where((line) => line.contains(method) && line.endsWith(path))
          .length;
    }

    /// 状態通知と稼働確認の GET はログに出さず、他の要求は記録すること
    test('omits status and health check reads from the request log', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final logs = <String>[];
        final port = await startCapturingLogs(
          ProxyConfig(origin: upstream!.origin, enableAdminApi: true),
          logs,
        );
        final base = 'http://127.0.0.1:$port';

        await _performRequest(Uri.parse('$base/__offline_web_proxy/status'));
        await _performRequest(Uri.parse('$base/__offline_web_proxy/health'));
        await _performRequest(
          Uri.parse('$base/__offline_web_proxy/health'),
          method: 'HEAD',
        );
        await _performRequest(
          Uri.parse('$base/__offline_web_proxy/status'),
          method: 'POST',
        );
        await _performRequest(
          Uri.parse('$base/__offline_web_proxy/admin/quarantine'),
        );
        await _performRequest(Uri.parse('$base/page'));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 監視スクリプトが一定間隔で読む要求はログを埋めないこと
        expect(
          countLogLines(logs, 'GET', '/__offline_web_proxy/status'),
          equals(0),
        );
        expect(
          countLogLines(logs, 'GET', '/__offline_web_proxy/health'),
          equals(0),
        );
        expect(
          countLogLines(logs, 'HEAD', '/__offline_web_proxy/health'),
          equals(0),
        );
        // 同じパスへの他メソッドと管理 API、通常の要求は記録すること
        expect(
          countLogLines(logs, 'POST', '/__offline_web_proxy/status'),
          equals(1),
        );
        expect(
          countLogLines(logs, 'GET', '/__offline_web_proxy/admin/quarantine'),
          equals(1),
        );
        expect(countLogLines(logs, 'GET', '/page'), equals(1));
      });
    });

    /// 状態通知を無効にすると、同じパスへの GET は通常の要求として記録すること
    test('logs the former status path when the endpoint is disabled', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final logs = <String>[];
        final port = await startCapturingLogs(
          ProxyConfig(origin: upstream!.origin, statusPath: ''),
          logs,
        );

        await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          countLogLines(logs, 'GET', '/__offline_web_proxy/status'),
          equals(1),
        );
      });
    });

    /// 変更した状態通知のパスをログから除外すること
    test('omits the configured status path from the request log', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final logs = <String>[];
        final port = await startCapturingLogs(
          ProxyConfig(
            origin: upstream!.origin,
            statusPath: '/internal/proxy_status',
          ),
          logs,
        );
        final base = 'http://127.0.0.1:$port';

        await _performRequest(Uri.parse('$base/internal/proxy_status'));
        await _performRequest(Uri.parse('$base/__offline_web_proxy/status'));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          countLogLines(logs, 'GET', '/internal/proxy_status'),
          equals(0),
        );
        // 既定のパスは状態通知ではなくなるため、通常の要求として記録すること
        expect(
          countLogLines(logs, 'GET', '/__offline_web_proxy/status'),
          equals(1),
        );
      });
    });
  });
}
