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
  'assets/static/bundled.html': ['assets/static/bundled.html'],
};

/// 同梱アセットのモック内容。asset key ごとの本文を返すために使用する。
final Map<String, String> _mockAssetContents = <String, String>{};

/// 上流が受信内容を記録する対象のリクエストヘッダ。
const List<String> _recordedRequestHeaders = <String>[
  'cookie',
  'authorization',
  'referer',
  'origin',
];

/// モックサーバが返す 1 経路分の応答内容。
typedef _MockRoute = ({
  int statusCode,
  String contentType,
  String body,
  List<int>? bodyBytes,
  Map<String, String> headers,
});

/// モックサーバの経路を組み立てる。
///
/// [body] は応答本文です。[statusCode] は応答のステータスです。
/// [contentType] は `Content-Type` です。[headers] は追加のヘッダです。
/// [bodyBytes] を渡した場合は [body] を使わずバイト列をそのまま返します。
///
/// Returns: 組み立てた経路。
_MockRoute _route(
  String body, {
  int statusCode = HttpStatus.ok,
  String contentType = 'text/html; charset=utf-8',
  Map<String, String> headers = const <String, String>{},
  List<int>? bodyBytes,
}) {
  return (
    statusCode: statusCode,
    contentType: contentType,
    body: body,
    bodyBytes: bodyBytes,
    headers: headers,
  );
}

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// 経路ごとに応答を差し替えられるサーバのモック。
///
/// 上流サーバと別 origin（CDN）の双方に使う。
class _MockServer {
  _MockServer(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();

        final path = request.uri.path;
        receivedPaths.add(path);
        receivedQueries[path] = request.uri.query;
        receivedHeaders[path] = <String, String>{
          for (final name in _recordedRequestHeaders)
            if (request.headers.value(name) != null)
              name: request.headers.value(name)!,
        };

        final route = routes[path];
        if (route == null) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }

        request.response.statusCode = route.statusCode;
        request.response.headers.contentType =
            ContentType.parse(route.contentType);
        route.headers.forEach(request.response.headers.set);
        final bodyBytes = route.bodyBytes;
        if (bodyBytes != null) {
          request.response.add(bodyBytes);
        } else if (route.body.isNotEmpty) {
          request.response.write(route.body);
        }
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 受信したパスの一覧。受信順に追加される。
  final List<String> receivedPaths = <String>[];

  /// パスごとに受信したクエリ文字列。
  final Map<String, String> receivedQueries = <String, String>{};

  /// パスごとに受信した、判定対象のリクエストヘッダ。
  final Map<String, Map<String, String>> receivedHeaders =
      <String, Map<String, String>>{};

  /// パスごとの応答内容。テスト中に差し替える。
  Map<String, _MockRoute> routes = <String, _MockRoute>{};

  /// サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// サーバのポート番号。
  int get port => _server.port;

  /// サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// モックサーバを起動する。
Future<_MockServer> _startMockServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _MockServer(server);
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

/// 実 HttpClient で読み取り要求を実行する。
///
/// [uri] は要求先です。[headers] は付与するリクエストヘッダです。
/// [followRedirects] は redirect を追跡するかどうかです。
///
/// Returns: ステータス、本文、および判定に使う応答ヘッダ。
Future<
    ({
      int statusCode,
      String body,
      String? location,
      String? allow,
      String? offlineSource,
      String? staticResource,
    })> _performGet(
  Uri uri, {
  Map<String, String> headers = const <String, String>{},
  bool followRedirects = true,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = followRedirects;
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      body: body,
      location: response.headers.value('location'),
      allow: response.headers.value('allow'),
      offlineSource: response.headers.value('x-offline-source'),
      staticResource: response.headers.value('x-static-resource'),
    );
  } finally {
    client.close(force: true);
  }
}

/// 実 HttpClient で読み取り要求を実行し、本文をバイト列で受け取る。
///
/// [uri] は要求先です。[autoUncompress] は本文の自動解凍の有無です。
///
/// Returns: ステータスと本文のバイト列。
Future<({int statusCode, List<int> bodyBytes})> _performGetBytes(
  Uri uri, {
  bool autoUncompress = true,
}) async {
  final client = HttpClient()..autoUncompress = autoUncompress;
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return (statusCode: response.statusCode, bodyBytes: bytes);
  } finally {
    client.close(force: true);
  }
}

