import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';
import 'package:offline_web_proxy/src/storage/hive_frame_inspector.dart';
import 'package:offline_web_proxy/src/storage/hive_key.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = <String, List<String>>{};

/// secure storage に置く暗号化鍵の名前。
const String _keyName = 'offline_web_proxy.cookie_box_encryption_key';

/// 送信済みのべき等性キーを記録する Box 名。
const String _idempotencyBoxName = 'proxy_idempotency';

/// Cookie を保存する暗号化 Box 名。
const String _cookieBoxName = 'proxy_cookies_secure';

/// Hive のキーの上限（255 バイト）を超える、300 文字のべき等性キー。
///
/// HTTP ヘッダの値に書ける ASCII の文字だけで作ります。
final String _longIdempotencyKey = 'k' * 300;

/// 壊れた Cookie の Box を作る鍵の種と、その鍵で Hive が壊れた記録を読んだ結果。
///
/// 壊れた記録の値の先頭は、キーの続きを鍵で復号したものになるため、結果は鍵で
/// 決まります。Hive 2.2.3 で結果を確かめた種と、そのときゾーンへ漏れる例外の
/// 判定を並べます。開けてしまう場合は例外が漏れません。Hive を更新して結果が
/// 変わった場合は、テストが失敗して種の選び直しが必要なことを知らせます。
final List<(int, String, Matcher)> _corruptedCookieBoxCases = [
  (0, 'HiveError', allOf(isNotEmpty, everyElement(isA<HiveError>()))),
  (58, 'RangeError', allOf(isNotEmpty, everyElement(isA<RangeError>()))),
  (11, 'opens as a double', isEmpty),
];

/// [seed] から、テスト用の 32 バイトの鍵を作る。
///
/// [seed] 鍵の種。
///
/// Returns: 鍵のバイト列。
List<int> _fixedKey(int seed) =>
    List<int>.generate(32, (index) => (seed * 37 + index * 11 + 5) & 0xff);

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

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// 常に 200 を返す上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
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

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 実 HttpClient で POST を実行する。
///
/// [uri] 要求先。
/// [headers] 付与するヘッダ。
///
/// Returns: 応答のステータスコード。
Future<int> _post(Uri uri, Map<String, String> headers) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri);
    headers.forEach(request.headers.set);
    request.write('{}');
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
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
/// [timeout] を超えた場合は待機を打ち切り、呼び出し側のアサーションに委ねます。
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

