/// 暗号化された Hive Box のファイルを、Box を開かずに鍵と照合する部品です。
///
/// Hive は鍵が違う Box を開くと、先頭フレームの CRC 不一致を破損とみなし、
/// ファイルを 0 バイトに切り詰めます。この部品は、Box を開く前にファイルを
/// 読むだけで鍵との一致を判定し、先頭側だけが壊れた Box を作り直します。
/// proxy の内部実装用で、ライブラリからは公開しません。
///
/// Hive 2.2.3 の内部形式（フレームの構成、CRC の計算方法、圧縮途中の
/// ファイルの扱い）に依存します。Hive を更新するときは、この部品との互換を
/// 確認してください。
///
/// フレームの形式は次のとおりです。数値はすべてリトルエンディアンです。
///
/// ```text
/// [uint32 フレーム長][キー][値（暗号化時は IV 16 バイト + AES-CBC）][uint32 CRC]
/// ```
///
/// フレーム長は、長さの欄と CRC の欄を含むフレーム全体のバイト数です。
/// CRC は、フレーム先頭から「フレーム長 - 4」バイトを、鍵の CRC を初期値として
/// CRC32 で計算した値です。削除を表すフレームは値を持ちません。文字列キーは、
/// 型 1 バイト、長さ 1 バイト、UTF-8 のバイト列の順に並びます。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hive/hive.dart';

/// フレーム長の欄のバイト数です。
const int _frameLengthFieldSize = 4;

/// CRC の欄のバイト数です。
const int _crcFieldSize = 4;

/// Hive がフレームとして読むフレーム長の下限です。
///
/// これより短い長さの欄を、Hive は破損とみなします。
const int _minimumFrameLength = _frameLengthFieldSize + _crcFieldSize;

/// キーの型の欄のバイト数です。
const int _keyTypeFieldSize = 1;

/// 文字列キーの長さの欄のバイト数です。
const int _keyLengthFieldSize = 1;

/// 文字列キーを表す、キーの型の値です。
///
/// Hive 2.2.3 の `FrameKeyType.utf8StringT` に相当します。
const int _stringKeyType = 1;

/// フレーム先頭から見た、キーの型の欄の位置です。
const int _keyTypeFieldOffset = _frameLengthFieldSize;

/// フレーム先頭から見た、文字列キーの長さの欄の位置です。
const int _keyLengthFieldOffset = _keyTypeFieldOffset + _keyTypeFieldSize;

/// フレーム先頭から見た、文字列キーの本体の位置です。
const int _keyBytesOffset = _keyLengthFieldOffset + _keyLengthFieldSize;

/// 走査で候補とする文字列キーの長さの下限です。
///
/// 業務キーと Cookie のキーは空になりません。長さの欄が 1 バイトのため、
/// 上限は 255 です。
const int _minimumCandidateKeyLength = 1;

/// 走査で候補とするフレーム長の下限です。
///
/// 長さの欄、キーの型の欄、キーの長さの欄、1 バイト以上のキー、CRC の欄を
/// 合わせた長さです。削除を表すフレームも、この長さ以上になります。
const int _minimumCandidateFrameLength =
    _keyBytesOffset + _minimumCandidateKeyLength + _crcFieldSize;

/// 業務キーに使う文字 `0` の文字コードです。
const int _asciiDigitZero = 0x30;

/// 業務キーに使う文字 `9` の文字コードです。
const int _asciiDigitNine = 0x39;

/// 業務キーに使う文字 `-` の文字コードです。
const int _asciiHyphen = 0x2d;

/// ASCII の範囲の上限です。この値未満の文字コードを ASCII とみなします。
const int _asciiUpperBound = 0x80;

/// 走査中に経過時間を確認する間隔です。この数の位置を調べるごとに確認します。
const int _scanTimeCheckInterval = 65536;

/// CRC32 の生成多項式です。ビットの並びを反転した表現で持ちます。
const int _crc32Polynomial = 0xedb88320;

/// 32 ビットのすべてのビットを立てた値です。CRC32 の前後の反転に使います。
const int _uint32AllBits = 0xffffffff;

/// 1 バイト分のビットを取り出すマスクです。
const int _byteMask = 0xff;

/// 1 バイトのビット数です。
const int _bitsPerByte = 8;

/// CRC32 の表の要素数です。1 バイトが取り得る値の数と同じです。
const int _crc32TableSize = 256;

