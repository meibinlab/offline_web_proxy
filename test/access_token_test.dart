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

/// 同梱アセットのモック内容。asset key ごとの本文を返すために使用する。
const Map<String, String> _mockAssetContents = {
  'assets/static/app.js': 'console.log("bundled");',
};

/// 上流が受信内容を記録する対象のリクエストヘッダ（小文字）。
const List<String> _recordedRequestHeaders = <String>[
  'cookie',
  'x-offline-web-proxy-token',
];

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// モックの上流が返す 1 経路分の応答内容。
typedef _MockRoute = ({
  int statusCode,
  String contentType,
  String body,
  Map<String, String> headers,
});

/// 受信内容を記録し、経路ごとに決めた応答を返す上流のモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final requestBody = await utf8.decoder.bind(request).join();

        final path = request.uri.path;
        receivedPaths.add(path);
        receivedBodies[path] = requestBody;
        receivedQueries[path] = request.uri.query;
        receivedHeaders[path] = <String, String>{
          for (final name in _recordedRequestHeaders)
            if (request.headers[name] != null)
              name: request.headers[name]!.join(', '),
        };

        final route = routes[path];
        request.response.statusCode = route?.statusCode ?? HttpStatus.ok;
        request.response.headers.contentType = ContentType.parse(
          route?.contentType ?? 'text/plain; charset=utf-8',
        );
        route?.headers.forEach(request.response.headers.set);
        for (final setCookie in setCookies[path] ?? const <String>[]) {
          request.response.headers.add('set-cookie', setCookie);
        }
        request.response.write(route?.body ?? 'upstream $path');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 受信したパスの一覧。受信順に追加される。
  final List<String> receivedPaths = <String>[];

  /// パスごとに受信した、判定対象のリクエストヘッダ。
  final Map<String, Map<String, String>> receivedHeaders =
      <String, Map<String, String>>{};

  /// パスごとに受信した要求本文。
  final Map<String, String> receivedBodies = <String, String>{};

  /// パスごとに受信したクエリ文字列。
  final Map<String, String> receivedQueries = <String, String>{};

  /// パスごとに応答へ付ける `Set-Cookie` の値。
  final Map<String, List<String>> setCookies = <String, List<String>>{};

  /// パスごとの応答内容。無いパスは `200` の `text/plain` で
  /// `upstream <パス>` を返す。
  final Map<String, _MockRoute> routes = <String, _MockRoute>{};

  /// サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 実 HttpClient で要求を実行した結果。
typedef _Response = ({
  int statusCode,
  String body,
  HttpHeaders headers,
});

/// 実 HttpClient で要求を実行する。
///
/// [uri] は要求先です。[method] は HTTP メソッドです。
/// [headers] は付与するリクエストヘッダです。同じ名前を複数送る場合は
/// 値の一覧を渡します。[body] は要求本文です。
///
/// Returns: ステータス、本文、応答ヘッダ。
Future<_Response> _performRequest(
  Uri uri, {
  String method = 'GET',
  Map<String, List<String>> headers = const <String, List<String>>{},
  String? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    headers.forEach((name, values) {
      for (final value in values) {
        request.headers.add(name, value);
      }
    });
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      body: responseBody,
      headers: response.headers,
    );
  } finally {
    client.close(force: true);
  }
}

/// 生のソケットで要求を送り、応答をそのまま返す。
///
/// HttpClient は `//` で始まるパスをそのまま送れないため、要求行を直接書く。
///
/// [port] は proxy のポートです。[requestTarget] は要求行のパスです。
/// [method] は HTTP メソッドです。[body] は要求本文（ASCII）です。
///
/// Returns: ステータスライン、ヘッダ、本文を含む応答の全文。
Future<String> _performRawGetText(
  int port,
  String requestTarget, {
  String method = 'GET',
  String? body,
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  try {
    socket.write('$method $requestTarget HTTP/1.1\r\n'
        'Host: 127.0.0.1:$port\r\n'
        '${body == null ? '' : 'Content-Type: application/json\r\n'
            'Content-Length: ${body.length}\r\n'}'
        'Connection: close\r\n'
        '\r\n'
        '${body ?? ''}');
    await socket.flush();
    return await utf8.decoder.bind(socket).join();
  } finally {
    socket.destroy();
  }
}

