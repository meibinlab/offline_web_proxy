/// 応答キャッシュを、メタデータの Box と本文の LazyBox に分けて保存する部品です。
///
/// Hive の通常の Box は、開くときに全件を読み込み（暗号化 Box では全件を
/// 復号し）、閉じるまでメモリに置きます。応答キャッシュは本文を含めると
/// 数百 MB になり得るため、本文とヘッダは 1 件ずつ読む LazyBox に置き、
/// 有効期限・保存日時・大きさなど走査に使う小さな値だけを通常の Box に
/// 置きます。期限切れの削除、容量の上限による削除、統計は本文を読まずに
/// 行えます。
///
/// 書き込みは本文 → メタデータ、削除はメタデータ → 本文の順に行います。
/// 途中で止まっても、メタデータだけがあって本文が無い記録は作りません。
/// 本文だけが残った記録は、次に開くときに削除します。
///
/// proxy の内部実装用で、ライブラリからは公開しません。
library;

import 'dart:typed_data';

import 'package:hive/hive.dart';

/// 平文で保存する応答キャッシュの、メタデータの Box 名です。
const String plainCacheIndexBoxName = 'proxy_cache_index';

/// 平文で保存する応答キャッシュの、本文の Box 名です。
const String plainCacheBodyBoxName = 'proxy_cache_body';

/// 暗号化して保存する応答キャッシュの、メタデータの Box 名です。
const String encryptedCacheIndexBoxName = 'proxy_cache_index_secure';

/// 暗号化して保存する応答キャッシュの、本文の Box 名です。
const String encryptedCacheBodyBoxName = 'proxy_cache_body_secure';

/// 0.21.0 以前が平文で保存した応答キャッシュの Box 名です。
///
/// 1 件の値に、メタデータと本文をまとめて保存していました。
const String legacyPlainCacheBoxName = 'proxy_cache';

/// 0.21.0 が暗号化して保存した応答キャッシュの Box 名です。
///
/// 1 件の値に、メタデータと本文をまとめて保存していました。
const String legacyEncryptedCacheBoxName = 'proxy_cache_secure';

/// 応答キャッシュが使う Box 名の一覧です。
///
/// 別のインスタンスが開いている Box を、ファイルを置き換える前に閉じるために
/// 使います。
const List<String> responseCacheBoxNames = [
  plainCacheIndexBoxName,
  plainCacheBodyBoxName,
  encryptedCacheIndexBoxName,
  encryptedCacheBodyBoxName,
  legacyPlainCacheBoxName,
  legacyEncryptedCacheBoxName,
];

/// 本文の Box に保存する、ヘッダの項目名です。
const String _headersField = 'headers';

/// 本文の Box に保存する、本文の項目名です。
const String _bodyField = 'body';

/// 暗号化した保存領域へ移すときの失敗を知らせる phase です。
const String cacheEncryptionMigrationPhase = 'cacheEncryptionMigration';

/// 平文のまま保存形式だけを移すときの失敗を知らせる phase です。
const String cacheFormatMigrationPhase = 'cacheFormatMigration';

/// 応答キャッシュの移行で起きた失敗を知らせる関数です。
///
/// [phase] 失敗した処理（[cacheEncryptionMigrationPhase] か
///   [cacheFormatMigrationPhase]）。
/// [error] 最後に起きた例外やエラー。
/// [failedCount] 移せなかった記録の件数。移行全体が失敗した場合は `null`。
typedef CacheMigrationErrorReporter = void Function(
  String phase,
  Object error, {
  int? failedCount,
});

/// メタデータの Box と本文の LazyBox を組にした応答キャッシュです。
///
/// 値は、0.21.0 以前と同じ形の `Map`（`statusCode`、`headers`、`body`、
/// `createdAt`、`expiresAt`、`contentType`、`sizeBytes`）で受け渡します。
/// メタデータの Box には `headers` と `body` 以外を、本文の Box には
/// `headers` と `body` を保存します。
class ResponseCacheStore {
  ResponseCacheStore._(this._index, this._bodies);