/// Box のファイルの拡張子です。
const String _hiveFileExtension = 'hive';

/// Hive が圧縮の途中に書き出すファイルの拡張子です。
const String _compactedFileExtension = 'hivec';

/// 作り直しでファイルを写すときに、一度に読むバイト数です。
const int _copyChunkSize = 64 * 1024;

/// 呼び出し元の isolate で読んで照合する先頭フレームの大きさの上限（バイト）。
/// これより大きい先頭フレームは、UI の isolate を止めないよう別の isolate で照合する。
const int _maxFirstFrameBytesOnCallerIsolate = 1024 * 1024;

/// CRC32 の計算に使う表です。最初に使うときに作ります。
final Uint32List _crc32Table = _buildCrc32Table();

/// 走査で候補とするフレームのキーの種類です。
///
/// 先頭が壊れた Box の中から鍵と一致するフレームを探すとき、キーの文字で
/// 候補を絞り込み、CRC を計算する位置を減らします。
enum HiveBoxKeyKind {
  /// キュー、隔離、ドロップ履歴のキーです。
  ///
  /// 数字と `-` だけで構成されるキーを候補にします。ミリ秒やマイクロ秒の
  /// タイムスタンプだけの過去の形式と、ゼロ埋めしたマイクロ秒と連番を `-` で
  /// つないだ現在の形式の両方が該当します。
  business,

  /// Cookie のキーです。
  ///
  /// ドメイン、パス、名前、種別をタブでつないだ、ASCII だけで構成される
  /// キーを候補にします。
  cookie,
}

/// 暗号化 Box のファイルを鍵と照合した結果の種類です。
enum HiveBoxVerificationStatus {
  /// ファイルが無い、または 0 バイトで、照合する記録がありません。
  empty,

  /// 先頭フレームの CRC が鍵と一致しました。
  ///
  /// 先頭が一致した時点で判定を終え、後ろのフレームは確認しません。
  match,

  /// 先頭フレームが書きかけで照合できず、後ろにも鍵と一致するフレームが
  /// ありません。
  ///
  /// 鍵が違うという根拠も無いため、不一致とは区別します。Hive がこの Box を
  /// 開くと、先頭から切り詰めて空にします。
  noMismatch,

  /// 先頭フレームが鍵と一致せず、後ろにも鍵と一致するフレームがありません。
  ///
  /// 先頭フレームが完全な長さを持つのに CRC が一致しない、または長さの欄が
  /// 8 未満の場合です。別の鍵で暗号化された Box である可能性が高い状態です。
  mismatch,

  /// 先頭フレームは鍵と一致しないものの、後ろに鍵と一致するフレームがあります。
  ///
  /// 先頭側が壊れた Box とみなし、[HiveBoxVerification.matchingFrameOffset]
  /// から後ろを残して作り直せます。
  corrupted,

  /// 走査が時間の上限を超えたため打ち切りました。
  ///
  /// 鍵と一致するかどうかは判定できていません。
  aborted,
}

/// 暗号化 Box のファイルを鍵と照合した結果です。
class HiveBoxVerification {
  /// 照合結果を作ります。
  ///
  /// [status] 照合結果の種類。
  /// [matchingFrameOffset] 鍵と一致した最初のフレームの位置。[status] が
  ///   [HiveBoxVerificationStatus.corrupted] の場合だけ指定します。
  const HiveBoxVerification(this.status, {this.matchingFrameOffset})
      : assert(
          (status == HiveBoxVerificationStatus.corrupted) ==
              (matchingFrameOffset != null),
          'matchingFrameOffset は corrupted の場合だけ指定します。',
        );

  /// 照合結果の種類です。
  final HiveBoxVerificationStatus status;

  /// 鍵と一致した最初のフレームの、ファイル先頭からのバイト位置です。
  ///
  /// [status] が [HiveBoxVerificationStatus.corrupted] の場合だけ値を持ち、
  /// それ以外の場合は `null` です。
  final int? matchingFrameOffset;
}

/// 先頭フレームを鍵と照合した結果です。
enum _FirstFrameResult {
  /// 先頭フレームの CRC が鍵と一致した。
  match,

  /// 先頭フレームの長さの欄が 8 未満、または CRC が鍵と一致しない。
  mismatch,

  /// ファイルが先頭フレームの途中で終わっており、照合できない。
  unverifiable,
}