/// 実 HttpClient で更新系の要求を実行する。
///
/// [uri] は要求先です。
///
/// Returns: ステータスと `Allow` ヘッダ。
Future<({int statusCode, String? allow})> _performPost(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write('{}');
    final response = await request.close();
    await response.drain<void>();
    return (
      statusCode: response.statusCode,
      allow: response.headers.value('allow'),
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

      final assetContent = _mockAssetContents[assetKey];
      if (assetContent != null) {
        return stringCodec.encodeMessage(assetContent);
      }
      return null;
    });
  });

  late OfflineWebProxy proxy;
  _MockServer? upstream;
  _MockServer? cdn;

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_mirrored_origin')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    _mockAssetContents.clear();
    proxy = OfflineWebProxy();
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream?.close();
    await cdn?.close();
    upstream = null;
    cdn = null;
  });

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: _RealHttpOverrides().createHttpClient,
    );
  }

  /// 上流と CDN のモックを起動し、既定の経路を用意する。
  Future<void> startServers() async {
    upstream = await _startMockServer();
    cdn = await _startMockServer();

    upstream!.routes = <String, _MockRoute>{
      '/index.html': _route(
        '<html><body>'
        '<script src="${cdn!.origin}/lib/app.js"></script>'
        '</body></html>',
      ),
    };
    cdn!.routes = <String, _MockRoute>{
      '/lib/app.js': _route(
        'console.log("cdn");',
        contentType: 'text/javascript; charset=utf-8',
      ),
    };
  }

  /// CDN 資源のミラー経路のパスを組み立てる。
  ///
  /// [path] は CDN 上のパスです。
  ///
  /// Returns: proxy が受け付けるパス。
  String mirroredPath(String path) =>
      '/__offline_web_proxy/ext/http/127.0.0.1:${cdn!.port}$path';

  group('mirroredOrigins（doc/specs.ja.md 【1】基本構成）', () {
    /// 既定では別 origin の URL に触れないこと
    test('leaves a cdn url untouched when no origin is listed', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response =
            await _performGet(Uri.parse('http://127.0.0.1:$port/index.html'));

        expect(response.body, contains('src="${cdn!.origin}/lib/app.js"'));
        expect(cdn!.receivedPaths, isEmpty);
      });
    });

    /// 許可した origin の絶対 URL を proxy 経路へ書き換えること
    test('rewrites a listed origin url in the served html', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response =
            await _performGet(Uri.parse('http://127.0.0.1:$port/index.html'));

        expect(
          response.body,
          contains('src="${mirroredPath('/lib/app.js')}"'),
        );
        // 元の絶対 URL は残らないこと
        expect(response.body, isNot(contains('src="${cdn!.origin}')));
      });
    });

    /// 書き換えた経路の要求を許可した origin へ中継すること
    test('relays the rewritten path to the listed origin', () async {
      await withRealHttpClient(() async {
        await startServers();
        cdn!.routes = <String, _MockRoute>{
          '/lib/app.js': _route(
            'console.log("cdn");',
            contentType: 'text/javascript; charset=utf-8',
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port${mirroredPath('/lib/app.js')}'
              '?v=1'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.body, equals('console.log("cdn");'));
        expect(cdn!.receivedPaths, contains('/lib/app.js'));
        // クエリも中継先へそのまま渡すこと
        expect(cdn!.receivedQueries['/lib/app.js'], equals('v=1'));
        // 上流には届かないこと
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// 中継した資源をキャッシュし、オフラインで返せること
    test('serves a relayed resource from cache while offline', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final uri = Uri.parse(
          'http://127.0.0.1:$port${mirroredPath('/lib/app.js')}',
        );
        await _performGet(uri);
        expect((await proxy.getCacheStats()).totalEntries, equals(1));

        await _emitConnectivity(['none']);
        final offlineResponse = await _performGet(uri);

        expect(offlineResponse.statusCode, equals(HttpStatus.ok));
        expect(offlineResponse.body, equals('console.log("cdn");'));
        expect(offlineResponse.offlineSource, equals('cache'));
      });
    });

    /// オフラインでもキャッシュした HTML を書き換えて返すこと
    test('rewrites the cached html while offline', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final uri = Uri.parse('http://127.0.0.1:$port/index.html');
        await _performGet(uri);

        await _emitConnectivity(['none']);
        final offlineResponse = await _performGet(uri);

        expect(offlineResponse.offlineSource, equals('cache'));
        // 保存は上流のバイト列のまま行い、返す直前に書き換えること
        expect(
          offlineResponse.body,
          contains('src="${mirroredPath('/lib/app.js')}"'),
        );
      });
    });

    /// 許可していない origin への中継は行わないこと
    test('answers 404 for an origin that is not listed', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/ext/https/evil.example.com/payload.js'),
        );

        expect(response.statusCode, equals(HttpStatus.notFound));
        // 設定済み origin へ素通しさせないこと
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// 中継経路の更新系は受け付けないこと
    test('answers 405 for an update request on the relayed path', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response = await _performPost(
          Uri.parse('http://127.0.0.1:$port${mirroredPath('/lib/app.js')}'),
        );

        expect(response.statusCode, equals(HttpStatus.methodNotAllowed));
        expect(response.allow, equals('GET, HEAD'));
        expect(cdn!.receivedPaths, isEmpty);
        // キューにも載せないこと
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// 資源を指すタグだけを書き換えること
    test('rewrites resource tags but not a canonical link', () async {
      await withRealHttpClient(() async {
        await startServers();
        upstream!.routes = <String, _MockRoute>{
          '/index.html': _route(
            '<html><head>'
            '<link rel="stylesheet" href="${cdn!.origin}/lib/app.css">'
            '<link rel="canonical" href="${cdn!.origin}/index.html">'
            '</head><body>'
            "<img src='${cdn!.origin}/img/logo.png'>"
            '</body></html>',
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response =
            await _performGet(Uri.parse('http://127.0.0.1:$port/index.html'));

        expect(
          response.body,
          contains('href="${mirroredPath('/lib/app.css')}"'),
        );
        // 引用符の書き方を保ったまま値だけを差し替えること
        expect(
          response.body,
          contains("src='${mirroredPath('/img/logo.png')}'"),
        );
        // 別ページを指す rel は資源ではないため触れないこと
        expect(
          response.body,
          contains('rel="canonical" href="${cdn!.origin}/index.html"'),
        );
      });
    });

    /// 相対 URL は書き換えないこと
    test('leaves a relative url untouched', () async {
      await withRealHttpClient(() async {
        await startServers();
        upstream!.routes = <String, _MockRoute>{
          '/index.html': _route(
            '<html><body><script src="/js/local.js"></script></body></html>',
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response =
            await _performGet(Uri.parse('http://127.0.0.1:$port/index.html'));

        expect(response.body, contains('src="/js/local.js"'));
      });
    });

    /// HTML 以外の応答は書き換えないこと
    test('leaves a response that is not html untouched', () async {
      await withRealHttpClient(() async {
        await startServers();
        upstream!.routes = <String, _MockRoute>{
          '/api/settings.json': _route(
            '{"script":"${cdn!.origin}/lib/app.js"}',
            contentType: 'application/json; charset=utf-8',
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/api/settings.json'),
        );

        expect(response.body, contains('${cdn!.origin}/lib/app.js'));
      });
    });

    /// ウォームアップの連鎖取得が許可した origin まで届くこと
    test('collects a listed origin resource during warmup', () async {
      await withRealHttpClient(() async {
        await startServers();
        await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final result = await proxy.warmupCache(
          paths: const <String>['/index.html'],
          followReferences: true,
        );

        expect(result.successCount, equals(2));
        expect(cdn!.receivedPaths, contains('/lib/app.js'));
        expect((await proxy.getCacheStats()).totalEntries, equals(2));
      });
    });

    /// 別 origin へ資格情報と要求元を渡さないこと
    test('does not relay credential headers to a listed origin', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        const requestHeaders = <String, String>{
          'cookie': 'session=abc',
          'authorization': 'Bearer token',
          'referer': 'http://127.0.0.1/index.html',
        };

        await _performGet(
          Uri.parse('http://127.0.0.1:$port${mirroredPath('/lib/app.js')}'),
          headers: requestHeaders,
        );
        await _performGet(
          Uri.parse('http://127.0.0.1:$port/index.html'),
          headers: requestHeaders,
        );

        expect(cdn!.receivedHeaders['/lib/app.js'], isEmpty);
        // 設定済み origin への転送は従来どおりであること
        expect(
          upstream!.receivedHeaders['/index.html'],
          containsPair('authorization', 'Bearer token'),
        );
        expect(
          upstream!.receivedHeaders['/index.html'],
          containsPair('cookie', 'session=abc'),
        );
      });
    });

    /// 別 origin の redirect を中継経路へ書き換えること
    test('rewrites a redirect from a listed origin', () async {
      await withRealHttpClient(() async {
        await startServers();
        cdn!.routes = <String, _MockRoute>{
          '/lib/latest.js': _route(
            '',
            statusCode: HttpStatus.movedTemporarily,
            headers: <String, String>{
              'Location': '${cdn!.origin}/lib/app-1.0.js',
            },
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port${mirroredPath('/lib/latest.js')}'),
          followRedirects: false,
        );

        expect(response.statusCode, equals(HttpStatus.movedTemporarily));
        expect(
          response.location,
          equals('http://127.0.0.1:$port${mirroredPath('/lib/app-1.0.js')}'),
        );
      });
    });

    /// 許可した origin の URL を proxy URL へ解決すること
    test('resolves a listed origin url to the proxy url', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final resolution = proxy.resolveNavigationTarget(
          targetUrl: '${cdn!.origin}/lib/app.js',
        );

        expect(
          resolution.disposition,
          equals(ProxyNavigationDisposition.inWebView),
        );
        expect(
          resolution.reason,
          equals(ProxyNavigationReason.mirroredOriginUrl),
        );
        expect(
          resolution.proxyUri.toString(),
          equals('http://127.0.0.1:$port${mirroredPath('/lib/app.js')}'),
        );
      });
    });

    /// 版指定やパーセントエンコードを含むパスを往復できること
    test('restores a path that carries an at sign and encoded characters',
        () async {
      await withRealHttpClient(() async {
        await startServers();
        const resourcePath = '/npm/haori@0.47.6/dist/a%20b.js';
        upstream!.routes = <String, _MockRoute>{
          '/index.html': _route(
            '<html><body>'
            '<script src="${cdn!.origin}$resourcePath"></script>'
            '</body></html>',
          ),
        };
        cdn!.routes = <String, _MockRoute>{
          '/npm/haori@0.47.6/dist/a%20b.js': _route(
            'console.log("cdn");',
            contentType: 'text/javascript; charset=utf-8',
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final html =
            await _performGet(Uri.parse('http://127.0.0.1:$port/index.html'));
        expect(html.body, contains(mirroredPath(resourcePath)));

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port${mirroredPath(resourcePath)}'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.body, equals('console.log("cdn");'));
        // パーセントエンコードを保ったまま中継先へ届くこと
        expect(
          cdn!.receivedPaths,
          contains('/npm/haori@0.47.6/dist/a%20b.js'),
        );
      });
    });

    /// プロトコル相対 URL も書き換えること
    test('rewrites a protocol relative url', () async {
      await withRealHttpClient(() async {
        await startServers();
        final cdnAuthority = '127.0.0.1:${cdn!.port}';
        upstream!.routes = <String, _MockRoute>{
          '/index.html': _route(
            '<html><body>'
            '<script src="//$cdnAuthority/lib/app.js"></script>'
            '</body></html>',
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response =
            await _performGet(Uri.parse('http://127.0.0.1:$port/index.html'));

        expect(
          response.body,
          contains('src="${mirroredPath('/lib/app.js')}"'),
        );
      });
    });

    /// 相対 Location の redirect も中継経路へ書き換えること
    test('rewrites a relative redirect from a listed origin', () async {
      await withRealHttpClient(() async {
        await startServers();
        cdn!.routes = <String, _MockRoute>{
          '/lib/latest.js': _route(
            '',
            statusCode: HttpStatus.movedTemporarily,
            headers: <String, String>{'Location': '/lib/app-1.0.js'},
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port${mirroredPath('/lib/latest.js')}'),
          followRedirects: false,
        );

        expect(response.statusCode, equals(HttpStatus.movedTemporarily));
        // 相対値は中継先の URL を基準に解決すること
        expect(
          response.location,
          equals('http://127.0.0.1:$port${mirroredPath('/lib/app-1.0.js')}'),
        );
      });
    });

    /// authority に認証情報を含むパスは中継しないこと
    test('answers 404 for a relayed path that carries user info', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/ext/http'
              '/evil%40127.0.0.1:${cdn!.port}/lib/app.js'),
        );

        // host が一致しても認証情報を伴う形は受け付けないこと
        expect(response.statusCode, equals(HttpStatus.notFound));
        expect(cdn!.receivedPaths, isEmpty);
      });
    });

    /// proxy 自身を指す中継は受け付けないこと
    test('answers 404 for a relayed path that points at the proxy itself',
        () async {
      await withRealHttpClient(() async {
        await startServers();

        // 起動前に proxy のポートを確定させるため、空きポートを確保して解放する
        final probe = await _startMockServer();
        final proxyPort = probe.port;
        await probe.close();

        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            port: proxyPort,
            mirroredOrigins: <String>['http://127.0.0.1:$proxyPort'],
          ),
        );
        // 確保したポートで待ち受けていること（テストの前提の確認）
        expect(port, equals(proxyPort));

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/ext/http/127.0.0.1:$port/index.html'),
        );

        // 自分への転送にならず、上流にも届かないこと
        expect(response.statusCode, equals(HttpStatus.notFound));
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// 許可外 origin をウォームアップに指定しても例外にしないこと
    test('reports a warmup failure for an origin that is not listed', () async {
      await withRealHttpClient(() async {
        await startServers();
        await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final errors = <String>[];
        final result = await proxy.warmupCache(
          paths: const <String>[
            '/__offline_web_proxy/ext/https/evil.example.com/payload.js',
          ],
          onError: (path, message) => errors.add(message),
        );

        // 例外を投げず、理由の分かる失敗として記録すること
        expect(result.successCount, equals(0));
        expect(result.failureCount, equals(1));
        expect(errors.single, contains('Mirrored origin is not allowed'));
      });
    });

    /// UTF-8 以外の本文でもバイト列を保ったまま書き換えること
    test('rewrites a shift_jis document without altering its bytes', () async {
      await withRealHttpClient(() async {
        await startServers();

        // 「画面」を Shift_JIS で表したバイト列
        const japaneseBytes = <int>[0x89, 0xE6, 0x96, 0xCA];
        final prefix = ascii.encode('<html><body><script src="');
        final reference = ascii.encode('${cdn!.origin}/lib/app.js');
        final suffix = ascii.encode('"></script>');
        final tail = ascii.encode('</body></html>');
        upstream!.routes = <String, _MockRoute>{
          '/index.html': _route(
            '',
            contentType: 'text/html; charset=Shift_JIS',
            bodyBytes: <int>[
              ...prefix,
              ...reference,
              ...suffix,
              ...japaneseBytes,
              ...tail,
            ],
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response = await _performGetBytes(
          Uri.parse('http://127.0.0.1:$port/index.html'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(
          response.bodyBytes,
          equals(<int>[
            ...prefix,
            ...ascii.encode(mirroredPath('/lib/app.js')),
            ...suffix,
            // 復号できない文字コードでもバイト列が壊れないこと
            ...japaneseBytes,
            ...tail,
          ]),
        );
      });
    });

    /// 圧縮された本文は書き換えずにそのまま返すこと
    test('leaves a compressed html untouched', () async {
      await withRealHttpClient(() async {
        await startServers();

        final plainBody = '<html><body>'
            '<script src="${cdn!.origin}/lib/app.js"></script>'
            '</body></html>';
        upstream!.routes = <String, _MockRoute>{
          '/index.html': _route(
            '',
            headers: <String, String>{'Content-Encoding': 'gzip'},
            bodyBytes: gzip.encode(utf8.encode(plainBody)),
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response =
            await _performGet(Uri.parse('http://127.0.0.1:$port/index.html'));

        // 解釈できない本文を壊さず、書き換えも行わないこと
        expect(response.body, equals(plainBody));
      });
    });

    /// Content-Encoding を持つ応答は書き換えの対象にしないこと
    test('skips rewriting when the response declares a content encoding',
        () async {
      await withRealHttpClient(() async {
        await startServers();

        // 判定を確かめるため、圧縮していない本文へ意図的に宣言だけを付ける
        final plainBody = '<html><body>'
            '<script src="${cdn!.origin}/lib/app.js"></script>'
            '</body></html>';
        upstream!.routes = <String, _MockRoute>{
          '/index.html': _route(
            '',
            headers: <String, String>{'Content-Encoding': 'gzip'},
            bodyBytes: utf8.encode(plainBody),
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response = await _performGetBytes(
          Uri.parse('http://127.0.0.1:$port/index.html'),
          autoUncompress: false,
        );

        // 宣言を信じて手を触れず、元の URL のまま返すこと
        expect(utf8.decode(response.bodyBytes), equals(plainBody));
      });
    });

    /// 差し替えたオフライン応答も書き換えの対象になること
    test('rewrites the configured offline fallback html', () async {
      await withRealHttpClient(() async {
        await startServers();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
            offlineFallbackHtml: '<html><body>'
                '<script src="${cdn!.origin}/lib/app.js"></script>'
                '</body></html>',
          ),
        );

        await _emitConnectivity(['none']);
        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/unknown.html'),
          headers: const <String, String>{'accept': 'text/html'},
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(
          response.body,
          contains('src="${mirroredPath('/lib/app.js')}"'),
        );
      });
    });

    /// 属性名で照合するため data-src は含み srcset は含まないこと
    test('rewrites a prefixed src attribute but not srcset', () async {
      await withRealHttpClient(() async {
        await startServers();
        upstream!.routes = <String, _MockRoute>{
          '/index.html': _route(
            '<html><body>'
            '<img data-src="${cdn!.origin}/img/lazy.png">'
            '<img srcset="${cdn!.origin}/img/wide.png 2x">'
            '</body></html>',
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response =
            await _performGet(Uri.parse('http://127.0.0.1:$port/index.html'));

        // 照合は属性名 src / href で行うため接頭辞付きも対象になること
        expect(
          response.body,
          contains('data-src="${mirroredPath('/img/lazy.png')}"'),
        );
        // srcset は対象外であること
        expect(
          response.body,
          contains('srcset="${cdn!.origin}/img/wide.png 2x"'),
        );
      });
    });

    /// 同梱アセットの HTML は書き換えの対象外であること
    test('leaves bundled static html untouched', () async {
      await withRealHttpClient(() async {
        await startServers();
        final bundledHtml = '<html><body>'
            '<script src="${cdn!.origin}/lib/app.js"></script>'
            '</body></html>';
        _mockAssetContents['assets/static/bundled.html'] = bundledHtml;

        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        final response =
            await _performGet(Uri.parse('http://127.0.0.1:$port/bundled.html'));

        // 静的リソースとして先に返るため、書き換えを通らないこと
        expect(response.staticResource, equals('true'));
        expect(response.body, equals(bundledHtml));
      });
    });

    /// 中継経路にも forceCachePaths を指定できること
    test('applies forceCachePaths to the relayed path', () async {
      await withRealHttpClient(() async {
        await startServers();
        cdn!.routes = <String, _MockRoute>{
          '/lib/app.js': _route(
            'console.log("cdn");',
            contentType: 'text/javascript; charset=utf-8',
            headers: <String, String>{'Cache-Control': 'no-store'},
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
            // 照合対象は proxy が受け取ったパスであること
            forceCachePaths: const <String>['/__offline_web_proxy/ext/**'],
          ),
        );

        await _performGet(
          Uri.parse('http://127.0.0.1:$port${mirroredPath('/lib/app.js')}'),
        );

        expect((await proxy.getCacheStats()).totalEntries, equals(1));
      });
    });

    /// origin として解釈できない設定は起動時に弾くこと
    test('rejects a listed origin that carries a path', () async {
      await withRealHttpClient(() async {
        await startServers();

        expect(
          () => proxy.start(
            config: ProxyConfig(
              origin: upstream!.origin,
              mirroredOrigins: const <String>['https://cdn.example.com/assets'],
            ),
          ),
          throwsA(isA<ProxyStartException>()),
        );
      });
    });
  });
}