  /// 走査に使う小さな値を保存する Box。開いている間は全件がメモリにあります。
  final Box _index;

  /// ヘッダと本文を保存する LazyBox。値は読むたびにファイルから読みます。
  final LazyBox _bodies;

  /// 応答キャッシュを開き、古い形式や暗号化の設定を変える前の記録を移します。
  ///
  /// [encrypt] が `false` の場合に残っている暗号化した記録は、呼び出し側が
  /// 先に [deleteEncrypted] で削除します。平文へ戻して移すことはしません。
  ///
  /// 開いた後、次の記録を 1 件ずつ移し、移し終えた Box のファイルを削除します。
  /// 移せなかった記録は捨てて残りを移し続け、件数を [onMigrationError] で
  /// 知らせます。キャッシュは上流から取り直せるうえ、平文のファイルを残さない
  /// ことを優先するためです。移し先に同じキーがある場合は、保存日時
  /// （`createdAt`）の新しい方を残します。
  ///
  /// * 0.21.0 以前の平文の記録（[legacyPlainCacheBoxName]）
  /// * [encrypt] が `true` の場合は、平文の組（[plainCacheIndexBoxName] と
  ///   [plainCacheBodyBoxName]）と、0.21.0 の暗号化した記録
  ///   （[legacyEncryptedCacheBoxName]）
  ///
  /// 鍵と合わない暗号化 Box（移し先と、0.21.0 の暗号化した記録）は、Hive が
  /// 開くときに空へ切り詰めます。
  ///
  /// [directoryPath] Hive の保存先ディレクトリ。
  /// [encrypt] 暗号化した Box を使う場合は `true`。
  /// [encryptionKey] 暗号化 Box の鍵。
  /// [openedBoxes] この呼び出しで新たに開いた Box を加える一覧。呼び出し側が
  ///   後続の処理に失敗したときに閉じるために使います。
  /// [onMigrationError] 移行の失敗を知らせる関数。
  /// [beforeEntryMoved] 1 件移す直前に呼ぶ関数（テスト用）。
  ///
  /// Returns: 開いた応答キャッシュ。
  ///
  /// Throws:
  ///   * [HiveError] または `FileSystemException` Box を開けない場合。
  static Future<ResponseCacheStore> open({
    required String directoryPath,
    required bool encrypt,
    required Uint8List encryptionKey,
    required List<BoxBase> openedBoxes,
    CacheMigrationErrorReporter? onMigrationError,
    Future<void> Function(Object key)? beforeEntryMoved,
  }) async {
    final cipher = encrypt ? HiveAesCipher(encryptionKey) : null;
    final indexName =
        encrypt ? encryptedCacheIndexBoxName : plainCacheIndexBoxName;
    final bodyName =
        encrypt ? encryptedCacheBodyBoxName : plainCacheBodyBoxName;

    final indexWasOpen = Hive.isBoxOpen(indexName);
    final index = await Hive.openBox(
      indexName,
      path: directoryPath,
      encryptionCipher: cipher,
    );
    if (!indexWasOpen) {
      openedBoxes.add(index);
    }
    final bodiesWereOpen = Hive.isBoxOpen(bodyName);
    final bodies = await Hive.openLazyBox(
      bodyName,
      path: directoryPath,
      encryptionCipher: cipher,
    );
    if (!bodiesWereOpen) {
      openedBoxes.add(bodies);
    }

    final store = ResponseCacheStore._(index, bodies);
    // 別のインスタンスが使っている組は、書き込みの途中を片割れと誤認しないよう触らない
    if (!indexWasOpen && !bodiesWereOpen) {
      await store._removeUnpairedRecords();
    }

    final migration = _CacheMigration(
      target: store,
      directoryPath: directoryPath,
      onError: onMigrationError,
      beforeEntryMoved: beforeEntryMoved,
    );
    if (encrypt) {
      await migration.movePair(
        indexName: plainCacheIndexBoxName,
        bodyName: plainCacheBodyBoxName,
      );
      await migration.moveLegacy(
        legacyPlainCacheBoxName,
        phase: cacheEncryptionMigrationPhase,
      );
      await migration.moveLegacy(
        legacyEncryptedCacheBoxName,
        phase: cacheEncryptionMigrationPhase,
        cipher: cipher,
      );
    } else {
      await migration.moveLegacy(
        legacyPlainCacheBoxName,
        phase: cacheFormatMigrationPhase,
      );
    }
    return store;
  }

