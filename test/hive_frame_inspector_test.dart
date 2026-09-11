import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:offline_web_proxy/src/storage/hive_frame_inspector.dart';

/// Box の暗号化に使う鍵のバイト数。
const int _encryptionKeyLength = 32;

/// 1 バイトの最大値。誤った鍵を作るときと、バイトを反転するときに使う。
const int _maxByteValue = 255;

/// フレーム長の欄と CRC の欄のバイト数。
const int _uint32Size = 4;

/// フレーム先頭から見た、文字列キーの長さの欄の位置。
const int _keyLengthFieldOffset = 5;

/// フレーム先頭から見た、文字列キーの本体の位置。
const int _keyBytesOffset = 6;

/// 末尾のフレームを書きかけにするために削るバイト数。
const int _truncatedTailSize = 3;

/// テストで使う Box の名前。Hive は Box の名前を小文字で扱う。
const String _boxName = 'inspector_box';

/// 乱数で埋める大きなファイルのバイト数。
const int _largeFileSize = 32 * 1024 * 1024;

/// 乱数の種。テストの再現性のため固定する。
const int _randomSeed = 20260911;

/// `Random.nextInt` に渡す、32 ビットの値の個数。
const int _uint32Range = 0x100000000;

/// 正しい鍵。テストの再現性のため固定値にする。
final List<int> _correctKey =
    List<int>.generate(_encryptionKeyLength, (index) => index);

/// 正しい鍵と異なる鍵。
final List<int> _wrongKey = List<int>.generate(
  _encryptionKeyLength,
  (index) => _maxByteValue - index,
);

/// 現在の形式の業務キー。19 桁にゼロ埋めしたマイクロ秒と 6 桁の連番を `-` でつなぐ。
const List<String> _businessKeys = <String>[
  '0001700000000000000-000000',
  '0001700000000000000-000001',
  '0001700000000000001-000000',
];

/// 過去の形式を含む業務キーの組。形式の説明ごとに、Box へ書く順のキーを持つ。
const Map<String, List<String>> _legacyBusinessKeys = <String, List<String>>{
  '13 桁のミリ秒': <String>['1700000000000', '1700000000001', '1700000000002'],
  '16 桁のマイクロ秒': <String>[
    '1700000000000000',
    '1700000000000001',
    '1700000000000002',
  ],
  '19 桁のマイクロ秒と連番': _businessKeys,
};

/// Cookie のキー。ドメイン、パス、名前、種別をタブでつなぐ。
const List<String> _cookieKeys = <String>[
  'example.com\t/\tSESSION\thost',
  'example.com\t/\tTHEME\thost',
  '.example.com\t/app\tLANG\tdomain',
];

/// テスト用ディレクトリにある Box の `.hive` ファイルを返す。
File _hiveFile(Directory directory) =>
    File('${directory.path}${Platform.pathSeparator}$_boxName.hive');

/// テスト用ディレクトリにある Box の `.hivec` ファイルを返す。
File _compactedFile(Directory directory) =>
    File('${directory.path}${Platform.pathSeparator}$_boxName.hivec');

/// キーに対応して Box に書く値を返す。読み戻した値の確認にも使う。
String _recordValue(String key) => 'record-$key';

/// [keys] の順に記録を書いた暗号化 Box を作り、閉じてからファイルの内容を返す。
///
/// Hive は書いた順にフレームを追記するため、先頭フレームは [keys] の先頭の記録になる。
Future<Uint8List> _writeEncryptedBox(
  Directory directory,
  List<String> keys, {
  List<int>? key,
}) async {
  final box = await Hive.openBox<String>(
    _boxName,
    encryptionCipher: HiveAesCipher(key ?? _correctKey),
  );
  for (final recordKey in keys) {
    await box.put(recordKey, _recordValue(recordKey));
  }
  await box.close();
  return _hiveFile(directory).readAsBytes();
}

/// [offset] から 4 バイトをリトルエンディアンの uint32 として読む。
///
/// 実装とは別の方法（ByteData）で読み、実装の読み方に依存せずに確かめる。
int _readUint32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

