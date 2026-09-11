import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';
import 'package:offline_web_proxy/src/storage/hive_frame_inspector.dart'
    show
        HiveBoxKeyKind,
        HiveBoxVerificationStatus,
        hiveKeyCrc,
        verifyHiveBoxFile;

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// 暗号化鍵を保存する secure storage 上の名前。
const String _keyName = 'offline_web_proxy.cookie_box_encryption_key';

/// Cookie の暗号化 Box の名前。
const String _cookieBoxName = 'proxy_cookies_secure';

/// キューの暗号化 Box の名前。
const String _queueBoxName = 'proxy_queue_secure';

/// 隔離の暗号化 Box の名前。
const String _quarantineBoxName = 'proxy_quarantined_requests_secure';

/// ドロップ履歴の暗号化 Box の名前。
const String _droppedBoxName = 'proxy_dropped_requests_secure';

/// 暗号化 Box の名前の一覧。
const List<String> _allEncryptedBoxNames = [
  _cookieBoxName,
  _queueBoxName,
  _quarantineBoxName,
  _droppedBoxName,
];

/// 暗号化する前の旧平文キューの Box の名前。
const String _legacyQueueBoxName = 'proxy_queue';

/// 起動に使う上流 origin。これらのテストでは上流へ接続しない。
const String _origin = 'https://example.com';

/// 先頭フレームを書きかけにするときに残すバイト数。
const int _partialFrameLength = 10;

/// テスト用の鍵を作る。
///
/// [seed] 鍵ごとに変える値。
///
/// Returns: 32 バイトの鍵。
List<int> _key(int seed) =>
    List<int>.generate(32, (index) => (index * 7 + seed) & 0xff);

/// 業務データの Box のキーを作る。
///
/// 破損した Box の走査で候補になる形式（19 桁 + `-` + 6 桁）にそろえる。
///
/// [index] 記録ごとに変える値。
///
/// Returns: `0001757000000000000-000000` の形式のキー。
String _storageKey(int index) =>
    '${(1757000000000000 + index).toString().padLeft(19, '0')}-000000';

/// 業務データの Box へ書き込む記録を、キーと値の組にまとめる。
///
/// [indexes] 書き込む記録の番号。書き込む順に並べる。
/// [build] 番号から値を作る関数。
///
/// Returns: [_storageKey] の形式のキーと値の組。
Map<String, Object> _entries(
  Iterable<int> indexes,
  Map<String, Object> Function(int index) build,
) {
  return {for (final index in indexes) _storageKey(index): build(index)};
}

/// キューに保存される形のデータを作る。
///
/// [index] 項目ごとに変える値。
///
/// Returns: キューの記録。
Map<String, Object> _queueEntry(int index) {
  return {
    'url': '$_origin/api/sales/$index',
    'method': 'POST',
    'headers': <String, String>{},
    'body': utf8.encode('{"total":$index}'),
    'queuedAt': DateTime(2026, 9, 1, 10, index).toIso8601String(),
    'retryCount': 0,
    'nextRetryAt': DateTime(2026, 9, 1, 10, index).toIso8601String(),
  };
}

/// 隔離に保存される形のデータを作る。
///
/// 起動時の保持期間（既定 30 日）で取り除かれないよう、日時は現在時刻を基準にする。
///
/// [index] 項目ごとに変える値。
///
/// Returns: 隔離の記録。
Map<String, Object> _quarantineEntry(int index) {
  final quarantinedAt =
      DateTime.now().add(Duration(seconds: index)).toIso8601String();
  return {
    'url': '$_origin/api/sales/$index',
    'method': 'POST',
    'headers': <String, String>{},
    'body': utf8.encode('{"total":$index}'),
    'queuedAt': quarantinedAt,
    'retryCount': 0,
    'nextRetryAt': quarantinedAt,
    'quarantinedAt': quarantinedAt,
    'statusCode': 400,
    'reason': '4xx_error',
    'errorMessage': 'rejected $index',
  };
}

/// ドロップ履歴に保存される形のデータを作る。
///
/// 起動時の保持期間（既定 30 日）で取り除かれないよう、日時は現在時刻を基準にする。
///
/// [index] 項目ごとに変える値。
///
/// Returns: ドロップ履歴の記録。
Map<String, Object> _droppedEntry(int index) {
  return {
    'url': '$_origin/api/sales/$index',
    'method': 'POST',
    'droppedAt': DateTime.now().add(Duration(seconds: index)).toIso8601String(),
    'dropReason': 'max_retry',
    'statusCode': 500,
    'errorMessage': 'dropped $index',
    'acknowledged': true,
  };
}

/// 復元する Cookie を作る。
///
/// [name] Cookie 名。
///
/// Returns: `example.com` のホスト限定 Cookie。
CookieRestoreEntry _cookie(String name) {
  return CookieRestoreEntry(
    name: name,
    value: 'token',
    domain: 'example.com',
    hostOnly: true,
  );
}

/// [future] の完了を待ち、送出された例外を返す。
///
/// 待ち始める前に失敗しても未処理のエラーにならないよう、処理を始めた直後に渡す。
///
/// [future] 待つ処理。
///
/// Returns: 送出された例外。正常に完了した場合は `null`。
Future<Object?> _errorOf(Future<Object?> future) {
  return future.then<Object?>(
    (_) => null,
    onError: (Object error) => error,
  );
}

/// 読み取りの結果・停止・失敗と、保護データの状態を操作できる secure storage。
class _FakeKeyStorage implements EncryptionKeyStorage {
  /// 保存されている値。
  final Map<String, String> values = {};

  /// 先頭から順に使う読み取り結果。文字列か `null` を返し、[Exception] は送出する。
  /// 使い切った後は [values] を読む。
  final List<Object?> scriptedReads = [];

  /// 読み取りを常に失敗させるかどうか。[scriptedReads] より優先する。
  bool failReads = false;

  /// 読み取りを止めておく待ち合わせ。`null` の場合は止めない。
  ///
  /// 初期化のロックを保持したまま鍵の読み取りで止まった状態を作るために使う。
  Completer<void>? readGate;

  /// [readGate] で止まる読み取りが始まったことを知らせる待ち合わせ。
  Completer<void>? readEntered;

  /// 読み取りが呼ばれた回数。
  int readCount = 0;

  /// 鍵を削除する直前に呼ぶ処理。削除した時点のファイルの状態を記録するために使う。
  void Function(String key)? onDelete;

  /// 保護データの利用可否。`null` は iOS / macOS 以外を表す。
  bool? protectedDataAvailable;

