import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/src/storage/storage_order.dart';

/// 並べ替えの対象になる記録を作る。
///
/// [key] 保存領域でのキー。
/// [savedAt] 保存時刻。`null` の場合は保存時刻を持たない記録にする。
StoredEntry _entry(String key, DateTime? savedAt) {
  return StoredEntry.fromData(
    key: key,
    data: {
      if (savedAt != null) 'queuedAt': savedAt.toIso8601String(),
    },
    timestampField: 'queuedAt',
  );
}

/// 保存順に並べたキーの一覧を返す。
List<String> _sortedKeys(List<StoredEntry> entries) {
  final sorted = [...entries]..sort(compareStoredEntries);
  return sorted.map((entry) => entry.key).toList();
}

void main() {
  group('parseStorageKeyTime', () {
    /// 19 桁と連番の形式は、マイクロ秒と連番として読むこと
    test('reads the sequenced key format', () {
      expect(
        parseStorageKeyTime('0001700000000000000-000002'),
        equals((microseconds: 1700000000000000, sequence: 2)),
      );
    });

    /// 16 桁はマイクロ秒、13 桁はミリ秒として読むこと
    test('reads microsecond and millisecond keys', () {
      expect(
        parseStorageKeyTime('1700000000000001'),
        equals((microseconds: 1700000000000001, sequence: 0)),
      );
      expect(
        parseStorageKeyTime('1700000000000'),
        equals((microseconds: 1700000000000000, sequence: 0)),
      );
    });

    /// 時刻として読めない形式は、マイクロ秒を持たないこと
    test('does not read other formats', () {
      expect(
        parseStorageKeyTime('legacy'),
        equals((microseconds: null, sequence: 0)),
      );
      expect(
        parseStorageKeyTime('17000000000000'),
        equals((microseconds: null, sequence: 0)),
      );
    });
  });

  group('compareStoredEntries', () {
    /// 保存時刻が異なる場合は、キーの形式によらず保存時刻の順に並べること
    test('orders by saved time before the key', () {
      final entries = [
        // 辞書順では先頭に来る 19 桁のキーを、最も新しい記録にする
        _entry('0001700000000000000-000000', DateTime(2026, 9, 3)),
        _entry('1700000000000', DateTime(2026, 9, 1)),
        _entry('1700000000000000', DateTime(2026, 9, 2)),
      ];

      expect(
        _sortedKeys(entries),
        equals([
          '1700000000000',
          '1700000000000000',
          '0001700000000000000-000000',
        ]),
      );
    });

    /// 保存時刻が同じ場合は、キーを時刻として読み直した値と連番の順に並べること
    test('orders by the key time when saved times are equal', () {
      final savedAt = DateTime(2026, 9, 1, 10);
      final entries = [
        _entry('0001700000000000500-000001', savedAt),
        _entry('1700000000001', savedAt),
        _entry('0001700000000000500-000000', savedAt),
        _entry('1700000000000400', savedAt),
      ];

      expect(
        _sortedKeys(entries),
        equals([
          '1700000000000400',
          '0001700000000000500-000000',
          '0001700000000000500-000001',
          '1700000000001',
        ]),
      );
    });

    /// 保存時刻を読めない記録は最も古いものとし、時刻として読めないキーは後ろに並べること
    test('puts unreadable saved times first and unreadable keys last', () {
      final savedAt = DateTime(2026, 9, 1, 10);
      final entries = [
        _entry('legacy', savedAt),
        _entry('1700000000000', savedAt),
        _entry('0001700000000000000-000000', null),
      ];

      expect(
        _sortedKeys(entries),
        equals([
          '0001700000000000000-000000',
          '1700000000000',
          'legacy',
        ]),
      );
    });
  });
}
