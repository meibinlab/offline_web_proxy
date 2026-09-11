import '../models/storage_integrity.dart';
import 'encryption_key_reader.dart';
import 'hive_frame_inspector.dart';

/// 暗号化 Box の中身の有無と、鍵との照合結果をまとめたものです。
///
/// proxy の内部実装用で、ライブラリからは公開しません。
class StorageInspection {
  /// 暗号化鍵の読み取り結果です。
  final EncryptionKeyRead keyRead;

  /// Box ごとの、中身があるかどうかです。
  final Map<ProxyStorageBox, bool> contents;

  /// Box ごとの照合結果です。
  final Map<ProxyStorageBox, StorageBoxCheckResult> results;

  /// 先頭側が壊れた Box ごとの、鍵と一致した最初の記録の位置です。
  final Map<ProxyStorageBox, int> matchingFrameOffsets;

  /// 照合結果を生成します。
  ///
  /// [keyRead] は暗号化鍵の読み取り結果です。
  /// [contents] は Box ごとの、中身があるかどうかです。
  /// [results] は Box ごとの照合結果です。
  /// [matchingFrameOffsets] は先頭側が壊れた Box の、鍵と一致した最初の記録の位置です。
  const StorageInspection({
    required this.keyRead,
    required this.contents,
    required this.results,
    this.matchingFrameOffsets = const {},
  });

  /// 中身のある暗号化 Box があるかどうかを返します。
  bool get hasAnyContent => contents.values.any((hasContent) => hasContent);

  /// 中身のある業務データ（キュー・隔離・ドロップ履歴）の Box があるかどうかを返します。
  bool get hasBusinessContent => contents.entries.any(
        (entry) => entry.key != ProxyStorageBox.cookies && entry.value,
      );
}

/// 判定表に従って取る動作です。
enum StorageIntegrityAction {
  /// 読めた鍵でそのまま開きます。
  open,

  /// 鍵を作り直して書き込みます。暗号化データが無いため失うものはありません。
  regenerateKey,

  /// Cookie Box を破棄し、読めた鍵で続けます。
  discardCookies,

  /// Cookie Box を破棄し、鍵を作り直して続けます。
  discardCookiesAndRegenerateKey,

  /// 起動を失敗させます。何も消しません。
  fail,
}

/// 判定表による判定結果です。
class StorageIntegrityDecision {
  /// 取る動作です。
  final StorageIntegrityAction action;

  /// 起動を失敗させる理由、または Cookie Box を破棄する理由です。
  final StorageIntegrityFailure? failure;

  /// 判定結果を生成します。
  ///
  /// [action] は取る動作です。
  /// [failure] は起動を失敗させる理由、または Cookie Box を破棄する理由です。
  const StorageIntegrityDecision(this.action, [this.failure]);

  @override
  String toString() => 'StorageIntegrityDecision($action, $failure)';
}

/// 照合で問題とみなす結果を、失敗の種別へ変換します。
///
/// [result] Box の照合結果。
///
/// Returns: 不一致・破損・照合打ち切りの場合は対応する種別。それ以外は `null`。
StorageIntegrityFailure? failureForCheckResult(StorageBoxCheckResult result) {
  return switch (result) {
    StorageBoxCheckResult.mismatch => StorageIntegrityFailure.keyMismatch,
    StorageBoxCheckResult.corrupted => StorageIntegrityFailure.corrupted,
    StorageBoxCheckResult.aborted =>
      StorageIntegrityFailure.verificationAborted,
    _ => null,
  };
}

/// ファイルの照合状態を、公開する照合結果へ変換します。
///
/// [status] ファイルの照合状態。
///
/// Returns: 対応する照合結果。
StorageBoxCheckResult checkResultForVerification(
  HiveBoxVerificationStatus status,
) {
  return switch (status) {
    HiveBoxVerificationStatus.empty => StorageBoxCheckResult.empty,
    HiveBoxVerificationStatus.match => StorageBoxCheckResult.match,
    HiveBoxVerificationStatus.noMismatch => StorageBoxCheckResult.noMismatch,
    HiveBoxVerificationStatus.mismatch => StorageBoxCheckResult.mismatch,
    HiveBoxVerificationStatus.corrupted => StorageBoxCheckResult.corrupted,
    HiveBoxVerificationStatus.aborted => StorageBoxCheckResult.aborted,
  };
}

