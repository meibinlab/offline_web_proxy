import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:offline_web_proxy/src/storage/response_cache_store.dart';

/// テスト用の暗号化鍵。
final Uint8List _key =
    Uint8List.fromList(List<int>.generate(32, (index) => index * 3 & 0xff));

/// 0.21.0 以前と同じ形の記録を作る。
///
/// [body] 本文の文字列。
/// [createdAt] 保存日時。
///
/// Returns: 記録。
Map<String, Object?> _entry(String body, DateTime createdAt) => {
      'statusCode': 200,
      'headers': {'content-type': 'text/plain'},
      'body': Uint8List.fromList(body.codeUnits),
      'createdAt': createdAt.toIso8601String(),
      'expiresAt': createdAt.add(const Duration(hours: 1)).toIso8601String(),
      'contentType': 'text/plain',
      'sizeBytes': body.length,
    };

void main() {
  late String directory;

  setUp(() async {
    directory = Directory.systemTemp
        .createTempSync('offline_web_proxy_cache_store')
        .path;
    Hive.init(directory);
  });

  tearDown(() async {
    await Hive.close();
    try {
      Directory(directory).deleteSync(recursive: true);
    } on FileSystemException {
      // Windows で解放が遅れたファイルがあっても、テストの結果には影響しない
    }
  });

  /// 応答キャッシュを開く。
  ///
  /// [encrypt] 暗号化した組を使う場合は `true`。
  ///
  /// Returns: 開いた応答キャッシュ。
  Future<ResponseCacheStore> open({bool encrypt = false}) =>
      ResponseCacheStore.open(
        directoryPath: directory,
        encrypt: encrypt,
        encryptionKey: _key,
        openedBoxes: <BoxBase>[],
      );

  group('ResponseCacheStore（doc/specs.ja.md 【8】保存形式）', () {
    /// 本文とヘッダは本文の Box に、それ以外はメタデータの Box に分けて保存すること
    test('splits an entry into metadata and body', () async {
      final store = await open();
      final now = DateTime.now();
      await store.put('k', _entry('hello', now));

      expect(store.metadata('k')!.containsKey('body'), isFalse);
      expect(store.metadata('k')!.containsKey('headers'), isFalse);
      expect(store.metadata('k')!['sizeBytes'], equals(5));
      final read = (await store.read('k'))!;
      expect(String.fromCharCodes(read['body'] as List<int>), equals('hello'));
      expect(read['headers'], equals({'content-type': 'text/plain'}));
      expect(read['createdAt'], equals(now.toIso8601String()));
    });

    /// 置き換えた後は、新しいメタデータと本文の組だけを返すこと
    test('replaces both halves of an entry', () async {
      final store = await open();
      final now = DateTime.now();
      await store.put('k', _entry('old', now));
      await store.put(
          'k', _entry('newer', now.add(const Duration(minutes: 1))));

      expect(store.length, equals(1));
      expect(store.metadata('k')!['sizeBytes'], equals(5));
      final read = (await store.read('k'))!;
      expect(String.fromCharCodes(read['body'] as List<int>), equals('newer'));
    });

    /// 別の処理が既に開いている組は、片方だけの記録でも消さないこと
    /// （書き込みの途中を片割れと誤認しないため）
    test('keeps unpaired records while another holder has the pair open',
        () async {
      final index = await Hive.openBox(plainCacheIndexBoxName, path: directory);
      final bodies =
          await Hive.openLazyBox(plainCacheBodyBoxName, path: directory);
      // 本文を書いてメタデータを書く前の状態
      await bodies.put('in-progress', {'headers': {}, 'body': Uint8List(0)});

      await open();

      expect(bodies.containsKey('in-progress'), isTrue);
      expect(index.isOpen, isTrue);
    });

    /// 移し先に同じキーがある場合は、保存日時の新しい方を残すこと
    test('keeps the newer entry when the destination has the same key',
        () async {
      final now = DateTime.now();
      final legacy =
          await Hive.openBox(legacyPlainCacheBoxName, path: directory);
      await legacy.put('newer-in-legacy', _entry('legacy-new', now));
      await legacy.put(
        'older-in-legacy',
        _entry('legacy-old', now.subtract(const Duration(hours: 1))),
      );
      await legacy.close();

      final existing = await open(encrypt: true);
      await existing.put(
        'newer-in-legacy',
        _entry('pair-old', now.subtract(const Duration(hours: 1))),
      );
      await existing.put('older-in-legacy', _entry('pair-new', now));
      await existing.close();
      // 0.21.0 以前の平文の記録を、もう一度置いた状態にする
      final again =
          await Hive.openBox(legacyPlainCacheBoxName, path: directory);
      await again.put('newer-in-legacy', _entry('legacy-new', now));
      await again.put(
        'older-in-legacy',
        _entry('legacy-old', now.subtract(const Duration(hours: 1))),
      );
      await again.close();

      final store = await open(encrypt: true);

      String bodyOf(Map data) =>
          String.fromCharCodes(data['body'] as List<int>);
      expect(
          bodyOf((await store.read('newer-in-legacy'))!), equals('legacy-new'));
      expect(
          bodyOf((await store.read('older-in-legacy'))!), equals('pair-new'));
      expect(await Hive.boxExists(legacyPlainCacheBoxName, path: directory),
          isFalse);
    });

    /// 暗号化した組の削除は、1 つを消せなくても残りを消してから送出すること
    test('deletes the rest of the encrypted boxes when one cannot be deleted',
        () async {
      final store = await open(encrypt: true);
      await store.put('k', _entry('x', DateTime.now()));
      await store.close();
      final legacy = await Hive.openBox(
        legacyEncryptedCacheBoxName,
        path: directory,
        encryptionCipher: HiveAesCipher(_key),
      );
      await legacy.put('k', _entry('x', DateTime.now()));
      await legacy.close();

      // Windows では開いたままのファイルを削除できないため、最初の Box だけ失敗させる
      final held = await File(
        '$directory${Platform.pathSeparator}$encryptedCacheIndexBoxName.hive',
      ).open();
      try {
        await expectLater(
          ResponseCacheStore.deleteEncrypted(directory),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await held.close();
      }

      expect(await Hive.boxExists(encryptedCacheBodyBoxName, path: directory),
          isFalse);
      expect(await Hive.boxExists(legacyEncryptedCacheBoxName, path: directory),
          isFalse);
    }, skip: !Platform.isWindows);

    /// 移し終えた古いファイルを削除できなかった場合は知らせ、次に開くときに
    /// 移し直して削除すること
    test('retries deleting the legacy box at the next open', () async {
      final now = DateTime.now();
      final legacy =
          await Hive.openBox(legacyPlainCacheBoxName, path: directory);
      await legacy.put('k', _entry('legacy', now));
      await legacy.close();

      final errors = <String>[];
      // Windows では開いたままのファイルを削除できないため、削除だけを失敗させる
      final held = await File(
        '$directory${Platform.pathSeparator}$legacyPlainCacheBoxName.hive',
      ).open();
      try {
        final store = await ResponseCacheStore.open(
          directoryPath: directory,
          encrypt: false,
          encryptionKey: _key,
          openedBoxes: <BoxBase>[],
          onMigrationError: (phase, error, {failedCount}) => errors.add(phase),
        );
        expect(store.containsKey('k'), isTrue);
        await store.close();
      } finally {
        await held.close();
      }
      expect(errors, contains(cacheFormatMigrationPhase));
      expect(await Hive.boxExists(legacyPlainCacheBoxName, path: directory),
          isTrue);

      final store = await open();

      expect(store.length, equals(1));
      expect(await Hive.boxExists(legacyPlainCacheBoxName, path: directory),
          isFalse);
    }, skip: !Platform.isWindows);
  });
}