  @override
  Future<String?> read(String key) async {
    readCount++;
    final gate = readGate;
    if (gate != null) {
      final entered = readEntered;
      if (entered != null && !entered.isCompleted) {
        entered.complete();
      }
      await gate.future;
    }

    if (failReads) {
      throw Exception('keystore unavailable');
    }
    if (scriptedReads.isNotEmpty) {
      final result = scriptedReads.removeAt(0);
      if (result is Exception) {
        throw result;
      }
      return result as String?;
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    onDelete?.call(key);
    values.remove(key);
  }

  @override
  Future<bool?> isProtectedDataAvailable() async => protectedDataAvailable;
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

  /// テスト用の差し替えを入れた proxy を作る。
  ///
  /// [verificationTimeLimit] 照合の走査を打ち切る時間の上限。`null` は既定値。
  /// [deferredMigrationDelay] 鍵を生成したときに旧平文 Box の移行を遅らせる時間。
  ///   `null` は既定値。
  ///
  /// Returns: [keyStorage] を使い、待たずに鍵を読み直す proxy。
  OfflineWebProxy createProxy({
    Duration? verificationTimeLimit,
    Duration? deferredMigrationDelay,
  }) {
    return OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks(
      keyStorage: keyStorage,
      keyRereadInterval: Duration.zero,
      verificationTimeLimit: verificationTimeLimit,
      deferredMigrationDelay: deferredMigrationDelay,
    ));
  }

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_storage_recovery')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    keyStorage = _FakeKeyStorage();
    proxy = createProxy();
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await Hive.close();
  });

  /// Box のファイル（`.hive`）を返す。
  File boxFile(String name) =>
      File('$hiveTestDirectory${Platform.pathSeparator}$name.hive');

  /// 圧縮途中の Box のファイル（`.hivec`）を返す。
  File compactedFile(String name) =>
      File('$hiveTestDirectory${Platform.pathSeparator}$name.hivec');

  /// Box のファイルの大きさを名前ごとに返す。何も消していないことの確認に使う。
  ///
  /// [names] Box の名前。
  ///
  /// Returns: 名前ごとのバイト数。ファイルが無い場合は `null`。
  Map<String, int?> fileSizes(Iterable<String> names) {
    return {
      for (final name in names)
        name: boxFile(name).existsSync() ? boxFile(name).lengthSync() : null,
    };
  }

  /// 鍵 [key] を Base64 にして secure storage の偽物へ保存する。
  void storeKey(List<int> key) {
    keyStorage.values[_keyName] = base64Encode(key);
  }

  /// 暗号化 Box を直接書き、閉じる。
  ///
  /// [name] Box の名前。
  /// [key] 暗号化に使う鍵。
  /// [entries] 書き込む内容。書き込む順に並べる。
  Future<void> writeEncryptedBox(
    String name,
    List<int> key,
    Map<String, Object> entries,
  ) async {
    await Hive.initFlutter();
    final box = await Hive.openBox(name, encryptionCipher: HiveAesCipher(key));
    await box.putAll(entries);
    await box.close();
  }

  /// 暗号化する前の平文の Box を直接書き、閉じる。
  ///
  /// [name] Box の名前。
  /// [entries] 書き込む内容。
  Future<void> writePlainBox(String name, Map<String, Object> entries) async {
    await Hive.initFlutter();
    final box = await Hive.openBox(name);
    await box.putAll(entries);
    await box.close();
  }

  /// 先頭フレームの長さの欄を壊し、先頭側だけが壊れた Box にする。
  ///
  /// [name] Box の名前。
  ///
  /// Returns: 壊した後のファイルの内容。
  Uint8List corruptFirstFrame(String name) {
    final file = boxFile(name);
    final bytes = file.readAsBytesSync();
    bytes.setRange(0, 4, [0xff, 0xff, 0xff, 0x7f]);
    file.writeAsBytesSync(bytes, flush: true);
    return bytes;
  }

  /// 先頭フレームの途中でファイルを切り、最初の書き込みの途中で止まった Box にする。
  ///
  /// [name] Box の名前。
  void cutInsideFirstFrame(String name) {
    final file = boxFile(name);
    final bytes = file.readAsBytesSync();
    file.writeAsBytesSync(bytes.sublist(0, _partialFrameLength), flush: true);
  }

  /// 鍵 [key] で Cookie を保存した状態を作り、Hive を閉じて proxy を作り直す。
  ///
  /// Cookie は [names] の順に 1 件ずつ書き込まれる。
  ///
  /// [key] 暗号化に使う鍵。
  /// [names] 保存する Cookie 名。
  Future<void> storeCookiesWithKey(List<int> key, List<String> names) async {
    storeKey(key);
    await proxy.restoreCookies([for (final name in names) _cookie(name)]);
    await Hive.close();
    proxy = createProxy();
  }

  /// Box を開かずにファイルを鍵 [key] と時間の上限なしで照合する。前提の確認に使う。
  ///
  /// [name] Box の名前。Cookie Box かどうかで走査の候補を変える。
  /// [key] 照合する鍵。
  ///
  /// Returns: 照合結果。
  Future<HiveBoxVerificationStatus> verifyBox(
      String name, List<int> key) async {
    final verification = await verifyHiveBoxFile(
      boxFile(name).path,
      hiveKeyCrc(key),
      name == _cookieBoxName ? HiveBoxKeyKind.cookie : HiveBoxKeyKind.business,
    );
    return verification.status;
  }

  /// 上流へ接続しない設定で proxy を起動する。
  ///
  /// Returns: 使用したポート番号。
  Future<int> startProxy() =>
      proxy.start(config: const ProxyConfig(origin: _origin));

  /// start() を呼び、送出された StorageIntegrityException を返す。
  ///
  /// Returns: start() が送出した例外。送出しなかった場合はテストを失敗させる。
  Future<StorageIntegrityException> startFailure() async {
    try {
      await startProxy();
    } on StorageIntegrityException catch (error) {
      return error;
    }
    fail('start() did not throw StorageIntegrityException');
  }

  /// Cookie 名の一覧を読む。
  Future<List<String>> cookieNames() async {
    return (await proxy.getCookies()).map((cookie) => cookie.name).toList();
  }

  /// 隔離されている記録の識別子（保存領域のキー）の一覧を読む。
  Future<List<String>> quarantineIds() async {
    return (await proxy.getQuarantinedRequests())
        .map((request) => request.id)
        .toList();
  }

  /// 復旧 API が何もせずに [rejection] を理由として返したことを確かめる。
  ///
  /// [result] 復旧 API の戻り値。
  /// [rejection] 期待する拒否の理由。
  void expectRejected(
    EncryptedStorageRecoveryResult result,
    StorageRecoveryRejection rejection,
  ) {
    // 処理を行わず、理由を返すこと
    expect(result.performed, isFalse);
    expect(result.rejection, rejection);
    // 削除・作り直し・鍵の削除のいずれも行っていないこと
    expect(result.deletedBoxes, isEmpty);
    expect(result.rebuiltBoxes, isEmpty);
    expect(result.keptBoxes, isEmpty);
    expect(result.keyDeleted, isFalse);
  }

  group('復旧 API の拒否（proxy が稼働中・起動処理中）', () {
    /// 稼働中は、処理を進めれば全削除になる状態でも何も消さずに拒否すること
    test('rejects recovery while the proxy is running', () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0, 1], _quarantineEntry));
      await startProxy();
      // 前提: 起動に成功し、隔離の記録を読めること
      expect(proxy.isRunning, isTrue);
      expect(await proxy.getQuarantinedRequests(), hasLength(2));
      final sizeBefore = boxFile(_quarantineBoxName).lengthSync();
      // 処理を進めれば全削除になる状態（鍵の読み取りが常に失敗）にする
      keyStorage.failReads = true;

      final result = await proxy.recoverEncryptedStorage();

      // 稼働中を理由に拒否すること
      expectRejected(result, StorageRecoveryRejection.proxyActive);
      // Box も鍵も消していないこと
      expect(boxFile(_quarantineBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));
      // 稼働を続け、隔離の記録を読めること
      expect(proxy.isRunning, isTrue);
      expect(await proxy.getQuarantinedRequests(), hasLength(2));
    });

    /// start() が鍵の読み取りで止まっている間は、何も消さずに拒否すること
    test('rejects recovery while start() is in progress', () async {
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      storeKey(_key(2));
      final sizeBefore = boxFile(_quarantineBoxName).lengthSync();
      final readGate = Completer<void>();
      final readEntered = Completer<void>();
      keyStorage
        ..readGate = readGate
        ..readEntered = readEntered;
      addTearDown(() {
        if (!readGate.isCompleted) {
          readGate.complete();
        }
      });

      final startError = _errorOf(startProxy());
      await readEntered.future;
      final result = await proxy.recoverEncryptedStorage();

      // 起動処理中を理由に拒否すること
      expectRejected(result, StorageRecoveryRejection.proxyActive);
      // 鍵と一致しない Box を消していないこと
      expect(boxFile(_quarantineBoxName).lengthSync(), sizeBefore);

      keyStorage.readGate = null;
      readGate.complete();
      final error = await startError;
      // 前提: 止めていた start() は鍵の不一致で失敗し、何も消していないこと
      expect(error, isA<StorageIntegrityException>());
      expect((error! as StorageIntegrityException).failure,
          StorageIntegrityFailure.keyMismatch);
      expect(boxFile(_quarantineBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values[_keyName], base64Encode(_key(2)));

      // 起動処理が終われば同じ状態で復旧を行うこと（拒否の理由が起動処理中だったこと）
      final retried = await proxy.recoverEncryptedStorage();
      expect(retried.performed, isTrue);
      expect(retried.deletedBoxes, {ProxyStorageBox.quarantine});
    });

    /// 初期化のロックを待つ間に同じインスタンスで start() が始まった場合も、
    /// 何も消さずに拒否すること
    test('rejects recovery when start() begins while it waits for the lock',
        () async {
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      storeKey(_key(2));
      final sizeBefore = boxFile(_quarantineBoxName).lengthSync();
      // 別のインスタンスの Cookie API に、初期化のロックを保持させたまま止める
      final otherKeyStorage = _FakeKeyStorage()
        ..values[_keyName] = base64Encode(_key(2));
      final readGate = Completer<void>();
      final readEntered = Completer<void>();
      otherKeyStorage
        ..readGate = readGate
        ..readEntered = readEntered;
      addTearDown(() {
        if (!readGate.isCompleted) {
          readGate.complete();
        }
      });
      final other = OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks(
        keyStorage: otherKeyStorage,
        keyRereadInterval: Duration.zero,
      ));
      final otherError = _errorOf(other.getCookies());
      await readEntered.future;

      // 復旧 API がロックを待っている間に start() を始めてから、ロックを解放させる
      final recovery = proxy.recoverEncryptedStorage();
      final startError = _errorOf(startProxy());
      otherKeyStorage.readGate = null;
      readGate.complete();
      final result = await recovery;

      // ロックを取得した時点で起動処理中を検知して拒否すること
      expectRejected(result, StorageRecoveryRejection.proxyActive);
      // 前提: 別のインスタンスの Cookie API と start() は鍵の不一致で失敗していること
      expect(await otherError, isA<CookieOperationException>());
      final error = await startError;
      expect(error, isA<StorageIntegrityException>());
      expect((error! as StorageIntegrityException).failure,
          StorageIntegrityFailure.keyMismatch);
      // 鍵と一致しない Box を消していないこと
      expect(boxFile(_quarantineBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values[_keyName], base64Encode(_key(2)));
    });
  });

  group('復旧 API の拒否（鍵を読み直し、消す必要が無いと判定した場合）', () {
    /// 鍵がすべての暗号化 Box と一致する場合は何も消さずに拒否し、start() を再試行できること
    test('rejects recovery when the key matches every encrypted box', () async {
      await storeCookiesWithKey(_key(1), ['SESSION']);
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([1, 2], _quarantineEntry));
      await writeEncryptedBox(
          _droppedBoxName, _key(1), _entries([3], _droppedEntry));
      await Hive.close();
      final names = [_cookieBoxName, _quarantineBoxName, _droppedBoxName];
      final sizesBefore = fileSizes(names);
      // 前提: どの Box も鍵と一致していること
      for (final name in names) {
        expect(await verifyBox(name, _key(1)), HiveBoxVerificationStatus.match,
            reason: name);
      }

      final result = await proxy.recoverEncryptedStorage();

      // start() が成功することを理由に拒否すること
      expectRejected(result, StorageRecoveryRejection.startWillSucceed);
      // Box も鍵も消していないこと
      expect(fileSizes(names), sizesBefore);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));
      // 拒否の理由どおり start() で起動でき、記録が残っていること
      await startProxy();
      expect(await cookieNames(), contains('SESSION'));
      expect(await proxy.getQuarantinedRequests(), hasLength(2));
      expect(await proxy.getDroppedRequests(), hasLength(1));
    });

    /// 最初の読み取りで鍵が無くても、読み直して鍵を読めた場合は消さずに拒否すること
    test('rejects recovery when the key is read again after a transient miss',
        () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      final sizeBefore = boxFile(_quarantineBoxName).lengthSync();
      // 最初の読み取りだけ鍵が無い結果を返す
      keyStorage.scriptedReads.add(null);

      final result = await proxy.recoverEncryptedStorage();

      // 読み直した鍵で照合し、問題が無いため拒否すること
      expectRejected(result, StorageRecoveryRejection.startWillSucceed);
      expect(keyStorage.scriptedReads, isEmpty);
      // Box も鍵も消していないこと
      expect(boxFile(_quarantineBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));
    });

    /// 保護データが利用できない（端末のロック中）場合は、処理を進めれば削除になる状態でも
    /// 何も消さずに拒否すること
    test('rejects recovery while protected data is unavailable', () async {
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      storeKey(_key(2));
      keyStorage.protectedDataAvailable = false;
      final sizeBefore = boxFile(_quarantineBoxName).lengthSync();
      // 前提: start() は一時的に読めないことを理由に失敗していること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.temporarilyUnavailable);

      final result = await proxy.recoverEncryptedStorage();

      // 一時的に読めないことを理由に拒否すること
      expectRejected(result, StorageRecoveryRejection.temporarilyUnavailable);
      // Box も鍵も消していないこと
      expect(boxFile(_quarantineBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values[_keyName], base64Encode(_key(2)));
    });

    /// 読み直した結果が null と例外で入り混じる場合は、一時的とみなして何も消さずに拒否すること
    test('rejects recovery when key reads mix null and errors', () async {
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      final sizeBefore = boxFile(_quarantineBoxName).lengthSync();
      keyStorage.scriptedReads.addAll([null, Exception('keystore')]);
      // 前提: start() も同じ読み取り結果で、一時的に読めないことを理由に失敗していること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.temporarilyUnavailable);
      keyStorage.scriptedReads.addAll([null, Exception('keystore')]);

      final result = await proxy.recoverEncryptedStorage();

      // 一時的に読めないことを理由に拒否すること
      expectRejected(result, StorageRecoveryRejection.temporarilyUnavailable);
      // 用意した読み取り結果を使い切り、読み直した結果で判定したこと
      expect(keyStorage.scriptedReads, isEmpty);
      // Box を消さず、鍵も作っていないこと
      expect(boxFile(_quarantineBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values, isEmpty);
    });

    /// 鍵が無く、中身のある暗号化 Box も無い（0 バイトのファイルだけ）場合は何も消さずに拒否すること
    test('rejects recovery without a key when no encrypted box has content',
        () async {
      boxFile(_queueBoxName).writeAsBytesSync(const <int>[], flush: true);
      boxFile(_quarantineBoxName).writeAsBytesSync(const <int>[], flush: true);

      final result = await proxy.recoverEncryptedStorage();

      // start() が成功することを理由に拒否すること
      expectRejected(result, StorageRecoveryRejection.startWillSucceed);
      // 中身の無いファイルも消さず、鍵も作っていないこと
      expect(boxFile(_queueBoxName).existsSync(), isTrue);
      expect(boxFile(_quarantineBoxName).existsSync(), isTrue);
      expect(keyStorage.values, isEmpty);
      // 拒否の理由どおり、start() は鍵を生成して起動できること
      await startProxy();
      expect(proxy.isRunning, isTrue);
      expect(base64Decode(keyStorage.values[_keyName]!), hasLength(32));
    });

    /// 鍵があり、中身のある暗号化 Box が無い場合は鍵を消さずに拒否すること
    test('rejects recovery with a key when no encrypted box has content',
        () async {
      storeKey(_key(1));

      final result = await proxy.recoverEncryptedStorage();

      // start() が成功することを理由に拒否すること
      expectRejected(result, StorageRecoveryRejection.startWillSucceed);
      // 鍵を消していないこと
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));
      // 拒否の理由どおり、start() は同じ鍵で起動できること
      await startProxy();
      expect(proxy.isRunning, isTrue);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));
    });

    /// 照合を打ち切っていない、先頭が書きかけで一致なし（noMismatch）の業務データの Box は
    /// 問題とみなさず拒否すること
    test('rejects recovery when a business box only stopped in its first frame',
        () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      cutInsideFirstFrame(_quarantineBoxName);
      // 前提: 時間の上限なしで照合しても不一致の根拠が無いこと
      expect(await verifyBox(_quarantineBoxName, _key(1)),
          HiveBoxVerificationStatus.noMismatch);

      final result = await proxy.recoverEncryptedStorage();

      // start() が成功することを理由に拒否し、ファイルを変えていないこと
      expectRejected(result, StorageRecoveryRejection.startWillSucceed);
      expect(boxFile(_quarantineBoxName).lengthSync(), _partialFrameLength);
      // 拒否の理由どおり start() で起動できること
      await startProxy();
      expect(proxy.isRunning, isTrue);
    });

    /// 業務データの Box に問題が無く、Cookie Box だけが鍵と一致しない場合は拒否すること
    test('rejects recovery when only the cookie box does not match the key',
        () async {
      await storeCookiesWithKey(_key(1), ['SESSION']);
      await writeEncryptedBox(
          _quarantineBoxName, _key(2), _entries([0], _quarantineEntry));
      await Hive.close();
      storeKey(_key(2));
      final names = [_cookieBoxName, _quarantineBoxName];
      final sizesBefore = fileSizes(names);
      // 前提: Cookie Box だけが鍵と一致しないこと
      expect(await verifyBox(_cookieBoxName, _key(2)),
          HiveBoxVerificationStatus.mismatch);
      expect(await verifyBox(_quarantineBoxName, _key(2)),
          HiveBoxVerificationStatus.match);

      final result = await proxy.recoverEncryptedStorage();

      // start() が Cookie Box を破棄して続けるため、拒否すること
      expectRejected(result, StorageRecoveryRejection.startWillSucceed);
      // Cookie Box も含めて何も消していないこと
      expect(fileSizes(names), sizesBefore);
      expect(keyStorage.values[_keyName], base64Encode(_key(2)));
    });

    /// 業務データの Box に問題が無く、Cookie Box だけが先頭側で壊れている場合は拒否すること
    test('rejects recovery when only the cookie box is corrupted', () async {
      await storeCookiesWithKey(_key(1), ['SESSION', 'PREFERENCE']);
      final corruptedBytes = corruptFirstFrame(_cookieBoxName);
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      // 前提: Cookie Box だけが破損と判定されること
      expect(await verifyBox(_cookieBoxName, _key(1)),
          HiveBoxVerificationStatus.corrupted);
      expect(await verifyBox(_quarantineBoxName, _key(1)),
          HiveBoxVerificationStatus.match);

      final result = await proxy.recoverEncryptedStorage();

      // start() が Cookie Box を破棄して続けるため、拒否すること
      expectRejected(result, StorageRecoveryRejection.startWillSucceed);
      // Cookie Box を作り直していないこと
      expect(boxFile(_cookieBoxName).readAsBytesSync(), corruptedBytes);
    });

    /// 鍵が無い状態が続いても、中身があるのが Cookie Box だけなら何も消さずに拒否すること
    test('rejects recovery without a key when only the cookie box has content',
        () async {
      await storeCookiesWithKey(_key(1), ['SESSION']);
      keyStorage.values.remove(_keyName);
      final sizeBefore = boxFile(_cookieBoxName).lengthSync();
      // 前提: Cookie Box に中身があること
      expect(sizeBefore, greaterThan(0));

      final result = await proxy.recoverEncryptedStorage();

      // start() が Cookie Box を破棄して続けるため、拒否すること
      expectRejected(result, StorageRecoveryRejection.startWillSucceed);
      // Cookie Box を消さず、鍵も作っていないこと
      expect(boxFile(_cookieBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values, isEmpty);
    });
  });

  group('鍵がある場合の復旧（不一致は削除、破損は作り直し、問題の無い Box と鍵は残す）', () {
    /// 不一致の Box は削除、破損の Box は作り直し、問題の無い Box と鍵は残し、
    /// 同じインスタンスの start() で作り直した Box の後ろ側の記録を読めること
    test(
        'deletes mismatching boxes, rebuilds corrupted ones and keeps the rest',
        () async {
      await storeCookiesWithKey(_key(1), ['SESSION']);
      await writeEncryptedBox(
          _queueBoxName, _key(2), _entries([0], _queueEntry));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([1, 2, 3], _quarantineEntry));
      await writeEncryptedBox(
          _droppedBoxName, _key(1), _entries([4], _droppedEntry));
      await Hive.close();
      final corruptedBytes = corruptFirstFrame(_quarantineBoxName);
      final keptSizes = fileSizes([_cookieBoxName, _droppedBoxName]);
      // 前提: start() が失敗し、Box ごとの照合結果が想定どおりであること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyMismatch);
      expect(error.boxResults, {
        ProxyStorageBox.cookies: StorageBoxCheckResult.match,
        ProxyStorageBox.queue: StorageBoxCheckResult.mismatch,
        ProxyStorageBox.quarantine: StorageBoxCheckResult.corrupted,
        ProxyStorageBox.droppedRequests: StorageBoxCheckResult.match,
      });

      final result = await proxy.recoverEncryptedStorage();

      // Box ごとの扱いを返し、鍵は削除していないこと
      expect(result.performed, isTrue);
      expect(result.rejection, isNull);
      expect(result.deletedBoxes, {ProxyStorageBox.queue});
      expect(result.rebuiltBoxes, {ProxyStorageBox.quarantine});
      expect(result.keptBoxes,
          {ProxyStorageBox.cookies, ProxyStorageBox.droppedRequests});
      expect(result.keyDeleted, isFalse);
      // 不一致の Box のファイルを削除したこと
      expect(boxFile(_queueBoxName).existsSync(), isFalse);
      // 破損の Box は先頭側を捨てて短くなり、先頭が鍵と一致すること
      expect(boxFile(_quarantineBoxName).lengthSync(),
          lessThan(corruptedBytes.length));
      expect(await verifyBox(_quarantineBoxName, _key(1)),
          HiveBoxVerificationStatus.match);
      // 問題の無い Box と鍵はそのまま残すこと
      expect(fileSizes([_cookieBoxName, _droppedBoxName]), keptSizes);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));

      // 同じインスタンスで start() でき、作り直した Box の後ろ側の記録を読めること
      await startProxy();
      expect(proxy.isRunning, isTrue);
      expect(await quarantineIds(),
          unorderedEquals([_storageKey(2), _storageKey(3)]));
      // 残した Box の記録も読め、削除した Box は空であること
      expect(await proxy.getDroppedRequests(), hasLength(1));
      expect(await cookieNames(), contains('SESSION'));
      expect(await proxy.getQueuedRequests(), isEmpty);
    });

    /// 業務データの Box に問題がある場合、鍵と一致しない Cookie Box も同じ規則で削除すること
    test('deletes a mismatching cookie box when a business box has a problem',
        () async {
      await storeCookiesWithKey(_key(1), ['SESSION']);
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      storeKey(_key(2));
      // 前提: Cookie Box と隔離の Box が鍵と一致しないこと
      expect(await verifyBox(_cookieBoxName, _key(2)),
          HiveBoxVerificationStatus.mismatch);
      expect(await verifyBox(_quarantineBoxName, _key(2)),
          HiveBoxVerificationStatus.mismatch);

      final result = await proxy.recoverEncryptedStorage();

      // Cookie Box も削除し、鍵は残すこと
      expect(result.performed, isTrue);
      expect(result.deletedBoxes,
          {ProxyStorageBox.cookies, ProxyStorageBox.quarantine});
      expect(result.rebuiltBoxes, isEmpty);
      expect(result.keyDeleted, isFalse);
      expect(boxFile(_cookieBoxName).existsSync(), isFalse);
      expect(boxFile(_quarantineBoxName).existsSync(), isFalse);
      expect(keyStorage.values[_keyName], base64Encode(_key(2)));
      // 同じインスタンスで start() でき、消した Box は空であること
      await startProxy();
      expect(await cookieNames(), isEmpty);
      expect(await proxy.getQuarantinedRequests(), isEmpty);
    });

    /// 業務データの Box に問題がある場合、先頭側が壊れた Cookie Box も同じ規則で作り直し、
    /// 後ろ側の Cookie を読めること
    test('rebuilds a corrupted cookie box when a business box has a problem',
        () async {
      await storeCookiesWithKey(_key(1), ['SESSION', 'PREFERENCE']);
      corruptFirstFrame(_cookieBoxName);
      await writeEncryptedBox(
          _quarantineBoxName, _key(2), _entries([0], _quarantineEntry));
      await Hive.close();
      // 前提: Cookie Box は破損、隔離の Box は不一致であること
      expect(await verifyBox(_cookieBoxName, _key(1)),
          HiveBoxVerificationStatus.corrupted);
      expect(await verifyBox(_quarantineBoxName, _key(1)),
          HiveBoxVerificationStatus.mismatch);

      final result = await proxy.recoverEncryptedStorage();

      // Cookie Box を作り直し、隔離の Box を削除すること
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.quarantine});
      expect(result.rebuiltBoxes, {ProxyStorageBox.cookies});
      expect(result.keptBoxes, isNot(contains(ProxyStorageBox.cookies)));
      expect(result.keyDeleted, isFalse);
      expect(await verifyBox(_cookieBoxName, _key(1)),
          HiveBoxVerificationStatus.match);
      // 同じインスタンスで start() でき、先頭の Cookie を失い、後ろの Cookie を読めること
      await startProxy();
      expect(await cookieNames(), equals(['PREFERENCE']));
      // 作り直した Cookie Box を start() が破棄していないこと
      expect(
          (await proxy.getDiagnostics()).lastCookieStorageDiscardedAt, isNull);
    });

    /// 照合を打ち切っていない、先頭が書きかけで一致なしの Box は作り直さずに残すこと
    test('keeps a partially written box whose check was not aborted', () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _queueBoxName, _key(2), _entries([0], _queueEntry));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([1], _quarantineEntry));
      await Hive.close();
      cutInsideFirstFrame(_quarantineBoxName);
      // 前提: キューは不一致、隔離は上限なしの照合でも noMismatch であること
      expect(await verifyBox(_queueBoxName, _key(1)),
          HiveBoxVerificationStatus.mismatch);
      expect(await verifyBox(_quarantineBoxName, _key(1)),
          HiveBoxVerificationStatus.noMismatch);

      final result = await proxy.recoverEncryptedStorage();

      // 不一致のキューだけを削除し、書きかけの隔離の Box は問題なしとして残すこと
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.queue});
      expect(result.rebuiltBoxes, isEmpty);
      expect(result.keptBoxes, contains(ProxyStorageBox.quarantine));
      expect(boxFile(_queueBoxName).existsSync(), isFalse);
      expect(boxFile(_quarantineBoxName).lengthSync(), _partialFrameLength);
    });
  });

  group('鍵を使えない状態が続く場合の復旧（暗号化 Box をすべて削除してから鍵を削除）', () {
    /// 鍵の読み取りが常に失敗する場合は、暗号化 Box をすべて削除してから鍵を削除し、
    /// 旧平文 Box は残し、同じインスタンスの start() が新しい鍵で成功すること
    test('deletes every encrypted box and then the key when reads keep failing',
        () async {
      await storeCookiesWithKey(_key(1), ['SESSION']);
      await writeEncryptedBox(
          _queueBoxName, _key(1), _entries([0], _queueEntry));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([1], _quarantineEntry));
      await writePlainBox(_legacyQueueBoxName, _entries([9], _queueEntry));
      await Hive.close();
      final legacySize = boxFile(_legacyQueueBoxName).lengthSync();
      // 移行を遅らせる時間を長くし、テスト中に移行が始まらないようにする
      proxy = createProxy(deferredMigrationDelay: const Duration(hours: 1));
      keyStorage.failReads = true;
      List<String>? boxesLeftAtKeyDeletion;
      keyStorage.onDelete = (_) {
        boxesLeftAtKeyDeletion = _allEncryptedBoxNames
            .where((name) => boxFile(name).existsSync())
            .toList();
      };
      // 前提: start() は鍵を読めないことを理由に失敗し、Box が残っていること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyUnreadable);
      for (final name in [_cookieBoxName, _queueBoxName, _quarantineBoxName]) {
        expect(boxFile(name).existsSync(), isTrue, reason: name);
      }
      final readsBeforeRecovery = keyStorage.readCount;

      final result = await proxy.recoverEncryptedStorage();

      // ファイルのあった暗号化 Box をすべて削除し、鍵も削除したことを返すこと
      expect(result.performed, isTrue);
      expect(result.rejection, isNull);
      expect(result.deletedBoxes, {
        ProxyStorageBox.cookies,
        ProxyStorageBox.queue,
        ProxyStorageBox.quarantine,
      });
      expect(result.rebuiltBoxes, isEmpty);
      expect(result.keptBoxes, isEmpty);
      expect(result.keyDeleted, isTrue);
      // 1 回の失敗で決めず、読み直しても失敗が続くことを確かめたこと
      expect(keyStorage.readCount - readsBeforeRecovery, greaterThan(1));
      // 暗号化 Box のファイルがすべて無いこと
      for (final name in _allEncryptedBoxNames) {
        expect(boxFile(name).existsSync(), isFalse, reason: name);
      }
      // 暗号化 Box を消し終えてから鍵を削除したこと
      expect(boxesLeftAtKeyDeletion, isNotNull);
      expect(boxesLeftAtKeyDeletion, isEmpty);
      expect(keyStorage.values.containsKey(_keyName), isFalse);
      // 旧平文 Box は消していないこと
      expect(boxFile(_legacyQueueBoxName).lengthSync(), legacySize);

      // 読み取りが回復すれば、同じインスタンスで新しい鍵を生成して起動できること
      keyStorage.failReads = false;
      await startProxy();
      expect(proxy.isRunning, isTrue);
      final newKey = keyStorage.values[_keyName];
      expect(base64Decode(newKey!), hasLength(32));
      expect(newKey, isNot(base64Encode(_key(1))));
      // 削除した Box の内容は読めないこと
      expect(await cookieNames(), isEmpty);
      expect(await proxy.getQuarantinedRequests(), isEmpty);
      // 旧平文 Box の移行は遅らせる移行になり、移行を待つ記録として読めること
      final queued = await proxy.getQueuedRequests();
      expect(queued, hasLength(1));
      expect(queued.single.pendingMigration, isTrue);
      expect(boxFile(_legacyQueueBoxName).existsSync(), isTrue);
    });

    /// 鍵が無い状態が読み直しても続く場合は、暗号化 Box をすべて削除して鍵を削除すること
    test('deletes every encrypted box and the key when the key stays missing',
        () async {
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await writeEncryptedBox(
          _droppedBoxName, _key(1), _entries([1], _droppedEntry));
      await Hive.close();
      // 前提: start() は鍵が無いことを理由に失敗していること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyMissing);

      final result = await proxy.recoverEncryptedStorage();

      // ファイルのあった暗号化 Box を削除し、鍵の削除を返すこと
      expect(result.performed, isTrue);
      expect(result.deletedBoxes,
          {ProxyStorageBox.quarantine, ProxyStorageBox.droppedRequests});
      expect(result.rebuiltBoxes, isEmpty);
      expect(result.keptBoxes, isEmpty);
      expect(result.keyDeleted, isTrue);
      expect(boxFile(_quarantineBoxName).existsSync(), isFalse);
      expect(boxFile(_droppedBoxName).existsSync(), isFalse);
      // 同じインスタンスで start() が新しい鍵を生成して起動できること
      await startProxy();
      expect(proxy.isRunning, isTrue);
      expect(base64Decode(keyStorage.values[_keyName]!), hasLength(32));
      expect(await proxy.getDroppedRequests(), isEmpty);
    });

    /// 鍵の形式が正しくない場合は、暗号化 Box をすべて削除して鍵を削除すること
    test('deletes every encrypted box and the key when the key is invalid',
        () async {
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      keyStorage.values[_keyName] = base64Encode(List<int>.filled(8, 1));
      // 前提: start() は鍵の形式不正を理由に失敗していること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyInvalid);

      final result = await proxy.recoverEncryptedStorage();

      // 暗号化 Box を削除し、形式不正の鍵も削除すること
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.quarantine});
      expect(result.keyDeleted, isTrue);
      expect(boxFile(_quarantineBoxName).existsSync(), isFalse);
      expect(keyStorage.values.containsKey(_keyName), isFalse);
      // 同じインスタンスで start() が新しい鍵を生成して起動できること
      await startProxy();
      expect(proxy.isRunning, isTrue);
      expect(base64Decode(keyStorage.values[_keyName]!), hasLength(32));
    });
  });

  group('照合打ち切りの Box の復旧（時間の上限なしで走査し直す）', () {
    /// 照合打ち切りで start() が失敗した Box に鍵と一致する記録が無ければ、0 バイトに
    /// 切り詰めて作り直した Box として返し、同じ時間の上限のまま start() が成功すること
    test('truncates an aborted box without a matching record', () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      cutInsideFirstFrame(_quarantineBoxName);
      proxy = createProxy(verificationTimeLimit: Duration.zero);
      // 前提: 起動時の照合は打ち切りで失敗し、上限なしなら noMismatch になること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.verificationAborted);
      expect(error.boxResults[ProxyStorageBox.quarantine],
          StorageBoxCheckResult.aborted);
      expect(boxFile(_quarantineBoxName).lengthSync(), _partialFrameLength);
      expect(await verifyBox(_quarantineBoxName, _key(1)),
          HiveBoxVerificationStatus.noMismatch);

      final result = await proxy.recoverEncryptedStorage();

      // 作り直した Box として返し、削除や鍵の削除はしないこと
      expect(result.performed, isTrue);
      expect(result.rebuiltBoxes, {ProxyStorageBox.quarantine});
      expect(result.deletedBoxes, isEmpty);
      expect(result.keptBoxes, isNot(contains(ProxyStorageBox.quarantine)));
      expect(result.keyDeleted, isFalse);
      // ファイルは残し、0 バイトに切り詰めたこと
      expect(boxFile(_quarantineBoxName).existsSync(), isTrue);
      expect(boxFile(_quarantineBoxName).lengthSync(), 0);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));
      // 同じ時間の上限のまま、同じインスタンスで start() できること
      await startProxy();
      expect(proxy.isRunning, isTrue);
      expect(await proxy.getQuarantinedRequests(), isEmpty);
    });

    /// 照合打ち切りの Box が別の鍵で書かれていれば、上限なしの走査で不一致と判定して削除すること
    test('deletes an aborted box that was written with another key', () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _quarantineBoxName, _key(2), _entries([0], _quarantineEntry));
      await Hive.close();
      proxy = createProxy(verificationTimeLimit: Duration.zero);
      // 前提: 起動時の照合は打ち切りで失敗していること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.verificationAborted);
      expect(error.boxResults[ProxyStorageBox.quarantine],
          StorageBoxCheckResult.aborted);

      final result = await proxy.recoverEncryptedStorage();

      // 不一致として削除し、鍵は残すこと
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.quarantine});
      expect(result.rebuiltBoxes, isEmpty);
      expect(result.keyDeleted, isFalse);
      expect(boxFile(_quarantineBoxName).existsSync(), isFalse);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));
      // 同じインスタンスで start() できること
      await startProxy();
      expect(proxy.isRunning, isTrue);
    });

    /// 照合打ち切りの Box の先頭側が壊れていれば、上限なしの走査で破損と判定して作り直すこと
    test('rebuilds an aborted box whose head is corrupted', () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([1, 2, 3], _quarantineEntry));
      await Hive.close();
      corruptFirstFrame(_quarantineBoxName);
      proxy = createProxy(verificationTimeLimit: Duration.zero);
      // 前提: 起動時の照合は打ち切りで失敗していること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.verificationAborted);

      final result = await proxy.recoverEncryptedStorage();

      // 破損として作り直すこと
      expect(result.performed, isTrue);
      expect(result.rebuiltBoxes, {ProxyStorageBox.quarantine});
      expect(result.deletedBoxes, isEmpty);
      expect(result.keyDeleted, isFalse);
      // 同じインスタンスで start() でき、後ろ側の記録を読めること
      await startProxy();
      expect(await quarantineIds(),
          unorderedEquals([_storageKey(2), _storageKey(3)]));
    });
  });

  group('残骸の .hivec と復旧の再実行', () {
    /// .hive がある暗号化 Box に残った .hivec を削除し、.hive はそのまま残すこと
    test('deletes leftover .hivec files of encrypted boxes', () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _queueBoxName, _key(2), _entries([0], _queueEntry));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([1], _quarantineEntry));
      await writeEncryptedBox(
          _droppedBoxName, _key(1), _entries([2], _droppedEntry));
      await Hive.close();
      final names = [_quarantineBoxName, _droppedBoxName];
      // 作り直しの置き換え前に止まった残骸を置く
      for (final name in names) {
        compactedFile(name).writeAsBytesSync(
            boxFile(name).readAsBytesSync().sublist(1),
            flush: true);
      }
      final sizesBefore = fileSizes(names);
      // 前提: start() は失敗し、残骸がそのまま残っていること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyMismatch);
      for (final name in names) {
        expect(compactedFile(name).existsSync(), isTrue, reason: name);
      }

      final result = await proxy.recoverEncryptedStorage();

      // 問題の無い Box として残すこと
      expect(result.performed, isTrue);
      expect(
          result.keptBoxes,
          containsAll(
              [ProxyStorageBox.quarantine, ProxyStorageBox.droppedRequests]));
      // 残骸の .hivec を削除し、.hive は変えていないこと
      for (final name in names) {
        expect(compactedFile(name).existsSync(), isFalse, reason: name);
      }
      expect(fileSizes(names), sizesBefore);
      // 同じインスタンスで start() でき、残した Box の記録を読めること
      await startProxy();
      expect(await proxy.getQuarantinedRequests(), hasLength(1));
      expect(await proxy.getDroppedRequests(), hasLength(1));
    });

    /// 前回の作り直しが .hivec を書きかけのまま止まっていても、再実行すれば同じ結果になること
    test('rebuilds the same way after a rebuild stopped before replacing',
        () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([1, 2, 3], _quarantineEntry));
      await Hive.close();
      final corruptedBytes = corruptFirstFrame(_quarantineBoxName);
      // 作り直しの書き写しが途中で止まった状態を再現する（元の .hive は残っている）
      compactedFile(_quarantineBoxName).writeAsBytesSync(
          corruptedBytes.sublist(corruptedBytes.length ~/ 2),
          flush: true);
      // 前提: start() は破損で失敗し、元の .hive と書きかけの .hivec が残っていること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.corrupted);
      expect(boxFile(_quarantineBoxName).readAsBytesSync(), corruptedBytes);
      expect(compactedFile(_quarantineBoxName).existsSync(), isTrue);

      final result = await proxy.recoverEncryptedStorage();

      // 残骸が無い場合と同じく作り直すこと
      expect(result.performed, isTrue);
      expect(result.rebuiltBoxes, {ProxyStorageBox.quarantine});
      expect(result.deletedBoxes, isEmpty);
      expect(compactedFile(_quarantineBoxName).existsSync(), isFalse);
      expect(await verifyBox(_quarantineBoxName, _key(1)),
          HiveBoxVerificationStatus.match);
      // 同じインスタンスで start() でき、後ろ側の記録を読めること
      await startProxy();
      expect(await quarantineIds(),
          unorderedEquals([_storageKey(2), _storageKey(3)]));
    });

    /// 作り直しの途中で失敗した場合は StorageRecoveryException を送出して元の .hive を残し、
    /// 原因を取り除いて再実行すれば作り直せること
    test('keeps the original file when a rebuild fails and rebuilds on retry',
        () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _queueBoxName, _key(2), _entries([0], _queueEntry));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([1, 2, 3], _quarantineEntry));
      await Hive.close();
      final corruptedBytes = corruptFirstFrame(_quarantineBoxName);
      // 作り直しの書き出し先（.hivec）にディレクトリを置き、書き写しを失敗させる
      final blocker = Directory(compactedFile(_quarantineBoxName).path)
        ..createSync();

      Object? failure;
      try {
        await proxy.recoverEncryptedStorage();
      } catch (error) {
        failure = error;
      }

      // 失敗を StorageRecoveryException で知らせ、元のエラーを持つこと
      expect(failure, isA<StorageRecoveryException>());
      expect((failure! as StorageRecoveryException).error,
          isA<FileSystemException>());
      // 作り直す前の .hive をそのまま残し、鍵も残していること
      expect(boxFile(_quarantineBoxName).readAsBytesSync(), corruptedBytes);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));

      blocker.deleteSync();
      final retried = await proxy.recoverEncryptedStorage();

      // 再実行で作り直し、先頭が鍵と一致すること
      expect(retried.performed, isTrue);
      expect(retried.rebuiltBoxes, {ProxyStorageBox.quarantine});
      expect(retried.keyDeleted, isFalse);
      expect(boxFile(_queueBoxName).existsSync(), isFalse);
      expect(await verifyBox(_quarantineBoxName, _key(1)),
          HiveBoxVerificationStatus.match);
      // 同じインスタンスで start() でき、後ろ側の記録を読めること
      await startProxy();
      expect(await quarantineIds(),
          unorderedEquals([_storageKey(2), _storageKey(3)]));
    });

    /// 鍵を残す復旧の直後にもう一度呼ぶと、消す必要が無いため拒否し、何も変えないこと
    test('rejects a second recovery after a recovery that kept the key',
        () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _queueBoxName, _key(2), _entries([0], _queueEntry));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([1, 2, 3], _quarantineEntry));
      await Hive.close();
      corruptFirstFrame(_quarantineBoxName);
      final first = await proxy.recoverEncryptedStorage();
      // 前提: 1 回目は削除と作り直しを行ったこと
      expect(first.performed, isTrue);
      expect(first.deletedBoxes, {ProxyStorageBox.queue});
      expect(first.rebuiltBoxes, {ProxyStorageBox.quarantine});
      final rebuiltBytes = boxFile(_quarantineBoxName).readAsBytesSync();

      final second = await proxy.recoverEncryptedStorage();

      // start() が成功することを理由に拒否すること
      expectRejected(second, StorageRecoveryRejection.startWillSucceed);
      // 1 回目の結果から何も変えていないこと
      expect(boxFile(_quarantineBoxName).readAsBytesSync(), rebuiltBytes);
      expect(boxFile(_queueBoxName).existsSync(), isFalse);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));
    });

    /// 鍵を削除する復旧の直後にもう一度呼ぶと、消す必要が無いため拒否し、鍵も作らないこと
    test('rejects a second recovery after a recovery that deleted the key',
        () async {
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      await Hive.close();
      keyStorage.failReads = true;
      final first = await proxy.recoverEncryptedStorage();
      // 前提: 1 回目は暗号化 Box と鍵を削除したこと
      expect(first.performed, isTrue);
      expect(first.keyDeleted, isTrue);

      final second = await proxy.recoverEncryptedStorage();

      // start() が成功することを理由に拒否し、鍵も作っていないこと
      expectRejected(second, StorageRecoveryRejection.startWillSucceed);
      expect(keyStorage.values, isEmpty);
      // 読み取りが回復すれば、同じインスタンスで start() できること
      keyStorage.failReads = false;
      await startProxy();
      expect(proxy.isRunning, isTrue);
    });
  });

  group('復旧後に同じインスタンスで start() できること（プロセスの再起動なし）', () {
    /// 一度起動して停止した後に鍵が置き換わり start() が失敗しても、復旧すれば
    /// 同じインスタンスで start() が成功すること（共有していた初期化の結果を捨てること）
    test('starts again after a previous run, a key change and a recovery',
        () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0, 1], _quarantineEntry));
      await Hive.close();
      await startProxy();
      // 前提: 一度は起動でき、隔離の記録を読めたこと
      expect(await proxy.getQuarantinedRequests(), hasLength(2));
      await proxy.stop();
      // 停止中に鍵が別の値へ置き換わった状態を再現する
      storeKey(_key(2));
      // 前提: 同じインスタンスの start() は鍵の不一致で失敗すること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyMismatch);

      final result = await proxy.recoverEncryptedStorage();

      // 鍵と一致しない隔離の Box だけを削除すること
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.quarantine});
      expect(result.rebuiltBoxes, isEmpty);
      expect(result.keyDeleted, isFalse);
      // 同じインスタンスで、置き換わった鍵のまま start() できること
      await startProxy();
      expect(proxy.isRunning, isTrue);
      expect(await proxy.getQuarantinedRequests(), isEmpty);
      expect(keyStorage.values[_keyName], base64Encode(_key(2)));
    });

    /// Cookie API の初期化で Cookie Box を開いたインスタンスでも、Box を閉じてから処理し、
    /// 同じインスタンスで start() して Cookie を読めること
    test('closes the cookie box opened by a cookie API and starts again',
        () async {
      storeKey(_key(1));
      await proxy.restoreCookies([_cookie('SESSION')]);
      // 前提: Cookie API の初期化で Cookie Box が開いていること
      expect(Hive.isBoxOpen(_cookieBoxName), isTrue);
      // 鍵と一致しない業務データの Box が置かれた状態を再現する
      await writeEncryptedBox(
          _quarantineBoxName, _key(2), _entries([0], _quarantineEntry));

      final result = await proxy.recoverEncryptedStorage();

      // 不一致の Box を削除し、Cookie Box は残すこと
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.quarantine});
      expect(result.keptBoxes, contains(ProxyStorageBox.cookies));
      // 削除や作り直しの前に proxy の Box を閉じたこと
      expect(Hive.isBoxOpen(_cookieBoxName), isFalse);
      // 同じインスタンスで start() でき、Cookie を読めること
      await startProxy();
      expect(proxy.isRunning, isTrue);
      expect(await cookieNames(), contains('SESSION'));
    });

    /// 別のインスタンスが開いている暗号化 Box も閉じてから削除し、start() が成功すること
    test('closes an encrypted box opened by another instance before deleting',
        () async {
      storeKey(_key(1));
      final other = createProxy();
      await other.restoreCookies([_cookie('SESSION')]);
      // 前提: 別のインスタンスが Cookie Box を開いていること
      expect(Hive.isBoxOpen(_cookieBoxName), isTrue);
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));
      // 鍵が置き換わり、Cookie Box と隔離の Box が鍵と一致しなくなった状態を再現する
      storeKey(_key(2));

      final result = await proxy.recoverEncryptedStorage();

      // 開いていた Cookie Box も閉じて削除すること
      expect(result.performed, isTrue);
      expect(result.deletedBoxes,
          {ProxyStorageBox.cookies, ProxyStorageBox.quarantine});
      expect(Hive.isBoxOpen(_cookieBoxName), isFalse);
      expect(boxFile(_cookieBoxName).existsSync(), isFalse);
      // このインスタンスで start() でき、削除した Cookie は読めないこと
      await startProxy();
      expect(proxy.isRunning, isTrue);
      expect(await cookieNames(), isEmpty);
    });
  });

  group('復旧 API と別のインスタンス・起動の重なり', () {
    /// 別のインスタンスが稼働中は、呼び出したインスタンスが稼働していなくても、処理を進めれば
    /// 全削除になる状態で何も消さずに proxyActive で拒否し、そのインスタンスの停止後は復旧を行うこと
    test('rejects recovery while another instance is running', () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0, 1], _quarantineEntry));
      await Hive.close();
      final other = createProxy();
      addTearDown(() async {
        if (other.isRunning) {
          await other.stop();
        }
      });
      await other.start(config: const ProxyConfig(origin: _origin));
      // 前提: 別のインスタンスが稼働し、隔離の記録を読めること
      expect(other.isRunning, isTrue);
      expect(await other.getQuarantinedRequests(), hasLength(2));
      final sizeBefore = boxFile(_quarantineBoxName).lengthSync();
      // 処理を進めれば全削除になる状態（鍵の読み取りが常に失敗）にする
      keyStorage.failReads = true;

      final result = await proxy.recoverEncryptedStorage();

      // 呼び出したインスタンスは稼働していなくても、稼働中のインスタンスを理由に拒否すること
      expect(proxy.isRunning, isFalse);
      expectRejected(result, StorageRecoveryRejection.proxyActive);
      // Box も鍵も消していないこと
      expect(boxFile(_quarantineBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));
      // 別のインスタンスの Box を閉じておらず、稼働を続けて記録を読めること
      expect(Hive.isBoxOpen(_quarantineBoxName), isTrue);
      expect(other.isRunning, isTrue);
      expect(await other.getQuarantinedRequests(), hasLength(2));

      // 別のインスタンスが停止した後は、同じ状態で復旧を行うこと（拒否の理由が稼働中だったこと）
      await other.stop();
      final retried = await proxy.recoverEncryptedStorage();
      expect(retried.performed, isTrue);
      expect(retried.keyDeleted, isTrue);
    });

    /// 復旧の後に Cookie API で段階 1 を済ませてから start() しても、段階 2 が鍵の無いことで
    /// 失敗せずに起動でき、Cookie と残した Box の記録を読めること
    test('starts after a cookie API runs stage 1 following a recovery',
        () async {
      storeKey(_key(1));
      await writeEncryptedBox(
          _queueBoxName, _key(2), _entries([0], _queueEntry));
      await writeEncryptedBox(
          _droppedBoxName, _key(1), _entries([1], _droppedEntry));
      await Hive.close();
      // 前提: start() は鍵の不一致で失敗し、復旧で不一致の Box だけを削除したこと
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyMismatch);
      final result = await proxy.recoverEncryptedStorage();
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.queue});

      // 復旧の後、start() より先に Cookie API で段階 1 を済ませる
      await proxy.restoreCookies([_cookie('SESSION')]);
      final startError = await _errorOf(startProxy());

      // 段階 2 が失敗せず、起動できること
      expect(startError, isNull);
      expect(proxy.isRunning, isTrue);
      // 段階 1 で復元した Cookie と、残した Box の記録を読めること
      expect(await cookieNames(), contains('SESSION'));
      expect(await proxy.getDroppedRequests(), hasLength(1));
      expect(await proxy.getQueuedRequests(), isEmpty);
    });

    /// 段階 1 を済ませたインスタンスで、復旧が鍵を読んでいる間に start() を呼んでも、復旧が捨てた鍵を
    /// 段階 2 で使おうとして失敗せず、復旧の結果の上で起動できること
    test('starts when start() is called while a recovery is in progress',
        () async {
      storeKey(_key(1));
      await proxy.restoreCookies([_cookie('SESSION')]);
      // 前提: Cookie API で段階 1 が完了し、Cookie Box が開いていること
      expect(Hive.isBoxOpen(_cookieBoxName), isTrue);
      // 鍵と一致しない業務データの Box が置かれた状態を再現する
      await writeEncryptedBox(
          _quarantineBoxName, _key(2), _entries([0], _quarantineEntry));
      final readGate = Completer<void>();
      final readEntered = Completer<void>();
      keyStorage
        ..readGate = readGate
        ..readEntered = readEntered;
      addTearDown(() {
        if (!readGate.isCompleted) {
          readGate.complete();
        }
      });

      final recovery = proxy.recoverEncryptedStorage();
      await readEntered.future;
      // 復旧が初期化のロックを持ったまま鍵の読み取りで止まっている間に start() を呼ぶ
      final startError = _errorOf(startProxy());
      keyStorage.readGate = null;
      readGate.complete();
      final result = await recovery;

      // 前提: 復旧は start() より先に始まっていたため、不一致の Box を削除したこと
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.quarantine});
      // start() は失敗せずに起動できること
      expect(await startError, isNull);
      expect(proxy.isRunning, isTrue);
      // 段階 1 をやり直して開いた Cookie Box の Cookie を読め、削除した Box は空であること
      expect(await cookieNames(), contains('SESSION'));
      expect(await proxy.getQuarantinedRequests(), isEmpty);
    });

    /// 段階 1 を済ませた別のインスタンス B が、A の復旧が鍵を読んでいる間に start() しても、
    /// 復旧の後の鍵（K2）で段階 1 からやり直して起動し、古い鍵（K1）で業務データの Box を作らないこと
    test('another instance starts with the current key after a recovery',
        () async {
      final instanceB = createProxy();
      addTearDown(() async {
        if (instanceB.isRunning) {
          await instanceB.stop();
        }
      });
      storeKey(_key(1));
      await instanceB.restoreCookies([_cookie('SESSION')]);
      // 前提: B が鍵 K1 で段階 1 を済ませ、Cookie Box を開いていること
      expect(Hive.isBoxOpen(_cookieBoxName), isTrue);
      await writeEncryptedBox(
          _queueBoxName, _key(1), _entries([0], _queueEntry));
      storeKey(_key(2));
      // 前提: A の start() は鍵の不一致で失敗すること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyMismatch);
      expect(error.boxResults[ProxyStorageBox.queue],
          StorageBoxCheckResult.mismatch);

      final readGate = Completer<void>();
      final readEntered = Completer<void>();
      keyStorage
        ..readGate = readGate
        ..readEntered = readEntered;
      addTearDown(() {
        if (!readGate.isCompleted) {
          readGate.complete();
        }
      });

      final recovery = proxy.recoverEncryptedStorage();
      await readEntered.future;
      // A の復旧が初期化のロックを持ったまま鍵の読み取りで止まっている間に、B の start() を呼ぶ
      final startErrorB = _errorOf(
        instanceB.start(config: const ProxyConfig(origin: _origin)),
      );
      keyStorage.readGate = null;
      readGate.complete();
      final result = await recovery;

      // 前提: 復旧は K2 と一致しない Box（Cookie とキュー）を削除し、鍵を残したこと
      expect(result.performed, isTrue);
      expect(result.deletedBoxes,
          {ProxyStorageBox.cookies, ProxyStorageBox.queue});
      expect(result.keyDeleted, isFalse);
      // B の start() は失敗せずに起動できること
      expect(await startErrorB, isNull);
      expect(instanceB.isRunning, isTrue);

      // B が開いたキューの暗号化 Box へ 1 件入れ、閉じてから現在の鍵（K2）と照合する
      await Hive.box(_queueBoxName).put(_storageKey(5), {
        ..._queueEntry(5),
        'nextRetryAt': DateTime(2099).toIso8601String(),
      });
      await instanceB.stop();
      await Hive.close();
      // B は現在の鍵でキューの Box を書いていること
      expect(await verifyBox(_queueBoxName, _key(2)),
          HiveBoxVerificationStatus.match);

      // 新しいインスタンスは照合で失敗せずに起動し、B が入れた記録を読めること
      proxy = createProxy();
      final startErrorC = await _errorOf(startProxy());
      expect(startErrorC, isNull);
      expect(
        (await proxy.getQueuedRequests()).map((request) => request.url),
        ['$_origin/api/sales/5'],
      );
    });

    /// 鍵を読めない状態が続く場合の復旧が、暗号化 Box を削除した後の鍵の削除で失敗しても、段階 1 を
    /// 済ませていた別のインスタンス B の start() は古い鍵（K1）のまま段階 2 を進めず、段階 1 から
    /// やり直して起動すること。鍵を読めず中身のある暗号化 Box も無いため、判定表どおり新しい鍵を
    /// 書き、その鍵でキューの Box を作ること
    test('another instance redoes stage 1 after a recovery failed midway',
        () async {
      final instanceB = createProxy();
      addTearDown(() async {
        if (instanceB.isRunning) {
          await instanceB.stop();
        }
      });
      storeKey(_key(1));
      await instanceB.restoreCookies([_cookie('SESSION')]);
      // 前提: B が鍵 K1 で段階 1 を済ませ、Cookie Box を開いていること
      expect(Hive.isBoxOpen(_cookieBoxName), isTrue);
      await writeEncryptedBox(
          _quarantineBoxName, _key(1), _entries([0], _quarantineEntry));

      // 鍵の読み取りが失敗し続ける状態にし、鍵の削除も失敗させる
      keyStorage.failReads = true;
      List<String>? boxesLeftAtKeyDeletion;
      keyStorage.onDelete = (_) {
        boxesLeftAtKeyDeletion = _allEncryptedBoxNames
            .where((name) => boxFile(name).existsSync())
            .toList();
        throw Exception('keystore delete failed');
      };
      final readGate = Completer<void>();
      final readEntered = Completer<void>();
      keyStorage
        ..readGate = readGate
        ..readEntered = readEntered;
      addTearDown(() {
        if (!readGate.isCompleted) {
          readGate.complete();
        }
      });

      final recoveryError = _errorOf(proxy.recoverEncryptedStorage());
      await readEntered.future;
      // A の復旧が初期化のロックを持ったまま鍵の読み取りで止まっている間に、B の start() を呼ぶ
      final startErrorB = _errorOf(
        instanceB.start(config: const ProxyConfig(origin: _origin)),
      );
      keyStorage.readGate = null;
      readGate.complete();

      // 前提: 復旧は暗号化 Box をすべて削除した後、鍵の削除で失敗したこと
      expect(await recoveryError, isA<StorageRecoveryException>());
      expect(boxesLeftAtKeyDeletion, isNotNull);
      expect(boxesLeftAtKeyDeletion, isEmpty);
      expect(keyStorage.values[_keyName], base64Encode(_key(1)));

      // B の start() は失敗せずに起動すること
      expect(await startErrorB, isNull);
      expect(instanceB.isRunning, isTrue);
      // B は段階 1 をやり直し、読めない鍵に代わる新しい鍵を書いたこと
      final newKey = keyStorage.values[_keyName]!;
      expect(base64Decode(newKey), hasLength(32));
      expect(newKey, isNot(base64Encode(_key(1))));

      // B が開いたキューの暗号化 Box へ 1 件入れ、閉じてから新しい鍵と照合する
      await Hive.box(_queueBoxName).put(_storageKey(5), {
        ..._queueEntry(5),
        'nextRetryAt': DateTime(2099).toIso8601String(),
      });
      await instanceB.stop();
      await Hive.close();
      // B は新しい鍵でキューの Box を書いていること
      expect(await verifyBox(_queueBoxName, base64Decode(newKey)),
          HiveBoxVerificationStatus.match);

      // 読み取りが回復した後の新しいインスタンスは照合で失敗せずに起動し、B が入れた記録を読めること
      keyStorage
        ..failReads = false
        ..onDelete = null;
      proxy = createProxy();
      final startErrorC = await _errorOf(startProxy());
      expect(startErrorC, isNull);
      expect(
        (await proxy.getQueuedRequests()).map((request) => request.url),
        ['$_origin/api/sales/5'],
      );
    });

    /// 保存領域の初期化（段階 2 まで）を済ませたまま起動に失敗したインスタンス S が、別のインスタンス R の
    /// 復旧が鍵を読んでいる間に start() しても、復旧が閉じた Box や古い初期化の結果のまま稼働せず、
    /// 復旧の後の鍵で保存領域を開き直して起動すること
    test('an instance with a finished stage 2 reopens storage after a recovery',
        () async {
      storeKey(_key(1));
      final instanceS = createProxy();
      addTearDown(() async {
        if (instanceS.isRunning) {
          await instanceS.stop();
        }
      });
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(occupied.close);

      // 保存領域の初期化の後でポートの確保に失敗させ、S に段階 2 の結果を残す
      final bindError = await _errorOf(instanceS.start(
        config: ProxyConfig(origin: _origin, port: occupied.port),
      ));
      // 前提: S は保存領域を開いたまま、稼働していないこと
      expect(bindError, isA<ProxyStartException>());
      expect(bindError, isNot(isA<StorageIntegrityException>()));
      expect(instanceS.isRunning, isFalse);
      expect(Hive.isBoxOpen(_queueBoxName), isTrue);

      // S が開いたキューの Box に K1 で記録を置き、鍵を K2 に置き換えて業務データと合わない状態にする
      await Hive.box(_queueBoxName).put(_storageKey(0), {
        ..._queueEntry(0),
        'nextRetryAt': DateTime(2099).toIso8601String(),
      });
      await Hive.box(_queueBoxName).flush();
      storeKey(_key(2));
      // 前提: R の start() は鍵の不一致で失敗すること
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyMismatch);
      expect(error.boxResults[ProxyStorageBox.queue],
          StorageBoxCheckResult.mismatch);

      final readGate = Completer<void>();
      final readEntered = Completer<void>();
      keyStorage
        ..readGate = readGate
        ..readEntered = readEntered;
      addTearDown(() {
        if (!readGate.isCompleted) {
          readGate.complete();
        }
      });

      final recovery = proxy.recoverEncryptedStorage();
      await readEntered.future;
      // R の復旧が初期化のロックを持ったまま鍵の読み取りで止まっている間に、S の start() を呼ぶ
      final startErrorS = _errorOf(
        instanceS.start(config: const ProxyConfig(origin: _origin)),
      );
      keyStorage.readGate = null;
      readGate.complete();
      final result = await recovery;

      // 復旧を行い、K2 と一致しないキューの Box を削除したこと
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.queue});
      expect(result.keyDeleted, isFalse);
      // S の start() は成功すること
      expect(await startErrorS, isNull);
      expect(instanceS.isRunning, isTrue);
      // S は復旧が閉じた Box のまま稼働しておらず、保存領域を開き直していること
      expect(Hive.isBoxOpen(_queueBoxName), isTrue);
      expect(Hive.isBoxOpen(_quarantineBoxName), isTrue);
      expect(await instanceS.getQueuedRequests(), isEmpty);

      // S が開いたキューの Box へ 1 件入れ、閉じてから現在の鍵（K2）と照合する
      await Hive.box(_queueBoxName).put(_storageKey(5), {
        ..._queueEntry(5),
        'nextRetryAt': DateTime(2099).toIso8601String(),
      });
      await instanceS.stop();
      await Hive.close();
      // S は現在の鍵でキューの Box を書いていること
      expect(await verifyBox(_queueBoxName, _key(2)),
          HiveBoxVerificationStatus.match);

      // 新しいインスタンスは照合で失敗せずに起動し、S が入れた記録を読めること
      proxy = createProxy();
      final startErrorC = await _errorOf(startProxy());
      expect(startErrorC, isNull);
      expect(
        (await proxy.getQueuedRequests()).map((request) => request.url),
        ['$_origin/api/sales/5'],
      );
    });

    /// 保存領域の初期化（段階 2 まで）を済ませたまま起動に失敗したインスタンスで、復旧 API が鍵を読んで
    /// いる間に同じインスタンスの start() を呼んでも、完了済みの初期化の結果のまま稼働せず、ロックの中で
    /// 確かめ直して起動し、起動後の Cookie API も使えること
    test(
        'the same instance starts after re-checking storage during its recovery',
        () async {
      storeKey(_key(1));
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(occupied.close);

      // 保存領域の初期化の後でポートの確保に失敗させ、段階 2 の結果を残す
      final bindError = await _errorOf(proxy.start(
        config: ProxyConfig(origin: _origin, port: occupied.port),
      ));
      // 前提: 保存領域を開いたまま、稼働していないこと
      expect(bindError, isA<ProxyStartException>());
      expect(bindError, isNot(isA<StorageIntegrityException>()));
      expect(proxy.isRunning, isFalse);
      expect(Hive.isBoxOpen(_queueBoxName), isTrue);

      // 開いているキューの Box に K1 で記録を置き、鍵を K2 に置き換えて業務データと合わない状態にする
      await Hive.box(_queueBoxName).put(_storageKey(0), {
        ..._queueEntry(0),
        'nextRetryAt': DateTime(2099).toIso8601String(),
      });
      await Hive.box(_queueBoxName).flush();
      storeKey(_key(2));
      // 前提: キューの Box のファイルは K2 と一致しないこと。完了済みの初期化の結果を残したまま確かめる
      // ため、start() ではなくファイルを照合する
      expect(await verifyBox(_queueBoxName, _key(2)),
          HiveBoxVerificationStatus.mismatch);

      final readGate = Completer<void>();
      final readEntered = Completer<void>();
      keyStorage
        ..readGate = readGate
        ..readEntered = readEntered;
      addTearDown(() {
        if (!readGate.isCompleted) {
          readGate.complete();
        }
      });

      final recovery = proxy.recoverEncryptedStorage();
      await readEntered.future;
      // 復旧が初期化のロックを持ったまま鍵の読み取りで止まっている間に、同じインスタンスの start() を呼ぶ
      final startError = _errorOf(startProxy());
      keyStorage.readGate = null;
      readGate.complete();
      final result = await recovery;

      // 復旧を行い、K2 と一致しないキューの Box を削除したこと
      expect(result.performed, isTrue);
      expect(result.deletedBoxes, {ProxyStorageBox.queue});
      expect(result.keyDeleted, isFalse);
      // start() は成功し、復旧が閉じた Box のまま稼働せず、保存領域を開き直していること
      expect(await startError, isNull);
      expect(proxy.isRunning, isTrue);
      expect(Hive.isBoxOpen(_queueBoxName), isTrue);
      expect(await proxy.getQueuedRequests(), isEmpty);
      // 起動後の Cookie API も使えること
      expect(await proxy.getCookies(), isEmpty);

      // キューの Box へ 1 件入れ、閉じてから現在の鍵（K2）と照合する
      await Hive.box(_queueBoxName).put(_storageKey(5), {
        ..._queueEntry(5),
        'nextRetryAt': DateTime(2099).toIso8601String(),
      });
      await proxy.stop();
      await Hive.close();
      // 現在の鍵でキューの Box を書いていること
      expect(await verifyBox(_queueBoxName, _key(2)),
          HiveBoxVerificationStatus.match);

      // 次のインスタンスは照合で失敗せずに起動し、入れた記録を読めること
      proxy = createProxy();
      final nextStartError = await _errorOf(startProxy());
      expect(nextStartError, isNull);
      expect(
        (await proxy.getQueuedRequests()).map((request) => request.url),
        ['$_origin/api/sales/5'],
      );
    });
  });
}
