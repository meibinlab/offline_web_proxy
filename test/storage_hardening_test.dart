// 保存データの強化（0.26.0、doc/specs.ja.md 【1】【5】【6】）のテストです。
//
// WebStorage の写しの暗号化と受付条件、べき等性キーの Box のキーを確かめます。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';

import 'support/access_token_http.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = <String, List<String>>{};

/// WebStorage の写しを暗号化して保存する Box 名。
const String _secureWebStorageBoxName = 'proxy_web_storage_secure';

/// 0.25.0 までの平文の WebStorage の Box 名。
const String _legacyWebStorageBoxName = 'proxy_web_storage';

/// 送信済みのべき等性キーを記録する Box 名。
const String _idempotencyBoxName = 'proxy_idempotency';

/// WebStorage の受け渡しのパス。
const String _bridgePath = '/__offline_web_proxy/web_storage/snapshot';

/// 写しに入れる目印。ファイルに平文で残らないことを確かめるために使う。
const String _marker = 'LOCAL-STORAGE-MARKER-0123456789';

/// 鍵を記憶領域に保持する、secure storage の代わり。
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

/// 受け取ったパスを記録し、常に 200 を返す上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        receivedPaths.add(request.uri.path);
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..write('ok');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 受け取った要求のパス。
  final List<String> receivedPaths = [];

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 応答のステータス、ヘッダ（小文字の名前）、本文。
typedef _HttpResult = ({
  int statusCode,
  Map<String, String> headers,
  String body,
});

/// 実 HttpClient で要求を送る。
///
/// [method] メソッド。
/// [uri] 要求先。
/// [headers] 付与するヘッダ。
/// [body] 本文。`null` の場合は送らない。
///
/// Returns: 応答のステータス、ヘッダ、本文。
Future<_HttpResult> _send(
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  String? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      responseHeaders[name.toLowerCase()] = values.join(', ');
    });
    final text = await utf8.decoder.bind(response).join();
    return (
      statusCode: response.statusCode,
      headers: responseHeaders,
      body: text,
    );
  } finally {
    client.close(force: true);
  }
}

/// [haystack] の中に [needle] と同じ並びのバイト列があるかを返す。
///
/// [haystack] 探す対象のバイト列。
/// [needle] 探すバイト列。
///
/// Returns: 含まれる場合は `true`。
bool _containsBytes(List<int> haystack, List<int> needle) {
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var matched = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return true;
    }
  }
  return false;
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

