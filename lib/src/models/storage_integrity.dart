/// proxy が暗号化して保存する Box の種類です。
///
/// 暗号化されるのは値だけで、Box のキーは平文のまま保存されます。
enum ProxyStorageBox {
  /// Cookie の保存領域です。
  cookies,

  /// オフライン時に受け付けた更新系リクエストのキューです。
  queue,

  /// 上流に拒否された更新系リクエストの隔離領域です。
  quarantine,

  /// キューから外したリクエストの履歴です。
  droppedRequests,
}

/// 暗号化 Box のファイルを、secure storage の鍵と照合した結果です。
///
/// 照合は Box を開かずにファイルを読んで行います。Hive は鍵が合わない Box を
/// 開くと中身を切り詰めるためです。
enum StorageBoxCheckResult {
  /// ファイルが無いか、中身がありません。
  empty,

  /// 先頭の記録が鍵と一致しました。
  match,

  /// 先頭の記録が書きかけのため照合できず、鍵と一致する記録も
  /// 見つかりませんでした。最初の書き込みの途中で止まった Box として扱い、
  /// そのまま開きます。
  noMismatch,

  /// 先頭の記録が鍵と一致せず、鍵と一致する記録も見つかりませんでした。
  /// 別の鍵で書かれた Box です。
  mismatch,

  /// 先頭側が壊れていますが、後ろに鍵と一致する記録があります。
  /// 鍵は正しく、先頭側の記録が失われています。
  corrupted,

  /// 照合が時間の上限を超えたため打ち切りました。
  aborted,

  /// 使える鍵が無いため照合していません。中身はあります。
  notVerified,
}

/// 暗号化した保存領域を使えない理由、または Cookie Box を破棄した理由です。
enum StorageIntegrityFailure {
  /// 端末のロック中などで、鍵を一時的に読めません。時間をおいて再試行します。
  temporarilyUnavailable,

  /// 鍵の読み取りが失敗し続けています。
  keyUnreadable,

  /// 鍵がありません。
  keyMissing,

  /// 鍵の形式が正しくありません（空文字、Base64 として読めない、または
  /// 32 バイトでない）。
  keyInvalid,

  /// 鍵と一致しない暗号化 Box があります。
  keyMismatch,

  /// 先頭側が壊れた暗号化 Box があります。
  corrupted,

  /// 照合が時間の上限を超えた暗号化 Box があります。
  verificationAborted,

  /// 新しい鍵を secure storage へ書き込めませんでした。
  keyWriteFailed,
}

/// 暗号化した保存領域の復旧 API が処理を行わなかった理由です。
enum StorageRecoveryRejection {
  /// proxy が稼働中、または起動処理中です。
  proxyActive,

  /// 端末のロック中などで、鍵を一時的に読めません。
  temporarilyUnavailable,

  /// 消す必要のある Box がありません。`start()` を再試行してください。
  ///
  /// 鍵を書き込めずに起動に失敗していた場合
  /// （[StorageIntegrityFailure.keyWriteFailed]）も、この理由になります。
  /// その場合は時間をおいて `start()` を再試行します。
  startWillSucceed,
}

/// 暗号化した保存領域の復旧 API の結果です。
class EncryptedStorageRecoveryResult {
  /// 削除や作り直しを行ったかどうかです。
  final bool performed;

  /// 処理を行わなかった理由です。[performed] が `true` の場合は `null` です。
  final StorageRecoveryRejection? rejection;

  /// 削除した Box です。
  final Set<ProxyStorageBox> deletedBoxes;

  /// 作り直した Box です。
  ///
  /// 先頭側が壊れた Box は、壊れた部分を捨て、鍵と一致する最初の記録から後ろを
  /// 残しています。失われた記録の件数は分かりません。
  ///
  /// 照合が時間の上限を超えた Box は、時間の上限を設けずに照合し直し、
  /// その結果で分けます。鍵と一致しなければ [deletedBoxes] に、
  /// 先頭側が壊れていればここに含みます。先頭の記録が書きかけで鍵と一致する
  /// 記録も無かったものは、0 バイトに切り詰めてここに含みます。何も残って
  /// いませんが、Hive が開くときにも同じく切り詰めるため、これによって
  /// 失われる記録はありません。
  final Set<ProxyStorageBox> rebuiltBoxes;

  /// 中身があり、そのまま残した Box です。
  final Set<ProxyStorageBox> keptBoxes;

  /// secure storage の鍵を削除したかどうかです。
  ///
  /// 削除した場合、次の `start()` は新しい鍵を生成します。
  final bool keyDeleted;

  /// 復旧 API の結果を生成します。
  ///
  /// [performed] は削除や作り直しを行ったかどうかです。
  /// [rejection] は処理を行わなかった理由です。
  /// [deletedBoxes] は削除した Box です。
  /// [rebuiltBoxes] は作り直した Box です。
  /// [keptBoxes] は中身があり、そのまま残した Box です。
  /// [keyDeleted] は鍵を削除したかどうかです。
  const EncryptedStorageRecoveryResult({
    required this.performed,
    this.rejection,
    this.deletedBoxes = const {},
    this.rebuiltBoxes = const {},
    this.keptBoxes = const {},
    this.keyDeleted = false,
  });

  /// 処理を行わなかった結果を生成します。
  ///
  /// [rejection] は処理を行わなかった理由です。
  const EncryptedStorageRecoveryResult.rejected(
      StorageRecoveryRejection this.rejection)
      : performed = false,
        deletedBoxes = const {},
        rebuiltBoxes = const {},
        keptBoxes = const {},
        keyDeleted = false;

  @override
  String toString() {
    return 'EncryptedStorageRecoveryResult{performed: $performed, '
        'rejection: $rejection, deleted: $deletedBoxes, '
        'rebuilt: $rebuiltBoxes, kept: $keptBoxes, keyDeleted: $keyDeleted}';
  }
}