/// 32 ビット符号なし整数をリトルエンディアンで書き込む。
///
/// [bytes] 書き込み先。
/// [offset] 書き込む位置。
/// [value] 書き込む値。
void _writeUint32(Uint8List bytes, int offset, int value) {
  ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);
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
  OfflineWebProxy createProxy() => OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(keyStorage: keyStorage),
      );

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_hive_key_length')
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
      createHttpClient: _RealHttpOverrides().createHttpClient,
    );
  }

  /// 上流を起動し（起動済みなら使い回し）、proxy を起動する。
  ///
  /// Returns: proxy のポート。
  Future<int> startProxy() async {
    upstream ??= _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    return proxy.start(config: ProxyConfig(origin: upstream!.origin));
  }

  /// 壊れた Box がある状態で proxy を起動し、ゾーンへ漏れた例外を返す。
  ///
  /// Hive は開けなかった Box の例外を、誰も待たない Future にも渡すため、
  /// 呼び出し元で捕まえても同じ例外がゾーンの未処理の例外として届きます。
  /// テストが失敗しないよう、ここで受け取って返します。
  ///
  /// Returns: ゾーンへ漏れた例外。
  Future<List<Object>> startProxyCollectingUncaught() async {
    final uncaught = <Object>[];
    final done = Completer<void>();
    runZonedGuarded(() {
      withRealHttpClient(() async {
        await startProxy();
      }).then(done.complete, onError: done.completeError);
    }, (error, _) => uncaught.add(error));
    await done.future;
    return uncaught;
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

  /// 0.21.0 以前のリリースビルドが書いた、壊れたフレームを Box の末尾に足す。
  ///
  /// Hive はキーの UTF-8 のバイト数を 1 バイトの欄に書くため、300 バイトの
  /// キーは長さの欄が 44 になります。CRC はフレーム全体で正しく計算されるため、
  /// Hive は破損として切り詰めず、読み取りの途中で例外を送出します。
  /// テストは assert が有効で、Hive に同じフレームを書かせられないため、
  /// 同じバイト列を組み立てて書き足します。
  ///
  /// [boxName] 書き足す Box の名前。
  /// [value] フレームに書く値。
  /// [cipher] 暗号化 Box の場合の暗号。
  Future<void> appendLongKeyFrame(
    String boxName,
    Object value, {
    HiveAesCipher? cipher,
  }) async {
    // 値の部分は、短いキーで Hive に書かせたフレームから取り出す
    const templateName = 'long_key_frame_template';
    final template = await Hive.openBox(
      templateName,
      path: hiveTestDirectory,
      encryptionCipher: cipher,
    );
    await template.put('z', value);
    await template.close();
    final templateBytes = boxFile(templateName).readAsBytesSync();
    await Hive.deleteBoxFromDisk(templateName, path: hiveTestDirectory);
    final templateLength =
        ByteData.sublistView(templateBytes).getUint32(0, Endian.little);
    // 長さ 4 + キーの型 1 + キーの長さ 1 + キー 1 の後から、CRC 4 の前まで
    final valueBytes = templateBytes.sublist(7, templateLength - 4);

    final keyBytes = utf8.encode('k' * 300);
    final frameLength = 4 + 2 + keyBytes.length + valueBytes.length + 4;
    final frame = Uint8List(frameLength);
    _writeUint32(frame, 0, frameLength);
    frame[4] = 1;
    frame[5] = keyBytes.length & 0xff;
    frame.setRange(6, 6 + keyBytes.length, keyBytes);
    frame.setRange(6 + keyBytes.length, frameLength - 4, valueBytes);
    _writeUint32(
      frame,
      frameLength - 4,
      hiveCrc32(
        frame,
        crc: cipher?.calculateKeyCrc() ?? 0,
        length: frameLength - 4,
      ),
    );

    boxFile(boxName).writeAsBytesSync(frame, mode: FileMode.append);
  }

  group('toHiveKey', () {
    /// 255 バイト以下のキーは変えず、既存の保存データをそのまま使えること
    test('keeps keys up to 255 bytes', () {
      expect(toHiveKey('abc'), 'abc');
      expect(toHiveKey('k' * 255), 'k' * 255);
      expect(toHiveKey('あ' * 85), 'あ' * 85);
    });

    /// 255 バイトを超えるキーは、文字数ではなく UTF-8 のバイト数で判定して置き換えること
    test('replaces keys over 255 bytes with a fixed-length hash', () {
      final hashed = toHiveKey('あ' * 86);
      expect(hashed, startsWith(hashedHiveKeyPrefix));
      expect(utf8.encode(hashed).length, lessThanOrEqualTo(255));
      expect(toHiveKey('あ' * 86), hashed);
      expect(toHiveKey('k' * 256), isNot(hashed));
      expect(toHiveKey('k' * 256), startsWith(hashedHiveKeyPrefix));
    });
  });

  group('Hive のキーの上限（doc/specs.ja.md 【4】【6】）', () {
    /// 255 バイトを超えるべき等性キーでも送信済みとして記録し、再起動できること
    test('records a long idempotency key and starts again', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        // 送信待ちから送って届いたキーを記録するため、回線を切って受け付ける
        await _emitConnectivity(['none']);
        final statusCode = await _post(
          Uri.parse('http://127.0.0.1:$port/api/orders'),
          {'Idempotency-Key': _longIdempotencyKey},
        );
        expect(statusCode, HttpStatus.accepted);
        await _emitConnectivity(['wifi']);
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
        expect(await proxy.getQueuedRequests(), isEmpty);

        await restartProxy();
        await startProxy();
        final statuses = await proxy.getRequestStatuses([_longIdempotencyKey]);
        expect(statuses.single.state, RequestState.delivered);
      });
    });

    /// 255 バイトを超える Cookie も保存でき、再起動後に読めること
    test('stores a cookie whose storage key is over 255 bytes', () async {
      final name = 'n' * 300;
      await proxy.restoreCookies([
        CookieRestoreEntry(
          name: name,
          value: 'v',
          domain: '127.0.0.1',
          path: '/',
          hostOnly: true,
        ),
      ]);

      await restartProxy();
      final cookies = await proxy.getCookies();
      expect(cookies.map((cookie) => cookie.name), contains(name));
    });

    /// 以前の版が壊したべき等性キーの Box は、作り直して起動を続けること
    test('rebuilds a corrupted idempotency box', () async {
      final box = await Hive.openBox(
        _idempotencyBoxName,
        path: hiveTestDirectory,
      );
      await box.put('short-key', DateTime.now().toIso8601String());
      await box.close();
      await appendLongKeyFrame(
        _idempotencyBoxName,
        DateTime.now().toIso8601String(),
      );

      final events = <ProxyEvent>[];
      final subscription = proxy.events.listen(events.add);
      final List<Object> uncaught;
      try {
        uncaught = await startProxyCollectingUncaught();
      } finally {
        await subscription.cancel();
      }
      expect(uncaught, everyElement(isA<HiveError>()));

      expect(proxy.isRunning, isTrue);
      expect(
        events.where((event) =>
            event.type == ProxyEventType.errorOccurred &&
            event.data['phase'] == 'idempotencyStoreRecovery'),
        hasLength(1),
      );
      final statuses = await proxy.getRequestStatuses(['short-key']);
      expect(statuses.single.state, RequestState.unknown);
    });

    /// 以前の版が壊した Cookie の Box は、破棄して起動を続け、鍵と他の暗号化 Box は
    /// そのまま使うこと
    ///
    /// 暗号化 Box では、壊れた記録を読んだ結果が鍵で決まるため、結果ごとに鍵を固定する。
    for (final (seed, outcome, uncaughtMatcher) in _corruptedCookieBoxCases) {
      test('discards a corrupted cookie box ($outcome)', () async {
        final key = _fixedKey(seed);
        keyStorage.values[_keyName] = base64Encode(key);
        await withRealHttpClient(() async {
          final port = await startProxy();
          await proxy.restoreCookies([
            const CookieRestoreEntry(
              name: 'session',
              value: 'v',
              domain: '127.0.0.1',
              path: '/',
              hostOnly: true,
            ),
          ]);
          // 送信待ちの Box に中身を残し、破棄の対象外であることを確かめる
          await _emitConnectivity(['none']);
          expect(
            await _post(
              Uri.parse('http://127.0.0.1:$port/api/orders'),
              {'Idempotency-Key': 'queued-key'},
            ),
            HttpStatus.accepted,
          );
        });
        await restartProxy();
        await appendLongKeyFrame(
          _cookieBoxName,
          <String, Object?>{'name': 'broken'},
          cipher: HiveAesCipher(key),
        );

        final events = <ProxyEvent>[];
        final subscription = proxy.events.listen(events.add);
        try {
          expect(await startProxyCollectingUncaught(), uncaughtMatcher);
        } finally {
          await subscription.cancel();
        }

        expect(proxy.isRunning, isTrue);
        expect(
          events.where((event) =>
              event.type == ProxyEventType.cookieStorageDiscarded &&
              event.data['reason'] == StorageIntegrityFailure.corrupted.name),
          hasLength(1),
        );
        expect(await proxy.getCookies(), isEmpty);
        expect(base64Decode(keyStorage.values[_keyName]!), key);
        final statuses = await proxy.getRequestStatuses(['queued-key']);
        expect(statuses.single.state, isNot(RequestState.unknown));
      });
    }

    /// Cookie として読めない値が入った Box も、壊れたものとして破棄すること
    test('discards a cookie box holding a value it never stores', () async {
      final key = _fixedKey(0);
      keyStorage.values[_keyName] = base64Encode(key);
      final box = await Hive.openBox(
        _cookieBoxName,
        path: hiveTestDirectory,
        encryptionCipher: HiveAesCipher(key),
      );
      await box.put('unexpected', 42);
      await box.close();

      final events = <ProxyEvent>[];
      final subscription = proxy.events.listen(events.add);
      try {
        final uncaught = await startProxyCollectingUncaught();
        expect(uncaught, isEmpty);
      } finally {
        await subscription.cancel();
      }

      expect(proxy.isRunning, isTrue);
      expect(
        events.where(
            (event) => event.type == ProxyEventType.cookieStorageDiscarded),
        hasLength(1),
      );
      expect(await proxy.getCookies(), isEmpty);
    });
  });
}
