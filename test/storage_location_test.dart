import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// 暗号化鍵を保存する secure storage 上の名前。
const String _keyName = 'offline_web_proxy.cookie_box_encryption_key';

/// キューの暗号化 Box の名前。
const String _queueBoxName = 'proxy_queue_secure';

/// キューの旧平文 Box の名前。
const String _legacyQueueBoxName = 'proxy_queue';

/// proxy が保存先の特定に使うポート設定 Box の名前。
const String _portPreferenceBoxName = 'proxy_port_preferences';

/// 起動に使う上流 origin。これらのテストでは上流へ接続しない。
const String _origin = 'https://example.com';

/// アプリが Hive を初期化するサブディレクトリの名前。path_provider の場所の下に作る。
const String _hiveSubdirectoryName = 'app_hive';

/// キューの記録のキー（19 桁のマイクロ秒と 6 桁の連番）。
const String _queueKey = '0001757000000000000-000000';

/// テスト用の鍵を作る。
///
/// [seed] 鍵ごとに変える値。
///
/// Returns: 32 バイトの鍵。
List<int> _key(int seed) =>
    List<int>.generate(32, (index) => (index * 7 + seed) & 0xff);

/// キューに保存される形のデータを作る。
///
/// 再送の時刻は十分先にし、テスト中に送られないようにする。
///
/// Returns: キューの記録。
Map<String, Object> _queueEntry() {
  final queuedAt = DateTime.now().subtract(const Duration(hours: 1));
  return {
    'url': '$_origin/api/sales/1',
    'method': 'POST',
    'headers': <String, String>{},
    'body': utf8.encode('{"total":1}'),
    'queuedAt': queuedAt.toIso8601String(),
    'retryCount': 0,
    'nextRetryAt': DateTime(2099).toIso8601String(),
  };
}

/// アダプタ 0 を登録済みの状態を再現するためだけのダミーの型。
class _DummyRecord {}

/// typeId 0 を占有するダミーのアダプタ。
///
/// アプリが独自のアダプタ 0 を登録し、Hive を自前で初期化している状態を再現する。
/// proxy はアダプタ 0 が登録済みの場合、`Hive.initFlutter()` を呼ばない。
class _DummyAdapter extends TypeAdapter<_DummyRecord> {
  @override
  final int typeId = 0;

  @override
  _DummyRecord read(BinaryReader reader) => _DummyRecord();

  @override
  void write(BinaryWriter writer, _DummyRecord obj) {}
}

