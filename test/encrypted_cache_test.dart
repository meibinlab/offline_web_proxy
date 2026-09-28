import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = <String, List<String>>{};

/// secure storage に置く暗号化鍵の名前。
const String _keyName = 'offline_web_proxy.cookie_box_encryption_key';

/// 平文の応答キャッシュの Box 名。
const String _plainBoxName = 'proxy_cache';

/// 暗号化した応答キャッシュの Box 名。
const String _encryptedBoxName = 'proxy_cache_secure';

/// ファイルに平文で残っていないかを探す、応答本文の目印。
const String _marker = 'EMPLOYEE-NAME-YAMADA-TARO';

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// 目印を含む JSON を、保存してよい応答として返す上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..headers.set('cache-control', 'max-age=3600')
          ..write('{"name":"$_marker","path":"${request.uri.path}"}');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
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

/// 実 HttpClient で GET を実行する。
///
/// [uri] は要求先です。戻り値はステータス、本文、`X-Offline-Source` の値です。
Future<({int statusCode, String body, String? offlineSource})> _get(
  Uri uri,
) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      body: body,
      offlineSource: response.headers.value('x-offline-source'),
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
        .createTempSync('offline_web_proxy_encrypted_cache')
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
    await _emitConnectivity(['wifi']);
  });

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: _RealHttpOverrides().createHttpClient,
    );
  }

  /// 上流を起動し（起動済みなら使い回し）、proxy を起動する。
  ///
  /// [encrypt] は応答キャッシュを暗号化するかどうかです。
  /// 戻り値は proxy のポートです。
  /// [cacheMaxSize] は応答キャッシュの上限です（`0` で上限なし）。
  Future<int> startProxy({required bool encrypt, int cacheMaxSize = 0}) async {
    upstream ??= _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    return proxy.start(
      config: ProxyConfig(
        origin: upstream!.origin,
        encryptResponseCache: encrypt,
        cacheMaxSize: cacheMaxSize,
      ),
    );
  }

  /// 平文の応答キャッシュの Box のファイル（.hive・.hivec・.lock）が
  /// 1 つでも残っているかを返す。
  bool plainFilesExist() => ['hive', 'hivec', 'lock'].any((extension) => File(
          '$hiveTestDirectory${Platform.pathSeparator}$_plainBoxName.$extension')
      .existsSync());

  /// proxy を止め、次の起動に備えて作り直す。
  Future<void> restartProxy() async {
    await proxy.stop();
    await Hive.close();
    proxy = OfflineWebProxy();
  }

  /// Box のファイルを返す。
  ///
  /// [name] Box の名前。
  File boxFile(String name) =>
      File('$hiveTestDirectory${Platform.pathSeparator}$name.hive');

  /// オフラインのときに、キャッシュから返せるかどうかを返す。
  ///
  /// [port] は proxy のポート、[path] は要求するパスです。
  Future<bool> servedFromCache(int port, String path) async {
    await _emitConnectivity(['none']);
    final response = await _get(Uri.parse('http://127.0.0.1:$port$path'));
    await _emitConnectivity(['wifi']);
    return response.statusCode == HttpStatus.ok &&
        response.offlineSource == 'cache' &&
        response.body.contains(_marker);
  }

  group('応答キャッシュの暗号化（doc/specs.ja.md 【16】キャッシュ容量・TTL）', () {
    /// 既定では従来どおり平文の Box に保存すること
    test('keeps the plain box by default', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(encrypt: false);

        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();

        expect(boxFile(_plainBoxName).existsSync(), isTrue);
        expect(boxFile(_encryptedBoxName).existsSync(), isFalse);
        expect(
          _containsBytes(
            boxFile(_plainBoxName).readAsBytesSync(),
            utf8.encode(_marker),
          ),
          isTrue,
        );
      });
    });

    /// 有効にすると、本文を平文でファイルに残さず、再起動後も使えること
    test('stores responses encrypted and serves them after a restart',
        () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: true);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();

        expect(boxFile(_plainBoxName).existsSync(), isFalse);
        final bytes = boxFile(_encryptedBoxName).readAsBytesSync();
        expect(bytes, isNotEmpty);
        expect(_containsBytes(bytes, utf8.encode(_marker)), isFalse);

        port = await startProxy(encrypt: true);
        expect(await servedFromCache(port, '/api/employees'), isTrue);
      });
    });

    /// 有効にしたとき、平文のキャッシュを移してから平文のファイルを消すこと
    test('moves an existing plain cache into the encrypted box', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: false);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();
        // 前提: 平文で保存されていること
        expect(boxFile(_plainBoxName).existsSync(), isTrue);

        port = await startProxy(encrypt: true);

        expect(plainFilesExist(), isFalse);
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        expect(await servedFromCache(port, '/api/employees'), isTrue);

        // 移した後の暗号化ファイルにも、本文が平文で入っていないこと
        await restartProxy();
        expect(
          _containsBytes(
            boxFile(_encryptedBoxName).readAsBytesSync(),
            utf8.encode(_marker),
          ),
          isFalse,
        );
      });
    });

    /// 移せなかった記録は捨てて残りを移し、平文のファイルは必ず消すこと
    test('drops an entry it cannot move and still deletes the plain file',
        () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: false);
        await _get(Uri.parse('http://127.0.0.1:$port/api/a'));
        await _get(Uri.parse('http://127.0.0.1:$port/api/b'));
        await restartProxy();

        var failed = false;
        proxy = OfflineWebProxy.withStorageTestHooks(
          ProxyStorageTestHooks(
            beforePlainCacheEntryMoved: (key) async {
              // 最初の 1 件だけ移せなかったことにする
              if (!failed) {
                failed = true;
                throw StateError('cannot move $key');
              }
            },
          ),
        );
        final errors = <ProxyEvent>[];
        final subscription = proxy.events
            .where((event) => event.type == ProxyEventType.errorOccurred)
            .listen(errors.add);

        port = await startProxy(encrypt: true);
        await Future<void>.delayed(Duration.zero);

        expect(plainFilesExist(), isFalse);
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        final error = errors.single;
        expect(error.data['phase'], equals('cacheEncryptionMigration'));
        expect(error.data['failedCount'], equals(1));
        await subscription.cancel();
      });
    });

    /// 移した後も、キャッシュの上限を合計の数え直しのうえで効かせること
    test('applies cacheMaxSize to entries moved into the encrypted box',
        () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: false);
        for (final path in ['/api/a', '/api/b', '/api/c']) {
          await _get(Uri.parse('http://127.0.0.1:$port$path'));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await restartProxy();

        // 1 件の本文は 60 バイトほどのため、3 件で上限を超える
        port = await startProxy(encrypt: true, cacheMaxSize: 150);
        final evicted = <ProxyEvent>[];
        final subscription = proxy.events
            .where((event) => event.type == ProxyEventType.cacheEvicted)
            .listen(evicted.add);
        await _get(Uri.parse('http://127.0.0.1:$port/api/d'));

        expect(evicted, isNotEmpty);
        expect(
          (await proxy.getCacheStats()).totalSize,
          lessThanOrEqualTo(150),
        );
        await subscription.cancel();
      });
    });

    /// 無効に戻したとき、暗号化した Box を平文へ戻さずに消すこと
    test('deletes the encrypted box when switched off', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: true);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();
        // 前提: 暗号化して保存されていること
        expect(boxFile(_encryptedBoxName).existsSync(), isTrue);

        port = await startProxy(encrypt: false);

        expect(boxFile(_encryptedBoxName).existsSync(), isFalse);
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(await servedFromCache(port, '/api/employees'), isFalse);
      });
    });

    /// 鍵が変わっても起動は失敗させず、キャッシュを空にして続けること
    test('empties the cache when the key no longer matches', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: true);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();

        // 別の鍵に置き換える（業務データの Box は空のため起動は続く）
        await const FlutterSecureStorage().write(
          key: _keyName,
          value: base64Encode(List<int>.generate(32, (index) => 255 - index)),
        );

        port = await startProxy(encrypt: true);

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(await servedFromCache(port, '/api/employees'), isFalse);
      });
    });

    /// 鍵を作り直した場合も、古い鍵の Box を消して続けること
    test('deletes the encrypted box when the key is regenerated', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: true);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();

        await const FlutterSecureStorage().delete(key: _keyName);
        // 前提: 古い鍵の Box が残っていること
        expect(boxFile(_encryptedBoxName).existsSync(), isTrue);

        // 起動前の Cookie API は段階 1（鍵）だけを実行する。Hive の切り詰めでは
        // なく、鍵を作り直した時点で削除していることを確かめる
        await proxy.getCookies();
        expect(boxFile(_encryptedBoxName).existsSync(), isFalse);

        port = await startProxy(encrypt: true);

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(await servedFromCache(port, '/api/employees'), isFalse);
      });
    });

    /// 復旧 API が鍵を削除するときは、暗号化したキャッシュも削除すること
    test('deletes the encrypted box when recovery deletes the key', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(encrypt: true);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        // キューに中身を作る（鍵を失うと起動に失敗する状態）
        await _emitConnectivity(['none']);
        final client = HttpClient();
        try {
          final request = await client
              .postUrl(Uri.parse('http://127.0.0.1:$port/api/records'));
          request.write('{"a":1}');
          await (await request.close()).drain<void>();
        } finally {
          client.close(force: true);
        }
        // オンラインへ戻すとキューが送られて空になるため、戻さずに止める
        // （tearDown が戻す）
        expect(await proxy.getQueuedRequests(), isNotEmpty);
        await restartProxy();

        await const FlutterSecureStorage().write(key: _keyName, value: 'x');
        await expectLater(
          startProxy(encrypt: true),
          throwsA(isA<StorageIntegrityException>()),
        );

        final result = await proxy.recoverEncryptedStorage();

        expect(result.keyDeleted, isTrue);
        expect(boxFile(_encryptedBoxName).existsSync(), isFalse);
      });
    });
  });
}
