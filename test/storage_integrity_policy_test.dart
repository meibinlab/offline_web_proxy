import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/storage/encrypted_storage_integrity.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_reader.dart';

/// 判定表の入力を組み立てる。
///
/// [key] 鍵の読み取り結果の区分。
/// [results] Box ごとの照合結果。指定しない Box は中身なしとして扱う。
///
/// Returns: 判定に渡す照合結果。
StorageInspection _inspection(
  EncryptionKeyState key, [
  Map<ProxyStorageBox, StorageBoxCheckResult> results = const {},
]) {
  final fullResults = {
    for (final box in ProxyStorageBox.values)
      box: results[box] ?? StorageBoxCheckResult.empty,
  };
  return StorageInspection(
    keyRead: EncryptionKeyRead(
      key,
      key: key == EncryptionKeyState.present ? Uint8List(32) : null,
    ),
    contents: {
      for (final entry in fullResults.entries)
        entry.key: entry.value != StorageBoxCheckResult.empty,
    },
    results: fullResults,
  );
}

/// 判定結果を比較しやすい形にする。
({StorageIntegrityAction action, StorageIntegrityFailure? failure}) _decide(
  StorageInspection inspection,
) {
  final decision = decideStorageIntegrity(inspection);
  return (action: decision.action, failure: decision.failure);
}

