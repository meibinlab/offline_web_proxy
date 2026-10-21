import 'dart:async';
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
    List<int>.generate(32, (index) => (index * 7 + 3) & 0xff);

/// 上流へ渡してはならない、要求元や元の URL を名乗るヘッダ。
const Map<String, String> _forwardingHeaders = {
  'Forwarded': 'for=203.0.113.1',
  'X-Forwarded-For': '203.0.113.1',
  'X-Forwarded-Host': 'admin.example.com',
  'X-Forwarded-Proto': 'https',
  'X-Forwarded-Port': '443',
  'X-Forwarded-Prefix': '/admin',
  'X-Real-IP': '203.0.113.1',
  'X-Client-IP': '203.0.113.1',
  'True-Client-IP': '203.0.113.1',
  'CF-Connecting-IP': '203.0.113.1',
  'X-Original-URL': '/admin',
  'X-Rewrite-URL': '/admin',
};

/// [_forwardingHeaders] のうち、受け付ける要求に付けられるもの。
///
/// `X-Forwarded-Host` と `X-Forwarded-Proto` を持つ要求は Host 照合で
/// 拒否するため、転送・中継・キュー保存の確認では除く。
final Map<String, String> _acceptedForwardingHeaders = {
  for (final entry in _forwardingHeaders.entries)
    if (entry.key != 'X-Forwarded-Host' && entry.key != 'X-Forwarded-Proto')
      entry.key: entry.value,
};

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