/// Hive 2.2.3 と同じ方式で CRC32 を計算します。
///
/// Hive の `Crc32.compute` と同じ表と手順で計算するため、同じ結果になります。
/// [crc] に途中までの結果を渡すと、続きから計算できます。
///
/// [bytes] 計算するバイト列。
/// [crc] 計算の初期値。暗号化 Box のフレームでは [hiveKeyCrc] の戻り値を
///   渡します。
/// [offset] 計算を始める位置。
/// [length] 計算するバイト数。`null` の場合は [offset] から末尾までを
///   計算します。
///
/// Returns: 32 ビット符号なし整数の CRC32。
///
/// Throws:
///   * [RangeError] [offset] と [length] で示す範囲が [bytes] に収まらない
///     場合。
int hiveCrc32(
  Uint8List bytes, {
  int crc = 0,
  int offset = 0,
  int? length,
}) {
  final end = offset + (length ?? bytes.length - offset);
  RangeError.checkValidRange(offset, end, bytes.length);

  final table = _crc32Table;
  var value = crc ^ _uint32AllBits;
  for (var index = offset; index < end; index++) {
    value = table[(value ^ bytes[index]) & _byteMask] ^ (value >> _bitsPerByte);
  }
  return value ^ _uint32AllBits;
}

/// 暗号化 Box のフレームの CRC 計算で初期値に使う、鍵の CRC を返します。
///
/// Hive の `HiveAesCipher.calculateKeyCrc` の値をそのまま返します。
///
/// [key] Box の暗号化に使う 32 バイトの鍵。
///
/// Returns: 鍵の SHA-256 を CRC32 で計算した値。
///
/// Throws:
///   * [ArgumentError] [key] が 32 バイトでない、または 0〜255 の範囲外の値を
///     含む場合。
int hiveKeyCrc(List<int> key) => HiveAesCipher(key).calculateKeyCrc();

/// 暗号化 Box のファイルの内容を、鍵と照合します。
///
/// 先頭フレームの CRC を鍵の CRC で確認し、一致すれば後ろを走査せずに
/// [HiveBoxVerificationStatus.match] を返します。先頭が一致しない、または
/// 照合できない場合は、2 バイト目以降から鍵と一致するフレームを探します。
/// 走査では、文字列キーを持ち、キーの文字が [keyKind] に合う位置だけで CRC を
/// 計算します。走査はバイト数では打ち切りません。
///
/// [bytes] Box のファイルの内容。
/// [keyCrc] 照合する鍵の CRC。[hiveKeyCrc] の戻り値を渡します。
/// [keyKind] 走査で候補とするキーの種類。
/// [scanTimeLimit] 走査にかける時間の上限。`null` の場合は上限を設けません。
///   走査の開始直後、一定数の位置を調べるごと、候補の CRC を計算するごとに
///   確認し、超えていれば [HiveBoxVerificationStatus.aborted] を返します。
///   [Duration.zero] を渡すと、走査が必要な場合は必ず打ち切ります。
///
/// Returns: 照合結果。
HiveBoxVerification verifyHiveBoxBytes(
  Uint8List bytes,
  int keyCrc,
  HiveBoxKeyKind keyKind, {
  Duration? scanTimeLimit,
}) {
  if (bytes.isEmpty) {
    return const HiveBoxVerification(HiveBoxVerificationStatus.empty);
  }

  final firstFrame = _verifyFirstFrame(bytes, keyCrc);
  if (firstFrame == _FirstFrameResult.match) {
    // 先頭が一致すれば鍵は正しいため、後ろは走査しない
    return const HiveBoxVerification(HiveBoxVerificationStatus.match);
  }

  final scanResult =
      _scanForMatchingFrame(bytes, keyCrc, keyKind, scanTimeLimit);
  if (scanResult != null) {
    return scanResult;
  }

  return firstFrame == _FirstFrameResult.unverifiable
      ? const HiveBoxVerification(HiveBoxVerificationStatus.noMismatch)
      : const HiveBoxVerification(HiveBoxVerificationStatus.mismatch);
}