  /// 暗号化した応答キャッシュの Box をファイルごと削除します。
  ///
  /// 0.21.0 の [legacyEncryptedCacheBoxName] も削除します。開いている場合は
  /// Hive が閉じてから削除します。1 つを削除できなくても、残りの削除を
  /// 続けてから送出します。
  ///
  /// [directoryPath] Hive の保存先ディレクトリ。
  ///
  /// Throws:
  ///   * `FileSystemException` など、削除できなかった Box のうち最後の例外。
  static Future<void> deleteEncrypted(String directoryPath) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (final name in const [
      encryptedCacheIndexBoxName,
      encryptedCacheBodyBoxName,
      legacyEncryptedCacheBoxName,
    ]) {
      try {
        await Hive.deleteBoxFromDisk(name, path: directoryPath);
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStackTrace!);
    }
  }

  /// 開いている応答キャッシュの Box を、名前で探してすべて閉じます。
  ///
  /// 別のインスタンスが開いている Box も閉じます。ファイルを削除したり
  /// 置き換えたりする前に呼びます。
  static Future<void> closeAllOpen() async {
    for (final name in responseCacheBoxNames) {
      await _closeIfOpen(name);
    }
  }

  /// 開いている Box を、通常の Box か LazyBox かを問わず閉じます。
  ///
  /// [name] Box 名。
  static Future<void> _closeIfOpen(String name) async {
    if (!Hive.isBoxOpen(name)) {
      return;
    }
    try {
      await Hive.box(name).close();
    } on HiveError {
      // LazyBox を Hive.box で取り出すと HiveError になる
      await Hive.lazyBox(name).close();
    }
  }

  /// メタデータの Box と本文の Box が、どちらも開いているかどうかです。
  bool get isOpen => _index.isOpen && _bodies.isOpen;

  /// 保存している記録のキーです。
  Iterable<dynamic> get keys => _index.keys;

  /// 保存している記録の件数です。
  int get length => _index.length;

  /// 指定したキーの記録があるかを返します。
  ///
  /// [key] 記録のキー。
  ///
  /// Returns: 記録がある場合は `true`。
  bool containsKey(Object key) => _index.containsKey(key);

  /// 記録のメタデータ（`headers` と `body` を除いた値）を返します。
  ///
  /// 本文を読まないため、全件の走査に使います。
  ///
  /// [key] 記録のキー。
  ///
  /// Returns: メタデータ。記録が無い場合は `null`。
  Map? metadata(Object key) {
    final value = _index.get(key);
    return value is Map ? value : null;
  }

  /// 記録全体（メタデータ、ヘッダ、本文）を読みます。
  ///
  /// [key] 記録のキー。
  ///
  /// Returns: 0.21.0 以前と同じ形の記録。記録が無い場合や、本文を
  ///   読めない場合は `null`。
  Future<Map?> read(Object key) async {
    final meta = metadata(key);
    if (meta == null) {
      return null;
    }
    final body = await _bodies.get(key);
    if (body is! Map) {
      return null;
    }
    return <dynamic, dynamic>{
      ...meta,
      _headersField: body[_headersField],
      _bodyField: body[_bodyField],
    };
  }

  /// 記録を保存します。同じキーの記録は置き換えます。
  ///
  /// 本文 → メタデータの順に書きます。置き換える場合は、先に古いメタデータを
  /// 消します。新しい本文と古いメタデータの組を、読み取りや途中で止まった
  /// 後の起動に見せないためです（その間は記録が無いものとして扱われます）。
  ///
  /// [key] 記録のキー。
  /// [data] 0.21.0 以前と同じ形の記録。
  ///
  /// Throws:
  ///   * [HiveError] Box が閉じている場合。
  Future<void> put(Object key, Map data) async {
    if (_index.containsKey(key)) {
      await _index.delete(key);
    }
    await _bodies.put(key, <String, dynamic>{
      _headersField: data[_headersField],
      _bodyField: data[_bodyField],
    });
    await _index.put(key, <dynamic, dynamic>{
      for (final entry in data.entries)
        if (entry.key != _headersField && entry.key != _bodyField)
          entry.key: entry.value,
    });
  }

  /// 記録を削除します。
  ///
  /// メタデータ → 本文の順に消します。
  ///
  /// [keys] 削除する記録のキー。
  ///
  /// Throws:
  ///   * [HiveError] Box が閉じている場合。
  Future<void> deleteAll(Iterable<Object> keys) async {
    final keyList = keys.toList(growable: false);
    if (keyList.isEmpty) {
      return;
    }
    await _index.deleteAll(keyList);
    await _bodies.deleteAll(keyList);
  }

  /// 記録を 1 件削除します。
  ///
  /// [key] 削除する記録のキー。
  ///
  /// Throws:
  ///   * [HiveError] Box が閉じている場合。
  Future<void> delete(Object key) => deleteAll([key]);

  /// すべての記録を削除します。
  ///
  /// Throws:
  ///   * [HiveError] Box が閉じている場合。
  Future<void> clear() async {
    await _index.clear();
    await _bodies.clear();
  }

  /// Box を閉じます。
  Future<void> close() async {
    if (_index.isOpen) {
      await _index.close();
    }
    if (_bodies.isOpen) {
      await _bodies.close();
    }
  }

  /// 片方の Box にしかない記録を削除します。
  ///
  /// 本文 → メタデータの順に書くため、書き込みの途中で止まると本文だけが
  /// 残ります。メタデータだけがある記録は、鍵と合わない Box を Hive が
  /// 片方だけ切り詰めた場合などに残ります。
  Future<void> _removeUnpairedRecords() async {
    final unpairedIndexKeys = _index.keys
        .where((key) => !_bodies.containsKey(key))
        .toList(growable: false);
    final unpairedBodyKeys = _bodies.keys
        .where((key) => !_index.containsKey(key))
        .toList(growable: false);
    if (unpairedIndexKeys.isNotEmpty) {
      await _index.deleteAll(unpairedIndexKeys);
    }
    if (unpairedBodyKeys.isNotEmpty) {
      await _bodies.deleteAll(unpairedBodyKeys);
    }
  }
}

