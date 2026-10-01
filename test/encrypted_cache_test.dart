import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

/// 平文の応答キャッシュの、メタデータと本文の Box 名。
const ({String index, String body}) _plainPair =
    (index: 'proxy_cache_index', body: 'proxy_cache_body');

/// 暗号化した応答キャッシュの、メタデータと本文の Box 名。
const ({String index, String body}) _encryptedPair =
    (index: 'proxy_cache_index_secure', body: 'proxy_cache_body_secure');

/// 0.21.0 以前が平文で保存した応答キャッシュの Box 名。
const String _legacyPlainBoxName = 'proxy_cache';

/// 0.21.0 が暗号化して保存した応答キャッシュの Box 名。
const String _legacyEncryptedBoxName = 'proxy_cache_secure';

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
  /// [encrypt] は応答キャッシュを暗号化するかどうかです。`null` の場合は
  /// 指定せず、既定値を使います。
  /// [cacheMaxSize] は応答キャッシュの上限です（`0` で上限なし）。
  ///
  /// 応答キャッシュを開き終わるまで待ってから返す。
  ///
  /// Returns: proxy のポート。
  Future<int> startProxy({bool? encrypt, int cacheMaxSize = 0}) async {
    upstream ??= _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    final port = await proxy.start(
      config: encrypt == null
          ? ProxyConfig(
              origin: upstream!.origin,
              cacheMaxSize: cacheMaxSize,
            )
          : ProxyConfig(
              origin: upstream!.origin,
              encryptResponseCache: encrypt,
              cacheMaxSize: cacheMaxSize,
            ),
    );
    // 応答キャッシュは start() の後に裏で開くため、開き終わるのを待つ
    await proxy.cacheReady;
    return port;
  }

  /// Box のファイル（.hive・.hivec・.lock）が 1 つでも残っているかを返す。
  ///
  /// [name] Box の名前。
  bool filesExist(String name) => ['hive', 'hivec', 'lock'].any((extension) =>
      File('$hiveTestDirectory${Platform.pathSeparator}$name.$extension')
          .existsSync());

  /// Box の組（メタデータと本文）のファイルが 1 つでも残っているかを返す。
  ///
  /// [pair] Box の組。
  bool pairFilesExist(({String index, String body}) pair) =>
      filesExist(pair.index) || filesExist(pair.body);

  /// proxy を止め、次の起動に備えて作り直す。
  Future<void> restartProxy() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await Hive.close();
    proxy = OfflineWebProxy();
  }

  /// Box のファイルを返す。
  ///
  /// [name] Box の名前。
  File boxFile(String name) =>
      File('$hiveTestDirectory${Platform.pathSeparator}$name.hive');

  /// Box のファイルに、応答本文の目印が平文で入っているかを返す。
  ///
  /// [name] Box の名前。
  bool containsMarker(String name) => _containsBytes(
        boxFile(name).readAsBytesSync(),
        utf8.encode(_marker),
      );

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

  /// 0.21.0 以前の形式（1 件の値にメタデータと本文をまとめた Box）で、
  /// proxy が保存するのと同じ記録を書く。
  ///
  /// 記録のキーは、proxy と同じく正規化した URL の SHA-256 を使う。そのため、
  /// proxy を起動する前に上流を起動しておく。
  ///
  /// [name] Box の名前。
  /// [path] 記録する要求のパス。
  /// [key] 暗号化 Box の場合の鍵。
  Future<void> writeLegacyEntry(
    String name,
    String path, {
    List<int>? key,
  }) async {
    upstream ??= _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    final url = '${upstream!.origin}$path';
    final cacheKey = sha256.convert(utf8.encode(url)).toString();
    final now = DateTime.now();
    final body = '{"name":"$_marker","path":"$path"}';
    final box = await Hive.openBox(
      name,
      path: hiveTestDirectory,
      encryptionCipher: key == null ? null : HiveAesCipher(key),
    );
    await box.put(cacheKey, <String, Object?>{
      'statusCode': HttpStatus.ok,
      'headers': {
        'content-type': 'application/json',
        'cache-control': 'max-age=3600',
      },
      'body': Uint8List.fromList(utf8.encode(body)),
      'createdAt': now.toIso8601String(),
      'expiresAt': now.add(const Duration(hours: 1)).toIso8601String(),
      'contentType': 'application/json',
      'sizeBytes': body.length,
    });
    await box.close();
  }

  group('応答キャッシュの暗号化（doc/specs.ja.md 【16】キャッシュ容量・TTL）', () {
    /// 既定では暗号化した組に保存し、本文を平文でファイルに残さないこと
    test('encrypts the cache by default', () async {
      await withRealHttpClient(() async {
        var port = await startProxy();
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();

        expect(pairFilesExist(_plainPair), isFalse);
        expect(boxFile(_encryptedPair.body).readAsBytesSync(), isNotEmpty);
        expect(containsMarker(_encryptedPair.body), isFalse);
        expect(containsMarker(_encryptedPair.index), isFalse);

        port = await startProxy();
        expect(await servedFromCache(port, '/api/employees'), isTrue);
      });
    });

    /// 無効にすると平文の組に保存し、本文はメタデータの Box に入れないこと
    test('keeps the plain pair when disabled', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: false);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();

        expect(pairFilesExist(_encryptedPair), isFalse);
        expect(containsMarker(_plainPair.body), isTrue);
        // 走査で読むメタデータの Box には本文を置かない
        expect(containsMarker(_plainPair.index), isFalse);

        port = await startProxy(encrypt: false);
        expect(await servedFromCache(port, '/api/employees'), isTrue);
      });
    });

    /// 有効にしたとき、平文の組を移してから平文のファイルを消すこと
    test('moves an existing plain cache into the encrypted pair', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: false);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();
        // 前提: 平文で保存されていること
        expect(containsMarker(_plainPair.body), isTrue);

        port = await startProxy(encrypt: true);

        expect(pairFilesExist(_plainPair), isFalse);
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        expect(await servedFromCache(port, '/api/employees'), isTrue);

        // 移した後の暗号化ファイルにも、本文が平文で入っていないこと
        await restartProxy();
        expect(containsMarker(_encryptedPair.body), isFalse);
      });
    });

    /// 移せなかった記録は捨てて残りを移し、平文のファイルは必ず消すこと
    test('drops an entry it cannot move and still deletes the plain files',
        () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: false);
        await _get(Uri.parse('http://127.0.0.1:$port/api/a'));
        await _get(Uri.parse('http://127.0.0.1:$port/api/b'));
        await restartProxy();

        var failed = false;
        proxy = OfflineWebProxy.withStorageTestHooks(
          ProxyStorageTestHooks(
            beforeCacheEntryMoved: (key) async {
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

        expect(pairFilesExist(_plainPair), isFalse);
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        final error = errors.single;
        expect(error.data['phase'], equals('cacheEncryptionMigration'));
        expect(error.data['failedCount'], equals(1));
        await subscription.cancel();
      });
    });

    /// 移した後も、キャッシュの上限を合計の数え直しのうえで効かせること
    test('applies cacheMaxSize to entries moved into the encrypted pair',
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

    /// 無効に戻したとき、暗号化した組を平文へ戻さずに消すこと
    test('deletes the encrypted pair when switched off', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: true);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();
        // 前提: 暗号化して保存されていること
        expect(pairFilesExist(_encryptedPair), isTrue);

        port = await startProxy(encrypt: false);

        expect(pairFilesExist(_encryptedPair), isFalse);
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

    /// 鍵を作り直した場合も、古い鍵の組を消して続けること
    test('deletes the encrypted pair when the key is regenerated', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: true);
        await _get(Uri.parse('http://127.0.0.1:$port/api/employees'));
        await restartProxy();

        await const FlutterSecureStorage().delete(key: _keyName);
        // 前提: 古い鍵の組が残っていること
        expect(pairFilesExist(_encryptedPair), isTrue);

        // 起動前の Cookie API は段階 1（鍵）だけを実行する。Hive の切り詰めでは
        // なく、鍵を作り直した時点で削除していることを確かめる
        await proxy.getCookies();
        expect(pairFilesExist(_encryptedPair), isFalse);

        port = await startProxy(encrypt: true);

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(await servedFromCache(port, '/api/employees'), isFalse);
      });
    });

    /// 復旧 API が鍵を削除するときは、暗号化したキャッシュも削除すること
    test('deletes the encrypted pair when recovery deletes the key', () async {
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
        expect(pairFilesExist(_encryptedPair), isFalse);
      });
    });

    /// 別の処理が開いている本文の LazyBox も、復旧 API が閉じてから削除すること
    test('closes a body box opened elsewhere before recovery deletes it',
        () async {
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
        await restartProxy();

        final key = base64Decode(
          (await const FlutterSecureStorage().read(key: _keyName))!,
        );
        // 別の処理が本文の LazyBox を開いたままにしている状態を作る
        await Hive.openLazyBox(
          _encryptedPair.body,
          path: hiveTestDirectory,
          encryptionCipher: HiveAesCipher(key),
        );
        await const FlutterSecureStorage().write(key: _keyName, value: 'x');

        final result = await proxy.recoverEncryptedStorage();

        expect(result.keyDeleted, isTrue);
        expect(Hive.isBoxOpen(_encryptedPair.body), isFalse);
        expect(pairFilesExist(_encryptedPair), isFalse);
      });
    });
  });

  group('応答キャッシュの保存形式（doc/specs.ja.md 【8】キャッシュ整合性）', () {
    /// 0.21.0 以前の平文の記録を、既定の暗号化した組へ移して古いファイルを消すこと
    test('moves the legacy plain cache into the encrypted pair', () async {
      await writeLegacyEntry(_legacyPlainBoxName, '/api/employees');

      await withRealHttpClient(() async {
        final port = await startProxy();

        expect(filesExist(_legacyPlainBoxName), isFalse);
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        expect(await servedFromCache(port, '/api/employees'), isTrue);
      });
      await restartProxy();
      expect(containsMarker(_encryptedPair.body), isFalse);
    });

    /// 暗号化しない場合も、0.21.0 以前の平文の記録を平文の組へ移すこと
    test('moves the legacy plain cache into the plain pair', () async {
      await writeLegacyEntry(_legacyPlainBoxName, '/api/employees');

      await withRealHttpClient(() async {
        final port = await startProxy(encrypt: false);

        expect(filesExist(_legacyPlainBoxName), isFalse);
        expect(await servedFromCache(port, '/api/employees'), isTrue);
      });
    });

    /// 0.21.0 が暗号化した記録を、同じ鍵の暗号化した組へ移すこと
    test('moves the 0.21.0 encrypted cache into the encrypted pair', () async {
      final key = List<int>.generate(32, (index) => (index * 7 + 1) & 0xff);
      FlutterSecureStorage.setMockInitialValues(
        <String, String>{_keyName: base64Encode(key)},
      );
      await writeLegacyEntry(_legacyEncryptedBoxName, '/api/employees',
          key: key);

      await withRealHttpClient(() async {
        final port = await startProxy();

        expect(filesExist(_legacyEncryptedBoxName), isFalse);
        expect(await servedFromCache(port, '/api/employees'), isTrue);
      });
    });

    /// 鍵と合わない 0.21.0 の暗号化した記録は、起動を止めずに空として扱い、消すこと
    test('drops a 0.21.0 encrypted cache that does not match the key',
        () async {
      final key = List<int>.generate(32, (index) => (index * 7 + 1) & 0xff);
      FlutterSecureStorage.setMockInitialValues(
        <String, String>{_keyName: base64Encode(key)},
      );
      await writeLegacyEntry(
        _legacyEncryptedBoxName,
        '/api/employees',
        key: List<int>.generate(32, (index) => 255 - index),
      );

      await withRealHttpClient(() async {
        final port = await startProxy();

        expect(filesExist(_legacyEncryptedBoxName), isFalse);
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(await servedFromCache(port, '/api/employees'), isFalse);
      });
    });

    /// 暗号化しない場合は、0.21.0 が暗号化した記録を平文へ戻さずに消すこと
    test('deletes the 0.21.0 encrypted cache when disabled', () async {
      final key = List<int>.generate(32, (index) => (index * 7 + 1) & 0xff);
      FlutterSecureStorage.setMockInitialValues(
        <String, String>{_keyName: base64Encode(key)},
      );
      await writeLegacyEntry(_legacyEncryptedBoxName, '/api/employees',
          key: key);

      await withRealHttpClient(() async {
        final port = await startProxy(encrypt: false);

        expect(filesExist(_legacyEncryptedBoxName), isFalse);
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(await servedFromCache(port, '/api/employees'), isFalse);
      });
    });

    /// 片方の Box にしかない記録（書き込みの途中で止まった記録など）は、
    /// 起動時に消すこと
    test('removes records found in only one of the pair', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(encrypt: false);
        await _get(Uri.parse('http://127.0.0.1:$port/api/a'));
        await _get(Uri.parse('http://127.0.0.1:$port/api/b'));
        final keys = Hive.box(_plainPair.index).keys.toList();
        expect(keys, hasLength(2));
        // 1 件は本文だけ、もう 1 件はメタデータだけを残す
        await Hive.box(_plainPair.index).delete(keys[0]);
        await Hive.lazyBox(_plainPair.body).delete(keys[1]);
        await restartProxy();

        port = await startProxy(encrypt: false);

        expect(Hive.box(_plainPair.index).keys, isEmpty);
        expect(Hive.lazyBox(_plainPair.body).keys, isEmpty);
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
      });
    });

    /// 削除と全削除は、メタデータと本文の両方から消すこと
    test('deletes both halves of a record', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(encrypt: false);
        await _get(Uri.parse('http://127.0.0.1:$port/api/a'));
        await _get(Uri.parse('http://127.0.0.1:$port/api/b'));

        await proxy.clearCacheForUrl('${upstream!.origin}/api/a');
        expect(Hive.box(_plainPair.index).length, equals(1));
        expect(Hive.lazyBox(_plainPair.body).length, equals(1));

        await proxy.clearCache();
        expect(Hive.box(_plainPair.index).length, equals(0));
        expect(Hive.lazyBox(_plainPair.body).length, equals(0));
      });
    });
  });

  group('応答キャッシュを開く時機（doc/specs.ja.md 【8】保存形式）', () {
    /// 平文の応答キャッシュを 2 件ためてから、移行を止められる proxy を作る。
    ///
    /// [gate] 完了するまで、移行の 1 件目を止める。
    Future<void> prepareBlockedMigration(Completer<void> gate) async {
      final port = await startProxy(encrypt: false);
      await _get(Uri.parse('http://127.0.0.1:$port/api/a'));
      await _get(Uri.parse('http://127.0.0.1:$port/api/b'));
      await restartProxy();
      proxy = OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(beforeCacheEntryMoved: (_) => gate.future),
      );
    }

    /// 移行が終わるのを待たずに start() が返り、開いている間は保存せず、
    /// キャッシュから返す要求と API は開き終わるのを待つこと
    test('returns from start before the cache is open', () async {
      await withRealHttpClient(() async {
        final gate = Completer<void>();
        await prepareBlockedMigration(gate);
        final skipped = <ProxyEvent>[];
        final subscription = proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen(skipped.add);

        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin, cacheMaxSize: 0),
        );

        var ready = false;
        unawaited(proxy.cacheReady.then((_) => ready = true));
        var statsDone = false;
        final stats =
            proxy.getCacheStats().whenComplete(() => statsDone = true);

        // 開いている間のオンラインの GET は、上流から返して保存しない
        final online = await _get(Uri.parse('http://127.0.0.1:$port/api/c'));
        expect(online.statusCode, equals(HttpStatus.ok));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(skipped.single.data['reason'], equals('cacheOpening'));
        expect(ready, isFalse);
        expect(statsDone, isFalse);

        // キャッシュから返す要求は、開き終わるのを待ってから返す
        await _emitConnectivity(['none']);
        final offline = _get(Uri.parse('http://127.0.0.1:$port/api/a'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        gate.complete();
        final served = await offline;
        await _emitConnectivity(['wifi']);

        expect(served.statusCode, equals(HttpStatus.ok));
        expect(served.offlineSource, equals('cache'));
        await proxy.cacheReady;
        expect(ready, isTrue);
        // 開いている間に取得した /api/c は保存していないこと
        expect((await stats).totalEntries, equals(2));
        await subscription.cancel();
      });
    });

    /// キャッシュから返す要求は、requestTimeout を上限に待つこと
    test('stops waiting for the cache at the request timeout', () async {
      await withRealHttpClient(() async {
        final gate = Completer<void>();
        await prepareBlockedMigration(gate);
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            requestTimeout: const Duration(milliseconds: 500),
          ),
        );

        await _emitConnectivity(['none']);
        final stopwatch = Stopwatch()..start();
        final response = await _get(Uri.parse('http://127.0.0.1:$port/api/a'));
        stopwatch.stop();
        await _emitConnectivity(['wifi']);
        gate.complete();

        expect(response.offlineSource, isNot(equals('cache')));
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      });
    });

    /// 停止すると移行を打ち切り、移していない記録は次の起動で移すこと
    test('resumes an interrupted migration at the next start', () async {
      await withRealHttpClient(() async {
        final gate = Completer<void>();
        await prepareBlockedMigration(gate);
        await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final stopping = proxy.stop();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        gate.complete();
        await stopping;

        // 移し元は、移していない記録を失わないよう残っていること
        expect(pairFilesExist(_plainPair), isTrue);
        expect(Hive.isBoxOpen(_encryptedPair.index), isFalse);

        await restartProxy();
        await startProxy();

        expect(pairFilesExist(_plainPair), isFalse);
        expect((await proxy.getCacheStats()).totalEntries, equals(2));
      });
    });

    /// 開けない場合も start() は成功し、キャッシュを使わずに動くこと
    test('keeps running without the cache when it cannot be opened', () async {
      await withRealHttpClient(() async {
        upstream ??= _MockUpstream(
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        );
        // Box のファイル名と同じディレクトリを置き、開くときに失敗させる
        Directory(
          '$hiveTestDirectory${Platform.pathSeparator}'
          '${_encryptedPair.index}.hive',
        ).createSync();
        final errors = <ProxyEvent>[];
        final subscription = proxy.events
            .where((event) => event.type == ProxyEventType.errorOccurred)
            .listen(errors.add);

        // Hive は開けなかった例外を、捕まえた後も未捕捉のエラーとして報告する
        final uncaughtErrors = <Object>[];
        late int port;
        await runZonedGuarded(() async {
          port = await proxy.start(
            config: ProxyConfig(origin: upstream!.origin),
          );
          await proxy.cacheReady;
        }, (error, stackTrace) => uncaughtErrors.add(error));
        await Future<void>.delayed(Duration.zero);

        expect(proxy.isRunning, isTrue);
        // 開けなかった例外以外の未捕捉エラーが紛れていないこと
        expect(uncaughtErrors, isNotEmpty);
        expect(uncaughtErrors, everyElement(isA<FileSystemException>()));
        expect(errors.single.data['phase'], equals('cacheOpen'));
        final response = await _get(Uri.parse('http://127.0.0.1:$port/api/a'));
        expect(response.statusCode, equals(HttpStatus.ok));
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        await subscription.cancel();
      });
    });

    /// 起動に失敗した場合は、開き始めた応答キャッシュを閉じること
    test('closes the cache when start fails', () async {
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(occupied.close);

      await expectLater(
        proxy.start(
          config: ProxyConfig(origin: 'http://127.0.0.1', port: occupied.port),
        ),
        throwsA(isA<ProxyStartException>()),
      );

      expect(Hive.isBoxOpen(_encryptedPair.index), isFalse);
      expect(Hive.isBoxOpen(_encryptedPair.body), isFalse);
      await proxy.cacheReady;
    });

    /// 起動に失敗した場合は、開く処理が終わるまで別の start() を受け付けず、
    /// 移行を始めずに移し元を残すこと
    test('waits for the cache opening when start fails', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(encrypt: false);
        await _get(Uri.parse('http://127.0.0.1:$port/api/a'));
        await restartProxy();
        final gate = Completer<void>();
        proxy = OfflineWebProxy.withStorageTestHooks(
          ProxyStorageTestHooks(beforeCacheOpened: () => gate.future),
        );
        final occupied =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(occupied.close);

        final failing = proxy.start(
          config: ProxyConfig(origin: upstream!.origin, port: occupied.port),
        );
        var failed = false;
        unawaited(failing.then((_) {}, onError: (_) => failed = true));
        // ポートの確保に失敗した後、開く処理が終わるのを待っている間
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(failed, isFalse);
        await expectLater(
          proxy.start(config: ProxyConfig(origin: upstream!.origin)),
          throwsA(isA<ProxyStartException>().having(
              (error) => error.message, 'message', contains('starting'))),
        );
        gate.complete();
        await expectLater(failing, throwsA(isA<ProxyStartException>()));

        expect(pairFilesExist(_plainPair), isTrue);
        expect(pairFilesExist(_encryptedPair), isFalse);
        expect(Hive.isBoxOpen(_encryptedPair.index), isFalse);
      });
    });

    /// 起動に失敗しても、別のインスタンスが開いている応答キャッシュは閉じないこと
    test('keeps the cache of another instance open when start fails', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        final occupied =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(occupied.close);
        final other = OfflineWebProxy();

        await expectLater(
          other.start(
            config: ProxyConfig(origin: upstream!.origin, port: occupied.port),
          ),
          throwsA(isA<ProxyStartException>()),
        );

        expect(Hive.isBoxOpen(_encryptedPair.index), isTrue);
        await _get(Uri.parse('http://127.0.0.1:$port/api/a'));
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
      });
    });
  });
}