/// 暗号化 Box の中身を調べ、鍵を読み取って照合します。
///
/// Box は開かず、ファイルを読むだけです。
///
/// [directoryPath] Hive の保存先ディレクトリ。
/// [boxNames] 照合する Box とそのファイル名（拡張子なし）。
/// [keyReader] 暗号化鍵を読み取るクラス。
/// [scanTimeLimit] 走査を打ち切る時間の上限。`null` の場合は上限なし。
///
/// Returns: 中身の有無、鍵の読み取り結果、Box ごとの照合結果。
Future<StorageInspection> inspectEncryptedStorage({
  required String directoryPath,
  required Map<ProxyStorageBox, String> boxNames,
  required EncryptionKeyReader keyReader,
  required Duration? scanTimeLimit,
}) async {
  final contents = <ProxyStorageBox, bool>{};
  for (final entry in boxNames.entries) {
    contents[entry.key] = await hasHiveBoxContent(directoryPath, entry.value);
  }

  final hasAnyContent = contents.values.any((hasContent) => hasContent);
  final keyRead = await keyReader.read(hasEncryptedContent: hasAnyContent);

  final results = <ProxyStorageBox, StorageBoxCheckResult>{};
  final offsets = <ProxyStorageBox, int>{};
  final key = keyRead.key;
  if (keyRead.state != EncryptionKeyState.present || key == null) {
    for (final box in boxNames.keys) {
      results[box] = contents[box] == true
          ? StorageBoxCheckResult.notVerified
          : StorageBoxCheckResult.empty;
    }
    return StorageInspection(
      keyRead: keyRead,
      contents: contents,
      results: results,
    );
  }

  final keyCrc = hiveKeyCrc(key);
  for (final entry in boxNames.entries) {
    if (contents[entry.key] != true) {
      results[entry.key] = StorageBoxCheckResult.empty;
      continue;
    }

    final verification = await verifyEncryptedBox(
      directoryPath: directoryPath,
      box: entry.key,
      boxName: entry.value,
      keyCrc: keyCrc,
      scanTimeLimit: scanTimeLimit,
    );
    results[entry.key] = checkResultForVerification(verification.status);
    final offset = verification.matchingFrameOffset;
    if (offset != null) {
      offsets[entry.key] = offset;
    }
  }

  return StorageInspection(
    keyRead: keyRead,
    contents: contents,
    results: results,
    matchingFrameOffsets: offsets,
  );
}

/// 暗号化 Box のファイル 1 つを鍵と照合します。
///
/// [directoryPath] Hive の保存先ディレクトリ。
/// [box] 照合する Box の種類。走査で候補とするキーの形式を決めます。
/// [boxName] Box のファイル名（拡張子なし）。
/// [keyCrc] 鍵から求めた CRC の初期値。
/// [scanTimeLimit] 走査を打ち切る時間の上限。`null` の場合は上限なし。
///
/// Returns: ファイルの照合結果。ファイルが無い場合は空として返します。
Future<HiveBoxVerification> verifyEncryptedBox({
  required String directoryPath,
  required ProxyStorageBox box,
  required String boxName,
  required int keyCrc,
  required Duration? scanTimeLimit,
}) {
  final file = findHiveBoxFile(directoryPath, boxName);
  if (file == null) {
    return Future.value(
      const HiveBoxVerification(HiveBoxVerificationStatus.empty),
    );
  }

  return verifyHiveBoxFile(
    file.path,
    keyCrc,
    box == ProxyStorageBox.cookies
        ? HiveBoxKeyKind.cookie
        : HiveBoxKeyKind.business,
    scanTimeLimit: scanTimeLimit,
  );
}

/// 判定表に従って、取る動作を決めます。
///
/// 業務データ（キュー・隔離・ドロップ履歴）は利用者の確認なしに消さず、
/// Cookie だけに問題がある場合は Cookie Box を破棄して続けます。
/// 業務データの Box に複数の問題がある場合の種別は、不一致・破損・照合打ち切りの
/// 順に優先します。
///
/// [inspection] 暗号化 Box の照合結果。
///
/// Returns: 取る動作と、その理由。
StorageIntegrityDecision decideStorageIntegrity(StorageInspection inspection) {
  final keyState = inspection.keyRead.state;
  if (keyState == EncryptionKeyState.temporarilyUnavailable) {
    return const StorageIntegrityDecision(
      StorageIntegrityAction.fail,
      StorageIntegrityFailure.temporarilyUnavailable,
    );
  }

  if (keyState == EncryptionKeyState.present) {
    final businessFailure = _businessFailure(inspection.results);
    if (businessFailure != null) {
      return StorageIntegrityDecision(
        StorageIntegrityAction.fail,
        businessFailure,
      );
    }

    final cookieResult = inspection.results[ProxyStorageBox.cookies];
    final cookieFailure =
        cookieResult == null ? null : failureForCheckResult(cookieResult);
    if (cookieFailure != null) {
      return StorageIntegrityDecision(
        StorageIntegrityAction.discardCookies,
        cookieFailure,
      );
    }

    return const StorageIntegrityDecision(StorageIntegrityAction.open);
  }

  if (!inspection.hasAnyContent) {
    return const StorageIntegrityDecision(StorageIntegrityAction.regenerateKey);
  }

  final keyFailure = switch (keyState) {
    EncryptionKeyState.missing => StorageIntegrityFailure.keyMissing,
    EncryptionKeyState.unreadable => StorageIntegrityFailure.keyUnreadable,
    _ => StorageIntegrityFailure.keyInvalid,
  };
  if (inspection.hasBusinessContent) {
    return StorageIntegrityDecision(StorageIntegrityAction.fail, keyFailure);
  }

  return StorageIntegrityDecision(
    StorageIntegrityAction.discardCookiesAndRegenerateKey,
    keyFailure,
  );
}

/// 業務データの Box の照合結果から、起動を失敗させる種別を求めます。
///
/// [results] Box ごとの照合結果。
///
/// Returns: 問題のある Box があればその種別。無ければ `null`。
StorageIntegrityFailure? _businessFailure(
  Map<ProxyStorageBox, StorageBoxCheckResult> results,
) {
  final businessResults = results.entries
      .where((entry) => entry.key != ProxyStorageBox.cookies)
      .map((entry) => entry.value)
      .toSet();

  const priority = [
    StorageBoxCheckResult.mismatch,
    StorageBoxCheckResult.corrupted,
    StorageBoxCheckResult.aborted,
  ];
  for (final result in priority) {
    if (businessResults.contains(result)) {
      return failureForCheckResult(result);
    }
  }
  return null;
}