/// 値を保持するだけの secure storage の偽物。鍵の有無をテストから操作する。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String pathProviderDirectory;

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        // path_provider が返す場所。proxy がここを保存先とみなすとテストで検出できる
        return pathProviderDirectory;
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

    // アダプタの登録は isolate 全体に残り、Hive.resetAdapters() は Hive の既定の
    // アダプタも消すため、このファイルのテストはすべてアダプタ 0 を登録した状態で行う
    Hive.registerAdapter(_DummyAdapter());
  });

  late String hiveDirectory;
  late _FakeKeyStorage keyStorage;
  late OfflineWebProxy proxy;

  setUp(() async {
    pathProviderDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_storage_location')
        .path;
    hiveDirectory = (Directory(
      '$pathProviderDirectory${Platform.pathSeparator}$_hiveSubdirectoryName',
    )..createSync())
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    // アプリが path_provider の場所ではなく、そのサブディレクトリで Hive を初期化した状態にする
    Hive.init(hiveDirectory);
    keyStorage = _FakeKeyStorage();
    proxy = OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks(
      keyStorage: keyStorage,
      keyRereadInterval: Duration.zero,
    ));
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await Hive.close();
  });

  /// [directory] にある Box のファイル（`.hive`）を返す。
  ///
  /// [directory] 探すディレクトリ。
  /// [name] Box の名前。
  ///
  /// Returns: Box のファイル。存在するかどうかは確認しない。
  File boxFileIn(String directory, String name) =>
      File('$directory${Platform.pathSeparator}$name.hive');

  /// proxy が path_provider の場所ではなく、Hive の実際の保存先で動いたことを確かめる。
  ///
  /// 保存先の特定に使うポート設定 Box が、実際の保存先にだけ作られていることで判定する。
  void expectStartedInActualHiveDirectory() {
    // Hive を初期化し直さず、実際の保存先にポート設定 Box を作ったこと
    expect(
      boxFileIn(hiveDirectory, _portPreferenceBoxName).existsSync(),
      isTrue,
    );
    // path_provider の場所には作っていないこと
    expect(
      boxFileIn(pathProviderDirectory, _portPreferenceBoxName).existsSync(),
      isFalse,
    );
  }

  group('保存先の特定（アダプタ 0 を登録し、サブディレクトリで Hive を初期化した場合）', () {
    /// path_provider の場所ではなく実際の保存先にある暗号化 Box を鍵と照合し、鍵と合わない
    /// 業務データの Box があれば、開いて切り詰めずに起動失敗にすること
    test('verifies encrypted boxes in the actual Hive directory', () async {
      final queueBox = await Hive.openBox(
        _queueBoxName,
        encryptionCipher: HiveAesCipher(_key(1)),
      );
      await queueBox.put(_queueKey, _queueEntry());
      await queueBox.close();
      final queueFile = boxFileIn(hiveDirectory, _queueBoxName);
      final sizeBefore = queueFile.lengthSync();
      keyStorage.values[_keyName] = base64Encode(_key(2));

      Object? startError;
      try {
        await proxy.start(config: const ProxyConfig(origin: _origin));
      } catch (error) {
        startError = error;
      }

      expectStartedInActualHiveDirectory();
      // 実際の保存先の Box を照合し、鍵の不一致で起動失敗にしたこと
      expect(startError, isA<StorageIntegrityException>());
      final integrityError = startError! as StorageIntegrityException;
      expect(integrityError.failure, StorageIntegrityFailure.keyMismatch);
      expect(
        integrityError.boxResults[ProxyStorageBox.queue],
        StorageBoxCheckResult.mismatch,
      );
      // Box を開いて切り詰めていないこと
      expect(queueFile.lengthSync(), sizeBefore);
      expect(proxy.isRunning, isFalse);
    });

    /// path_provider の場所ではなく実際の保存先にある旧平文 Box を段階 2 で見つけ、
    /// キーを保ったまま実際の保存先の暗号化 Box へ移し、旧 Box を消すこと
    test('migrates legacy boxes found in the actual Hive directory', () async {
      final legacyBox = await Hive.openBox(_legacyQueueBoxName);
      await legacyBox.put(_queueKey, _queueEntry());
      await legacyBox.close();
      // 前提: 旧平文 Box は実際の保存先にあること
      expect(
        boxFileIn(hiveDirectory, _legacyQueueBoxName).existsSync(),
        isTrue,
      );
      // 鍵が既にある状態にし、移行を遅らせずに段階 2 で行わせる
      keyStorage.values[_keyName] = base64Encode(_key(1));

      await proxy.start(config: const ProxyConfig(origin: _origin));

      expectStartedInActualHiveDirectory();
      // 実際の保存先の旧平文 Box を消したこと
      expect(
        boxFileIn(hiveDirectory, _legacyQueueBoxName).existsSync(),
        isFalse,
      );
      // 実際の保存先の暗号化 Box へ、同じキーで移したこと
      expect(boxFileIn(hiveDirectory, _queueBoxName).existsSync(), isTrue);
      expect(Hive.box(_queueBoxName).keys.toList(), [_queueKey]);
      // 移した記録を、移行済みとして一覧で読めること
      final queued = await proxy.getQueuedRequests();
      expect(queued, hasLength(1));
      expect(queued.single.pendingMigration, isFalse);
    });
  });
}