/// 長さの欄を先頭からたどり、ファイルに収まる各フレームの開始位置を返す。
List<int> _frameOffsets(Uint8List bytes) {
  final offsets = <int>[];
  var offset = 0;
  while (offset + _uint32Size <= bytes.length) {
    final frameLength = _readUint32(bytes, offset);
    if (frameLength < 2 * _uint32Size || offset + frameLength > bytes.length) {
      break;
    }
    offsets.add(offset);
    offset += frameLength;
  }
  return offsets;
}

/// 先頭フレームの値（暗号文）の途中の 1 バイトを反転したコピーを返す。
///
/// 長さの欄、キー、CRC の欄は壊さないため、先頭フレームは CRC だけが一致しなくなる。
Uint8List _corruptFirstFrameValue(Uint8List bytes) {
  final frameLength = _readUint32(bytes, 0);
  final valueStart = _keyBytesOffset + bytes[_keyLengthFieldOffset];
  final valueEnd = frameLength - _uint32Size;
  final targetOffset = (valueStart + valueEnd) ~/ 2;
  final corrupted = Uint8List.fromList(bytes);
  corrupted[targetOffset] ^= _maxByteValue;
  return corrupted;
}

/// 固定の種の乱数で埋めた [length] バイトのバイト列を返す。
Uint8List _randomBytes(int length) {
  final random = Random(_randomSeed);
  final words = Uint32List(length ~/ Uint32List.bytesPerElement);
  for (var index = 0; index < words.length; index++) {
    words[index] = random.nextInt(_uint32Range);
  }
  return words.buffer.asUint8List();
}

