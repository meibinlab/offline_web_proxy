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

/// Cookie の暗号化 Box の名前。
const String _cookieBoxName = 'proxy_cookies_secure';

/// キューの暗号化 Box の名前。
const String _queueBoxName = 'proxy_queue_secure';

/// 起動に使う上流 origin。これらのテストでは上流へ接続しない。
const String _origin = 'https://example.com';

/// テスト用の鍵を作る。
///
/// [seed] 鍵ごとに変える値。
///
/// Returns: 32 バイトの鍵。
List<int> _key(int seed) =>
    List<int>.generate(32, (index) => (index * 7 + seed) & 0xff);

/// キューに保存される形のデータを作る。
///
/// [index] 項目ごとに変える値。
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

/// 読み取りの結果と保護データの状態を操作できる secure storage。
class _FakeKeyStorage implements EncryptionKeyStorage {
  /// 保存されている値。
  final Map<String, String> values = {};

  /// 先頭から順に使う読み取り結果。文字列か `null` を返し、[Exception] は送出する。
  /// 使い切った後は [values] を読む。
  final List<Object?> scriptedReads = [];

  /// 書き込みを失敗させるかどうか。
  bool failWrites = false;

  /// 保護データの利用可否。`null` は iOS / macOS 以外を表す。
  bool? protectedDataAvailable;

