import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/storage_integrity.dart';

/// 暗号化鍵を保存する secure storage への窓口です。
///
/// proxy の内部実装用で、ライブラリからは公開しません。テストでは、読み取りの
/// 失敗や遅延、端末ロック中の状態を再現するために差し替えます。
abstract class EncryptionKeyStorage {
  /// 鍵を読み取ります。
  ///
  /// [key] 保存に使う名前。
  ///
  /// Returns: 保存されている値。無い場合は `null`。
  Future<String?> read(String key);

  /// 鍵を書き込みます。
  ///
  /// [key] 保存に使う名前。
  /// [value] 保存する値。
  Future<void> write(String key, String value);

  /// 鍵を削除します。
  ///
  /// [key] 保存に使う名前。
  Future<void> delete(String key);

  /// iOS / macOS の保護データ（Keychain など）を読める状態かを返します。
  ///
  /// Returns: 読める場合は `true`、端末のロック中などで読めない場合は
  ///   `false`。iOS / macOS 以外では `null`。
  Future<bool?> isProtectedDataAvailable();
}

/// [FlutterSecureStorage] を使う [EncryptionKeyStorage] です。
class SecureEncryptionKeyStorage implements EncryptionKeyStorage {
  /// 読み書きに使う secure storage です。
  final FlutterSecureStorage _storage;

  /// [storage] を使う窓口を生成します。
  ///
  /// [storage] 読み書きに使う secure storage。
  const SecureEncryptionKeyStorage([
    this._storage = const FlutterSecureStorage(),
  ]);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<bool?> isProtectedDataAvailable() =>
      _storage.isCupertinoProtectedDataAvailable();
}

/// 保存領域の処理をテストから差し替えるための設定です。
///
/// proxy の内部実装用で、ライブラリからは公開しません。`null` の項目は
/// 既定値を使います。
class ProxyStorageTestHooks {
  /// 鍵の読み書きに使う窓口です。
  final EncryptionKeyStorage? keyStorage;

  /// 鍵を生成したインスタンスで、旧平文 Box の移行を遅らせる時間です。
  final Duration? deferredMigrationDelay;

  /// 起動時の照合で、走査を打ち切る時間の上限です。
  final Duration? verificationTimeLimit;

  /// 鍵を読み直す間隔です。
  final Duration? keyRereadInterval;

  /// 鍵を読み直す回数です（最初の読み取りを含みません）。
  final int? keyRereadAttempts;

  /// キュー消化・隔離・ドロップ履歴の排他を取得するまでの上限時間です。
  final Duration? storageLockTimeout;

  /// 旧平文 Box を書き写した後、旧 Box を空にする直前に呼ぶ処理です。
  ///
  /// 例外を送出すると、移行の途中で失敗した場合を再現できます。完了を
  /// 遅らせると、移行がロックを保持している状態を再現できます。
  final Future<void> Function(ProxyStorageBox kind)? beforeLegacyBoxCleared;

  /// テスト用の設定を生成します。
  ///
  /// [keyStorage] は鍵の読み書きに使う窓口です。
  /// [deferredMigrationDelay] は旧平文 Box の移行を遅らせる時間です。
  /// [verificationTimeLimit] は照合の走査を打ち切る時間の上限です。
  /// [keyRereadInterval] は鍵を読み直す間隔です。
  /// [keyRereadAttempts] は鍵を読み直す回数です。
  /// [storageLockTimeout] は排他を取得するまでの上限時間です。
  /// [beforeLegacyBoxCleared] は旧 Box を空にする直前に呼ぶ処理です。
  const ProxyStorageTestHooks({
    this.keyStorage,
    this.deferredMigrationDelay,
    this.verificationTimeLimit,
    this.keyRereadInterval,
    this.keyRereadAttempts,
    this.storageLockTimeout,
    this.beforeLegacyBoxCleared,
  });
}
