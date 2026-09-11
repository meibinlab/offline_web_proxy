import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_reader.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';

/// secure storage 上の鍵の名前。
const String _storageKey = 'offline_web_proxy.cookie_box_encryption_key';

/// 32 バイトの正しい形式の鍵。
final String _validKey = base64Encode(List<int>.generate(32, (i) => i));

/// 読み取りのたびに、あらかじめ決めた結果を返す secure storage。
class _ScriptedKeyStorage implements EncryptionKeyStorage {
  /// 読み取りごとの結果。文字列または `null` を返し、[Exception] は送出する。
  /// 使い切った後は最後の結果を繰り返す。
  final List<Object?> reads;

  /// 保護データの利用可否の問い合わせごとの結果。使い切った後は最後の結果を繰り返す。
  final List<Object?> protectedData;

  /// 読み取った回数。
  int readCount = 0;

  /// 保護データの利用可否を問い合わせた回数。
  int protectedDataCount = 0;

  _ScriptedKeyStorage(this.reads, {this.protectedData = const [null]});

  @override
  Future<String?> read(String key) async {
    final result =
        reads[readCount < reads.length ? readCount : reads.length - 1];
    readCount++;
    if (result is Exception) {
      throw result;
    }
    return result as String?;
  }

  @override
  Future<bool?> isProtectedDataAvailable() async {
    final index = protectedDataCount < protectedData.length
        ? protectedDataCount
        : protectedData.length - 1;
    protectedDataCount++;
    final result = protectedData[index];
    if (result is Exception) {
      throw result;
    }
    return result as bool?;
  }

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

/// 読み直しの待ち時間を 0 にした読み取りクラスを作る。
EncryptionKeyReader _reader(EncryptionKeyStorage storage) {
  return EncryptionKeyReader(
    storage: storage,
    storageKey: _storageKey,
    rereadInterval: Duration.zero,
    rereadAttempts: 3,
  );
}

void main() {
  group('EncryptionKeyReader の区分', () {
    /// 正しい形式の鍵を読めた場合は、その鍵を返すこと
    test('returns the key when it is valid', () async {
      final result = await _reader(_ScriptedKeyStorage([_validKey])).readOnce();

      expect(result.state, EncryptionKeyState.present);
      expect(result.key, hasLength(32));
    });

    /// 空文字は 32 バイトでない値として、形式不正として扱うこと
    test('treats an empty value as invalid', () async {
      final result = await _reader(_ScriptedKeyStorage([''])).readOnce();

      expect(result.state, EncryptionKeyState.invalid);
    });

    /// Base64 として読めない値と、32 バイトでない値は形式不正とすること
    test('treats a malformed value as invalid', () async {
      final notBase64 = await _reader(_ScriptedKeyStorage(['***'])).readOnce();
      final shortKey = await _reader(
        _ScriptedKeyStorage([base64Encode(List<int>.filled(8, 1))]),
      ).readOnce();

      expect(notBase64.state, EncryptionKeyState.invalid);
      expect(shortKey.state, EncryptionKeyState.invalid);
    });

    /// 端末のロック中は読み取らずに一時的に読めない状態とすること
    test('does not read while protected data is unavailable', () async {
      final storage =
          _ScriptedKeyStorage([_validKey], protectedData: const [false]);

      final result = await _reader(storage).read(hasEncryptedContent: true);

      expect(result.state, EncryptionKeyState.temporarilyUnavailable);
      expect(storage.readCount, 0);
    });

    /// 読み取りの失敗の直後に端末がロックされていた場合は、失敗を判定に使わないこと
    test('ignores a read failure when the device got locked', () async {
      final storage = _ScriptedKeyStorage(
        [Exception('keychain')],
        protectedData: const [true, false],
      );

      final result = await _reader(storage).readOnce();

      expect(result.state, EncryptionKeyState.temporarilyUnavailable);
    });

    /// 保護データの状態を取得できない場合は利用可能とみなして読み取ること
    test('reads the key when protected data availability is unknown', () async {
      final storage = _ScriptedKeyStorage(
        [_validKey],
        protectedData: [Exception('channel')],
      );

      final result = await _reader(storage).readOnce();

      expect(result.state, EncryptionKeyState.present);
    });
  });

  group('EncryptionKeyReader の読み直し', () {
    /// 中身のある暗号化 Box が無い場合は読み直さないこと
    test('does not reread without encrypted content', () async {
      final storage = _ScriptedKeyStorage([null]);

      final result = await _reader(storage).read(hasEncryptedContent: false);

      expect(result.state, EncryptionKeyState.missing);
      expect(storage.readCount, 1);
    });

    /// すべて null の場合だけ、鍵なしが続いているとみなすこと
    test('reports missing only when every read returns null', () async {
      final storage = _ScriptedKeyStorage([null]);

      final result = await _reader(storage).read(hasEncryptedContent: true);

      expect(result.state, EncryptionKeyState.missing);
      expect(storage.readCount, 4);
    });

    /// すべて例外の場合だけ、読み取り不能が続いているとみなすこと
    test('reports unreadable only when every read throws', () async {
      final storage = _ScriptedKeyStorage([Exception('keystore')]);

      final result = await _reader(storage).read(hasEncryptedContent: true);

      expect(result.state, EncryptionKeyState.unreadable);
      expect(result.error, isA<Exception>());
      expect(storage.readCount, 4);
    });

    /// 一時的な失敗の後に読めた場合は、その値で判定すること
    test('uses the value read after a transient failure', () async {
      final missingThenPresent =
          await _reader(_ScriptedKeyStorage([null, null, _validKey]))
              .read(hasEncryptedContent: true);
      final failingThenInvalid =
          await _reader(_ScriptedKeyStorage([Exception('keystore'), '***']))
              .read(hasEncryptedContent: true);

      expect(missingThenPresent.state, EncryptionKeyState.present);
      expect(failingThenInvalid.state, EncryptionKeyState.invalid);
    });

    /// null と例外が入り混じる場合は一時的に読めない状態とすること
    test('reports temporarily unavailable when results are mixed', () async {
      final storage = _ScriptedKeyStorage([null, Exception('keystore')]);

      final result = await _reader(storage).read(hasEncryptedContent: true);

      expect(result.state, EncryptionKeyState.temporarilyUnavailable);
    });

    /// 読み直しの途中で端末がロックされた場合は一時的に読めない状態とすること
    test('reports temporarily unavailable when locked while rereading',
        () async {
      final storage = _ScriptedKeyStorage(
        [null],
        protectedData: const [true, true, false],
      );

      final result = await _reader(storage).read(hasEncryptedContent: true);

      expect(result.state, EncryptionKeyState.temporarilyUnavailable);
    });
  });
}
