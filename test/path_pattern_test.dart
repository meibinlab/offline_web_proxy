import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/src/matching/path_pattern.dart';

void main() {
  group('PathPattern（設定のパスパターン照合）', () {
    /// メタ文字を含まないパターンは完全一致になること
    test('matches exactly when the pattern has no wildcard', () {
      final pattern = PathPattern('/api/registers/auth.json');

      expect(pattern.matches('/api/registers/auth.json'), isTrue);
      expect(pattern.matches('/api/registers/auth.json.bak'), isFalse);
      expect(pattern.matches('/api/registers'), isFalse);
    });

    /// `*` は 1 セグメント内だけに一致すること
    test('matches within a single segment for a single asterisk', () {
      final pattern = PathPattern('/js/*');

      expect(pattern.matches('/js/haori.js'), isTrue);
      expect(pattern.matches('/js/'), isTrue);
      expect(pattern.matches('/js/vendor/haori.js'), isFalse);
    });

    /// `**` はセグメントを跨いで一致すること
    test('matches across segments for a double asterisk', () {
      final pattern = PathPattern('/js/**');

      expect(pattern.matches('/js/haori.js'), isTrue);
      expect(pattern.matches('/js/vendor/haori.js'), isTrue);
      expect(pattern.matches('/css/app.css'), isFalse);
    });

    /// 拡張子を含む部分一致が使えること
    test('matches a suffix pattern inside one segment', () {
      final pattern = PathPattern('/js/*.js');

      expect(pattern.matches('/js/haori.js'), isTrue);
      expect(pattern.matches('/js/haori.css'), isFalse);
    });

    /// 先頭の `/` は補って比較すること
    test('normalizes a missing leading slash on both sides', () {
      expect(PathPattern('app/index.html').matches('/app/index.html'), isTrue);
      expect(PathPattern('/app/index.html').matches('app/index.html'), isTrue);
    });

    /// 正規表現のメタ文字は文字として扱うこと
    test('treats regular expression metacharacters as literals', () {
      final pattern = PathPattern('/api/v1.0/sales');

      expect(pattern.matches('/api/v1.0/sales'), isTrue);
      // `.` が任意 1 文字として働くと誤って一致してしまう
      expect(pattern.matches('/api/v1X0/sales'), isFalse);
    });

    /// 大文字と小文字を区別すること
    test('compares case sensitively', () {
      expect(PathPattern('/App').matches('/app'), isFalse);
    });

    /// 空の指定は取り除いてまとめて生成できること
    test('skips blank entries when compiling a list', () {
      final patterns = PathPattern.compileAll(['/a', '  ', '', ' /b ']);

      expect(patterns, hasLength(2));
      expect(patterns.first.matches('/a'), isTrue);
      expect(patterns.last.matches('/b'), isTrue);
    });
  });
}