/// 暗号化 Box のファイルを別の isolate で読み、鍵と照合します。
///
/// 通常の起動では先頭フレームが鍵と一致するため、まず先頭フレームだけを読んで
/// 照合し、一致した場合はそのまま返します。先頭フレームが 1 MiB を超える場合は、
/// 呼び出し元の isolate では読みません。一致しない場合と先頭フレームが大きい
/// 場合は、ファイルの読み込みと走査で呼び出し元の isolate を止めないように、
/// [Isolate.run] の中で [verifyHiveBoxBytes] を実行します。ファイルが無い、
/// または 0 バイトの場合は、isolate を起動せずに
/// [HiveBoxVerificationStatus.empty] を返します。
///
/// [filePath] 照合するファイルのパス。通常は [findHiveBoxFile] で見つけた
///   ファイルのパスを渡します。
/// [keyCrc] 照合する鍵の CRC。[hiveKeyCrc] の戻り値を渡します。
/// [keyKind] 走査で候補とするキーの種類。
/// [scanTimeLimit] 走査にかける時間の上限。扱いは [verifyHiveBoxBytes] と
///   同じです。ファイルの読み込みと isolate の起動にかかる時間は含みません。
///
/// Returns: 照合結果。
///
/// Throws:
///   * [FileSystemException] ファイルを読めなかった場合。
Future<HiveBoxVerification> verifyHiveBoxFile(
  String filePath,
  int keyCrc,
  HiveBoxKeyKind keyKind, {
  Duration? scanTimeLimit,
}) async {
  final stat = await FileStat.stat(filePath);
  if (stat.type == FileSystemEntityType.notFound || stat.size == 0) {
    return const HiveBoxVerification(HiveBoxVerificationStatus.empty);
  }

  if (await _firstFrameMatchesInFile(filePath, stat.size, keyCrc)) {
    return const HiveBoxVerification(HiveBoxVerificationStatus.match);
  }

  return _verifyHiveBoxFileInIsolate(filePath, keyCrc, keyKind, scanTimeLimit);
}

/// ファイルの先頭フレームだけを読み、鍵と一致するかどうかを返します。
///
/// [filePath] 照合するファイルのパス。
/// [fileSize] ファイルの大きさ（バイト）。
/// [keyCrc] 照合する鍵の CRC。
///
/// Returns: 先頭フレームが完結していて、鍵と一致する場合は `true`。先頭フレームが
///   [_maxFirstFrameBytesOnCallerIsolate] より大きい場合は、呼び出し元の isolate
///   では読まずに `false`（呼び出し側が別の isolate で照合します）。
///
/// Throws:
///   * [FileSystemException] ファイルを読めなかった場合。
Future<bool> _firstFrameMatchesInFile(
  String filePath,
  int fileSize,
  int keyCrc,
) async {
  if (fileSize < _minimumFrameLength) {
    return false;
  }

  final file = await File(filePath).open();
  try {
    final lengthField = await file.read(_frameLengthFieldSize);
    if (lengthField.length < _frameLengthFieldSize) {
      return false;
    }

    final frameLength = _readUint32(lengthField, 0);
    if (frameLength < _minimumFrameLength ||
        frameLength > fileSize ||
        frameLength > _maxFirstFrameBytesOnCallerIsolate) {
      return false;
    }

    await file.setPosition(0);
    final frame = await file.read(frameLength);
    if (frame.length < frameLength) {
      return false;
    }
    return _frameCrcMatches(frame, 0, frameLength, keyCrc);
  } finally {
    await file.close();
  }
}

/// Hive が Box を開くときに使うファイルを探します。
///
/// Hive 2.2.3 と同じ優先順で、`<boxName>.hive` があればそれを返し、無ければ
/// 圧縮途中の `<boxName>.hivec` を返します。Hive は `.hivec` だけが残っている
/// 場合、それを `.hive` へ名前を変えて使います。
///
/// [directoryPath] Box のファイルを置くディレクトリのパス。
/// [boxName] Box の名前。Hive と同じく小文字にして扱います。
///
/// Returns: 見つかったファイル。どちらも無い場合は `null`。
File? findHiveBoxFile(String directoryPath, String boxName) {
  final hiveFile = _boxFile(directoryPath, boxName, _hiveFileExtension);
  if (hiveFile.existsSync()) {
    return hiveFile;
  }

  final compactedFile =
      _boxFile(directoryPath, boxName, _compactedFileExtension);
  if (compactedFile.existsSync()) {
    return compactedFile;
  }
  return null;
}

