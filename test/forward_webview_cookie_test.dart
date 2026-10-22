import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';

import 'support/access_token_http.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// 暗号化鍵を保存する secure storage 上の名前。
const String _keyName = 'offline_web_proxy.cookie_box_encryption_key';

/// キューの暗号化 Box の名前。
const String _queueBoxName = 'proxy_queue_secure';

/// テストで暗号化 Box に使う 32 バイトの鍵。
final List<int> _encryptionKey =
    List<int>.generate(32, (index) => (index * 11 + 5) & 0xff);

/// メモリ上に鍵を保存する secure storage。
class _FakeKeyStorage implements EncryptionKeyStorage {
  /// 保存されている値。
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<bool?> isProtectedDataAvailable() async => null;
}

/// 受信した `Cookie` を記録し、経路ごとに `Set-Cookie` を返すサーバのモック。
///
/// 上流と中継先（CDN）の双方に使う。
class _CookieServer {
  /// [_server] で待ち受けるモックを作る。
  _CookieServer(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        final path = request.uri.path;
        receivedPaths.add(path);
        receivedCookies
            .add((path: path, cookie: request.headers.value('cookie')));
        final location = redirects[path];
        request.response.statusCode =
            location != null ? HttpStatus.found : statusCode;
        if (location != null) {
          request.response.headers.set('location', location);
        }
        request.response.headers.contentType =
            ContentType('text', 'plain', charset: 'utf-8');
        for (final setCookie in setCookies[path] ?? const <String>[]) {
          request.response.headers.add('set-cookie', setCookie);
        }
        request.response.write('ok');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  /// 待ち受けているサーバ。
  final HttpServer _server;

  /// 受信したパスの一覧。受信順に追加される。
  final List<String> receivedPaths = <String>[];

  /// 受信した要求のパスと `Cookie` ヘッダ。受信順に追加される。
  final List<({String path, String? cookie})> receivedCookies = [];

  /// パスごとに返す `Set-Cookie` の値。
  final Map<String, List<String>> setCookies = <String, List<String>>{};

  /// パスごとに `302` で返す `Location` の値。
  final Map<String, String> redirects = <String, String>{};

  /// 応答するステータスコード。テスト中に変更できる。
  int statusCode = HttpStatus.ok;

  /// [host] で表したサーバの origin。
  ///
  /// [host] origin に使うホスト名。
  ///
  /// Returns: `http://<host>:<port>` 形式の origin。
  String originFor(String host) => 'http://$host:${_server.port}';

  /// サーバのポート番号。
  int get port => _server.port;

  /// [path] 宛てに最後に受信した `Cookie` ヘッダ。
  ///
  /// [path] 対象のパス。
  ///
  /// Returns: 最後に受信した値。`Cookie` が無かった場合は `null`。
  String? lastCookieFor(String path) =>
      receivedCookies.lastWhere((entry) => entry.path == path).cookie;

  /// サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// モックサーバを IPv4 の loopback で起動する。
Future<_CookieServer> _startCookieServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _CookieServer(server);
}

/// 実 HttpClient で要求を実行する。
///
/// [uri] 要求先。
/// [method] HTTP メソッド。
/// [cookie] WebView が送る想定の `Cookie` ヘッダ。
///
/// Returns: ステータス、受け取った `Set-Cookie` の一覧と `Location`。
Future<({int statusCode, List<String> setCookies, String? location})> _request(
  Uri uri, {
  String method = 'GET',
  String? cookie,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    // proxy が返した redirect そのものを確かめるため、たどらない
    request.followRedirects = false;
    if (cookie != null) {
      request.headers.set('cookie', cookie);
    }
    if (method != 'GET') {
      request.headers.contentType = ContentType.json;
      request.write('{"total":1}');
    }
    final response = await request.close();
    await response.drain<void>();
    return (
      statusCode: response.statusCode,
      setCookies: response.headers['set-cookie'] ?? const <String>[],
      location: response.headers.value('location'),
    );
  } finally {
    client.close(force: true);
  }
}

/// `Cookie` を複数の行に分けた要求を、ソケットへ直接書いて送る。
///
/// dart:io の HttpClient は同じ名前のヘッダを 1 行にまとめるため、
/// 行を分けて送る WebView を再現するのに使う。
///
/// [port] proxy の待ち受けポート。
/// [path] 要求するパス。
/// [accessToken] 付ける秘密値。
/// [cookieLines] `Cookie` の各行の値。
/// [method] HTTP メソッド。
///
/// Returns: 応答のステータス行。
Future<String> _sendSplitCookieRequest(
  int port, {
  required String path,
  required String accessToken,
  required List<String> cookieLines,
  String method = 'GET',
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  try {
    const body = '{"total":1}';
    final hasBody = method != 'GET';
    final buffer = StringBuffer()
      ..write('$method $path HTTP/1.1\r\n')
      ..write('Host: 127.0.0.1:$port\r\n')
      ..write('${OfflineWebProxy.accessTokenHeaderName}: $accessToken\r\n');
    for (final line in cookieLines) {
      buffer.write('Cookie: $line\r\n');
    }
    if (hasBody) {
      buffer
        ..write('Content-Type: application/json\r\n')
        ..write('Content-Length: ${utf8.encode(body).length}\r\n');
    }
    buffer.write('Connection: close\r\n\r\n');
    if (hasBody) {
      buffer.write(body);
    }
    socket.write(buffer.toString());
    await socket.flush();
    final response = await utf8.decoder.bind(socket).join();
    return response.split('\r\n').first;
  } finally {
    socket.destroy();
  }
}

/// [check] が真を返すまで待つ。
///
/// [check] 待ち終える条件。
/// [timeout] 待つ上限。
///
/// Returns: 上限までに条件を満たした場合は `true`。
Future<bool> _waitUntil(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
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

  late _FakeKeyStorage keyStorage;
  late OfflineWebProxy proxy;
  _CookieServer? upstream;
  _CookieServer? cdn;

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_forward_webview_cookie')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    keyStorage = _FakeKeyStorage();
    proxy = trackAccessToken(
      OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks(
        keyStorage: keyStorage,
        keyRereadInterval: Duration.zero,
      )),
    );
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream?.close();
    await cdn?.close();
    upstream = null;
    cdn = null;
    await Hive.close();
  });

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: AccessTokenHttpOverrides().createHttpClient,
    );
  }

  /// 上流のモックを起動し、[forwardWebViewCookieNames] で proxy を起動する。
  ///
  /// [forwardWebViewCookieNames] 上流へ渡す WebView の Cookie 名。
  /// [mirroredOrigins] 中継する別 origin。
  ///
  /// Returns: proxy の待ち受けポート。
  Future<int> startProxy({
    Set<String> forwardWebViewCookieNames = const <String>{},
    List<String> mirroredOrigins = const <String>[],
  }) async {
    upstream ??= await _startCookieServer();
    return proxy.start(
      config: ProxyConfig(
        origin: upstream!.originFor('127.0.0.1'),
        forwardWebViewCookieNames: forwardWebViewCookieNames,
        mirroredOrigins: mirroredOrigins,
      ),
    );
  }

  /// 暗号化 Box に保存されているキューの項目 1 件のヘッダを、そのまま読む。
  Map<String, String> storedHeaders() {
    final data = Hive.box(_queueBoxName).values.single as Map;
    return Map<String, String>.from(data['headers'] as Map);
  }

  group('上流へ渡す WebView の Cookie（doc/specs.ja.md 【14】Cookie ヘッダ）', () {
    /// 既定では WebView の Cookie を上流へ渡さないこと
    test('drops every WebView cookie by default', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();

        await _request(
          Uri.parse('http://127.0.0.1:$port/page'),
          cookie: 'app=1; planted=2',
        );

        expect(upstream!.lastCookieFor('/page'), isNull);
      });
    });

    /// 許可した名前の Cookie だけを上流へ渡すこと
    test('forwards only the listed cookie names', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(forwardWebViewCookieNames: {'app'});

        await _request(
          Uri.parse('http://127.0.0.1:$port/page'),
          // 名前は大文字小文字を区別する
          cookie: 'app=1; planted=2; APP=3',
        );

        expect(upstream!.lastCookieFor('/page'), 'app=1');
      });
    });

    /// `Cookie` が複数の行に分かれていても、許可しない Cookie を値に紛れさせないこと
    test('filters cookies split across several Cookie lines', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(forwardWebViewCookieNames: {'app'});

        final status = await _sendSplitCookieRequest(
          port,
          path: '/page',
          accessToken: proxy.accessToken!,
          cookieLines: ['app=1', 'planted=2'],
        );

        expect(status, contains('200'));
        expect(upstream!.lastCookieFor('/page'), 'app=1');
      });
    });

    /// 許可した名前でも、Jar に同じ名前があれば Jar の値を送ること
    test('prefers the jar value over a listed WebView cookie', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          forwardWebViewCookieNames: {'SESSION', 'app'},
        );
        upstream!.setCookies['/login'] = ['SESSION=jar; Path=/'];
        await _request(Uri.parse('http://127.0.0.1:$port/login'));

        await _request(
          Uri.parse('http://127.0.0.1:$port/page'),
          cookie: 'SESSION=webview; app=1',
        );

        expect(upstream!.lastCookieFor('/page'), 'SESSION=jar; app=1');
      });
    });

    /// `'*'` では秘密値以外の WebView の Cookie をすべて渡すこと（0.25.0 互換）
    test('forwards every cookie but the token with "*"', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(forwardWebViewCookieNames: {'*'});

        await _request(
          Uri.parse('http://127.0.0.1:$port/page'),
          cookie: 'app=1; '
              '${OfflineWebProxy.accessTokenCookieName}=${proxy.accessToken}; '
              'other=2',
        );

        expect(upstream!.lastCookieFor('/page'), 'app=1; other=2');
      });
    });
  });

  group('forwardWebViewCookieNames の検証（doc/specs.ja.md 【20】）', () {
    /// 起動を拒否する値を [names] で起動し、ProxyStartException を確かめる
    Future<void> expectRejected(Set<String> names) async {
      await expectLater(
        proxy.start(
          config: ProxyConfig(
            origin: 'https://example.com',
            forwardWebViewCookieNames: names,
          ),
        ),
        throwsA(isA<ProxyStartException>()),
      );
      expect(proxy.isRunning, isFalse);
    }

    /// RFC 6265 の token でない名前を拒否すること
    test('rejects names that are not RFC 6265 tokens', () async {
      await expectRejected({'bad name'});
      await expectRejected({'a;b'});
      await expectRejected({'a=b'});
      await expectRejected({''});
    });

    /// 秘密値の Cookie 名を拒否すること
    test('rejects the access token cookie name', () async {
      await expectRejected({OfflineWebProxy.accessTokenCookieName});
    });

    /// `'*'` と他の名前の混在を拒否すること
    test('rejects "*" combined with other names', () async {
      await expectRejected({'*', 'app'});
    });

    /// `'*'` 単独と token の名前は受け付けること
    test('accepts "*" alone and token names', () async {
      for (final names in [
        {'*'},
        {'app', r"!#$%&'*+-.^_`|~09AZaz"},
      ]) {
        await proxy.start(
          config: ProxyConfig(
            origin: 'https://example.com',
            forwardWebViewCookieNames: names,
          ),
        );
        expect(proxy.isRunning, isTrue);
        await proxy.stop();
      }
    });
  });

  group('中継経路の Set-Cookie（doc/specs.ja.md 【14】Set-Cookie）', () {
    /// 中継先の Set-Cookie を WebView へ返さず、Jar には保存すること
    test('keeps a relayed Set-Cookie in the jar only', () async {
      await withRealHttpClient(() async {
        cdn = await _startCookieServer();
        // 設定済み origin と別のホストにし、受け入れ規則で拒否されないようにする
        final cdnOrigin = cdn!.originFor('localhost');
        cdn!.setCookies['/lib/app.js'] = ['cdn=1; Path=/'];
        final port = await startProxy(mirroredOrigins: [cdnOrigin]);

        final response = await _request(Uri.parse(
          'http://127.0.0.1:$port'
          '/__offline_web_proxy/ext/http/localhost:${cdn!.port}/lib/app.js',
        ));

        expect(response.statusCode, HttpStatus.ok);
        expect(cdn!.receivedPaths, ['/lib/app.js']);
        expect(response.setCookies, isEmpty);
        final cookies = await proxy.getCookies();
        expect(cookies.map((cookie) => (cookie.name, cookie.domain)),
            [('cdn', 'localhost')]);
      });
    });

    /// 中継先の redirect でも Set-Cookie を WebView へ返さず、Jar には保存すること
    test('keeps a Set-Cookie of a relayed redirect in the jar only', () async {
      await withRealHttpClient(() async {
        cdn = await _startCookieServer();
        final cdnOrigin = cdn!.originFor('localhost');
        cdn!.redirects['/lib/latest.js'] = '$cdnOrigin/lib/app.js';
        cdn!.setCookies['/lib/latest.js'] = ['cdn=1; Path=/'];
        final port = await startProxy(mirroredOrigins: [cdnOrigin]);

        final response = await _request(Uri.parse(
          'http://127.0.0.1:$port'
          '/__offline_web_proxy/ext/http/localhost:${cdn!.port}/lib/latest.js',
        ));

        // 前提: 中継先内の redirect を proxy URL へ書き換えて返している
        expect(response.statusCode, HttpStatus.found);
        expect(
          response.location,
          endsWith(
            '/__offline_web_proxy/ext/http/localhost:${cdn!.port}/lib/app.js',
          ),
        );
        expect(response.setCookies, isEmpty);
        final cookies = await proxy.getCookies();
        expect(cookies.map((cookie) => (cookie.name, cookie.domain)),
            [('cdn', 'localhost')]);
      });
    });

    /// 設定済み origin の Set-Cookie は従来どおり WebView へ返すこと
    test('returns a Set-Cookie of the configured origin', () async {
      await withRealHttpClient(() async {
        upstream = await _startCookieServer();
        upstream!.setCookies['/page'] = ['a=1; Path=/', 'b=2; Path=/'];
        final port = await startProxy();

        final response =
            await _request(Uri.parse('http://127.0.0.1:$port/page'));

        expect(response.setCookies, ['a=1; Path=/', 'b=2; Path=/']);
        expect(
          (await proxy.getCookies()).map((cookie) => cookie.name).toSet(),
          {'a', 'b'},
        );
      });
    });
  });

  group('キューの Cookie（doc/specs.ja.md 【5】）', () {
    /// 保存するヘッダの Cookie を許可した名前だけにすること
    test('stores only the listed cookies in the queue', () async {
      await withRealHttpClient(() async {
        upstream = await _startCookieServer();
        upstream!.statusCode = HttpStatus.internalServerError;
        final port = await startProxy(forwardWebViewCookieNames: {'app'});

        await _request(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          method: 'POST',
          cookie: 'app=1; planted=2',
        );

        expect(await proxy.getQueuedRequests(), hasLength(1));
        final stored = storedHeaders();
        expect(
          stored.entries
              .where((entry) => entry.key.toLowerCase() == 'cookie')
              .map((entry) => entry.value),
          ['app=1'],
        );
      });
    });

    /// `Cookie` が複数の行に分かれていても、保存する Cookie を許可した名前だけにすること
    test('stores only the listed cookies from several Cookie lines', () async {
      await withRealHttpClient(() async {
        upstream = await _startCookieServer();
        upstream!.statusCode = HttpStatus.internalServerError;
        final port = await startProxy(forwardWebViewCookieNames: {'app'});

        await _sendSplitCookieRequest(
          port,
          path: '/api/sales',
          method: 'POST',
          accessToken: proxy.accessToken!,
          cookieLines: ['app=1', 'planted=2'],
        );

        // 前提: 1 件がキューに保存されている
        expect(await proxy.getQueuedRequests(), hasLength(1));
        expect(
          storedHeaders()
              .entries
              .where((entry) => entry.key.toLowerCase() == 'cookie')
              .map((entry) => entry.value),
          ['app=1'],
        );
        // 転送で上流が受け取った値も同じであること
        expect(upstream!.lastCookieFor('/api/sales'), 'app=1');
      });
    });

    /// 許可した Cookie が残らない場合は Cookie を保存しないこと
    test('leaves the cookie header out when none is listed', () async {
      await withRealHttpClient(() async {
        upstream = await _startCookieServer();
        upstream!.statusCode = HttpStatus.internalServerError;
        final port = await startProxy();

        await _request(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          method: 'POST',
          cookie: 'app=1; planted=2',
        );

        expect(await proxy.getQueuedRequests(), hasLength(1));
        expect(
          storedHeaders().keys.map((name) => name.toLowerCase()),
          isNot(contains('cookie')),
        );
      });
    });

    /// 0.25.0 形式の保存データからも、許可しない Cookie を再送しないこと
    test('drops unlisted cookies of 0.25.0 queue data when replaying',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startCookieServer();

        // 0.25.0 は WebView の Cookie をすべて保存していた
        keyStorage.values[_keyName] = base64Encode(_encryptionKey);
        await Hive.initFlutter();
        final box = await Hive.openBox(
          _queueBoxName,
          encryptionCipher: HiveAesCipher(_encryptionKey),
        );
        final queuedAt = DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toIso8601String();
        await box.put('0001757000000000000-000000', {
          'url': '${upstream!.originFor('127.0.0.1')}/api/sales',
          'method': 'POST',
          'headers': <String, String>{
            'content-type': 'application/json',
            'cookie': 'app=1; planted=2',
          },
          'body': utf8.encode('{"total":1}'),
          'queuedAt': queuedAt,
          'acceptedAt': queuedAt,
          'retryCount': 0,
          'nextRetryAt': queuedAt,
        });
        await box.close();

        await startProxy(forwardWebViewCookieNames: {'app'});

        final drained = await _waitUntil(
            () async => (await proxy.getQueuedRequests()).isEmpty);
        expect(drained, isTrue, reason: 'キューが時間内に空になりませんでした');
        expect(upstream!.lastCookieFor('/api/sales'), 'app=1');
      });
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
