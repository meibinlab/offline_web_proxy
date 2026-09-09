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

/// パスごとに応答を差し替えられる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await utf8.decoder.bind(request).join();
        receivedPaths.add(request.uri.path);
        receivedCookies.add(request.headers.value('cookie'));

        final body = bodies[request.uri.path];
        if (body == null) {
          request.response.statusCode = statusCode;
          request.response.headers.contentType =
              ContentType('text', 'plain', charset: 'utf-8');
          request.response.write('upstream');
        } else {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = body.contentType;
          for (final value in setCookies) {
            request.response.headers.add('set-cookie', value);
          }
          request.response.write(body.content);
        }
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 上流が受信したパスの一覧。受信順に追加される。
  final List<String> receivedPaths = <String>[];

  /// 上流が受信した `Cookie` ヘッダの一覧。付与が無い場合は `null` が入る。
  final List<String?> receivedCookies = <String?>[];

  /// パスごとの応答内容。未登録のパスは [statusCode] で応答する。
  final Map<String, ({String content, ContentType contentType})> bodies = {};

  /// 応答へ付与する `Set-Cookie` の一覧。
  final List<String> setCookies = <String>[];

  /// 未登録パスへ返すステータスコード。
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

/// 実 HttpClient で要求を実行する。
///
/// [uri] は要求先、[method] は HTTP メソッド、[headers] は付与するヘッダです。
/// 戻り値はステータス、本文、および判定に使う応答ヘッダです。
Future<
    ({
      int statusCode,
      String body,
      String? allowOrigin,
      String? cacheControl,
    })> _performRequest(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  String? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.write(body);
    }
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      body: responseBody,
      allowOrigin: response.headers.value('access-control-allow-origin'),
      cacheControl: response.headers.value('cache-control'),
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
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_warmup_reference')
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

  group('ウォームアップ（doc/specs.ja.md 【8】キャッシュ整合性）', () {
    /// 認証が必要な資源を取得できるよう Cookie Jar を送ること
    test('sends the cookie jar so authenticated resources can be warmed up',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.bodies['/api/sign_in'] = (
          content: 'ok',
          contentType: ContentType('text', 'plain', charset: 'utf-8'),
        );
        upstream!.setCookies.add('session=abc123; Path=/');
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        // 通常の転送で Cookie Jar へ保存させる
        await _performRequest(
          Uri.parse('http://127.0.0.1:$port/api/sign_in'),
        );
        upstream!.setCookies.clear();
        upstream!.receivedCookies.clear();

        await proxy.warmupCache(paths: ['/api/registers.json']);

        // Cookie を送らないと認証必須の資源が 403 になり、何も貯まらない
        expect(upstream!.receivedCookies.single, contains('session=abc123'));
      });
    });

    /// 参照資源を続けて取得すること
    test('follows references found in the warmed html', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.bodies['/app/register'] = (
          content: '<html><head>'
              '<link rel="stylesheet" href="/css/app.css?v=1">'
              '<script src="js/app.js"></script>'
              '</head><body><img src="/img/logo.png"></body></html>',
          contentType: ContentType('text', 'html', charset: 'utf-8'),
        );
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        expect(port, greaterThan(0));

        final result = await proxy.warmupCache(
          paths: ['/app/register'],
          followReferences: true,
        );

        expect(
          upstream!.receivedPaths,
          containsAll(<String>[
            '/app/register',
            '/css/app.css',
            '/img/logo.png',
            '/app/js/app.js'
          ]),
        );
        expect(result.entries, hasLength(4));
        // 参照元を辿れること
        final referenced =
            result.entries.where((entry) => entry.referencedFrom != null);
        expect(referenced, hasLength(3));
        expect(
          referenced.every((entry) => entry.referencedFrom == '/app/register'),
          isTrue,
        );
      });
    });

    /// 既定では参照資源を取得しないこと
    test('does not follow references unless asked', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.bodies['/app/register'] = (
          content:
              '<html><body><script src="/js/app.js"></script></body></html>',
          contentType: ContentType('text', 'html', charset: 'utf-8'),
        );
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        expect(port, greaterThan(0));

        await proxy.warmupCache(paths: ['/app/register']);

        expect(upstream!.receivedPaths, equals(['/app/register']));
      });
    });

    /// 別 origin の参照は取得しないこと
    test('skips references that point at another origin', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.bodies['/app/register'] = (
          content: '<html><body>'
              '<script src="https://cdn.jsdelivr.net/npm/haori.js"></script>'
              '<script src="/js/local.js"></script>'
              '</body></html>',
          contentType: ContentType('text', 'html', charset: 'utf-8'),
        );
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        expect(port, greaterThan(0));

        await proxy.warmupCache(
          paths: ['/app/register'],
          followReferences: true,
        );

        expect(
            upstream!.receivedPaths, equals(['/app/register', '/js/local.js']));
      });
    });

    /// 同じ資源を二度取得しないこと
    test('requests a shared resource only once', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        const html = '<html><body>'
            '<script src="/js/app.js"></script>'
            '<script src="/js/app.js"></script>'
            '</body></html>';
        upstream!.bodies['/app/a'] = (
          content: html,
          contentType: ContentType('text', 'html', charset: 'utf-8'),
        );
        upstream!.bodies['/app/b'] = (
          content: html,
          contentType: ContentType('text', 'html', charset: 'utf-8'),
        );
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        expect(port, greaterThan(0));

        await proxy.warmupCache(
          paths: ['/app/a', '/app/b'],
          followReferences: true,
        );

        expect(
          upstream!.receivedPaths.where((path) => path == '/js/app.js'),
          hasLength(1),
        );
      });
    });

    /// 別ページを指す link は取得しないこと
    test('skips a link that points at another page', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.bodies['/app/register'] = (
          content: '<html><head>'
              '<link rel="canonical" href="/app/register-canonical">'
              '<link rel="alternate" href="/app/register.csv">'
              '<link rel="stylesheet" href="/css/app.css">'
              '</head><body></body></html>',
          contentType: ContentType('text', 'html', charset: 'utf-8'),
        );
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        expect(port, greaterThan(0));

        await proxy.warmupCache(
          paths: ['/app/register'],
          followReferences: true,
        );

        // 資源を指す rel だけを対象にすること
        expect(
            upstream!.receivedPaths, equals(['/app/register', '/css/app.css']));
      });
    });

    /// 上流 origin にパスが含まれる場合も正しく解決すること
    test('resolves references when the origin carries a base path', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.bodies['/base/app/register'] = (
          content: '<html><head>'
              '<link rel="stylesheet" href="/base/css/app.css">'
              '</head><body></body></html>',
          contentType: ContentType('text', 'html', charset: 'utf-8'),
        );
        final port = await proxy.start(
          config: ProxyConfig(origin: '${upstream!.origin}/base'),
        );
        expect(port, greaterThan(0));

        await proxy.warmupCache(
          paths: ['/app/register'],
          followReferences: true,
        );

        // origin の接頭辞を二重に付けないこと
        expect(upstream!.receivedPaths,
            equals(['/base/app/register', '/base/css/app.css']));
      });
    });

    /// HTML 以外からは参照を抽出しないこと
    test('does not scan a response that is not html', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.bodies['/api/config.json'] = (
          content: '{"script":"<script src=/js/app.js></script>"}',
          contentType: ContentType('application', 'json', charset: 'utf-8'),
        );
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        expect(port, greaterThan(0));

        await proxy.warmupCache(
          paths: ['/api/config.json'],
          followReferences: true,
        );

        expect(upstream!.receivedPaths, equals(['/api/config.json']));
      });
    });
  });
}