/// Box のファイルに内容があるかどうかを返します。
///
/// [directoryPath] Box のファイルを置くディレクトリのパス。
/// [boxName] Box の名前。Hive と同じく小文字にして扱います。
///
/// Returns: [findHiveBoxFile] が見つけたファイルが 0 バイトより大きい場合は
///   `true`。ファイルが無い場合は `false`。
Future<bool> hasHiveBoxContent(String directoryPath, String boxName) async {
  final file = findHiveBoxFile(directoryPath, boxName);
  if (file == null) {
    return false;
  }

  // 確認の直後に消えた場合、FileStat の size は -1 になる
  final stat = await file.stat();
  return stat.size > 0;
}

/// 先頭側が壊れた Box を、[offset] から後ろだけで作り直します。
///
/// 元のファイルの [offset] 以降を圧縮途中のファイル `<boxName>.hivec` へ書き、
/// ディスクへ書き出して閉じてから、`<boxName>.hive` へ名前を変えて置き換えます。
/// 置き換えるまで元の `.hive` は残すため、途中で処理が止まっても、Hive は次に
/// Box を開くときに `.hivec` を捨てて元の `.hive` を使います。`.hive` が無く
/// `.hivec` だけがある場合は、Hive と同じく先に `.hivec` を `.hive` へ名前を
/// 変えてから作り直します。
///
/// Box を開いている間は呼ばないでください。
///
/// [directoryPath] Box のファイルを置くディレクトリのパス。
/// [boxName] Box の名前。Hive と同じく小文字にして扱います。
/// [offset] 残す範囲の先頭の位置。通常は
///   [HiveBoxVerification.matchingFrameOffset] を渡します。
///
/// Throws:
///   * [ArgumentError] [offset] が 0 未満、またはファイルの長さ以上の場合。
///     このときファイルは変更しません。
///   * [FileSystemException] Box のファイルが無い場合、または読み書きや名前の
///     変更に失敗した場合。
Future<void> rebuildHiveBoxFromOffset(
  String directoryPath,
  String boxName,
  int offset,
) async {
  final sourceFile = findHiveBoxFile(directoryPath, boxName);
  if (sourceFile == null) {
    throw FileSystemException(
      'Hive Box のファイルが見つかりません',
      _boxFile(directoryPath, boxName, _hiveFileExtension).path,
    );
  }

  final fileLength = await sourceFile.length();
  if (offset < 0 || offset >= fileLength) {
    throw ArgumentError.value(
      offset,
      'offset',
      'ファイルの長さ $fileLength バイトの範囲外です',
    );
  }

  final hiveFile = await _promoteToHiveFile(sourceFile, directoryPath, boxName);
  final compactedFile =
      _boxFile(directoryPath, boxName, _compactedFileExtension);
  await _copyFileTail(hiveFile, compactedFile, offset);
  await compactedFile.rename(hiveFile.path);
}

/// Box のファイルを 0 バイトに切り詰めます。
///
/// `.hive` が無く `.hivec` だけがある場合は、Hive と同じく先に `.hivec` を
/// `.hive` へ名前を変えてから切り詰めます。どちらも無い場合は何もしません。
///
/// Box を開いている間は呼ばないでください。
///
/// [directoryPath] Box のファイルを置くディレクトリのパス。
/// [boxName] Box の名前。Hive と同じく小文字にして扱います。
///
/// Throws:
///   * [FileSystemException] 名前の変更や書き込みに失敗した場合。
Future<void> truncateHiveBox(String directoryPath, String boxName) async {
  final sourceFile = findHiveBoxFile(directoryPath, boxName);
  if (sourceFile == null) {
    return;
  }

  final hiveFile = await _promoteToHiveFile(sourceFile, directoryPath, boxName);
  await hiveFile.writeAsBytes(const <int>[], flush: true);
}

/// CRC32 の表を作ります。
///
/// Returns: 1 バイトの各値に対応する CRC32 の表。
Uint32List _buildCrc32Table() {
  final table = Uint32List(_crc32TableSize);
  for (var index = 0; index < _crc32TableSize; index++) {
    var value = index;
    for (var bit = 0; bit < _bitsPerByte; bit++) {
      value = (value & 1) != 0 ? (value >> 1) ^ _crc32Polynomial : value >> 1;
    }
    table[index] = value;
  }
  return table;
}

/// [offset] から 4 バイトを、リトルエンディアンの符号なし 32 ビット整数として
/// 読みます。
///
/// 呼び出し元は、4 バイトが [bytes] に収まることを保証します。
int _readUint32(Uint8List bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << _bitsPerByte) |
      (bytes[offset + 2] << (2 * _bitsPerByte)) |
      (bytes[offset + 3] << (3 * _bitsPerByte));
}

