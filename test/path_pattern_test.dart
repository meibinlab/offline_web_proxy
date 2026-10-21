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

    /// `;` 以降のパスパラメータを取り除いて比較すること
    test('ignores path parameters after a semicolon', () {
      final pattern = PathPattern('/api/login');

      expect(pattern.matches('/api/login;jsessionid=ABC'), isTrue);
      expect(pattern.matches('/api;v=1/login'), isTrue);
      expect(PathPattern('/api/login;x').matches('/api/login'), isTrue);
    });

    /// 末尾の `/` と `/` の重複を取り除いて比較すること
    test('collapses duplicate slashes and drops a trailing slash', () {
      final pattern = PathPattern('/api/login');

      expect(pattern.matches('/api/login/'), isTrue);
      expect(pattern.matches('//api//login'), isTrue);
      expect(PathPattern('/api/login/').matches('/api/login'), isTrue);
      // ルートだけは `/` のまま残す
      expect(PathPattern('/').matches('/'), isTrue);
      expect(PathPattern('/').matches('//'), isTrue);
      expect(PathPattern('/').matches('/a'), isFalse);
    });

    /// 非予約文字の `%XX` だけを復号して比較すること
    test('decodes percent-encoded unreserved characters only', () {
      final pattern = PathPattern('/api/login');

      expect(pattern.matches('/api/%6Cogin'), isTrue);
      expect(pattern.matches('/api/%6cogin'), isTrue);
      expect(PathPattern('/api/%6Cogin').matches('/api/login'), isTrue);
      expect(PathPattern('/a-b._~').matches('/%61%2D%62%2E%5F%7E'), isTrue);
      // `%2F` を `/` にするとセグメントの区切りが変わるため、復号しない
      expect(PathPattern('/a/b').matches('/a%2Fb'), isFalse);
      // 残した `%XX` は 16 進の大文字と小文字を区別しない
      expect(PathPattern('/a%2fb').matches('/a%2Fb'), isTrue);
      // 16 進数 2 桁が続かない `%` はそのまま比較する
      expect(PathPattern('/a%zz').matches('/a%zz'), isTrue);
      expect(PathPattern('/a%2').matches('/a%2'), isTrue);
    });

    /// 末尾の `/*` と `/**` は、その手前のパスそのものにも一致すること
    test('lets a trailing wildcard segment match the parent path', () {
      expect(PathPattern('/js/*').matches('/js'), isTrue);
      expect(PathPattern('/js/**').matches('/js'), isTrue);
      expect(PathPattern('/js/**').matches('/js/'), isTrue);
      expect(PathPattern('/js/*').matches('/jsx'), isFalse);
      expect(PathPattern('/js/**').matches('/jsx/a'), isFalse);
      expect(PathPattern('/**').matches('/'), isTrue);
      expect(PathPattern('/**').matches('/a/b'), isTrue);
      expect(PathPattern('/*').matches('/a'), isTrue);
      expect(PathPattern('/*').matches('/a/b'), isFalse);
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