/// 古い形式や、暗号化の設定を変える前の記録を移す処理です。
class _CacheMigration {
  _CacheMigration({
    required this.target,
    required this.directoryPath,
    required this.onError,
    required this.beforeEntryMoved,
  });

  /// 移し先の応答キャッシュ。
  final ResponseCacheStore target;

  /// Hive の保存先ディレクトリ。
  final String directoryPath;

  /// 移行の失敗を知らせる関数。
  final CacheMigrationErrorReporter? onError;

  /// 1 件移す直前に呼ぶ関数（テスト用）。
  final Future<void> Function(Object key)? beforeEntryMoved;

  /// 平文の組（メタデータと本文）を、暗号化した組へ移します。
  ///
  /// 例外は送出しません。
  ///
  /// [indexName] 移し元のメタデータの Box 名。
  /// [bodyName] 移し元の本文の Box 名。
  Future<void> movePair({
    required String indexName,
    required String bodyName,
  }) async {
    const phase = cacheEncryptionMigrationPhase;
    try {
      if (!await Hive.boxExists(indexName, path: directoryPath) &&
          !await Hive.boxExists(bodyName, path: directoryPath)) {
        return;
      }
      await ResponseCacheStore._closeIfOpen(indexName);
      await ResponseCacheStore._closeIfOpen(bodyName);

      final index = await Hive.openBox(indexName, path: directoryPath);
      try {
        final bodies = await Hive.openLazyBox(bodyName, path: directoryPath);
        try {
          await _moveEntries(
            index.keys.toList(growable: false),
            phase: phase,
            read: (key) async {
              final meta = index.get(key);
              final body = await bodies.get(key);
              if (meta is! Map || body is! Map) {
                return null;
              }
              return <dynamic, dynamic>{...meta, ...body};
            },
          );
        } finally {
          await bodies.close();
        }
      } finally {
        await index.close();
      }
    } catch (error) {
      onError?.call(phase, error);
    } finally {
      await _deleteBox(indexName, phase);
      await _deleteBox(bodyName, phase);
    }
  }