/// 先頭フレームを鍵と照合します。
///
/// Hive 2.2.3 の `readFrame` と同じ条件で、長さの欄とファイルの長さを確認
/// してから CRC を比べます。
///
/// Returns: 先頭フレームの照合結果。
_FirstFrameResult _verifyFirstFrame(Uint8List bytes, int keyCrc) {
  if (bytes.length < _frameLengthFieldSize) {
    return _FirstFrameResult.unverifiable;
  }

  final frameLength = _readUint32(bytes, 0);
  if (frameLength > bytes.length) {
    return _FirstFrameResult.unverifiable;
  }
  if (frameLength < _minimumFrameLength) {
    return _FirstFrameResult.mismatch;
  }
  return _frameCrcMatches(bytes, 0, frameLength, keyCrc)
      ? _FirstFrameResult.match
      : _FirstFrameResult.mismatch;
}

/// 2 バイト目以降から、鍵と一致するフレームを探します。
///
/// すべての位置で CRC を計算すると、計算量がファイルサイズの 2 乗に比例します。
/// そのため [_isCandidateFrame] の条件を満たす位置だけで CRC を計算し、計算量を
/// ファイルサイズにほぼ比例させます。
///
/// [bytes] Box のファイルの内容。
/// [keyCrc] 照合する鍵の CRC。
/// [keyKind] 走査で候補とするキーの種類。
/// [scanTimeLimit] 走査にかける時間の上限。`null` の場合は上限を設けません。
///
/// Returns: 一致するフレームが見つかった場合は corrupted、時間の上限を超えた
///   場合は aborted の結果。最後まで見つからなかった場合は `null`。
HiveBoxVerification? _scanForMatchingFrame(
  Uint8List bytes,
  int keyCrc,
  HiveBoxKeyKind keyKind,
  Duration? scanTimeLimit,
) {
  const aborted = HiveBoxVerification(HiveBoxVerificationStatus.aborted);
  final stopwatch = Stopwatch()..start();
  bool isTimeUp() =>
      scanTimeLimit != null && stopwatch.elapsed >= scanTimeLimit;

  if (isTimeUp()) {
    return aborted;
  }

  // 候補のフレームは _minimumCandidateFrameLength 以上の長さを持つため、
  // それより末尾に近い位置は調べない
  final lastCandidateOffset = bytes.length - _minimumCandidateFrameLength;
  for (var offset = 1; offset <= lastCandidateOffset; offset++) {
    if (offset % _scanTimeCheckInterval == 0 && isTimeUp()) {
      return aborted;
    }
    if (!_isCandidateFrame(bytes, offset, keyKind)) {
      continue;
    }
    if (_frameCrcMatches(bytes, offset, _readUint32(bytes, offset), keyCrc)) {
      return HiveBoxVerification(
        HiveBoxVerificationStatus.corrupted,
        matchingFrameOffset: offset,
      );
    }
    // 長いフレームの CRC 計算が続いても上限を大きく超えないように確認する
    if (isTimeUp()) {
      return aborted;
    }
  }
  return null;
}

/// [offset] が、走査で CRC を計算する候補のフレームの先頭かどうかを返します。
///
/// 文字列キーを持ち、フレーム長がファイルに収まり、キーが CRC の欄より前に
/// 収まり、キーの文字が [keyKind] に合う位置だけを候補にします。安い条件から
/// 順に確認します。
///
/// 呼び出し元は、[offset] から [_minimumCandidateFrameLength] バイトが
/// [bytes] に収まることを保証します。
///
/// Returns: 候補の場合は `true`。
bool _isCandidateFrame(Uint8List bytes, int offset, HiveBoxKeyKind keyKind) {
  if (bytes[offset + _keyTypeFieldOffset] != _stringKeyType) {
    return false;
  }

  final frameLength = _readUint32(bytes, offset);
  if (frameLength < _minimumCandidateFrameLength ||
      frameLength > bytes.length - offset) {
    return false;
  }

  final keyLength = bytes[offset + _keyLengthFieldOffset];
  if (keyLength < _minimumCandidateKeyLength) {
    return false;
  }

  final keyStart = offset + _keyBytesOffset;
  final keyEnd = keyStart + keyLength;
  if (keyEnd > offset + frameLength - _crcFieldSize) {
    return false;
  }
  return _isCandidateKey(bytes, keyStart, keyEnd, keyKind);
}