/// [check] が真を返すまで待機する。
///
/// [check] 判定する関数。
/// [timeout] 待つ上限。超えた場合は呼び出し側のアサーションに委ねます。
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

  late _FakeKeyStorage keyStorage;
  late OfflineWebProxy proxy;
  _MockUpstream? upstream;

  /// テスト用の鍵の保存先を使う proxy を作る。
  ///
  /// [beforeLegacyWebStorageMoved] 平文の写しを移す直前に呼ぶ処理。
  /// [beforeLegacyWebStorageDeleted] 無効な設定で平文の Box を削除する直前に
  ///   呼ぶ処理。
  OfflineWebProxy createProxy({
    Future<void> Function()? beforeLegacyWebStorageMoved,
    Future<void> Function()? beforeLegacyWebStorageDeleted,
  }) =>
      trackAccessToken(OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(
          keyStorage: keyStorage,
          beforeLegacyWebStorageMoved: beforeLegacyWebStorageMoved,
          beforeLegacyWebStorageDeleted: beforeLegacyWebStorageDeleted,
        ),
      ));

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_storage_hardening')
        .path;
    keyStorage = _FakeKeyStorage();
    await Hive.close();
    proxy = createProxy();
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream?.close();
    upstream = null;
    await _emitConnectivity(['wifi']);
    await Hive.close();
  });

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  ///
  /// [body] テスト本体。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: AccessTokenHttpOverrides().createHttpClient,
    );
  }

  /// 上流を起動し（起動済みなら使い回し）、proxy を起動する。
  ///
  /// [enableWebStorage] WebStorage の受け渡しを有効にするかどうか。
  /// [corsAnyOrigin] 全 origin へ CORS ヘッダを付ける設定にするかどうか。
  ///
  /// Returns: proxy のポート。
  Future<int> startProxy({
    bool enableWebStorage = true,
    bool corsAnyOrigin = false,
  }) async {
    upstream ??= _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    return proxy.start(
      config: ProxyConfig(
        origin: upstream!.origin,
        enableWebStorageInheritance: enableWebStorage,
        addCorsHeaders: corsAnyOrigin,
        corsAllowedOrigins: corsAnyOrigin ? const ['*'] : const [],
      ),
    );
  }

  /// proxy を止め、次の起動に備えて作り直す。
  Future<void> restartProxy() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await Hive.close();
    proxy = createProxy();
  }

  /// Box のファイルを返す。
  ///
  /// [name] Box の名前。
  File boxFile(String name) =>
      File('$hiveTestDirectory${Platform.pathSeparator}$name.hive');

  /// 受け渡しの URI を返す。
  ///
  /// [port] proxy のポート。
  /// [host] 要求先のホスト名。
  Uri bridgeUri(int port, {String host = '127.0.0.1'}) =>
      Uri.parse('http://$host:$port$_bridgePath');

  /// proxy 自身の origin を返す。
  ///
  /// [port] proxy のポート。
  /// [host] origin のホスト名。
  String ownOrigin(int port, {String host = '127.0.0.1'}) =>
      'http://$host:$port';

  /// 目印を入れた写しを、proxy 自身の origin から保存する。
  ///
  /// [port] proxy のポート。
  ///
  /// Returns: 応答。
  Future<_HttpResult> postSnapshot(int port) => _send(
        'POST',
        bridgeUri(port),
        headers: {'origin': ownOrigin(port)},
        body: jsonEncode({
          'localStorage': {'token': _marker},
        }),
      );

  /// 0.25.0 までの平文の Box に、目印を入れた写しを書く。
  Future<void> writeLegacySnapshot() async {
    final box = await Hive.openBox(
      _legacyWebStorageBoxName,
      path: hiveTestDirectory,
    );
    await box.put('snapshot', {
      'localStorage': {'legacy': _marker},
    });
    await box.close();
  }

  group('WebStorage の写しの保存（doc/specs.ja.md 【1】保存データ）', () {
    /// 写しを暗号化した Box に保存し、ファイルに平文で残さないこと
    test('stores the snapshot in the encrypted box', () async {
      await withRealHttpClient(() async {
        var port = await startProxy();
        final saved = await postSnapshot(port);
        expect(saved.statusCode, equals(HttpStatus.ok));
        await restartProxy();

        expect(boxFile(_secureWebStorageBoxName).existsSync(), isTrue);
        expect(
          _containsBytes(
            boxFile(_secureWebStorageBoxName).readAsBytesSync(),
            utf8.encode(_marker),
          ),
          isFalse,
        );
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isFalse);

        // 再起動後も読み出せること
        port = await startProxy();
        final restored = await _send('GET', bridgeUri(port));
        expect(restored.statusCode, equals(HttpStatus.ok));
        expect(restored.body, contains(_marker));
      });
    });

    /// 有効な場合は、平文の Box から写しを移してファイルごと消すこと
    test('migrates the legacy plain box and deletes it', () async {
      await withRealHttpClient(() async {
        await Hive.initFlutter();
        await writeLegacySnapshot();
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isTrue);

        var port = await startProxy();
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isFalse);
        final restored = await _send('GET', bridgeUri(port));
        expect(restored.body, contains(_marker));
        await restartProxy();

        expect(
          _containsBytes(
            boxFile(_secureWebStorageBoxName).readAsBytesSync(),
            utf8.encode(_marker),
          ),
          isFalse,
        );
        port = await startProxy();
        expect((await _send('GET', bridgeUri(port))).body, contains(_marker));
      });
    });

    /// 移行が途中で失敗しても起動を止めず、平文の Box を残して次の起動で移すこと
    test('continues startup after a failed migration and retries it', () async {
      await withRealHttpClient(() async {
        await Hive.initFlutter();
        await writeLegacySnapshot();
        proxy = createProxy(
          beforeLegacyWebStorageMoved: () async =>
              throw const FileSystemException('injected failure'),
        );
        final events = <ProxyEvent>[];
        final subscription = proxy.events.listen(events.add);

        var port = await startProxy();
        await subscription.cancel();

        expect(proxy.isRunning, isTrue);
        final failures = events.where((event) =>
            event.type == ProxyEventType.errorOccurred &&
            event.data['phase'] == 'webStorageMigration');
        expect(failures, hasLength(1));
        expect(failures.single.data['error'], equals('FileSystemException'));
        // 平文の Box は閉じて残し、写しはまだ移っていないこと
        expect(Hive.isBoxOpen(_legacyWebStorageBoxName), isFalse);
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isTrue);
        expect(
          (await _send('GET', bridgeUri(port))).body,
          isNot(contains(_marker)),
        );

        // 次の起動で移すこと
        await restartProxy();
        port = await startProxy();
        expect((await _send('GET', bridgeUri(port))).body, contains(_marker));
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isFalse);
      });
    });

    /// 暗号化 Box を作り直した場合も、平文の Box から写しを移すこと
    test('migrates the legacy box after rebuilding the encrypted box',
        () async {
      await withRealHttpClient(() async {
        // 鍵を先に用意し、保存しない形の値を持つ暗号化 Box を作る
        final key = List<int>.generate(32, (index) => index * 7 & 0xff);
        keyStorage.values['offline_web_proxy.cookie_box_encryption_key'] =
            base64Encode(key);
        await Hive.initFlutter();
        final broken = await Hive.openBox(
          _secureWebStorageBoxName,
          path: hiveTestDirectory,
          encryptionCipher: HiveAesCipher(key),
        );
        await broken.put('snapshot', 'not a map');
        await broken.close();
        await writeLegacySnapshot();
        final events = <ProxyEvent>[];
        final subscription = proxy.events.listen(events.add);

        final port = await startProxy();
        await subscription.cancel();

        expect(
          events.where((event) =>
              event.type == ProxyEventType.errorOccurred &&
              event.data['phase'] == 'webStorageRecovery'),
          hasLength(1),
        );
        expect((await _send('GET', bridgeUri(port))).body, contains(_marker));
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isFalse);
      });
    });

    /// 暗号化 Box に写しがあれば、平文の Box の古い写しで上書きしないこと
    test('keeps the encrypted snapshot over the legacy one', () async {
      await withRealHttpClient(() async {
        var port = await startProxy();
        await _send(
          'POST',
          bridgeUri(port),
          headers: {'origin': ownOrigin(port)},
          body: jsonEncode({
            'localStorage': {'current': 'newer'},
          }),
        );
        await restartProxy();
        await Hive.initFlutter();
        await writeLegacySnapshot();

        port = await startProxy();
        final restored = await _send('GET', bridgeUri(port));
        expect(restored.body, contains('newer'));
        expect(restored.body, isNot(contains(_marker)));
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isFalse);
      });
    });

    /// 無効な場合は Box を開かず、平文の Box をファイルごと消すこと
    test('deletes the legacy box without opening any box when disabled',
        () async {
      await withRealHttpClient(() async {
        await Hive.initFlutter();
        await writeLegacySnapshot();

        await startProxy(enableWebStorage: false);

        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isFalse);
        expect(Hive.isBoxOpen(_legacyWebStorageBoxName), isFalse);
        expect(Hive.isBoxOpen(_secureWebStorageBoxName), isFalse);
        expect(boxFile(_secureWebStorageBoxName).existsSync(), isFalse);
      });
    });

    /// 無効な設定で平文の Box を削除できなくても起動を止めず、次の起動で消すこと
    test('continues startup when deleting the legacy box fails', () async {
      await withRealHttpClient(() async {
        await Hive.initFlutter();
        await writeLegacySnapshot();
        proxy = createProxy(
          beforeLegacyWebStorageDeleted: () async =>
              throw const FileSystemException('injected failure'),
        );
        final events = <ProxyEvent>[];
        final subscription = proxy.events.listen(events.add);

        await startProxy(enableWebStorage: false);
        await subscription.cancel();

        expect(proxy.isRunning, isTrue);
        final failures = events.where((event) =>
            event.type == ProxyEventType.errorOccurred &&
            event.data['phase'] == 'webStorageMigration');
        expect(failures, hasLength(1));
        expect(failures.single.data['error'], equals('FileSystemException'));
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isTrue);

        // 次の起動で削除し直すこと
        await restartProxy();
        await startProxy(enableWebStorage: false);
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isFalse);
      });
    });

    /// clearWebStorageSnapshot() は、稼働中なら写しを消して圧縮すること
    test('clears the snapshot while running', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await postSnapshot(port);

        await proxy.clearWebStorageSnapshot();

        final restored = await _send('GET', bridgeUri(port));
        expect(restored.statusCode, equals(HttpStatus.ok));
        expect(jsonDecode(restored.body), isEmpty);
        // 圧縮して、消した記録のフレームを残さないこと
        await restartProxy();
        expect(boxFile(_secureWebStorageBoxName).lengthSync(), equals(0));
      });
    });

    /// clearWebStorageSnapshot() は、停止中なら新旧の Box をファイルごと消すこと
    test('deletes the boxes while stopped', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await postSnapshot(port);
        await restartProxy();
        await Hive.initFlutter();
        await writeLegacySnapshot();
        expect(boxFile(_secureWebStorageBoxName).existsSync(), isTrue);

        await proxy.clearWebStorageSnapshot();

        expect(boxFile(_secureWebStorageBoxName).existsSync(), isFalse);
        expect(boxFile(_legacyWebStorageBoxName).existsSync(), isFalse);
      });
    });

    /// 無効な設定で稼働中でも、前に保存した写しを消せること
    test('deletes the encrypted box while running with the bridge disabled',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await postSnapshot(port);
        await restartProxy();

        await startProxy(enableWebStorage: false);
        expect(boxFile(_secureWebStorageBoxName).existsSync(), isTrue);
        await proxy.clearWebStorageSnapshot();

        expect(boxFile(_secureWebStorageBoxName).existsSync(), isFalse);
      });
    });
  });

  group('WebStorage の受け渡しの受付条件（doc/specs.ja.md 【5】内部エンドポイント）', () {
    /// proxy 自身の origin（127.0.0.1 と localhost）からの要求を受け付けること
    test('accepts requests from the proxy own origin', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();

        final fromLoopback = await postSnapshot(port);
        final fromLocalhost = await _send(
          'POST',
          bridgeUri(port, host: 'localhost'),
          headers: {'origin': ownOrigin(port, host: 'localhost')},
          body: '{}',
        );
        final crossAlias = await _send(
          'POST',
          bridgeUri(port),
          headers: {'origin': ownOrigin(port, host: 'localhost')},
          body: '{"localStorage":{"k":"v"}}',
        );
        final getWithoutOrigin = await _send('GET', bridgeUri(port));
        final getSameOrigin = await _send(
          'GET',
          bridgeUri(port),
          headers: {
            'origin': ownOrigin(port),
            'sec-fetch-site': 'same-origin',
          },
        );
        final getNavigation = await _send(
          'GET',
          bridgeUri(port),
          headers: {'sec-fetch-site': 'none'},
        );

        for (final response in [
          fromLoopback,
          fromLocalhost,
          crossAlias,
          getWithoutOrigin,
          getSameOrigin,
          getNavigation,
        ]) {
          expect(response.statusCode, equals(HttpStatus.ok));
          expect(response.headers['cache-control'], equals('no-store'));
        }
        expect(getSameOrigin.body, contains('"k":"v"'));
      });
    });

    /// 別の origin（上流の origin を含む）からの要求を拒否すること
    test('rejects requests from other origins', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await postSnapshot(port);

        final origins = [
          upstream!.origin,
          'https://example.com',
          'http://127.0.0.1:${port + 1}',
          'https://127.0.0.1:$port',
          'null',
        ];
        for (final origin in origins) {
          final post = await _send(
            'POST',
            bridgeUri(port),
            headers: {'origin': origin},
            body: '{"localStorage":{"k":"overwritten"}}',
          );
          final get = await _send(
            'GET',
            bridgeUri(port),
            headers: {'origin': origin},
          );
          expect(post.statusCode, equals(HttpStatus.forbidden), reason: origin);
          expect(get.statusCode, equals(HttpStatus.forbidden), reason: origin);
          expect(get.body, isNot(contains(_marker)), reason: origin);
          expect(get.headers['cache-control'], equals('no-store'));
        }

        // 写しは書き換えられていないこと
        final restored = await _send('GET', bridgeUri(port));
        expect(restored.body, contains(_marker));
      });
    });

    /// POST に Origin が無い場合と、別のサイトからの GET を拒否すること
    test('rejects POST without Origin and cross-site GET', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await postSnapshot(port);

        final postWithoutOrigin = await _send(
          'POST',
          bridgeUri(port),
          body: '{"localStorage":{"k":"overwritten"}}',
        );
        expect(postWithoutOrigin.statusCode, equals(HttpStatus.forbidden));

        for (final site in ['cross-site', 'same-site']) {
          final get = await _send(
            'GET',
            bridgeUri(port),
            headers: {'sec-fetch-site': site},
          );
          expect(get.statusCode, equals(HttpStatus.forbidden), reason: site);
          expect(get.body, isNot(contains(_marker)), reason: site);
        }

        // Origin が一致しても、別のサイトからの POST は拒否すること
        final crossSitePost = await _send(
          'POST',
          bridgeUri(port),
          headers: {
            'origin': ownOrigin(port),
            'sec-fetch-site': 'cross-site',
          },
          body: '{"localStorage":{"k":"overwritten"}}',
        );
        expect(crossSitePost.statusCode, equals(HttpStatus.forbidden));

        expect((await _send('GET', bridgeUri(port))).body, contains(_marker));
      });
    });

    /// GET と POST 以外のメソッドは 405 にすること
    test('answers 405 to other methods', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();

        for (final method in ['PUT', 'DELETE', 'PATCH', 'OPTIONS']) {
          final response = await _send(
            method,
            bridgeUri(port),
            headers: {'origin': ownOrigin(port)},
          );
          expect(
            response.statusCode,
            equals(HttpStatus.methodNotAllowed),
            reason: method,
          );
          expect(response.headers['allow'], equals('GET, POST'));
          expect(response.headers['cache-control'], equals('no-store'));
        }
        expect(upstream!.receivedPaths, isEmpty);
      });
    });

    /// CORS ヘッダを付けず、統計にも数えないこと
    test('is an internal endpoint without CORS headers or statistics',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy(corsAnyOrigin: true);
        final before = (await proxy.getStats()).totalRequests;

        final post = await postSnapshot(port);
        final get = await _send(
          'GET',
          bridgeUri(port),
          headers: {'origin': ownOrigin(port)},
        );
        final rejected = await _send(
          'GET',
          bridgeUri(port),
          headers: {'origin': 'https://example.com'},
        );

        for (final response in [post, get, rejected]) {
          expect(
            response.headers.containsKey('access-control-allow-origin'),
            isFalse,
          );
        }
        expect((await proxy.getStats()).totalRequests, equals(before));
      });
    });

    /// 無効な場合も上流へ転送せず、404 を返すこと
    test('answers 404 without forwarding when disabled', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(enableWebStorage: false);

        final get = await _send('GET', bridgeUri(port));
        final post = await postSnapshot(port);
        final base = await _send(
          'GET',
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/web_storage'),
        );

        for (final response in [get, post, base]) {
          expect(response.statusCode, equals(HttpStatus.notFound));
          expect(response.headers['cache-control'], equals('no-store'));
        }
        expect(upstream!.receivedPaths, isEmpty);
      });
    });
  });

  group('べき等性キーの Box のキー（doc/specs.ja.md 【6】Idempotency）', () {
    /// 新しい形式（h1: と HMAC）で記録し、画面が送ったキーを Box に残さないこと
    test('records the key as an HMAC without the raw key', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(enableWebStorage: false);
        const key = 'sale-raw-key-0001';
        // 送信済みの記録は、キューからの再送が届いたときに作る
        await _emitConnectivity(['none']);
        final response = await _send(
          'POST',
          Uri.parse('http://127.0.0.1:$port/api/records'),
          headers: {'Idempotency-Key': key},
          body: '{}',
        );
        expect(response.statusCode, equals(HttpStatus.accepted));
        await _emitConnectivity(['wifi']);
        await _waitUntil(() async =>
            (await proxy.getRequestStatuses([key])).single.state ==
            RequestState.delivered);

        final box = Hive.box(_idempotencyBoxName);
        expect(box.keys, isNotEmpty);
        expect(
          box.keys,
          everyElement(
            isA<String>().having((k) => k, 'key', startsWith('h1:')),
          ),
        );
        expect(box.keys, isNot(contains(key)));
        expect(
          (await proxy.getRequestStatuses([key])).single.state,
          equals(RequestState.delivered),
        );

        // 再起動しても同じ記録を指すこと
        await restartProxy();
        expect(
          _containsBytes(
            boxFile(_idempotencyBoxName).readAsBytesSync(),
            utf8.encode(key),
          ),
          isFalse,
        );
        port = await startProxy(enableWebStorage: false);
        expect(
          (await proxy.getRequestStatuses([key])).single.state,
          equals(RequestState.delivered),
        );
      });
    });

    /// 0.25.0 以前の形式の記録も、0.25.0 の規則で照会できること
    test('finds records written in the 0.25.0 format', () async {
      await withRealHttpClient(() async {
        await startProxy(enableWebStorage: false);

        const shortKey = 'legacy-short-key';
        // 0.25.0 は `sha256:` で始まる 255 バイト以下のキーも生のまま記録した
        final prefixedKey = 'sha256:${'a' * 64}';
        final longKey = 'k' * 300;
        final now = DateTime.now().toIso8601String();
        final box = Hive.box(_idempotencyBoxName);
        await box.put(shortKey, now);
        await box.put(prefixedKey, now);
        await box.put('sha256:${sha256.convert(utf8.encode(longKey))}', now);

        final statuses = await proxy.getRequestStatuses([
          shortKey,
          prefixedKey,
          longKey,
          'not-recorded',
        ]);
        expect(statuses.map((status) => status.state), [
          RequestState.delivered,
          RequestState.delivered,
          RequestState.delivered,
          RequestState.unknown,
        ]);
      });
    });

    /// 0.25.0 以前の形式の記録で、キューの要求を送り直さないこと
    test('does not resend a request recorded in the 0.25.0 format', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(enableWebStorage: false);
        const key = 'legacy-queued-key';
        await _emitConnectivity(['none']);
        final queued = await _send(
          'POST',
          Uri.parse('http://127.0.0.1:$port/api/records'),
          headers: {'Idempotency-Key': key},
          body: '{}',
        );
        expect(queued.statusCode, equals(HttpStatus.accepted));
        // 0.25.0 が送信済みとして記録した形を再現する
        await Hive.box(_idempotencyBoxName)
            .put(key, DateTime.now().toIso8601String());

        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);

        expect(await proxy.getQueuedRequests(), isEmpty);
        // 送信済みの要求は上流へ送り直さないこと
        expect(upstream!.receivedPaths, isNot(contains('/api/records')));
      });
    });
  });
}
