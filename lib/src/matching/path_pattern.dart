/// 設定で指定するパスパターンです。
///
/// `ProxyConfig.forceCachePaths` のように、リクエストのパスを設定値と
/// 照合する箇所で使用します。利用側が正規表現を直接指定できるようにすると、
/// 設定の誤りが proxy 全体を止め得るため、記法は次の glob に限定しています。
///
/// ## 記法
///
/// * `*`: `/` を含まない 1 セグメント内の任意文字列に一致します
/// * `**`: `/` を含む任意文字列に一致します
/// * メタ文字を含まない場合は完全一致です
///
/// ## 照合規則
///
/// * 照合対象はパスだけです。クエリ文字列とフラグメントは含みません
/// * 大文字と小文字は区別します
/// * パターンとパスの双方について、先頭に `/` が無い場合は補って比較します
///
/// ## 使用例
///
/// ```dart
/// PathPattern('/api/registers/auth.json')
///     .matches('/api/registers/auth.json'); // true
/// PathPattern('/js/**').matches('/js/vendor/haori.js'); // true
/// PathPattern('/js/*').matches('/js/vendor/haori.js');  // false
/// PathPattern('/js/*').matches('/js/haori.js');         // true
/// ```
class PathPattern {
  /// 設定に記述されたままのパターン文字列です。
  final String pattern;

  /// [pattern] から組み立てた照合用の正規表現です。
  final RegExp _regExp;

  PathPattern._(this.pattern, this._regExp);

  /// パターン文字列から [PathPattern] を生成します。
  ///
  /// [pattern] は照合に使う glob パターンです。
  ///
  /// Returns: 生成した [PathPattern]。
  factory PathPattern(String pattern) {
    final normalizedPattern = normalizePath(pattern);
    return PathPattern._(
      pattern,
      RegExp('^${_toRegExpSource(normalizedPattern)}\$'),
    );
  }

  /// パターン一覧をまとめて生成します。
  ///
  /// 起動時に一度だけ組み立て、リクエストごとの正規表現生成を避けるために
  /// 使用します。
  ///
  /// [patterns] は glob パターンの一覧です。空文字列は無視します。
  ///
  /// Returns: 生成した [PathPattern] の一覧。
  static List<PathPattern> compileAll(Iterable<String> patterns) {
    final compiled = <PathPattern>[];
    for (final pattern in patterns) {
      if (pattern.trim().isEmpty) {
        continue;
      }
      compiled.add(PathPattern(pattern.trim()));
    }
    return compiled;
  }

  /// パス文字列を照合用に正規化します。
  ///
  /// [path] は正規化するパスです。
  ///
  /// Returns: 先頭に `/` を持つパス。
  static String normalizePath(String path) {
    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) {
      return '/';
    }
    return trimmedPath.startsWith('/') ? trimmedPath : '/$trimmedPath';
  }

  /// glob パターンを正規表現の断片へ変換します。
  ///
  /// [pattern] は正規化済みのパターンです。
  ///
  /// Returns: 正規表現のソース文字列。
  static String _toRegExpSource(String pattern) {
    final buffer = StringBuffer();
    var index = 0;

    while (index < pattern.length) {
      final character = pattern[index];
      if (character != '*') {
        buffer.write(RegExp.escape(character));
        index++;
        continue;
      }

      // `**` は `/` を跨ぐため、先に 2 文字分を確認する
      if (index + 1 < pattern.length && pattern[index + 1] == '*') {
        buffer.write('.*');
        index += 2;
        continue;
      }

      buffer.write('[^/]*');
      index++;
    }

    return buffer.toString();
  }

  /// パスがこのパターンに一致するかどうかを返します。
  ///
  /// [path] は照合するパスです。クエリ文字列は含めないでください。
  ///
  /// Returns: 一致する場合は `true`。
  bool matches(String path) {
    return _regExp.hasMatch(normalizePath(path));
  }

  @override
  String toString() => 'PathPattern{pattern: $pattern}';
}