/// [start] から [end] の直前までのキーの文字が、[keyKind] に合うかどうかを
/// 返します。
///
/// Returns: すべての文字が [keyKind] に合う場合は `true`。
bool _isCandidateKey(
  Uint8List bytes,
  int start,
  int end,
  HiveBoxKeyKind keyKind,
) {
  switch (keyKind) {
    case HiveBoxKeyKind.business:
      for (var index = start; index < end; index++) {
        final code = bytes[index];
        final isDigit = code >= _asciiDigitZero && code <= _asciiDigitNine;
        if (!isDigit && code != _asciiHyphen) {
          return false;
        }
      }
      return true;
    case HiveBoxKeyKind.cookie:
      for (var index = start; index < end; index++) {
        if (bytes[index] >= _asciiUpperBound) {
          return false;
        }
      }
      return true;
  }
}

/// [offset] から始まる長さ [frameLength] のフレームの CRC が、鍵と一致するか
/// どうかを返します。
///
/// 呼び出し元は、フレームが [bytes] に収まり、[frameLength] が
/// [_minimumFrameLength] 以上であることを保証します。
///
/// Returns: 保存された CRC と、鍵の CRC を初期値に計算した CRC が一致する
///   場合は `true`。
bool _frameCrcMatches(
  Uint8List bytes,
  int offset,
  int frameLength,
  int keyCrc,
) {
  final crcLength = frameLength - _crcFieldSize;
  final storedCrc = _readUint32(bytes, offset + crcLength);
  final computedCrc =
      hiveCrc32(bytes, crc: keyCrc, offset: offset, length: crcLength);
  return computedCrc == storedCrc;
}

/// [verifyHiveBoxFile] の読み込みと照合を、別の isolate で実行します。
///
/// isolate へ渡す処理が不要な値を取り込まないように、必要な引数だけを持つ
/// 関数に分けています。
///
/// Returns: 照合結果。
///
/// Throws:
///   * [FileSystemException] ファイルを読めなかった場合。
Future<HiveBoxVerification> _verifyHiveBoxFileInIsolate(
  String filePath,
  int keyCrc,
  HiveBoxKeyKind keyKind,
  Duration? scanTimeLimit,
) {
  return Isolate.run(
    () => verifyHiveBoxBytes(
      File(filePath).readAsBytesSync(),
      keyCrc,
      keyKind,
      scanTimeLimit: scanTimeLimit,
    ),
  );
}

/// Box のファイルを表す [File] を作ります。
///
/// Hive 2.2.3 と同じく、ディレクトリのパス末尾の区切り文字を取り除いてから、
/// `<ディレクトリ><区切り文字><小文字の Box 名>.<拡張子>` を組み立てます。
///
/// Returns: Box のファイル。存在するかどうかは確認しません。
File _boxFile(String directoryPath, String boxName, String extension) {
  final separator = Platform.pathSeparator;
  final directory = directoryPath.endsWith(separator)
      ? directoryPath.substring(0, directoryPath.length - separator.length)
      : directoryPath;
  return File('$directory$separator${boxName.toLowerCase()}.$extension');
}

/// [file] が圧縮途中の `.hivec` であれば、Hive と同じく `.hive` へ名前を変えます。
///
/// Returns: `.hive` のファイル。
///
/// Throws:
///   * [FileSystemException] 名前の変更に失敗した場合。
Future<File> _promoteToHiveFile(
  File file,
  String directoryPath,
  String boxName,
) async {
  final hiveFile = _boxFile(directoryPath, boxName, _hiveFileExtension);
  if (file.path == hiveFile.path) {
    return file;
  }
  return file.rename(hiveFile.path);
}

/// [source] の [offset] 以降を [destination] へ写し、ディスクへ書き出して
/// 閉じます。
///
/// [destination] が既にある場合は、内容を置き換えます。
///
/// Throws:
///   * [FileSystemException] 読み書きに失敗した場合。
Future<void> _copyFileTail(File source, File destination, int offset) async {
  final input = await source.open();
  try {
    final output = await destination.open(mode: FileMode.write);
    try {
      await input.setPosition(offset);
      final buffer = Uint8List(_copyChunkSize);
      while (true) {
        final readCount = await input.readInto(buffer);
        if (readCount == 0) {
          break;
        }
        await output.writeFrom(buffer, 0, readCount);
      }
      await output.flush();
    } finally {
      await output.close();
    }
  } finally {
    await input.close();
  }
}