  @override
  Future<String?> read(String key) async {
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
    if (failWrites) {
      throw Exception('write failed');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
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
  /// [verificationTimeLimit] 照合の走査を打ち切る時間の上限。
  OfflineWebProxy createProxy({Duration? verificationTimeLimit}) {
    return OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks(
      keyStorage: keyStorage,
      keyRereadInterval: Duration.zero,
      verificationTimeLimit: verificationTimeLimit,
    ));
  }

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_storage_integrity')
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

  /// Box のファイルを返す。
  File boxFile(String name) =>
      File('$hiveTestDirectory${Platform.pathSeparator}$name.hive');

  /// 暗号化 Box を直接書き、閉じる。
  ///
  /// [name] Box の名前。
  /// [key] 暗号化に使う鍵。
  /// [entries] 書き込む内容。
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

  /// 鍵 [key] で Cookie を保存した状態を作り、Hive を閉じる。
  Future<void> storeCookieWithKey(List<int> key, String name) async {
    keyStorage.values[_keyName] = base64Encode(key);
    await proxy.restoreCookies([
      CookieRestoreEntry(
        name: name,
        value: 'token',
        domain: 'example.com',
        hostOnly: true,
      ),
    ]);
    await Hive.close();
    proxy = createProxy();
  }

  /// Cookie 名の一覧を読む。
  Future<List<String>> cookieNames() async {
    return (await proxy.getCookies()).map((cookie) => cookie.name).toList();
  }

  /// start() が送出した例外を返す。
  Future<StorageIntegrityException> startFailure() async {
    try {
      await proxy.start(config: const ProxyConfig(origin: _origin));
    } on StorageIntegrityException catch (error) {
      return error;
    }
    fail('start() did not throw StorageIntegrityException');
  }

  group('鍵と暗号化 Box の照合（中身のある暗号化 Box が無い場合）', () {
    /// 新規インストールでは鍵を生成して起動すること
    test('generates a key on a fresh install', () async {
      await proxy.start(config: const ProxyConfig(origin: _origin));

      expect(base64Decode(keyStorage.values[_keyName]!), hasLength(32));
    });

    /// 形式不正の鍵は、暗号化データが無ければ作り直すこと
    test('regenerates an invalid key', () async {
      keyStorage.values[_keyName] = base64Encode(List<int>.filled(8, 1));

      await proxy.start(config: const ProxyConfig(origin: _origin));

      expect(base64Decode(keyStorage.values[_keyName]!), hasLength(32));
    });

    /// 鍵を書き込めない場合は Box を作らずに起動失敗にすること
    test('fails without creating boxes when the key cannot be written',
        () async {
      keyStorage.failWrites = true;

      final error = await startFailure();

      expect(error.failure, StorageIntegrityFailure.keyWriteFailed);
      expect(boxFile(_cookieBoxName).existsSync(), isFalse);
    });

    /// 端末のロック中は起動失敗（一時的）にし、鍵を生成しないこと
    test('fails temporarily while protected data is unavailable', () async {
      keyStorage.protectedDataAvailable = false;

      final error = await startFailure();

      expect(error.failure, StorageIntegrityFailure.temporarilyUnavailable);
      expect(keyStorage.values, isEmpty);
    });
  });

  group('鍵と暗号化 Box の照合（Cookie Box だけに中身がある場合）', () {
    /// 0.14.0 からの通常の更新（鍵と Box が一致）では何も消さないこと
    test('keeps cookies when the key matches', () async {
      await storeCookieWithKey(_key(1), 'SESSION');
      await writeEncryptedBox(_queueBoxName, _key(1), {
        '0001757000000000000-000000': _queueEntry(1),
      });
      await Hive.close();

      await proxy.start(config: const ProxyConfig(origin: _origin));

      expect(await cookieNames(), contains('SESSION'));
      final diagnostics = await proxy.getDiagnostics();
      expect(diagnostics.lastCookieStorageDiscardedAt, isNull);
      expect(diagnostics.lastCookieStorageDiscardReason, isNull);
    });

    /// 鍵が合わない Cookie Box は破棄して起動を続け、イベントと診断情報で知らせること
    test('discards a mismatching cookie box and reports it', () async {
      await storeCookieWithKey(_key(1), 'SESSION');
      keyStorage.values[_keyName] = base64Encode(_key(2));
      final events = <ProxyEvent>[];
      final subscription = proxy.events
          .where((event) => event.type == ProxyEventType.cookieStorageDiscarded)
          .listen(events.add);
      addTearDown(subscription.cancel);

      await proxy.start(config: const ProxyConfig(origin: _origin));
      await pumpEventQueue();

      expect(await cookieNames(), isEmpty);
      expect(events, hasLength(1));
      expect(events.single.data['reason'], 'keyMismatch');
      final diagnostics = await proxy.getDiagnostics();
      expect(diagnostics.lastCookieStorageDiscardedAt, isNotNull);
      expect(
        diagnostics.lastCookieStorageDiscardReason,
        StorageIntegrityFailure.keyMismatch,
      );
      // 鍵は作り直さないこと
      expect(keyStorage.values[_keyName], base64Encode(_key(2)));
    });

    /// 鍵が無い状態が続く場合は、Cookie Box を破棄して鍵を作り直すこと
    test('discards the cookie box and regenerates a missing key', () async {
      await storeCookieWithKey(_key(1), 'SESSION');
      keyStorage.values.remove(_keyName);

      await proxy.start(config: const ProxyConfig(origin: _origin));

      expect(await cookieNames(), isEmpty);
      expect(
        (await proxy.getDiagnostics()).lastCookieStorageDiscardReason,
        StorageIntegrityFailure.keyMissing,
      );
      expect(base64Decode(keyStorage.values[_keyName]!), hasLength(32));
    });

    /// 一時的に鍵を読めなかった後に読めた場合は、Cookie Box を残すこと
    test('keeps the cookie box when the key is read after a transient miss',
        () async {
      await storeCookieWithKey(_key(1), 'SESSION');
      keyStorage.scriptedReads.addAll([null, null]);

      await proxy.start(config: const ProxyConfig(origin: _origin));

      expect(await cookieNames(), contains('SESSION'));
      expect(
          (await proxy.getDiagnostics()).lastCookieStorageDiscardedAt, isNull);
    });

    /// 読み取りの結果が null と例外で入り混じる場合は、何も消さずに起動失敗（一時的）にすること
    test('fails temporarily without deleting when reads are mixed', () async {
      await storeCookieWithKey(_key(1), 'SESSION');
      final sizeBefore = boxFile(_cookieBoxName).lengthSync();
      keyStorage.scriptedReads.addAll([null, Exception('keystore')]);

      final error = await startFailure();

      expect(error.failure, StorageIntegrityFailure.temporarilyUnavailable);
      expect(boxFile(_cookieBoxName).lengthSync(), sizeBefore);
    });

    /// 起動前の restoreCookies() の中で Cookie Box を破棄した場合も、復元した Cookie は新しい Box に残ること
    test('keeps cookies restored while the old cookie box was discarded',
        () async {
      await storeCookieWithKey(_key(1), 'OLD');
      keyStorage.values[_keyName] = base64Encode(_key(2));

      await proxy.restoreCookies([
        const CookieRestoreEntry(
          name: 'NEW',
          value: 'token',
          domain: 'example.com',
          hostOnly: true,
        ),
      ]);
      await proxy.start(config: const ProxyConfig(origin: _origin));

      expect(await cookieNames(), equals(['NEW']));
    });
  });

  group('鍵と暗号化 Box の照合（業務データの Box に中身がある場合）', () {
    /// 鍵が合わない業務データの Box があれば、何も消さずに起動失敗にすること
    test('fails without deleting when a business box does not match', () async {
      await writeEncryptedBox(_queueBoxName, _key(1), {
        '0001757000000000000-000000': _queueEntry(1),
      });
      await Hive.close();
      keyStorage.values[_keyName] = base64Encode(_key(2));
      final sizeBefore = boxFile(_queueBoxName).lengthSync();

      final error = await startFailure();

      expect(error.failure, StorageIntegrityFailure.keyMismatch);
      expect(error.boxResults[ProxyStorageBox.queue],
          StorageBoxCheckResult.mismatch);
      expect(error.boxResults[ProxyStorageBox.cookies],
          StorageBoxCheckResult.empty);
      expect(boxFile(_queueBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values[_keyName], base64Encode(_key(2)));
      expect(proxy.isRunning, isFalse);
    });

    /// 鍵が無く業務データの Box に中身があれば、鍵を作り直さずに起動失敗にすること
    test('fails without regenerating the key when a business box has content',
        () async {
      await writeEncryptedBox(_queueBoxName, _key(1), {
        '0001757000000000000-000000': _queueEntry(1),
      });
      await Hive.close();

      final error = await startFailure();

      expect(error.failure, StorageIntegrityFailure.keyMissing);
      expect(error.boxResults[ProxyStorageBox.queue],
          StorageBoxCheckResult.notVerified);
      expect(keyStorage.values, isEmpty);
    });

    /// 先頭の記録が書きかけの業務データの Box でも、鍵が無ければ作り直さないこと
    test('does not regenerate the key for a partially written business box',
        () async {
      await writeEncryptedBox(_queueBoxName, _key(1), {
        '0001757000000000000-000000': _queueEntry(1),
      });
      await Hive.close();
      final file = boxFile(_queueBoxName);
      final bytes = file.readAsBytesSync();
      file.writeAsBytesSync(bytes.sublist(0, 10), flush: true);

      final error = await startFailure();

      expect(error.failure, StorageIntegrityFailure.keyMissing);
      expect(keyStorage.values, isEmpty);
      expect(file.lengthSync(), 10);
    });

    /// 先頭側が壊れた業務データの Box があれば、起動失敗（破損）にすること
    test('fails when a business box is corrupted at the head', () async {
      await writeEncryptedBox(_queueBoxName, _key(1), {
        '0001757000000000000-000000': _queueEntry(1),
        '0001757000000000001-000000': _queueEntry(2),
        '0001757000000000002-000000': _queueEntry(3),
      });
      await Hive.close();
      final file = boxFile(_queueBoxName);
      final bytes = file.readAsBytesSync();
      // 先頭の記録の長さの欄を壊す
      bytes.setRange(0, 4, [0xff, 0xff, 0xff, 0x7f]);
      file.writeAsBytesSync(bytes, flush: true);
      keyStorage.values[_keyName] = base64Encode(_key(1));

      final error = await startFailure();

      expect(error.failure, StorageIntegrityFailure.corrupted);
      expect(error.boxResults[ProxyStorageBox.queue],
          StorageBoxCheckResult.corrupted);
      expect(file.lengthSync(), bytes.length);
    });

    /// 照合が時間の上限を超えた場合は、何も消さずに起動失敗（照合打ち切り）にすること
    test('fails without deleting when verification is aborted', () async {
      await writeEncryptedBox(_queueBoxName, _key(1), {
        '0001757000000000000-000000': _queueEntry(1),
      });
      await Hive.close();
      keyStorage.values[_keyName] = base64Encode(_key(2));
      proxy = createProxy(verificationTimeLimit: Duration.zero);
      final sizeBefore = boxFile(_queueBoxName).lengthSync();

      final error = await startFailure();

      expect(error.failure, StorageIntegrityFailure.verificationAborted);
      expect(error.boxResults[ProxyStorageBox.queue],
          StorageBoxCheckResult.aborted);
      expect(boxFile(_queueBoxName).lengthSync(), sizeBefore);
    });

    /// Cookie API は照合の失敗を CookieOperationException の cause として返すこと
    test('reports the failure to cookie APIs as the cause', () async {
      await writeEncryptedBox(_queueBoxName, _key(1), {
        '0001757000000000000-000000': _queueEntry(1),
      });
      await Hive.close();
      keyStorage.values[_keyName] = base64Encode(_key(2));

      Object? error;
      try {
        await proxy.getCookies();
      } catch (caught) {
        error = caught;
      }

      expect(error, isA<CookieOperationException>());
      final cause = (error! as CookieOperationException).cause;
      expect(cause, isA<StorageIntegrityException>());
      expect((cause! as StorageIntegrityException).failure,
          StorageIntegrityFailure.keyMismatch);
    });
  });

  group('Cookie Box だけに中身がある場合の破棄と通知（統合）', () {
    /// proxy が出す cookieStorageDiscarded イベントを集める。
    ///
    /// 呼び出した時点の proxy を購読するため、proxy を作り直した後に呼ぶ。
    ///
    /// Returns: 受け取ったイベントの一覧（受信順に追加される）。
    List<ProxyEvent> collectDiscardEvents() {
      final events = <ProxyEvent>[];
      final subscription = proxy.events
          .where((event) => event.type == ProxyEventType.cookieStorageDiscarded)
          .listen(events.add);
      addTearDown(subscription.cancel);
      return events;
    }

    /// 鍵が無い状態が続き、新しい鍵の書き込みに失敗した場合は、Cookie Box を消さずに起動失敗
    /// （書き込み不能）にすること。鍵を書いてから Cookie Box を破棄する順序のため、破棄も知らせない
    test('keeps the cookie box when writing a new key fails', () async {
      await storeCookieWithKey(_key(1), 'SESSION');
      keyStorage.values.remove(_keyName);
      keyStorage.failWrites = true;
      final sizeBefore = boxFile(_cookieBoxName).lengthSync();
      final events = collectDiscardEvents();

      final error = await startFailure();
      await pumpEventQueue();

      // 書き込み不能を理由に起動失敗にし、書き込みの失敗を元の例外として持つこと
      expect(error.failure, StorageIntegrityFailure.keyWriteFailed);
      expect(error.error, isA<Exception>());
      expect(proxy.isRunning, isFalse);
      // Cookie Box のファイルを消していないこと
      expect(boxFile(_cookieBoxName).existsSync(), isTrue);
      expect(boxFile(_cookieBoxName).lengthSync(), sizeBefore);
      // 破棄していないため、イベントも診断情報も無いこと
      expect(events, isEmpty);
      final diagnostics = await proxy.getDiagnostics();
      expect(diagnostics.lastCookieStorageDiscardedAt, isNull);
      expect(diagnostics.lastCookieStorageDiscardReason, isNull);
      // 鍵を書いていないこと
      expect(keyStorage.values, isEmpty);
    });

    /// 鍵の書き込みに失敗して起動に失敗した後の復旧 API は、何も消さずに startWillSucceed を返し、
    /// 書き込みが直った後は同じインスタンスの start() で起動できること
    test('rejects recovery after a key write failure and starts once fixed',
        () async {
      await storeCookieWithKey(_key(1), 'SESSION');
      keyStorage.values.remove(_keyName);
      keyStorage.failWrites = true;
      // 前提: start() が書き込み不能で失敗したこと
      final error = await startFailure();
      expect(error.failure, StorageIntegrityFailure.keyWriteFailed);
      final sizeBefore = boxFile(_cookieBoxName).lengthSync();

      final result = await proxy.recoverEncryptedStorage();

      // 何も消さずに、start() の再試行で起動できることを理由に拒否すること
      expect(result.performed, isFalse);
      expect(result.rejection, StorageRecoveryRejection.startWillSucceed);
      expect(result.deletedBoxes, isEmpty);
      expect(result.rebuiltBoxes, isEmpty);
      expect(result.keptBoxes, isEmpty);
      expect(result.keyDeleted, isFalse);
      // Cookie Box のファイルを残し、鍵も書いていないこと
      expect(boxFile(_cookieBoxName).lengthSync(), sizeBefore);
      expect(keyStorage.values, isEmpty);

      // 書き込みが直れば、同じインスタンスの start() で起動できること
      keyStorage.failWrites = false;
      await proxy.start(config: const ProxyConfig(origin: _origin));
      expect(proxy.isRunning, isTrue);
      expect(base64Decode(keyStorage.values[_keyName]!), hasLength(32));
    });

    /// 起動前の Cookie API の中で鍵と合わない Cookie Box を破棄した場合も、先に購読していた
    /// リスナーへ cookieStorageDiscarded が届き、診断情報にも破棄の日時と理由が残ること。
    /// その後の start() は破棄し直さず、起動後も診断情報で確認できること
    test('reports a discard that happened inside a cookie API before start()',
        () async {
      await storeCookieWithKey(_key(1), 'SESSION');
      keyStorage.values[_keyName] = base64Encode(_key(2));
      final events = collectDiscardEvents();

      final cookies = await proxy.getCookies();
      await pumpEventQueue();

      // 前提: 起動前の Cookie API の中で破棄したこと
      expect(proxy.isRunning, isFalse);
      expect(cookies, isEmpty);
      // 購読していたリスナーへ、理由付きのイベントが届くこと
      expect(events, hasLength(1));
      expect(events.single.data['reason'], 'keyMismatch');
      // 診断情報に破棄の日時と理由が残ること
      final beforeStart = await proxy.getDiagnostics();
      expect(beforeStart.lastCookieStorageDiscardedAt, isNotNull);
      expect(
        beforeStart.lastCookieStorageDiscardReason,
        StorageIntegrityFailure.keyMismatch,
      );

      await proxy.start(config: const ProxyConfig(origin: _origin));
      await pumpEventQueue();

      // start() では破棄し直さないこと
      expect(events, hasLength(1));
      // 起動後も、起動前の破棄を診断情報で確認できること
      final afterStart = await proxy.getDiagnostics();
      expect(
        afterStart.lastCookieStorageDiscardedAt,
        beforeStart.lastCookieStorageDiscardedAt,
      );
      expect(
        afterStart.lastCookieStorageDiscardReason,
        StorageIntegrityFailure.keyMismatch,
      );
    });

    /// 鍵の読み取りが読み直しても失敗し続け、中身があるのが Cookie Box だけの場合は、Cookie Box を
    /// 破棄し鍵を作り直して起動し、イベントと診断情報の理由が keyUnreadable になること
    test('discards the cookie box when the key stays unreadable', () async {
      await storeCookieWithKey(_key(1), 'SESSION');
      // 最初の読み取りと 2 回の読み直しを、すべて例外にする
      keyStorage.scriptedReads.addAll([
        Exception('keystore'),
        Exception('keystore'),
        Exception('keystore'),
      ]);
      proxy = OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks(
        keyStorage: keyStorage,
        keyRereadInterval: Duration.zero,
        keyRereadAttempts: 2,
      ));
      final events = collectDiscardEvents();

      await proxy.start(config: const ProxyConfig(origin: _origin));
      await pumpEventQueue();

      // 前提: 用意した失敗をすべて使い、読み直しても読めなかったこと
      expect(keyStorage.scriptedReads, isEmpty);
      // Cookie Box を破棄して起動を続けること
      expect(proxy.isRunning, isTrue);
      expect(await cookieNames(), isEmpty);
      // 破棄の理由を、イベントと診断情報で読み取り不能として知らせること
      expect(events.map((event) => event.data['reason']), ['keyUnreadable']);
      expect(
        (await proxy.getDiagnostics()).lastCookieStorageDiscardReason,
        StorageIntegrityFailure.keyUnreadable,
      );
      // 鍵を作り直したこと
      final newKey = keyStorage.values[_keyName]!;
      expect(base64Decode(newKey), hasLength(32));
      expect(newKey, isNot(base64Encode(_key(1))));
    });

    // 形式不正の鍵の値ごとにテストを分ける
    final invalidKeys = <String, String>{
      '空文字': '',
      '32 バイトでない値': base64Encode(List<int>.filled(8, 1)),
    };
    for (final invalidKey in invalidKeys.entries) {
      /// 鍵の形式が正しくなく、中身があるのが Cookie Box だけの場合は、Cookie Box を破棄し鍵を
      /// 作り直して起動し、イベントと診断情報の理由が keyInvalid になること
      test(
          'discards the cookie box when the key is invalid (${invalidKey.key})',
          () async {
        await storeCookieWithKey(_key(1), 'SESSION');
        keyStorage.values[_keyName] = invalidKey.value;
        final events = collectDiscardEvents();

        await proxy.start(config: const ProxyConfig(origin: _origin));
        await pumpEventQueue();

        // Cookie Box を破棄して起動を続けること
        expect(proxy.isRunning, isTrue);
        expect(await cookieNames(), isEmpty);
        // 破棄の理由を、イベントと診断情報で形式不正として知らせること
        expect(events.map((event) => event.data['reason']), ['keyInvalid']);
        expect(
          (await proxy.getDiagnostics()).lastCookieStorageDiscardReason,
          StorageIntegrityFailure.keyInvalid,
        );
        // 正しい形式の鍵を作り直したこと
        expect(base64Decode(keyStorage.values[_keyName]!), hasLength(32));
      });
    }
  });

  group('.hivec だけが残っている暗号化 Box の起動時の判定', () {
    /// キューの記録のキー（19 桁のマイクロ秒と 6 桁の連番）。
    const queueKey = '0001757000000000000-000000';

    /// 圧縮途中のファイル（`.hivec`）を返す。
    ///
    /// [name] Box の名前。
    File compactedBoxFile(String name) =>
        File('$hiveTestDirectory${Platform.pathSeparator}$name.hivec');

    /// 鍵 [key] で 1 件を書いたキューの暗号化 Box を作り、`.hive` を `.hivec` へ名前を変えて、
    /// 圧縮の途中で止まった状態にする。記録の再送の時刻は十分先にする。
    Future<void> writeQueueBoxAsCompactedFile(List<int> key) async {
      await writeEncryptedBox(_queueBoxName, key, {
        queueKey: {
          ..._queueEntry(1),
          'nextRetryAt': DateTime(2099).toIso8601String(),
        },
      });
      await Hive.close();
      boxFile(_queueBoxName).renameSync(compactedBoxFile(_queueBoxName).path);
    }

    /// 鍵と一致する .hivec だけの Box は、中身のある Box として照合して開き、記録を読めること
    test('opens a box left only as .hivec when the key matches', () async {
      await writeQueueBoxAsCompactedFile(_key(1));
      keyStorage.values[_keyName] = base64Encode(_key(1));
      // 前提: .hive が無く、中身のある .hivec だけがあること
      expect(boxFile(_queueBoxName).existsSync(), isFalse);
      expect(compactedBoxFile(_queueBoxName).lengthSync(), greaterThan(0));

      await proxy.start(config: const ProxyConfig(origin: _origin));

      // 起動でき、.hivec に残っていた記録を読めること
      expect(proxy.isRunning, isTrue);
      final queued = await proxy.getQueuedRequests();
      expect(queued.map((request) => request.url), ['$_origin/api/sales/1']);
      // Hive が .hivec を .hive として使ったこと
      expect(boxFile(_queueBoxName).existsSync(), isTrue);
      expect(compactedBoxFile(_queueBoxName).existsSync(), isFalse);
    });

    /// 鍵と一致しない .hivec だけの業務データの Box があれば、何も消さずに起動失敗（不一致）にすること
    test('fails without deleting a mismatching box left only as .hivec',
        () async {
      await writeQueueBoxAsCompactedFile(_key(1));
      keyStorage.values[_keyName] = base64Encode(_key(2));
      final sizeBefore = compactedBoxFile(_queueBoxName).lengthSync();

      final error = await startFailure();

      // 鍵の不一致を理由に起動失敗にし、Box ごとの結果にも不一致を持つこと
      expect(error.failure, StorageIntegrityFailure.keyMismatch);
      expect(error.boxResults[ProxyStorageBox.queue],
          StorageBoxCheckResult.mismatch);
      // .hivec を開いて切り詰めておらず、.hive も作っていないこと
      expect(compactedBoxFile(_queueBoxName).lengthSync(), sizeBefore);
      expect(boxFile(_queueBoxName).existsSync(), isFalse);
      // 鍵を作り直していないこと
      expect(keyStorage.values[_keyName], base64Encode(_key(2)));
    });

    /// 鍵が無く、業務データの Box が .hivec だけで残っている場合も中身があるとみなし、鍵を作り直さずに
    /// 起動失敗（鍵なし）にすること
    test('does not regenerate the key for a business box left only as .hivec',
        () async {
      await writeQueueBoxAsCompactedFile(_key(1));
      final sizeBefore = compactedBoxFile(_queueBoxName).lengthSync();

      final error = await startFailure();

      // 鍵なしを理由に起動失敗にし、中身のある Box として照合していないこと
      expect(error.failure, StorageIntegrityFailure.keyMissing);
      expect(error.boxResults[ProxyStorageBox.queue],
          StorageBoxCheckResult.notVerified);
      // 鍵を作らず、.hivec も消していないこと
      expect(keyStorage.values, isEmpty);
      expect(compactedBoxFile(_queueBoxName).lengthSync(), sizeBefore);
    });
  });
}