void main() {
  group('判定表（中身のある暗号化 Box が無い場合）', () {
    /// 一時的に読めない場合は起動失敗にすること
    test('fails while the key is temporarily unavailable', () {
      expect(
        _decide(_inspection(EncryptionKeyState.temporarilyUnavailable)),
        equals((
          action: StorageIntegrityAction.fail,
          failure: StorageIntegrityFailure.temporarilyUnavailable,
        )),
      );
    });

    /// 鍵があればそのまま開くこと
    test('opens with the stored key', () {
      expect(
        _decide(_inspection(EncryptionKeyState.present)),
        equals((action: StorageIntegrityAction.open, failure: null)),
      );
    });

    /// 鍵が無い・形式不正・読み取り不能の場合は、失うものが無いため作り直すこと
    test('regenerates a missing, invalid or unreadable key', () {
      for (final state in [
        EncryptionKeyState.missing,
        EncryptionKeyState.invalid,
        EncryptionKeyState.unreadable,
      ]) {
        expect(
          _decide(_inspection(state)),
          equals((action: StorageIntegrityAction.regenerateKey, failure: null)),
          reason: state.name,
        );
      }
    });
  });

  group('判定表（中身のある暗号化 Box がある場合）', () {
    /// 一時的に読めない場合は、中身を問わず起動失敗にすること
    test('fails while the key is temporarily unavailable', () {
      expect(
        _decide(_inspection(EncryptionKeyState.temporarilyUnavailable, {
          ProxyStorageBox.queue: StorageBoxCheckResult.notVerified,
          ProxyStorageBox.cookies: StorageBoxCheckResult.notVerified,
        })),
        equals((
          action: StorageIntegrityAction.fail,
          failure: StorageIntegrityFailure.temporarilyUnavailable,
        )),
      );
    });

    /// 0.14.0 からの通常の更新（すべて問題なし）はそのまま開くこと
    test('opens when every box is fine', () {
      expect(
        _decide(_inspection(EncryptionKeyState.present, {
          ProxyStorageBox.cookies: StorageBoxCheckResult.match,
          ProxyStorageBox.queue: StorageBoxCheckResult.match,
          ProxyStorageBox.quarantine: StorageBoxCheckResult.noMismatch,
        })),
        equals((action: StorageIntegrityAction.open, failure: null)),
      );
    });

    /// 業務データに問題が無く Cookie Box だけに問題がある場合は、Cookie Box を破棄して続けること
    test('discards only the cookie box when business boxes are fine', () {
      const expectations = {
        StorageBoxCheckResult.mismatch: StorageIntegrityFailure.keyMismatch,
        StorageBoxCheckResult.corrupted: StorageIntegrityFailure.corrupted,
        StorageBoxCheckResult.aborted:
            StorageIntegrityFailure.verificationAborted,
      };
      for (final entry in expectations.entries) {
        expect(
          _decide(_inspection(EncryptionKeyState.present, {
            ProxyStorageBox.cookies: entry.key,
            ProxyStorageBox.queue: StorageBoxCheckResult.match,
          })),
          equals((
            action: StorageIntegrityAction.discardCookies,
            failure: entry.value,
          )),
          reason: entry.key.name,
        );
      }
    });

    /// 業務データの Box に問題があれば、Cookie Box を問わず起動失敗にし、種別は不一致・破損・打ち切りの順に優先すること
    test('fails when a business box has a problem', () {
      expect(
        _decide(_inspection(EncryptionKeyState.present, {
          ProxyStorageBox.queue: StorageBoxCheckResult.aborted,
          ProxyStorageBox.quarantine: StorageBoxCheckResult.corrupted,
          ProxyStorageBox.droppedRequests: StorageBoxCheckResult.mismatch,
          ProxyStorageBox.cookies: StorageBoxCheckResult.mismatch,
        })),
        equals((
          action: StorageIntegrityAction.fail,
          failure: StorageIntegrityFailure.keyMismatch,
        )),
      );
      expect(
        _decide(_inspection(EncryptionKeyState.present, {
          ProxyStorageBox.queue: StorageBoxCheckResult.aborted,
          ProxyStorageBox.quarantine: StorageBoxCheckResult.corrupted,
        })),
        equals((
          action: StorageIntegrityAction.fail,
          failure: StorageIntegrityFailure.corrupted,
        )),
      );
      expect(
        _decide(_inspection(EncryptionKeyState.present, {
          ProxyStorageBox.droppedRequests: StorageBoxCheckResult.aborted,
          ProxyStorageBox.cookies: StorageBoxCheckResult.match,
        })),
        equals((
          action: StorageIntegrityAction.fail,
          failure: StorageIntegrityFailure.verificationAborted,
        )),
      );
    });

    /// 使える鍵が無く中身があるのが Cookie Box だけの場合は、Cookie Box を破棄して鍵を作り直すこと
    test('discards the cookie box and regenerates the key', () {
      const expectations = {
        EncryptionKeyState.missing: StorageIntegrityFailure.keyMissing,
        EncryptionKeyState.unreadable: StorageIntegrityFailure.keyUnreadable,
        EncryptionKeyState.invalid: StorageIntegrityFailure.keyInvalid,
      };
      for (final entry in expectations.entries) {
        expect(
          _decide(_inspection(entry.key, {
            ProxyStorageBox.cookies: StorageBoxCheckResult.notVerified,
          })),
          equals((
            action: StorageIntegrityAction.discardCookiesAndRegenerateKey,
            failure: entry.value,
          )),
          reason: entry.key.name,
        );
      }
    });

    /// 使える鍵が無く業務データの Box に中身がある場合は、何も消さずに起動失敗にすること
    test('fails when a business box has content without a usable key', () {
      const expectations = {
        EncryptionKeyState.missing: StorageIntegrityFailure.keyMissing,
        EncryptionKeyState.unreadable: StorageIntegrityFailure.keyUnreadable,
        EncryptionKeyState.invalid: StorageIntegrityFailure.keyInvalid,
      };
      for (final entry in expectations.entries) {
        expect(
          _decide(_inspection(entry.key, {
            ProxyStorageBox.droppedRequests: StorageBoxCheckResult.notVerified,
            ProxyStorageBox.cookies: StorageBoxCheckResult.notVerified,
          })),
          equals((
            action: StorageIntegrityAction.fail,
            failure: entry.value,
          )),
          reason: entry.key.name,
        );
      }
    });
  });
}