/// 走査の所要時間をテストの出力へ記録する。合否には使わない。
void _printElapsed(String label, Duration elapsed) {
  // ignore: avoid_print
  print('$label: ${elapsed.inMilliseconds} ms');
}

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('hive_frame_inspector_test');
    Hive.init(tempDirectory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  group('hiveCrc32 と hiveKeyCrc', () {
    /// 標準の CRC32 の検査値と同じ値を計算できること。
    test('"123456789" の CRC32 が 0xCBF43926 であること', () {
      final bytes = Uint8List.fromList(ascii.encode('123456789'));

      // CRC32 の標準の検査値と一致する
      expect(hiveCrc32(bytes), 0xCBF43926);
    });

    /// 途中までの結果を初期値に渡すと、開始位置から末尾まで続けて計算できること。
    test('初期値と開始位置を指定すると、続きから計算できること', () {
      final bytes = Uint8List.fromList(ascii.encode('123456789'));
      const splitOffset = 4;

      final headCrc = hiveCrc32(bytes, length: splitOffset);
      final continuedCrc = hiveCrc32(bytes, crc: headCrc, offset: splitOffset);

      // 分けて計算しても、全体を一度に計算した値と一致する
      expect(continuedCrc, hiveCrc32(bytes));
    });

    /// 鍵の CRC が、Hive と同じく鍵の SHA-256 を CRC32 で計算した値であること。
    test('鍵の CRC が鍵の SHA-256 の CRC32 と一致すること', () {
      final digest = Uint8List.fromList(sha256.convert(_correctKey).bytes);

      // Hive の Crc32 で計算された値と、自前の CRC32 で計算した値が一致する
      expect(hiveKeyCrc(_correctKey), hiveCrc32(digest));
    });

    /// Hive が暗号化 Box に書いた各フレームの CRC を、鍵の CRC を初期値にして再計算できること。
    test('Hive が書いたフレームの CRC を再計算すると一致すること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);
      final keyCrc = hiveKeyCrc(_correctKey);

      final offsets = _frameOffsets(bytes);

      // 書いた記録の数だけ、ファイル末尾までフレームをたどれる
      expect(offsets, hasLength(_businessKeys.length));

      // 各フレームで、保存された CRC と再計算した CRC が一致する
      for (final offset in offsets) {
        final crcLength = _readUint32(bytes, offset) - _uint32Size;
        expect(
          hiveCrc32(bytes, crc: keyCrc, offset: offset, length: crcLength),
          _readUint32(bytes, offset + crcLength),
          reason: '位置 $offset のフレーム',
        );
      }
    });
  });

  group('verifyHiveBoxBytes', () {
    /// 書いたときと同じ鍵で照合すると、先頭フレームが一致して match になること。
    test('正しい鍵では match になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);

      final result = verifyHiveBoxBytes(
        bytes,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 先頭フレームが鍵と一致する
      expect(result.status, HiveBoxVerificationStatus.match);
      // corrupted 以外では一致したフレームの位置を持たない
      expect(result.matchingFrameOffset, isNull);
    });

    /// 別の鍵で照合すると、先頭も後ろのフレームも一致せず mismatch になること。
    test('誤った鍵では mismatch になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);

      final result = verifyHiveBoxBytes(
        bytes,
        hiveKeyCrc(_wrongKey),
        HiveBoxKeyKind.business,
      );

      // 先頭フレームは完全な長さを持つのに CRC が一致せず、後ろにも一致するフレームが無い
      expect(result.status, HiveBoxVerificationStatus.mismatch);
    });

    /// 末尾のフレームが書きかけでも、先頭フレームが一致すれば match になること。
    test('末尾のフレームが書きかけでも先頭が一致すれば match になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);
      final truncated = bytes.sublist(0, bytes.length - _truncatedTailSize);

      final result = verifyHiveBoxBytes(
        truncated,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 先頭フレームだけで一致を判定し、書きかけの末尾は判定に影響しない
      expect(result.status, HiveBoxVerificationStatus.match);
    });

    /// 先頭フレームの途中でファイルが終わり、後ろに一致するフレームも無い場合は noMismatch になること。
    test('先頭フレームが書きかけで一致するフレームが無い場合は noMismatch になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);
      final truncated = bytes.sublist(0, _readUint32(bytes, 0) ~/ 2);

      final result = verifyHiveBoxBytes(
        truncated,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 照合できないだけで不一致の根拠も無いため、mismatch とは区別する
      expect(result.status, HiveBoxVerificationStatus.noMismatch);
    });

    /// 先頭フレームの長さの欄だけが壊れた場合、2 番目のフレームの位置で corrupted になること。
    test('長さの欄が壊れ、後ろに一致するフレームがある場合は corrupted になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);
      final secondFrameOffset = _frameOffsets(bytes)[1];
      final corrupted = Uint8List.fromList(bytes)
        ..fillRange(0, _uint32Size, _maxByteValue);

      final result = verifyHiveBoxBytes(
        corrupted,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 先頭の破損を判定する
      expect(result.status, HiveBoxVerificationStatus.corrupted);
      // 鍵と一致した最初のフレームは 2 番目のフレーム
      expect(result.matchingFrameOffset, secondFrameOffset);
    });

    /// 先頭フレームの値の 1 バイトが壊れた場合、2 番目のフレームの位置で corrupted になること。
    test('先頭フレームの値が壊れ、後ろが一致する場合は corrupted になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);
      final secondFrameOffset = _frameOffsets(bytes)[1];

      final result = verifyHiveBoxBytes(
        _corruptFirstFrameValue(bytes),
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 先頭の破損を判定する
      expect(result.status, HiveBoxVerificationStatus.corrupted);
      // 鍵と一致した最初のフレームは 2 番目のフレーム
      expect(result.matchingFrameOffset, secondFrameOffset);
    });

    /// Cookie のキーを持つ Box は、Cookie の種類で走査すると先頭の破損を判定できること。
    test('Cookie のキーの Box は keyKind cookie で corrupted になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _cookieKeys);
      final secondFrameOffset = _frameOffsets(bytes)[1];

      final result = verifyHiveBoxBytes(
        _corruptFirstFrameValue(bytes),
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.cookie,
      );

      // タブを含む ASCII のキーを候補にして、先頭の破損を判定する
      expect(result.status, HiveBoxVerificationStatus.corrupted);
      // 鍵と一致した最初のフレームは 2 番目のフレーム
      expect(result.matchingFrameOffset, secondFrameOffset);
    });

    /// Cookie のキーはタブと英字を含むため、業務キーの種類では候補にならず mismatch になること。
    test('Cookie のキーの Box は keyKind business では mismatch になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _cookieKeys);

      final result = verifyHiveBoxBytes(
        _corruptFirstFrameValue(bytes),
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 後ろのフレームが候補から外れるため、一致するフレームが見つからない
      expect(result.status, HiveBoxVerificationStatus.mismatch);
    });

    /// 時間の上限に Duration.zero を渡すと、走査が必要な Box では必ず aborted になること。
    test('上限が Duration.zero の場合、走査が必要な Box は aborted になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);

      final result = verifyHiveBoxBytes(
        bytes,
        hiveKeyCrc(_wrongKey),
        HiveBoxKeyKind.business,
        scanTimeLimit: Duration.zero,
      );

      // 先頭が一致しないため走査が必要になり、開始直後に打ち切る
      expect(result.status, HiveBoxVerificationStatus.aborted);
    });

    /// 時間の上限に Duration.zero を渡しても、先頭が一致する Box は走査しないため match になること。
    test('上限が Duration.zero でも、先頭が一致する Box は match になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);

      final result = verifyHiveBoxBytes(
        bytes,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
        scanTimeLimit: Duration.zero,
      );

      // 先頭フレームの照合だけで判定するため、時間の上限の影響を受けない
      expect(result.status, HiveBoxVerificationStatus.match);
    });

    /// 長さの欄を読めない 4 バイト未満の内容は、照合できないため noMismatch になること。
    test('4 バイト未満の内容は noMismatch になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);

      final result = verifyHiveBoxBytes(
        bytes.sublist(0, _uint32Size - 1),
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 照合できないだけで不一致の根拠も無い
      expect(result.status, HiveBoxVerificationStatus.noMismatch);
    });

    /// 長さの欄が 8 未満の場合は、Hive と同じく破損として扱い、一致するフレームが無ければ mismatch になること。
    test('長さの欄が 8 未満で一致するフレームが無い場合は mismatch になること', () async {
      final bytes = await _writeEncryptedBox(
        tempDirectory,
        <String>[_businessKeys.first],
      );
      final corrupted = Uint8List.fromList(bytes);
      ByteData.sublistView(corrupted).setUint32(
        0,
        2 * _uint32Size - 1,
        Endian.little,
      );

      final result = verifyHiveBoxBytes(
        corrupted,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 照合不能ではなく不一致として扱う
      expect(result.status, HiveBoxVerificationStatus.mismatch);
    });

    /// 走査が時間の上限内に終われば、上限を指定しても打ち切らずに corrupted を判定すること。
    test('上限内に走査が終われば corrupted を判定できること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);
      final secondFrameOffset = _frameOffsets(bytes)[1];

      final result = verifyHiveBoxBytes(
        _corruptFirstFrameValue(bytes),
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
        scanTimeLimit: const Duration(minutes: 1),
      );

      // 打ち切らずに先頭の破損を判定する
      expect(result.status, HiveBoxVerificationStatus.corrupted);
      // 鍵と一致した最初のフレームは 2 番目のフレーム
      expect(result.matchingFrameOffset, secondFrameOffset);
    });

    /// 0 バイトの内容は、照合する記録が無いため empty になること。
    test('0 バイトの内容は empty になること', () {
      final result = verifyHiveBoxBytes(
        Uint8List(0),
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 照合する記録が無い
      expect(result.status, HiveBoxVerificationStatus.empty);
    });
  });

  group('verifyHiveBoxFile', () {
    /// isolate でファイルを読んで照合した結果が、同じ内容を直接照合した結果と一致すること。
    test('isolate 経由でも verifyHiveBoxBytes と同じ結果になること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);
      final corrupted = _corruptFirstFrameValue(bytes);
      final file = _hiveFile(tempDirectory);
      await file.writeAsBytes(corrupted, flush: true);
      final keyCrc = hiveKeyCrc(_correctKey);

      final fileResult =
          await verifyHiveBoxFile(file.path, keyCrc, HiveBoxKeyKind.business);
      final bytesResult =
          verifyHiveBoxBytes(corrupted, keyCrc, HiveBoxKeyKind.business);

      // 位置まで比べられるように、比較の基準は corrupted の結果である
      expect(bytesResult.status, HiveBoxVerificationStatus.corrupted);
      // 結果の種類が一致する
      expect(fileResult.status, bytesResult.status);
      // 一致したフレームの位置が一致する
      expect(fileResult.matchingFrameOffset, bytesResult.matchingFrameOffset);
    });

    /// ファイルが無い場合は empty になること。
    test('ファイルが無い場合は empty になること', () async {
      final result = await verifyHiveBoxFile(
        _hiveFile(tempDirectory).path,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 照合する記録が無い
      expect(result.status, HiveBoxVerificationStatus.empty);
    });

    /// 0 バイトのファイルは empty になること。
    test('0 バイトのファイルは empty になること', () async {
      final file = _hiveFile(tempDirectory);
      await file.writeAsBytes(const <int>[], flush: true);

      final result = await verifyHiveBoxFile(
        file.path,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );

      // 照合する記録が無い
      expect(result.status, HiveBoxVerificationStatus.empty);
    });

    /// 先頭フレームだけで数 MB ある大きな Box でも、先頭フレームが鍵と一致すれば match になり、
    /// 別の鍵では mismatch になること。所要時間は記録するだけで合否に使わない。
    test('先頭フレームが数 MB の大きな Box でも正しく照合できること', () async {
      // 1 件あたりの値のバイト数。先頭フレームを数 MB にするために大きくする
      const recordSize = 2 * 1024 * 1024;
      final box = await Hive.openBox<Uint8List>(
        _boxName,
        encryptionCipher: HiveAesCipher(_correctKey),
      );
      for (var index = 0; index < _businessKeys.length; index++) {
        await box.put(
          _businessKeys[index],
          Uint8List(recordSize)..fillRange(0, recordSize, index + 1),
        );
      }
      await box.close();
      final file = _hiveFile(tempDirectory);
      final bytes = await file.readAsBytes();

      // 前提: 先頭フレームだけで数 MB あり、ファイル全体はさらに大きいこと
      expect(_readUint32(bytes, 0), greaterThan(recordSize));
      expect(bytes.length, greaterThan(_businessKeys.length * recordSize));

      final stopwatch = Stopwatch()..start();
      final matched = await verifyHiveBoxFile(
        file.path,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );
      stopwatch.stop();
      _printElapsed(
        'verifyHiveBoxFile（先頭フレームが一致、${bytes.length} バイト）',
        stopwatch.elapsed,
      );

      // 大きな先頭フレームでも、鍵と一致すると判定する
      expect(matched.status, HiveBoxVerificationStatus.match);
      // corrupted 以外では一致したフレームの位置を持たない
      expect(matched.matchingFrameOffset, isNull);

      final mismatched = await verifyHiveBoxFile(
        file.path,
        hiveKeyCrc(_wrongKey),
        HiveBoxKeyKind.business,
      );

      // 別の鍵では、大きな先頭フレームを一致と誤って判定しない
      expect(mismatched.status, HiveBoxVerificationStatus.mismatch);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('findHiveBoxFile、hasHiveBoxContent、truncateHiveBox', () {
    /// `.hive` が無く `.hivec` だけがある場合、`.hivec` を見つけて照合できること。
    test('.hivec だけがある場合も見つけて照合できること', () async {
      await _writeEncryptedBox(tempDirectory, _businessKeys);
      await _hiveFile(tempDirectory).rename(_compactedFile(tempDirectory).path);

      final found = findHiveBoxFile(tempDirectory.path, _boxName);

      // Hive と同じく、.hive が無ければ .hivec を使う
      expect(found?.path, _compactedFile(tempDirectory).path);
      // .hivec の内容も鍵と照合できる
      final result = await verifyHiveBoxFile(
        found!.path,
        hiveKeyCrc(_correctKey),
        HiveBoxKeyKind.business,
      );
      expect(result.status, HiveBoxVerificationStatus.match);
    });

    /// `.hive` と `.hivec` の両方がある場合、Hive と同じく `.hive` を優先すること。
    test('.hive と .hivec の両方がある場合は .hive を返すこと', () async {
      await _writeEncryptedBox(tempDirectory, _businessKeys);
      await _compactedFile(tempDirectory).writeAsBytes(const <int>[1, 2, 3]);

      final found = findHiveBoxFile(tempDirectory.path, _boxName);

      // .hive を優先する
      expect(found?.path, _hiveFile(tempDirectory).path);
    });

    /// Box のファイルが無い場合、ファイルは見つからず、内容も無いと判定すること。
    test('Box のファイルが無い場合は null と false を返すこと', () async {
      // どちらのファイルも無い
      expect(findHiveBoxFile(tempDirectory.path, _boxName), isNull);
      // 内容が無い
      expect(await hasHiveBoxContent(tempDirectory.path, _boxName), isFalse);
    });

    /// 切り詰めると 0 バイトになり、内容が無いと判定すること。
    test('truncateHiveBox で 0 バイトになり、hasHiveBoxContent が false になること',
        () async {
      await _writeEncryptedBox(tempDirectory, _businessKeys);

      // 切り詰める前は内容がある
      expect(await hasHiveBoxContent(tempDirectory.path, _boxName), isTrue);

      await truncateHiveBox(tempDirectory.path, _boxName);

      // .hive が 0 バイトになる
      expect(await _hiveFile(tempDirectory).length(), 0);
      // 内容が無いと判定する
      expect(await hasHiveBoxContent(tempDirectory.path, _boxName), isFalse);
    });

    /// `.hivec` だけがある場合、`.hive` へ名前を変えてから切り詰めること。
    test('.hivec だけがある場合は .hive へ名前を変えてから切り詰めること', () async {
      await _writeEncryptedBox(tempDirectory, _businessKeys);
      await _hiveFile(tempDirectory).rename(_compactedFile(tempDirectory).path);

      await truncateHiveBox(tempDirectory.path, _boxName);

      // .hive が 0 バイトで作られる
      expect(await _hiveFile(tempDirectory).length(), 0);
      // .hivec は残らない
      expect(_compactedFile(tempDirectory).existsSync(), isFalse);
      // 内容が無いと判定する
      expect(await hasHiveBoxContent(tempDirectory.path, _boxName), isFalse);
    });
  });

  group('rebuildHiveBoxFromOffset', () {
    /// 過去の形式のキーを含む Box でも先頭の破損を判定でき、作り直すと壊した先頭以外の記録を
    /// 正しい鍵で読めること。形式ごとにテストを分ける。
    for (final entry in _legacyBusinessKeys.entries) {
      test('${entry.key}のキーの Box を作り直すと、先頭以外の記録を読めること', () async {
        final keys = entry.value;
        final bytes = await _writeEncryptedBox(tempDirectory, keys);
        final corrupted = _corruptFirstFrameValue(bytes);
        final hiveFile = _hiveFile(tempDirectory);
        await hiveFile.writeAsBytes(corrupted, flush: true);
        final keyCrc = hiveKeyCrc(_correctKey);
        final secondFrameOffset = _frameOffsets(bytes)[1];

        final verification =
            verifyHiveBoxBytes(corrupted, keyCrc, HiveBoxKeyKind.business);

        // 過去の形式のキーも候補になり、先頭の破損を判定する
        expect(verification.status, HiveBoxVerificationStatus.corrupted);
        // 鍵と一致した最初のフレームは 2 番目のフレーム
        expect(verification.matchingFrameOffset, secondFrameOffset);

        await rebuildHiveBoxFromOffset(
          tempDirectory.path,
          _boxName,
          verification.matchingFrameOffset!,
        );

        // 作り直した .hive は、一致したフレーム以降の内容と同じになる
        expect(
          await hiveFile.readAsBytes(),
          corrupted.sublist(secondFrameOffset),
        );
        // 圧縮途中のファイルは残らない
        expect(_compactedFile(tempDirectory).existsSync(), isFalse);
        // 作り直した Box は先頭フレームから鍵と一致する
        final rebuiltVerification = await verifyHiveBoxFile(
          hiveFile.path,
          keyCrc,
          HiveBoxKeyKind.business,
        );
        expect(rebuiltVerification.status, HiveBoxVerificationStatus.match);

        final box = await Hive.openBox<String>(
          _boxName,
          encryptionCipher: HiveAesCipher(_correctKey),
        );
        // 壊した先頭の記録は無い
        expect(box.containsKey(keys.first), isFalse);
        // 先頭以外の記録がすべて残る
        expect(box.length, keys.length - 1);
        // 先頭以外の記録の値を正しく読める
        for (final key in keys.skip(1)) {
          expect(box.get(key), _recordValue(key), reason: 'キー $key');
        }
        await box.close();
      });
    }

    /// `.hive` が無く `.hivec` だけがある場合も、`.hivec` を元に作り直せること。
    test('.hivec だけがある Box も作り直せること', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);
      final corrupted = _corruptFirstFrameValue(bytes);
      await _compactedFile(tempDirectory).writeAsBytes(corrupted, flush: true);
      await _hiveFile(tempDirectory).delete();
      final secondFrameOffset = _frameOffsets(bytes)[1];

      await rebuildHiveBoxFromOffset(
        tempDirectory.path,
        _boxName,
        secondFrameOffset,
      );

      // .hive が、一致したフレーム以降の内容で作られる
      expect(
        await _hiveFile(tempDirectory).readAsBytes(),
        corrupted.sublist(secondFrameOffset),
      );
      // .hivec は残らない
      expect(_compactedFile(tempDirectory).existsSync(), isFalse);
    });

    /// 作り直す位置がファイルの範囲外の場合は ArgumentError となり、ファイルを変更しないこと。
    test('位置が範囲外の場合は ArgumentError となり、ファイルを変更しないこと', () async {
      final bytes = await _writeEncryptedBox(tempDirectory, _businessKeys);

      // 負の位置は範囲外
      await expectLater(
        rebuildHiveBoxFromOffset(tempDirectory.path, _boxName, -1),
        throwsArgumentError,
      );
      // ファイルの長さ以上の位置は範囲外
      await expectLater(
        rebuildHiveBoxFromOffset(tempDirectory.path, _boxName, bytes.length),
        throwsArgumentError,
      );
      // 元の .hive は変更されない
      expect(await _hiveFile(tempDirectory).readAsBytes(), bytes);
      // .hivec は作られない
      expect(_compactedFile(tempDirectory).existsSync(), isFalse);
    });

    /// Box のファイルが無い場合は FileSystemException となること。
    test('Box のファイルが無い場合は FileSystemException となること', () async {
      // 作り直す元が無い
      await expectLater(
        rebuildHiveBoxFromOffset(tempDirectory.path, _boxName, 0),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('大きなファイルの走査', () {
    /// 乱数で埋めた 32 MB のファイルを上限なしで走査し、所要時間を記録すること。
    ///
    /// 所要時間は実行環境で変わるため合否に使わず、鍵と一致するフレームが無いと
    /// 判定することだけを確認する。
    test(
      '乱数で埋めた 32 MB のファイルを上限なしで走査できること',
      () async {
        final bytes = _randomBytes(_largeFileSize);
        final file = _hiveFile(tempDirectory);
        await file.writeAsBytes(bytes, flush: true);
        final keyCrc = hiveKeyCrc(_correctKey);
        const notMatchedStatuses = <HiveBoxVerificationStatus>[
          HiveBoxVerificationStatus.noMismatch,
          HiveBoxVerificationStatus.mismatch,
        ];

        for (final keyKind in HiveBoxKeyKind.values) {
          final stopwatch = Stopwatch()..start();
          final result = verifyHiveBoxBytes(bytes, keyCrc, keyKind);
          stopwatch.stop();
          _printElapsed(
            'verifyHiveBoxBytes（${keyKind.name}、32 MB）',
            stopwatch.elapsed,
          );

          // 乱数の中に鍵と一致するフレームは無い
          expect(result.status, isIn(notMatchedStatuses));
        }

        final stopwatch = Stopwatch()..start();
        final fileResult = await verifyHiveBoxFile(
          file.path,
          keyCrc,
          HiveBoxKeyKind.business,
        );
        stopwatch.stop();
        _printElapsed(
          'verifyHiveBoxFile（business、32 MB、読み込みと isolate の起動を含む）',
          stopwatch.elapsed,
        );

        // isolate 経由でも、鍵と一致するフレームは無いと判定する
        expect(fileResult.status, isIn(notMatchedStatuses));
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