/// 生のソケットで GET 要求を送り、ステータスコードを返す。
///
/// [port] は proxy のポートです。[requestTarget] は要求行のパスです。
///
/// Returns: 応答のステータスコード。
Future<int> _performRawGet(int port, String requestTarget) async {
  final response = await _performRawGetText(port, requestTarget);
  final statusLine = response.split('\r\n').first;
  return int.parse(statusLine.split(' ')[1]);
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

/// 条件を満たすまで待つ。
///
/// [condition] は判定処理です。[timeout] は待機の上限です。
Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('condition was not met within $timeout');
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

      final assetContent = _mockAssetContents[assetKey];
      if (assetContent != null) {
        return stringCodec.encodeMessage(assetContent);
      }
      return null;
    });
  });

  late OfflineWebProxy proxy;
  _MockUpstream? upstream;

  setUp(() async {
    hiveTestDirectory =
        Directory.systemTemp.createTempSync('offline_web_proxy_token').path;
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

  /// 上流のモックを起動し、proxy を起動する。
  ///
  /// 引数はいずれも同じ名前の [ProxyConfig] の項目へ渡します。
  /// [healthCheckPath] を省略した場合は既定のパスを使います。
  ///
  /// Returns: proxy のポート番号。
  Future<int> startProxy({
    bool requireAccessToken = true,
    bool addCorsHeaders = true,
    bool enableAdminApi = false,
    bool enableWebStorageInheritance = false,
    List<String> mirroredOrigins = const <String>[],
    String healthCheckPath = '/__offline_web_proxy/health',
    int port = 0,
  }) async {
    upstream ??= _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    return proxy.start(
      config: ProxyConfig(
        origin: upstream!.origin,
        requireAccessToken: requireAccessToken,
        addCorsHeaders: addCorsHeaders,
        enableAdminApi: enableAdminApi,
        enableWebStorageInheritance: enableWebStorageInheritance,
        mirroredOrigins: mirroredOrigins,
        healthCheckPath: healthCheckPath,
        port: port,
      ),
    );
  }

  /// 正しい秘密値を Cookie で送るためのヘッダ。
  Map<String, List<String>> tokenCookie({String? extra}) => {
        'cookie': [
          [
            if (extra != null) extra,
            '${OfflineWebProxy.accessTokenCookieName}=${proxy.accessToken}',
          ].join('; '),
        ],
      };

  group('秘密値の生成（doc/specs.ja.md 【2】到達の制限）', () {
    /// 起動ごとに値を生成し、停止すると消えること
    test('is generated on every start and cleared on stop', () async {
      await withRealHttpClient(() async {
        expect(proxy.accessToken, isNull);

        await startProxy(requireAccessToken: false);
        final first = proxy.accessToken;
        expect(first, isNotNull);
        // 32 バイトを base64url（パディングなし）にした 43 文字
        expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));

        await proxy.stop();
        expect(proxy.accessToken, isNull);

        await startProxy(requireAccessToken: false);
        expect(proxy.accessToken, isNotNull);
        expect(proxy.accessToken, isNot(equals(first)));
      });
    });

    /// 再起動すると前回の値では到達できなくなること
    test('refuses the token of the previous start', () async {
      await withRealHttpClient(() async {
        await startProxy();
        final previousCookie = tokenCookie();
        await proxy.stop();

        final port = await startProxy();
        final stale = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: previousCookie,
        );
        final current = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: tokenCookie(),
        );

        expect(stale.statusCode, equals(HttpStatus.forbidden));
        expect(current.statusCode, equals(HttpStatus.ok));
      });
    });

    /// 値を生成した後に起動が失敗した場合は値を残さないこと
    test('clears the token when start fails after generating it', () async {
      await withRealHttpClient(() async {
        // 使用中のポートを指定し、秘密値の生成より後のバインドで失敗させる
        final occupied =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        try {
          await expectLater(
            startProxy(port: occupied.port),
            throwsA(isA<ProxyStartException>()),
          );
          expect(proxy.isRunning, isFalse);
          expect(proxy.accessToken, isNull);
        } finally {
          await occupied.close();
        }
      });
    });

    /// 再バインドでは値を変えないこと
    test('keeps the token across a forced rebind', () async {
      await withRealHttpClient(() async {
        await startProxy();
        final token = proxy.accessToken;

        final result = await proxy.ensureRunning(force: true);

        expect(result.restarted, isTrue);
        expect(proxy.accessToken, equals(token));
        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:${proxy.port}/page'),
          headers: tokenCookie(),
        );
        expect(response.statusCode, equals(HttpStatus.ok));
      });
    });
  });

  group('秘密値による到達の制限（doc/specs.ja.md 【2】到達の制限）', () {
    /// 既定では秘密値の無い要求も従来どおり転送すること
    test('forwards a request without the token by default', () async {
      await withRealHttpClient(() async {
        upstream = _MockUpstream(
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        );
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedPaths, equals(['/page']));
      });
    });

    /// 秘密値の無い要求を 403 で拒否し、上流へ送らないこと
    test('refuses a request without the token', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();

        final response =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));

        expect(response.statusCode, equals(HttpStatus.forbidden));
        expect(response.headers.value('cache-control'), equals('no-store'));
        // 拒否した応答は別 origin へ開かないこと
        expect(response.headers.value('access-control-allow-origin'), isNull);
        expect(upstream!.receivedPaths, isEmpty);
        // 拒否した要求は統計に数えないこと
        expect((await proxy.getStats()).totalRequests, equals(0));
      });
    });

    /// 値の異なる Cookie とヘッダを拒否すること
    test('refuses a wrong token', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        final wrong = 'x' * proxy.accessToken!.length;

        final byCookie = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: {
            'cookie': ['${OfflineWebProxy.accessTokenCookieName}=$wrong'],
          },
        );
        final byHeader = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: {
            OfflineWebProxy.accessTokenHeaderName: [wrong],
          },
        );
        final shorter = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: {
            OfflineWebProxy.accessTokenHeaderName: [
              proxy.accessToken!.substring(1),
            ],
          },
        );

        expect(byCookie.statusCode, equals(HttpStatus.forbidden));
        expect(byHeader.statusCode, equals(HttpStatus.forbidden));
        expect(shorter.statusCode, equals(HttpStatus.forbidden));
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// Cookie の秘密値で許可し、上流へは秘密値を渡さず他の Cookie を渡すこと
    test('accepts the token cookie and strips it before forwarding', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: tokenCookie(extra: 'app=1'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedHeaders['/page'], equals({'cookie': 'app=1'}));
      });
    });

    /// ヘッダの秘密値で許可し、上流へはヘッダを渡さないこと
    test('accepts the token header and strips it before forwarding', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: {
            OfflineWebProxy.accessTokenHeaderName: [proxy.accessToken!],
          },
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedHeaders['/page'], isEmpty);
      });
    });

    /// 同じ名前の Cookie が複数あれば、どれか 1 つの一致で許可し、すべて取り除くこと
    test('accepts one matching cookie among several of the same name',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        const name = OfflineWebProxy.accessTokenCookieName;

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: {
            'cookie': ['$name=stale; app=1; $name=${proxy.accessToken}'],
          },
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedHeaders['/page'], equals({'cookie': 'app=1'}));
      });
    });

    /// 無効な場合も、予約名の Cookie とヘッダは上流へ渡さないこと
    test('strips the token even when the check is disabled', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(requireAccessToken: false);

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: {
            ...tokenCookie(extra: 'app=1'),
            OfflineWebProxy.accessTokenHeaderName: ['anything'],
          },
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedHeaders['/page'], equals({'cookie': 'app=1'}));
      });
    });

    /// 上流の Set-Cookie で WebView の秘密値を上書きさせないこと
    test('drops a Set-Cookie of the reserved name from responses', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        upstream!.setCookies['/page'] = [
          '${OfflineWebProxy.accessTokenCookieName}=evil; Path=/',
          'session=abc; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT',
        ];

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: tokenCookie(),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        final setCookies = response.headers['set-cookie'] ?? const <String>[];
        expect(
          setCookies.where(
            (value) => value.contains(OfflineWebProxy.accessTokenCookieName),
          ),
          isEmpty,
        );
        // 他の Cookie は Expires の `,` で分断せずに残すこと
        expect(
          setCookies,
          equals([
            'session=abc; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT',
          ]),
        );
      });
    });

    /// 稼働確認だけは秘密値なしで応答し、ルーターと同じ基準で判定すること
    test('exempts only the health check', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        const healthPath = '/__offline_web_proxy/health';

        final get = await _performRequest(
            Uri.parse('http://127.0.0.1:$port$healthPath'));
        final head = await _performRequest(
          Uri.parse('http://127.0.0.1:$port$healthPath'),
          method: 'HEAD',
        );
        final withQuery = await _performRequest(
          Uri.parse('http://127.0.0.1:$port$healthPath?x=1'),
        );
        final post = await _performRequest(
          Uri.parse('http://127.0.0.1:$port$healthPath'),
          method: 'POST',
          body: '{}',
        );
        final trailingSlash = await _performRequest(
          Uri.parse('http://127.0.0.1:$port$healthPath/'),
        );
        final doubleSlash = await _performRawGet(port, '/$healthPath');

        expect(get.statusCode, equals(HttpStatus.noContent));
        expect(head.statusCode, equals(HttpStatus.noContent));
        expect(withQuery.statusCode, equals(HttpStatus.noContent));
        expect(await proxy.probe(), isTrue);
        // 先頭の `/` の重複は 1 つにまとめるため、同じ稼働確認として応答すること
        expect(doubleSlash, equals(HttpStatus.noContent));
        // ルーターが転送経路へ回す要求は検査すること
        expect(post.statusCode, equals(HttpStatus.forbidden));
        expect(trailingSlash.statusCode, equals(HttpStatus.forbidden));
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// 除外するのは設定した稼働確認のパスであること
    test('exempts the configured health check path', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(healthCheckPath: '/hc');

        final custom =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/hc'));
        final defaultPath = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/health'),
        );

        expect(custom.statusCode, equals(HttpStatus.noContent));
        expect(await proxy.probe(), isTrue);
        expect(defaultPath.statusCode, equals(HttpStatus.forbidden));
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// CORS の preflight（OPTIONS）は Cookie を送らないため拒否すること
    test('refuses a preflight request', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();

        final page = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          method: 'OPTIONS',
          headers: {
            'origin': ['https://evil.example'],
            'access-control-request-method': ['POST'],
          },
        );
        final health = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/health'),
          method: 'OPTIONS',
        );

        expect(page.statusCode, equals(HttpStatus.forbidden));
        expect(page.headers.value('access-control-allow-origin'), isNull);
        expect(health.statusCode, equals(HttpStatus.forbidden));
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// 状態通知と管理エンドポイントも検査すること
    test('covers the status and admin endpoints', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(enableAdminApi: true);
        final statusUri =
            Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status');
        final adminUri = Uri.parse(
            'http://127.0.0.1:$port/__offline_web_proxy/admin/quarantine');
        final discardUri = Uri.parse(
            'http://127.0.0.1:$port/__offline_web_proxy/admin/quarantine/x');

        expect((await _performRequest(statusUri)).statusCode,
            equals(HttpStatus.forbidden));
        expect((await _performRequest(adminUri)).statusCode,
            equals(HttpStatus.forbidden));
        expect(
          (await _performRequest(discardUri, method: 'DELETE')).statusCode,
          equals(HttpStatus.forbidden),
        );

        expect(
          (await _performRequest(statusUri, headers: tokenCookie())).statusCode,
          equals(HttpStatus.ok),
        );
        expect(
          (await _performRequest(adminUri, headers: tokenCookie())).statusCode,
          equals(HttpStatus.ok),
        );
        expect(
          (await _performRequest(
            discardUri,
            method: 'DELETE',
            headers: tokenCookie(),
          ))
              .statusCode,
          equals(HttpStatus.notFound),
        );
      });
    });

    /// 同梱アセットも検査すること
    test('covers bundled static assets', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        final uri = Uri.parse('http://127.0.0.1:$port/app.js');

        final refused = await _performRequest(uri);
        final accepted = await _performRequest(uri, headers: tokenCookie());

        expect(refused.statusCode, equals(HttpStatus.forbidden));
        expect(accepted.statusCode, equals(HttpStatus.ok));
        expect(accepted.body, equals('console.log("bundled");'));
      });
    });

    /// WebStorage の橋渡しも検査すること
    test('covers the web storage bridge', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(enableWebStorageInheritance: true);
        final uri = Uri.parse(
            'http://127.0.0.1:$port/__offline_web_proxy/web_storage/snapshot');

        final refused = await _performRequest(uri);
        final accepted = await _performRequest(uri, headers: tokenCookie());

        expect(refused.statusCode, equals(HttpStatus.forbidden));
        expect(accepted.statusCode, equals(HttpStatus.ok));
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// 別 origin の中継経路も検査すること
    test('covers the mirrored origin path', () async {
      await withRealHttpClient(() async {
        final cdn = _MockUpstream(
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        );
        try {
          final port = await startProxy(mirroredOrigins: [cdn.origin]);
          final cdnPort = Uri.parse(cdn.origin).port;
          final uri = Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/ext/http/127.0.0.1:$cdnPort/lib/app.js');

          final refused = await _performRequest(uri);
          // 独自ヘッダは中継先へも転送されるため、ヘッダの除去もここで確かめる
          final accepted = await _performRequest(
            uri,
            headers: {
              OfflineWebProxy.accessTokenHeaderName: [proxy.accessToken!],
            },
          );

          expect(refused.statusCode, equals(HttpStatus.forbidden));
          expect(accepted.statusCode, equals(HttpStatus.ok));
          expect(cdn.receivedPaths, equals(['/lib/app.js']));
          // 中継先へも秘密値を渡さないこと
          expect(cdn.receivedHeaders['/lib/app.js'], isEmpty);
        } finally {
          await cdn.close();
        }
      });
    });

    /// キューへ保存する要求と再送に秘密値を含めないこと
    test('does not store the token in the queue', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();

        await _emitConnectivity(['none']);
        final queued = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/api/sales.json'),
          method: 'POST',
          headers: {
            ...tokenCookie(extra: 'app=1'),
            OfflineWebProxy.accessTokenHeaderName: [proxy.accessToken!],
          },
          body: '{"total":1000}',
        );
        expect(queued.statusCode, equals(HttpStatus.accepted));

        // 一覧は Cookie の値を伏せて返すため、Cookie は再送で上流が受け取った
        // 値で確かめる
        final stored = (await proxy.getQueuedRequests()).single;
        expect(
          stored.headers.keys.map((name) => name.toLowerCase()),
          isNot(contains(OfflineWebProxy.accessTokenHeaderName.toLowerCase())),
        );

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(
          upstream!.receivedHeaders['/api/sales.json'],
          equals({'cookie': 'app=1'}),
        );
      });
    });
  });

  group('CORS ヘッダ（doc/specs.ja.md 【2】CORS ヘッダ）', () {
    /// 既定では転送経路の応答へ CORS ヘッダを付けること
    test('adds CORS headers by default', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(requireAccessToken: false);

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: {
            'origin': ['https://evil.example'],
          },
        );

        expect(
            response.headers.value('access-control-allow-origin'), equals('*'));
      });
    });

    /// 無効にすると CORS ヘッダを付けないこと
    test('does not add CORS headers when disabled', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          requireAccessToken: false,
          addCorsHeaders: false,
        );

        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: {
            'origin': ['https://evil.example'],
          },
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.headers.value('access-control-allow-origin'), isNull);
        expect(response.headers.value('access-control-allow-methods'), isNull);
        expect(response.headers.value('access-control-allow-headers'), isNull);
      });
    });
  });

  group('Set-Cookie の中継（doc/specs.ja.md 【14】ヘッダ書換え粒度）', () {
    /// 複数の Set-Cookie の値。`Expires` の `,` を含むものを混ぜる。
    const setCookies = [
      'a=1; Path=/',
      'b=2; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT',
      'c=3; Path=/; HttpOnly',
    ];

    /// 上流が返した複数の Set-Cookie を 1 件ずつ別の行で返すこと
    test('passes each Set-Cookie on its own line', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(requireAccessToken: false);
        upstream!.setCookies['/page'] = setCookies;

        final response =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));

        expect(response.statusCode, equals(HttpStatus.ok));
        // CORS ヘッダを足しても行を連結しないこと
        expect(
            response.headers.value('access-control-allow-origin'), equals('*'));
        expect(response.headers['set-cookie'], equals(setCookies));
      });
    });

    /// 別 origin の URL を書き換えた HTML でも行を連結しないこと
    test('keeps separate lines in a rewritten page', () async {
      await withRealHttpClient(() async {
        final cdn = _MockUpstream(
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        );
        try {
          final port = await startProxy(
            requireAccessToken: false,
            mirroredOrigins: [cdn.origin],
          );
          upstream!.routes['/page'] = (
            statusCode: HttpStatus.ok,
            contentType: 'text/html; charset=utf-8',
            body: '<html><body>'
                '<script src="${cdn.origin}/lib.js"></script>'
                '</body></html>',
            headers: const <String, String>{},
          );
          upstream!.setCookies['/page'] = setCookies;

          final response =
              await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));

          expect(response.body, contains('/__offline_web_proxy/ext/'));
          expect(response.headers['set-cookie'], equals(setCookies));
        } finally {
          await cdn.close();
        }
      });
    });

    /// WebStorage の橋渡しを注入した HTML でも行を連結しないこと
    test('keeps separate lines in a page with the web storage bridge',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          requireAccessToken: false,
          enableWebStorageInheritance: true,
        );
        upstream!.routes['/page'] = (
          statusCode: HttpStatus.ok,
          contentType: 'text/html; charset=utf-8',
          body: '<html><body>page</body></html>',
          headers: const <String, String>{},
        );
        upstream!.setCookies['/page'] = setCookies;

        final response =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/page'));

        expect(
            response.body, contains('__offline_web_proxy_web_storage_bridge'));
        expect(response.headers['set-cookie'], equals(setCookies));
      });
    });

    /// proxy が Location を書き換えたリダイレクトでも行を連結しないこと
    test('keeps separate lines in a rewritten redirect', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(requireAccessToken: false);
        upstream!.routes['/login'] = (
          statusCode: HttpStatus.found,
          contentType: 'text/plain; charset=utf-8',
          body: '',
          headers: {'location': '${upstream!.origin}/home'},
        );
        upstream!.setCookies['/login'] = setCookies;

        final response =
            await _performRequest(Uri.parse('http://127.0.0.1:$port/login'));

        expect(response.statusCode, equals(HttpStatus.found));
        expect(response.headers.value('location'),
            equals('http://127.0.0.1:$port/home'));
        expect(response.headers['set-cookie'], equals(setCookies));
      });
    });

    /// キャッシュから返す応答では、保存時の Set-Cookie を返さないこと
    test('does not replay Set-Cookie from the cache', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(requireAccessToken: false);
        upstream!.setCookies['/page'] = setCookies;
        final uri = Uri.parse('http://127.0.0.1:$port/page');

        final online = await _performRequest(uri);
        expect(online.headers['set-cookie'], equals(setCookies));

        await _emitConnectivity(['none']);
        final offline = await _performRequest(uri);
        final offlineHead = await _performRequest(uri, method: 'HEAD');
        final offlineRange = await _performRequest(
          uri,
          headers: {
            'range': ['bytes=0-3'],
          },
        );
        await _emitConnectivity(['wifi']);

        // 上流へは 1 回しか送っていないこと（2 回目以降はキャッシュ）
        expect(upstream!.receivedPaths, equals(['/page']));
        expect(offline.statusCode, equals(HttpStatus.ok));
        expect(offline.body, equals('upstream /page'));
        expect(offline.headers['set-cookie'], isNull);
        expect(offlineHead.statusCode, equals(HttpStatus.ok));
        expect(offlineHead.headers['set-cookie'], isNull);
        expect(offlineRange.statusCode, equals(HttpStatus.partialContent));
        expect(offlineRange.body, equals('upst'));
        expect(offlineRange.headers['set-cookie'], isNull);
      });
    });
  });

  group('内部エンドポイントの判定（doc/specs.ja.md 【2】死活監視）', () {
    /// 先頭の `/` の重複は 1 つにまとめ、内部エンドポイントを上流へ送らないこと
    test('collapses a doubled leading slash before routing', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          requireAccessToken: false,
          enableAdminApi: true,
        );

        final health =
            await _performRawGetText(port, '//__offline_web_proxy/health');
        final status =
            await _performRawGetText(port, '//__offline_web_proxy/status');
        final admin = await _performRawGetText(
            port, '///__offline_web_proxy/admin/quarantine');

        expect(health.split('\r\n').first, contains('204'));
        expect(status.split('\r\n').first, contains('200'));
        expect(status, contains('"isOnline"'));
        expect(admin.split('\r\n').first, contains('200'));
        expect(admin, contains('"requests"'));
        // 内部エンドポイントとして扱い、上流へ送らず統計にも数えないこと
        expect(upstream!.receivedPaths, isEmpty);
        expect((await proxy.getStats()).totalRequests, equals(0));
        for (final response in [health, status, admin]) {
          expect(response.toLowerCase(),
              isNot(contains('access-control-allow-origin')));
        }
      });
    });

    /// 転送する要求は、まとめたパスで本文もそのまま上流へ送ること
    test('forwards a doubled leading slash path as the single slash path',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy(requireAccessToken: false);

        final response = await _performRawGetText(
          port,
          '//api/sales.json?x=1',
          method: 'POST',
          body: '{"total":1000}',
        );

        expect(response.split('\r\n').first, contains('200'));
        expect(upstream!.receivedPaths, equals(['/api/sales.json']));
        expect(upstream!.receivedBodies['/api/sales.json'],
            equals('{"total":1000}'));
        expect(upstream!.receivedQueries['/api/sales.json'], equals('x=1'));

        // パスが `/` だけの場合もクエリを保つこと
        final root = await _performRawGetText(port, '//?y=2');
        expect(root.split('\r\n').first, contains('200'));
        expect(upstream!.receivedPaths.last, equals('/'));
        expect(upstream!.receivedQueries['/'], equals('y=2'));
        expect((await proxy.getStats()).totalRequests, equals(2));
      });
    });

    /// 先頭の `/` を重ねても秘密値の検査を避けられないこと
    test('checks the token on a doubled leading slash path', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(enableAdminApi: true);

        final status =
            await _performRawGetText(port, '//__offline_web_proxy/status');
        final admin = await _performRawGetText(
            port, '//__offline_web_proxy/admin/quarantine');
        final page = await _performRawGetText(port, '//page');

        for (final response in [status, admin, page]) {
          expect(response.split('\r\n').first, contains('403'));
        }
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// ルーターが登録していないメソッドやパスは転送経路として扱うこと
    test('treats unrouted methods and paths as the forwarding path', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          requireAccessToken: false,
          enableAdminApi: true,
        );

        final postStatus = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
          method: 'POST',
          body: '{}',
        );
        final unknownAdmin = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/admin/other'),
        );
        final getRetry = await _performRequest(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/admin/quarantine/x/retry'),
        );

        expect(upstream!.receivedPaths, hasLength(3));
        expect((await proxy.getStats()).totalRequests, equals(3));
        for (final response in [postStatus, unknownAdmin, getRetry]) {
          expect(response.statusCode, equals(HttpStatus.ok));
          expect(response.headers.value('access-control-allow-origin'),
              equals('*'));
        }
      });
    });

    /// ルーターが内部エンドポイントへ渡す要求は統計と CORS から外すこと
    test('keeps routed internal endpoints out of statistics', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          requireAccessToken: false,
          enableAdminApi: true,
        );

        final status = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );
        final list = await _performRequest(
          Uri.parse(
              'http://127.0.0.1:$port/__offline_web_proxy/admin/quarantine'),
        );
        final retry = await _performRequest(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/admin/quarantine/x/retry'),
          method: 'POST',
          body: '{}',
        );
        // ルーターは GET の登録に HEAD を加えるため、HEAD も内部扱いとなること
        final statusHead = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
          method: 'HEAD',
        );
        final listHead = await _performRequest(
          Uri.parse(
              'http://127.0.0.1:$port/__offline_web_proxy/admin/quarantine'),
          method: 'HEAD',
        );
        final discard = await _performRequest(
          Uri.parse(
              'http://127.0.0.1:$port/__offline_web_proxy/admin/quarantine/x'),
          method: 'DELETE',
        );

        expect(status.statusCode, equals(HttpStatus.ok));
        expect(list.statusCode, equals(HttpStatus.ok));
        expect(retry.statusCode, equals(HttpStatus.notFound));
        expect(discard.statusCode, equals(HttpStatus.notFound));
        expect(upstream!.receivedPaths, isEmpty);
        expect((await proxy.getStats()).totalRequests, equals(0));
        expect(statusHead.statusCode, equals(HttpStatus.ok));
        expect(listHead.statusCode, equals(HttpStatus.ok));
        for (final response in [
          status,
          list,
          retry,
          discard,
          statusHead,
          listHead,
        ]) {
          expect(response.headers.value('access-control-allow-origin'), isNull);
        }
      });
    });

    /// 正しいパスの稼働確認は従来どおり内部エンドポイントとして扱うこと
    test('keeps the exact health check path internal', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(requireAccessToken: false);

        final health =
            await _performRawGetText(port, '/__offline_web_proxy/health');

        expect(health.split('\r\n').first, contains('204'));
        expect(upstream!.receivedPaths, isEmpty);
        expect((await proxy.getStats()).totalRequests, equals(0));
        expect(health.toLowerCase(),
            isNot(contains('access-control-allow-origin')));
      });
    });
  });
}