/// 受信した要求のパスとヘッダを記録するサーバのモック。
///
/// 上流と中継先（CDN）の双方に使う。
class _RecordingServer {
  /// [_server] で待ち受けるモックを作る。
  _RecordingServer(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        final headers = <String, String>{};
        request.headers.forEach((name, values) {
          headers[name.toLowerCase()] = values.join(', ');
        });
        received.add((path: request.uri.path, headers: headers));
        request.response.statusCode = statusCode;
        request.response.headers.contentType =
            ContentType('text', 'plain', charset: 'utf-8');
        request.response.write('ok');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  /// 待ち受けているサーバ。
  final HttpServer _server;

  /// 受信した要求のパス（符号化されたまま）とヘッダ（名前は小文字）。
  final List<({String path, Map<String, String> headers})> received = [];

  /// 応答するステータスコード。テスト中に変更できる。
  int statusCode = HttpStatus.ok;

  /// サーバのポート番号。
  int get port => _server.port;

  /// [host] で表したサーバの origin。
  ///
  /// [host] origin に使うホスト名。
  ///
  /// Returns: `http://<host>:<port>` 形式の origin。
  String originFor(String host) => 'http://$host:$port';

  /// 受信したパスの一覧。
  List<String> get receivedPaths =>
      received.map((entry) => entry.path).toList();

  /// サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// モックサーバを IPv4 の loopback で起動する。
Future<_RecordingServer> _startServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _RecordingServer(server);
}

/// 生ソケットで受け取った応答。
typedef _RawResponse = ({int statusCode, Map<String, String> headers});

/// 要求行と `Host` ヘッダをそのままソケットへ書いて送る。
///
/// dart:io の HttpClient は `Host` を宛先から決め、パスも正規化するため、
/// 偽の `Host` や符号化したパスを送るのに使う。
///
/// [port] proxy の待ち受けポート。
/// [target] 要求行に書く宛先（パスまたは絶対 URL）。
/// [host] `Host` ヘッダの値。`null` の場合は書かない。
/// [address] 接続先のアドレス。
/// [accessToken] 付ける秘密値。
/// [method] HTTP メソッド。
/// [protocol] 要求行の HTTP バージョン。
/// [extraHeaders] 追加するヘッダ。
///
/// Returns: 応答のステータスコードとヘッダ（名前は小文字）。
Future<_RawResponse> _rawRequest(
  int port, {
  required String target,
  required String? host,
  String address = '127.0.0.1',
  String? accessToken,
  String method = 'GET',
  String protocol = 'HTTP/1.1',
  Map<String, String> extraHeaders = const {},
}) async {
  final socket = await Socket.connect(address, port);
  try {
    final buffer = StringBuffer()..write('$method $target $protocol\r\n');
    if (host != null) {
      buffer.write('Host: $host\r\n');
    }
    if (accessToken != null) {
      buffer
          .write('${OfflineWebProxy.accessTokenHeaderName}: $accessToken\r\n');
    }
    extraHeaders.forEach((name, value) => buffer.write('$name: $value\r\n'));
    buffer.write('Connection: close\r\n\r\n');
    socket.write(buffer.toString());
    await socket.flush();
    final response = await utf8.decoder.bind(socket).join();
    final head = response.split('\r\n\r\n').first.split('\r\n');
    final headers = <String, String>{};
    for (final line in head.skip(1)) {
      final separator = line.indexOf(':');
      if (separator > 0) {
        headers[line.substring(0, separator).trim().toLowerCase()] =
            line.substring(separator + 1).trim();
      }
    }
    return (statusCode: int.parse(head.first.split(' ')[1]), headers: headers);
  } finally {
    socket.destroy();
  }
}

/// 実 HttpClient で要求を実行する。
///
/// [uri] 要求先。
/// [method] HTTP メソッド。
/// [headers] 追加するヘッダ。
///
/// Returns: 応答のステータスとヘッダ。
Future<HttpClientResponse> _request(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (method != 'GET') {
      request.headers.contentType = ContentType.json;
      request.write('{"total":1}');
    }
    final response = await request.close();
    await response.drain<void>();
    return response;
  } finally {
    client.close(force: true);
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

/// [address] で待ち受けられるかどうかを返す。
///
/// IPv6 の loopback や `127.0.0.2` が使えない環境を見分けるのに使う。
///
/// [address] 試すアドレス。
///
/// Returns: 待ち受けられた場合は `true`。
Future<bool> _canBind(String address) async {
  try {
    final socket = await ServerSocket.bind(address, 0);
    await socket.close();
    return true;
  } on SocketException {
    return false;
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

  late _FakeKeyStorage keyStorage;
  late OfflineWebProxy proxy;
  late List<ProxyEvent> events;
  StreamSubscription<ProxyEvent>? eventSubscription;
  _RecordingServer? upstream;
  _RecordingServer? cdn;

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_request_target')
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
    events = <ProxyEvent>[];
    eventSubscription = proxy.events.listen(events.add);
  });

  tearDown(() async {
    await eventSubscription?.cancel();
    eventSubscription = null;
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

  /// 実 HttpClient が使えるゾーンでテストを登録する。
  ///
  /// proxy は起動したゾーンで上流へ要求するため、起動から検証まで同じ
  /// ゾーンで行う。
  ///
  /// [description] テストの説明。
  /// [body] テスト本体。
  /// [timeout] テストの制限時間。
  void realTest(
    String description,
    Future<void> Function() body, {
    Timeout? timeout,
  }) {
    test(description, () => withRealHttpClient(body), timeout: timeout);
  }

  /// 上流のモックを起動し、既定値を補って proxy を起動する。
  ///
  /// [host] proxy が待ち受けるホスト。
  /// [addCorsHeaders] CORS ヘッダを付けるかどうか。
  /// [authResumePaths] ログインのパス。
  /// [queueOwnerResolver] 持ち主の判定関数。
  /// [queueExcludePaths] キューへ入れない規則。
  /// [mirroredOrigins] 中継する別 origin。
  ///
  /// Returns: proxy の待ち受けポート。
  Future<int> startProxy({
    String host = '127.0.0.1',
    bool addCorsHeaders = false,
    List<String> authResumePaths = const [],
    QueueOwnerResolver? queueOwnerResolver,
    List<QueueExcludeRule> queueExcludePaths = const [],
    List<String> mirroredOrigins = const [],
  }) async {
    upstream ??= await _startServer();
    return proxy.start(
      config: ProxyConfig(
        origin: upstream!.originFor('127.0.0.1'),
        host: host,
        addCorsHeaders: addCorsHeaders,
        corsAllowedOrigins: addCorsHeaders ? const ['*'] : const [],
        authResumePaths: authResumePaths,
        queueOwnerResolver: queueOwnerResolver,
        queueExcludePaths: queueExcludePaths,
        mirroredOrigins: mirroredOrigins,
      ),
    );
  }

  group('Host ヘッダの照合（doc/specs.ja.md 【2】Host 照合）', () {
    /// proxy 自身を指す Host を受け付けること
    realTest('accepts hosts that name the proxy', () async {
      final port = await startProxy();
      for (final host in [
        '127.0.0.1:$port',
        'localhost:$port',
        'LocalHost:$port',
        '[::1]:$port',
      ]) {
        final response = await _rawRequest(
          port,
          target: '/page',
          host: host,
          accessToken: proxy.accessToken,
        );
        expect(response.statusCode, HttpStatus.ok, reason: host);
      }
      expect(upstream!.receivedPaths, hasLength(4));
    });

    /// 別のホスト名、違うポート、ポートなし、末尾ドットの Host を拒否すること
    realTest('rejects hosts that do not name the proxy', () async {
      final port = await startProxy(addCorsHeaders: true);
      final totalBefore = (await proxy.getStats()).totalRequests;

      for (final host in [
        'evil.example:$port',
        'EVIL.example:$port',
        '127.0.0.1:${port == 65535 ? port - 1 : port + 1}',
        '127.0.0.1',
        'localhost',
        'localhost.:$port',
        '127.0.0.2:$port',
        '[::2]:$port',
        '[0:0:0:0:0:0:0:1]:$port',
        '',
      ]) {
        final response = await _rawRequest(
          port,
          target: '/page',
          host: host,
          accessToken: proxy.accessToken,
        );
        expect(response.statusCode, HttpStatus.forbidden, reason: host);
        expect(response.headers['content-type'], startsWith('text/plain'));
        expect(response.headers['cache-control'], 'no-store');
        // CORS を有効にしていても、拒否には CORS ヘッダを付けない
        expect(response.headers.keys,
            isNot(contains('access-control-allow-origin')));
      }

      expect(upstream!.receivedPaths, isEmpty);
      // 統計とイベントに数えない
      expect((await proxy.getStats()).totalRequests, totalBefore);
      expect(
        events.where((event) => event.type == ProxyEventType.requestReceived),
        isEmpty,
      );
    });

    /// Host を持たない要求を拒否すること
    realTest('rejects a request without a Host header', () async {
      final port = await startProxy();

      final response = await _rawRequest(
        port,
        target: '/page',
        host: null,
        accessToken: proxy.accessToken,
        protocol: 'HTTP/1.0',
      );

      expect(response.statusCode, HttpStatus.forbidden);
      expect(upstream!.receivedPaths, isEmpty);
    });

    /// 要求行が別ホストの絶対 URL の場合は、Host が正しくても拒否すること
    realTest('rejects an absolute-form target naming another host', () async {
      final port = await startProxy();

      final rejected = await _rawRequest(
        port,
        target: 'http://evil.example:$port/page',
        host: '127.0.0.1:$port',
        accessToken: proxy.accessToken,
      );
      final accepted = await _rawRequest(
        port,
        target: 'http://127.0.0.1:$port/page',
        host: '127.0.0.1:$port',
        accessToken: proxy.accessToken,
      );

      expect(rejected.statusCode, HttpStatus.forbidden);
      expect(accepted.statusCode, HttpStatus.ok);
      expect(upstream!.receivedPaths, ['/page']);
    });

    /// 要求行の絶対 URL が userinfo を持つ場合は拒否すること
    realTest('rejects an absolute-form target with user info', () async {
      final port = await startProxy();

      final response = await _rawRequest(
        port,
        target: 'http://u:p@127.0.0.1:$port/page',
        host: '127.0.0.1:$port',
        accessToken: proxy.accessToken,
      );

      expect(response.statusCode, HttpStatus.forbidden);
      expect(upstream!.receivedPaths, isEmpty);
    });

    /// X-Forwarded-Host か X-Forwarded-Proto を持つ要求は、値にかかわらず拒否すること
    realTest('rejects X-Forwarded-Host and X-Forwarded-Proto of any value',
        () async {
      final port = await startProxy(addCorsHeaders: true);
      final totalBefore = (await proxy.getStats()).totalRequests;

      for (final header in <Map<String, String>>[
        {'X-Forwarded-Host': '127.0.0.1:$port'},
        {'X-Forwarded-Host': '127.0.0.1:$port/injected'},
        {'X-Forwarded-Host': 'evil.example/injected'},
        {'X-Forwarded-Host': 'u:p@127.0.0.1:$port'},
        {'X-Forwarded-Host': '127.0.0.1:$port/injected?q=1'},
        {'x-forwarded-host': ''},
        {'X-Forwarded-Proto': 'http'},
        {'X-Forwarded-Proto': 'https'},
        {'X-Forwarded-Proto': 'http://127.0.0.1:$port/injected'},
      ]) {
        final response = await _rawRequest(
          port,
          target: '/page?x=1',
          host: '127.0.0.1:$port',
          accessToken: proxy.accessToken,
          extraHeaders: header,
        );
        expect(response.statusCode, HttpStatus.forbidden, reason: '$header');
        expect(response.headers['content-type'], startsWith('text/plain'));
        expect(response.headers['cache-control'], 'no-store');
        expect(response.headers.keys,
            isNot(contains('access-control-allow-origin')));
      }

      // フラグメントを含む値は requestedUri に入り、shelf がパイプラインより前に 400 にする
      final withFragment = await _rawRequest(
        port,
        target: '/page',
        host: '127.0.0.1:$port',
        accessToken: proxy.accessToken,
        extraHeaders: {'X-Forwarded-Host': '127.0.0.1:$port/injected#f'},
      );
      expect(withFragment.statusCode, HttpStatus.badRequest);

      expect(upstream!.receivedPaths, isEmpty);
      expect((await proxy.getStats()).totalRequests, totalBefore);
      // 注入したパスや userinfo がイベントに出ない（起動のイベントだけ）
      expect(
        events.map((event) => event.type),
        [ProxyEventType.serverStarted],
      );
    });

    /// 稼働確認も Host を照合し、秘密値の検査より先に拒否すること
    realTest('checks the health check and runs before the token check',
        () async {
      final port = await startProxy();

      final foreign = await _rawRequest(
        port,
        target: '/__offline_web_proxy/health',
        host: 'evil.example:$port',
      );
      final local = await _rawRequest(
        port,
        target: '/__offline_web_proxy/health',
        host: 'localhost:$port',
      );
      // 秘密値を持たない要求でも、Host が違えば 403 の理由は Host
      final noToken = await _rawRequest(
        port,
        target: '/page',
        host: 'evil.example:$port',
      );

      expect(foreign.statusCode, HttpStatus.forbidden);
      expect(local.statusCode, HttpStatus.noContent);
      expect(noToken.statusCode, HttpStatus.forbidden);
      expect(upstream!.receivedPaths, isEmpty);
    });

    /// 再バインドで変わった稼働中のポートと照合すること
    realTest('compares with the port in use after a rebind', () async {
      final port = await startProxy();
      await proxy.closeServerSocketForTesting();
      final recovery = await proxy.ensureRunning(
        probeTimeout: const Duration(milliseconds: 300),
      );
      final newPort = proxy.port!;

      // 前提: 再バインドが成功している
      expect(recovery.restarted, isTrue);

      final response = await _rawRequest(
        newPort,
        target: '/page',
        host: '127.0.0.1:$newPort',
        accessToken: proxy.accessToken,
      );
      expect(response.statusCode, HttpStatus.ok);
      if (newPort != port) {
        final stale = await _rawRequest(
          newPort,
          target: '/page',
          host: '127.0.0.1:$port',
          accessToken: proxy.accessToken,
        );
        expect(stale.statusCode, HttpStatus.forbidden);
      }
    });
  });

  group('待ち受けるホストの制限（doc/specs.ja.md 【2】host 制限）', () {
    /// loopback 以外のホストでは起動しないこと
    realTest('refuses to start on a non-loopback host', () async {
      for (final host in [
        '0.0.0.0',
        '192.168.1.10',
        '::',
        'example.com',
        'localhost.',
        '',
      ]) {
        await expectLater(
          proxy.start(
            config: ProxyConfig(origin: 'https://example.com', host: host),
          ),
          throwsA(isA<ProxyStartException>()),
          reason: host,
        );
        expect(proxy.isRunning, isFalse);
      }
    });

    /// localhost で起動し、localhost の Host を受け付けること
    realTest('starts on localhost', () async {
      final port = await startProxy(host: 'LOCALHOST');
      expect(proxy.isRunning, isTrue);

      // localhost が IPv4 と IPv6 のどちらで待ち受けるかは環境による
      _RawResponse? response;
      for (final address in ['127.0.0.1', '::1']) {
        try {
          response = await _rawRequest(
            port,
            target: '/page',
            host: 'localhost:$port',
            address: address,
            accessToken: proxy.accessToken,
          );
          break;
        } on SocketException {
          continue;
        }
      }
      expect(response?.statusCode, HttpStatus.ok);
    });

    /// 127.0.0.0/8 の他のアドレスで起動し、そのアドレスの Host を受け付けること
    realTest('starts on another 127.0.0.0/8 address', () async {
      if (!await _canBind('127.0.0.2')) {
        markTestSkipped('127.0.0.2 で待ち受けられない環境');
        return;
      }
      final port = await startProxy(host: '127.0.0.2');

      final own = await _rawRequest(
        port,
        target: '/page',
        host: '127.0.0.2:$port',
        address: '127.0.0.2',
        accessToken: proxy.accessToken,
      );
      final other = await _rawRequest(
        port,
        target: '/page',
        host: '127.0.0.3:$port',
        address: '127.0.0.2',
        accessToken: proxy.accessToken,
      );

      expect(own.statusCode, HttpStatus.ok);
      expect(other.statusCode, HttpStatus.forbidden);
    });

    /// IPv6 の loopback で起動し、`[::1]` の Host を受け付けること
    realTest('starts on the IPv6 loopback', () async {
      if (!await _canBind('::1')) {
        markTestSkipped('IPv6 の loopback で待ち受けられない環境');
        return;
      }
      final port = await startProxy(host: '::1');

      final response = await _rawRequest(
        port,
        target: '/page',
        host: '[::1]:$port',
        address: '::1',
        accessToken: proxy.accessToken,
      );

      expect(response.statusCode, HttpStatus.ok);
    });
  });

  group('パスの検証（doc/specs.ja.md 【2】パス検証）', () {
    /// 符号化で隠した dot セグメントを 400 で拒否し、イベントで知らせること
    realTest('rejects dot segments hidden behind encoding', () async {
      final port = await startProxy();

      for (final path in [
        '/a/..%2Fb',
        '/a/%2E%2E%2Fb',
        '/a/%5C..',
        '/x/%2E%2E%5Cy',
        '/a/..;/b',
      ]) {
        final response = await _rawRequest(
          port,
          target: '$path?token=secret',
          host: '127.0.0.1:$port',
          accessToken: proxy.accessToken,
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: path);
        expect(response.headers['cache-control'], 'no-store');
      }

      expect(upstream!.receivedPaths, isEmpty);
      final pathEvents = events
          .where((event) =>
              event.type == ProxyEventType.errorOccurred &&
              event.data['phase'] == 'requestPath')
          .toList();
      expect(pathEvents, hasLength(5));
      expect(pathEvents.first.data['reason'], 'dotSegment');
      expect(pathEvents.first.data['method'], 'GET');
      // クエリはイベントに載せない
      expect(pathEvents.first.url, isNot(contains('secret')));
    });

    /// 秘密値を持たない要求は、パスを検査する前に 403 で断り、イベントを
    /// 出さないこと（秘密値を持つ要求は 400 とイベント）
    realTest('refuses requests without the token before checking the path',
        () async {
      final port = await startProxy();

      final withoutToken = await _rawRequest(
        port,
        target: '/a/..%2Fb',
        host: '127.0.0.1:$port',
      );
      expect(withoutToken.statusCode, HttpStatus.forbidden);
      expect(
        events.where((event) => event.data['phase'] == 'requestPath'),
        isEmpty,
      );

      final withToken = await _rawRequest(
        port,
        target: '/a/..%2Fb',
        host: '127.0.0.1:$port',
        accessToken: proxy.accessToken,
      );
      expect(withToken.statusCode, HttpStatus.badRequest);
      expect(
        events.where((event) => event.data['phase'] == 'requestPath'),
        hasLength(1),
      );
      expect(upstream!.receivedPaths, isEmpty);
    });

    /// `/` で区切った dot セグメントは dart:io が先に解決し、上流へ `..` を渡さないこと
    realTest('resolves plain dot segments before forwarding', () async {
      final port = await startProxy();

      final response = await _rawRequest(
        port,
        target: '/a/%2E%2E/x',
        host: '127.0.0.1:$port',
        accessToken: proxy.accessToken,
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(upstream!.receivedPaths, ['/x']);
    });

    /// 不正な `%` は dart:io が `%25` に符号化し直し、そのまま転送すること
    realTest('forwards a stray percent sign re-encoded by dart:io', () async {
      final port = await startProxy();

      final response = await _rawRequest(
        port,
        target: '/a/%zz',
        host: '127.0.0.1:$port',
        accessToken: proxy.accessToken,
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(upstream!.receivedPaths, ['/a/%25zz']);
    });

    /// dot セグメントを伴わない符号化した区切りは転送すること
    realTest('forwards an encoded slash without dot segments', () async {
      final port = await startProxy();

      final response = await _rawRequest(
        port,
        target: '/a%2Fb',
        host: '127.0.0.1:$port',
        accessToken: proxy.accessToken,
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(upstream!.receivedPaths, ['/a%2Fb']);
    });

    /// 不正な UTF-8 を含むパスは、shelf がパイプラインより前に 400 にすること
    realTest('leaves invalid UTF-8 paths to shelf', () async {
      final port = await startProxy();

      final response = await _rawRequest(
        port,
        target: '/files/%82%A0.txt',
        host: '127.0.0.1:$port',
        accessToken: proxy.accessToken,
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(upstream!.receivedPaths, isEmpty);
      // proxy のパス検証ではないため、requestPath のイベントは出ない
      expect(
        events.where((event) => event.data['phase'] == 'requestPath'),
        isEmpty,
      );
    });
  });

  group('設定のパスパターンの正規化（doc/specs.ja.md 【1】パス記法）', () {
    /// パスパラメータ、末尾の `/`、`%6C` を付けてもログインのパスに一致すること
    realTest('matches authResumePaths through equivalent spellings', () async {
      await withRealHttpClient(() async {
        final resolvedPaths = <String>[];
        final port = await startProxy(
          authResumePaths: const ['/api/login'],
          queueOwnerResolver: (context) {
            resolvedPaths.add(context.path);
            return 'user-a';
          },
        );

        for (final path in [
          '/api/login;jsessionid=ABC',
          '/api/login/',
          '/api/%6Cogin',
          '/api//login',
        ]) {
          final response = await _rawRequest(
            port,
            target: path,
            host: '127.0.0.1:$port',
            method: 'POST',
            accessToken: proxy.accessToken,
            extraHeaders: const {'Content-Length': '0'},
          );
          expect(response.statusCode, HttpStatus.ok, reason: path);
        }

        expect(resolvedPaths, hasLength(4));
      });
    });

    /// パスパラメータ、末尾の `/`、`%6C` を付けてもキューへ入れない規則に一致すること
    realTest('matches queueExcludePaths through equivalent spellings',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startServer();
        upstream!.statusCode = HttpStatus.internalServerError;
        final port = await startProxy(
          queueExcludePaths: const [
            QueueExcludeRule(path: '/api/registers/auth.json'),
          ],
        );

        for (final path in [
          '/api/registers/auth.json;jsessionid=ABC',
          '/api/registers/auth.json/',
          '/api/registers/%61uth.json',
        ]) {
          final response = await _request(
            Uri.parse('http://127.0.0.1:$port$path'),
            method: 'POST',
          );
          // 除外規則に一致した 5xx は保存せず、上流の応答をそのまま返す
          expect(response.statusCode, HttpStatus.internalServerError);
          expect(response.headers.value('x-offline-queued'), isNull,
              reason: path);
        }
        expect(await proxy.getQueuedRequests(), isEmpty);

        // 前提: 一致しないパスは従来どおり保存する
        final other = await _request(
          Uri.parse('http://127.0.0.1:$port/api/registers/other.json'),
          method: 'POST',
        );
        expect(other.headers.value('x-offline-queued'), '1');
      });
    });
  });

  group('要求元を名乗るヘッダ（doc/specs.ja.md 【14】転送しないヘッダ）', () {
    /// 転送で上流へ渡さないこと
    realTest('drops forwarding headers when forwarding', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();

        await _request(
          Uri.parse('http://127.0.0.1:$port/page'),
          headers: {..._acceptedForwardingHeaders, 'X-App': '1'},
        );

        final headers = upstream!.received.single.headers;
        expect(headers['x-app'], '1');
        for (final name in _forwardingHeaders.keys) {
          expect(headers.keys, isNot(contains(name.toLowerCase())),
              reason: name);
        }
      });
    });

    /// 別 origin への中継で渡さないこと
    realTest('drops forwarding headers when relaying', () async {
      await withRealHttpClient(() async {
        cdn = await _startServer();
        final cdnOrigin = cdn!.originFor('localhost');
        final port = await startProxy(mirroredOrigins: [cdnOrigin]);

        final response = await _request(
          Uri.parse(
            'http://127.0.0.1:$port'
            '/__offline_web_proxy/ext/http/localhost:${cdn!.port}/lib/app.js',
          ),
          headers: _acceptedForwardingHeaders,
        );

        expect(response.statusCode, HttpStatus.ok);
        final headers = cdn!.received.single.headers;
        for (final name in _forwardingHeaders.keys) {
          expect(headers.keys, isNot(contains(name.toLowerCase())),
              reason: name);
        }
      });
    });

    /// キューへ保存せず、再送でも渡さないこと
    realTest('drops forwarding headers when queueing and replaying', () async {
      await withRealHttpClient(() async {
        upstream = await _startServer();
        upstream!.statusCode = HttpStatus.internalServerError;
        final port = await startProxy();

        await _request(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          method: 'POST',
          headers: _acceptedForwardingHeaders,
        );

        // 前提: 1 件がキューに保存されている
        expect(await proxy.getQueuedRequests(), hasLength(1));
        final data = Hive.box(_queueBoxName).values.single as Map;
        final storedNames = (data['headers'] as Map)
            .keys
            .map((name) => name.toString().toLowerCase());
        for (final name in _forwardingHeaders.keys) {
          expect(storedNames, isNot(contains(name.toLowerCase())),
              reason: name);
        }

        upstream!.statusCode = HttpStatus.ok;
        final drained = await _waitUntil(
            () async => (await proxy.getQueuedRequests()).isEmpty);
        expect(drained, isTrue, reason: 'キューが時間内に空になりませんでした');
        for (final entry in upstream!.received) {
          for (final name in _forwardingHeaders.keys) {
            expect(entry.headers.keys, isNot(contains(name.toLowerCase())),
                reason: name);
          }
        }
      });
    }, timeout: const Timeout(Duration(minutes: 1)));

    /// 0.25.0 形式の保存データに含まれていても、再送で渡さないこと
    realTest('drops forwarding headers of 0.25.0 queue data when replaying',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startServer();

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
            'x-app': '1',
            for (final entry in _forwardingHeaders.entries)
              entry.key.toLowerCase(): entry.value,
          },
          'body': utf8.encode('{"total":1}'),
          'queuedAt': queuedAt,
          'acceptedAt': queuedAt,
          'retryCount': 0,
          'nextRetryAt': queuedAt,
        });
        await box.close();

        await startProxy();

        final drained = await _waitUntil(
            () async => (await proxy.getQueuedRequests()).isEmpty);
        expect(drained, isTrue, reason: 'キューが時間内に空になりませんでした');
        final headers = upstream!.received.single.headers;
        expect(headers['x-app'], '1');
        for (final name in _forwardingHeaders.keys) {
          expect(headers.keys, isNot(contains(name.toLowerCase())),
              reason: name);
        }
      });
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
