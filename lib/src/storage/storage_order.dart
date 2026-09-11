/// 保存領域（キュー・隔離・ドロップ履歴）の記録を保存順に並べる部品です。
///
/// Hive はキーを文字列の辞書順に並べます。v0.11.0 以降のキー（0 埋め 19 桁の
/// マイクロ秒と連番）は、それより前のキー（13 桁のミリ秒、16 桁のマイクロ秒）より
/// 辞書順で前に来るため、キーの順は保存順になりません。そこで保存時刻と、
/// キーを時刻として読み直した値で並べます。
///
/// proxy の内部実装用で、ライブラリからは公開しません。
library;

/// v0.11.0 以降のキー（19 桁のマイクロ秒と 6 桁の連番）の形式。
final RegExp _sequencedKeyPattern = RegExp(r'^(\d{19})-(\d{6})$');

/// マイクロ秒だけのキー（16 桁）の形式。
final RegExp _microsecondKeyPattern = RegExp(r'^\d{16}$');

/// ミリ秒だけのキー（13 桁）の形式。
final RegExp _millisecondKeyPattern = RegExp(r'^\d{13}$');

/// ミリ秒をマイクロ秒へ換算する倍率。
const int _microsecondsPerMillisecond = 1000;

/// 保存領域の記録 1 件と、並べ替えに使う値です。
class StoredEntry {
  /// 保存領域でのキーです。
  final String key;

  /// 保存されている値です。
  final Map data;

  /// 移行を待っている旧平文 Box の記録かどうかです。
  final bool pendingMigration;

  /// 保存時刻です。読み取れない場合は `null` です。
  final DateTime? savedAt;

  /// キーを時刻として読み直したマイクロ秒です。読み取れない場合は `null` です。
  final int? keyMicroseconds;

  /// キーに含まれる同一マイクロ秒内の連番です。連番の無い形式では 0 です。
  final int keySequence;

  /// 記録を生成します。
  ///
  /// [key] は保存領域でのキーです。
  /// [data] は保存されている値です。
  /// [pendingMigration] は移行を待っている旧平文 Box の記録かどうかです。
  /// [savedAt] は保存時刻です。
  /// [keyMicroseconds] はキーを時刻として読み直したマイクロ秒です。
  /// [keySequence] はキーに含まれる連番です。
  const StoredEntry({
    required this.key,
    required this.data,
    required this.pendingMigration,
    required this.savedAt,
    required this.keyMicroseconds,
    required this.keySequence,
  });

  /// 保存されている値から記録を生成します。
  ///
  /// [key] 保存領域でのキー。
  /// [data] 保存されている値。
  /// [timestampField] 保存時刻を持つ項目名（`queuedAt` など）。
  /// [pendingMigration] 移行を待っている旧平文 Box の記録かどうか。
  ///
  /// Returns: 並べ替えに使う値を持つ記録。
  factory StoredEntry.fromData({
    required String key,
    required Map data,
    required String timestampField,
    bool pendingMigration = false,
  }) {
    final keyTime = parseStorageKeyTime(key);
    final savedAtValue = data[timestampField];
    return StoredEntry(
      key: key,
      data: data,
      pendingMigration: pendingMigration,
      savedAt: savedAtValue is String ? DateTime.tryParse(savedAtValue) : null,
      keyMicroseconds: keyTime.microseconds,
      keySequence: keyTime.sequence,
    );
  }
}

/// キーを時刻として読み直します。
///
/// 桁数で単位をそろえます。19 桁と連番の形式はマイクロ秒と連番、16 桁は
/// マイクロ秒、13 桁はミリ秒として読みます。
///
/// [key] 保存領域でのキー。
///
/// Returns: マイクロ秒と連番。読み取れない形式ではマイクロ秒が `null`。
({int? microseconds, int sequence}) parseStorageKeyTime(String key) {
  final sequenced = _sequencedKeyPattern.firstMatch(key);
  if (sequenced != null) {
    return (
      microseconds: int.parse(sequenced.group(1)!),
      sequence: int.parse(sequenced.group(2)!),
    );
  }

  if (_microsecondKeyPattern.hasMatch(key)) {
    return (microseconds: int.parse(key), sequence: 0);
  }

  if (_millisecondKeyPattern.hasMatch(key)) {
    return (
      microseconds: int.parse(key) * _microsecondsPerMillisecond,
      sequence: 0,
    );
  }

  return (microseconds: null, sequence: 0);
}

/// 2 件の記録を保存順に比較します。
///
/// 保存時刻、キーを時刻として読み直した値、連番、キーの文字列の順に比べます。
/// 保存時刻を読み取れない記録は最も古いものとして扱い、処理から取り残さないように
/// します。キーを時刻として読めない記録は、読める記録より後に並べます。
///
/// [a] 比較する記録。
/// [b] 比較する記録。
///
/// Returns: [a] が先なら負、[b] が先なら正、同じなら 0。
int compareStoredEntries(StoredEntry a, StoredEntry b) {
  final savedAtA = a.savedAt ?? DateTime.fromMicrosecondsSinceEpoch(0);
  final savedAtB = b.savedAt ?? DateTime.fromMicrosecondsSinceEpoch(0);
  final comparedAt = savedAtA.compareTo(savedAtB);
  if (comparedAt != 0) {
    return comparedAt;
  }

  final microsecondsA = a.keyMicroseconds;
  final microsecondsB = b.keyMicroseconds;
  if (microsecondsA != microsecondsB) {
    if (microsecondsA == null) {
      return 1;
    }
    if (microsecondsB == null) {
      return -1;
    }
    return microsecondsA.compareTo(microsecondsB);
  }

  final comparedSequence = a.keySequence.compareTo(b.keySequence);
  if (comparedSequence != 0) {
    return comparedSequence;
  }

  return a.key.compareTo(b.key);
}