  /// 0.21.0 以前の形式（1 件の値にメタデータと本文をまとめた Box）の記録を
  /// 移します。
  ///
  /// 移し元は 1 件ずつ読む形で開き、キャッシュ全体をメモリへ載せません。
  /// 例外は送出しません。
  ///
  /// [name] 移し元の Box 名。
  /// [phase] 失敗を知らせるときの phase。
  /// [cipher] 移し元が暗号化 Box の場合の暗号。
  Future<void> moveLegacy(
    String name, {
    required String phase,
    HiveCipher? cipher,
  }) async {
    try {
      if (!await Hive.boxExists(name, path: directoryPath)) {
        return;
      }
      await ResponseCacheStore._closeIfOpen(name);

      final source = await Hive.openLazyBox(
        name,
        path: directoryPath,
        encryptionCipher: cipher,
      );
      try {
        await _moveEntries(
          source.keys.toList(growable: false),
          phase: phase,
          read: (key) async {
            final value = await source.get(key);
            return value is Map ? value : null;
          },
        );
      } finally {
        await source.close();
      }
    } catch (error) {
      onError?.call(phase, error);
    } finally {
      await _deleteBox(name, phase);
    }
  }

  /// 記録を 1 件ずつ移し、移せなかった件数を知らせます。
  ///
  /// 移し先に同じキーがある場合は、保存日時（`createdAt`）の新しい方を
  /// 残します。暗号化の設定を切り替える間に、両方へ保存されることがあるためです。
  ///
  /// [keys] 移す記録のキー。
  /// [phase] 失敗を知らせるときの phase。
  /// [read] 移し元から記録を読む関数。読めない場合は `null` を返します。
  Future<void> _moveEntries(
    List<dynamic> keys, {
    required String phase,
    required Future<Map?> Function(Object key) read,
  }) async {
    var failedCount = 0;
    Object? lastError;
    for (final key in keys) {
      try {
        await beforeEntryMoved?.call(key as Object);
        final value = await read(key);
        if (value == null) {
          continue;
        }
        final existing = target.metadata(key);
        if (existing != null &&
            !_storedAt(value).isAfter(_storedAt(existing))) {
          continue;
        }
        await target.put(key, value);
      } catch (error) {
        failedCount++;
        lastError = error;
      }
    }
    if (failedCount > 0) {
      onError?.call(phase, lastError!, failedCount: failedCount);
    }
  }

  /// 記録の保存日時を返します。
  ///
  /// [data] 記録またはメタデータ。
  ///
  /// Returns: 保存日時。読めない場合は最も古い日時。
  static DateTime _storedAt(Map data) =>
      DateTime.tryParse(data['createdAt'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  /// 移し終えた Box のファイルを削除します。
  ///
  /// 失敗は [onError] で知らせ、送出しません。次に開くときに移し直します。
  ///
  /// [name] Box 名。
  /// [phase] 失敗を知らせるときの phase。
  Future<void> _deleteBox(String name, String phase) async {
    try {
      await Hive.deleteBoxFromDisk(name, path: directoryPath);
    } catch (error) {
      onError?.call(phase, error);
    }
  }
}
