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

  /// 復旧 API が Box を照合し直すときの、Box ごとの時間の上限です。
  final Duration? recoveryVerificationTimeLimit;

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

  /// 応答キャッシュの記録を 1 件移す直前に呼ぶ処理です。
  ///
  /// 平文の記録を暗号化した Box へ移す場合と、0.21.0 以前の形式から移す
  /// 場合に呼びます。例外を送出すると、その記録を移せなかった場合を再現
  /// できます。
  final Future<void> Function(Object key)? beforeCacheEntryMoved;

  /// `start()` の後に裏で応答キャッシュを開き始める直前に呼ぶ処理です。
  ///
  /// 完了を遅らせると、応答キャッシュを開いている途中の状態を再現できます。
  final Future<void> Function()? beforeCacheOpened;

  /// キューから送る要求のヘッダを付け終え、本文を送る直前に呼ぶ処理です。
  ///
  /// 完了を遅らせると、送信の途中でログインが始まった状態を再現できます。
  final Future<void> Function()? beforeQueuedRequestSent;

  /// 要求をキューへ保存する直前に、キューの投入の排他を持ったまま呼ぶ処理です。
  ///
  /// 完了を遅らせると、排他を取得できずに保存しない状態を再現できます。
  final Future<void> Function()? beforeQueueEntrySaved;

  /// ログインや Cookie の復元で、持ち主を決める直前に呼ぶ処理です。
  ///
  /// 完了を遅らせると、ログインの順番待ちを持ったままの状態を再現できます。
  final Future<void> Function()? beforeQueueOwnerDecided;

  /// `restoreCookies()` と `clearCookies()` で Cookie Jar を書き換える直前に
  /// 呼ぶ処理です。
  ///
  /// 例外を投げると、Cookie の保存や削除に失敗した場合を再現できます。
  final Future<void> Function()? beforeCookieStoreChanged;

  /// 0.25.0 までの平文の WebStorage の Box から、写しを暗号化 Box へ移す
  /// 直前に呼ぶ処理です。
  ///
  /// 例外を投げると、移行の途中で失敗した場合を再現できます。
  final Future<void> Function()? beforeLegacyWebStorageMoved;

  /// 0.25.0 までの平文の WebStorage の Box を、無効な設定の起動で削除する
  /// 直前に呼ぶ処理です。
  ///
  /// 例外を投げると、削除に失敗した場合を再現できます。
  final Future<void> Function()? beforeLegacyWebStorageDeleted;

  /// 再送に失敗した要求の次の送信時刻を、キューへ保存する直前に呼ぶ処理です。
  ///
  /// 例外を投げると、保存に失敗した場合を再現できます。
  final Future<void> Function()? beforeRetryScheduleSaved;

  /// テスト用の設定を生成します。
  ///
  /// [keyStorage] は鍵の読み書きに使う窓口です。
  /// [deferredMigrationDelay] は旧平文 Box の移行を遅らせる時間です。
  /// [verificationTimeLimit] は照合の走査を打ち切る時間の上限です。
  /// [recoveryVerificationTimeLimit] は復旧 API が照合し直すときの時間の
  /// 上限です。
  /// [keyRereadInterval] は鍵を読み直す間隔です。
  /// [keyRereadAttempts] は鍵を読み直す回数です。
  /// [storageLockTimeout] は排他を取得するまでの上限時間です。
  /// [beforeLegacyBoxCleared] は旧 Box を空にする直前に呼ぶ処理です。
  /// [beforeCacheEntryMoved] は応答キャッシュの記録を 1 件移す直前に
  /// 呼ぶ処理です。
  /// [beforeCacheOpened] は応答キャッシュを開き始める直前に呼ぶ処理です。
  /// [beforeQueuedRequestSent] はキューから送る要求の本文を送る直前に
  /// 呼ぶ処理です。
  /// [beforeQueueEntrySaved] は要求をキューへ保存する直前に呼ぶ処理です。
  /// [beforeQueueOwnerDecided] は持ち主を決める直前に呼ぶ処理です。
  /// [beforeCookieStoreChanged] は Cookie Jar を書き換える直前に呼ぶ処理です。
  /// [beforeLegacyWebStorageMoved] は平文の WebStorage の写しを移す直前に
  /// 呼ぶ処理です。
  /// [beforeLegacyWebStorageDeleted] は平文の WebStorage の Box を削除する
  /// 直前に呼ぶ処理です。
  /// [beforeRetryScheduleSaved] は次の送信時刻を保存する直前に呼ぶ処理です。
  const ProxyStorageTestHooks({
    this.keyStorage,
    this.deferredMigrationDelay,
    this.verificationTimeLimit,
    this.recoveryVerificationTimeLimit,
    this.keyRereadInterval,
    this.keyRereadAttempts,
    this.storageLockTimeout,
    this.beforeLegacyBoxCleared,
    this.beforeCacheEntryMoved,
    this.beforeCacheOpened,
    this.beforeQueuedRequestSent,
    this.beforeQueueEntrySaved,
    this.beforeQueueOwnerDecided,
    this.beforeCookieStoreChanged,
    this.beforeLegacyWebStorageMoved,
    this.beforeLegacyWebStorageDeleted,
    this.beforeRetryScheduleSaved,
  });
}
