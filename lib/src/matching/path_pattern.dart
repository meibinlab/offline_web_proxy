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
/// * 末尾の `/*` と `/**` は、その手前のパスそのもの（`/js/*` に対する
///   `/js`）にも一致します。末尾の `/` は取り除いて比較するため、`/js/` は
///   `/js` と同じものとして扱います
///
/// ## 照合規則
///
/// * 照合対象はパスだけです。クエリ文字列とフラグメントは含みません
/// * 大文字と小文字は区別します
/// * パターンとパスの双方を [normalizePath] で同じ形にそろえてから
///   比較します。同じ資源を指す書き方の違い（`;jsessionid=...` の付加、
///   `%6C` のような不要な符号化、`//` の重複、末尾の `/`）で照合を
///   すり抜けないようにするためです
///
/// ## 使用例
///
/// ```dart
/// PathPattern('/api/registers/auth.json')
///     .matches('/api/registers/auth.json'); // true
/// PathPattern('/js/**').matches('/js/vendor/haori.js'); // true
/// PathPattern('/js/*').matches('/js/vendor/haori.js');  // false
/// PathPattern('/js/*').matches('/js/haori.js');         // true
/// PathPattern('/login').matches('/login;jsessionid=1'); // true
/// PathPattern('/login').matches('/%6Cogin/');           // true
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
  /// 次の順に整えます。
  ///
  /// 1. 前後の空白を除き、先頭に `/` が無ければ補う
  /// 2. 各セグメントの `;` 以降（パスパラメータ）を取り除く
  /// 3. 非予約文字（`A-Z a-z 0-9 - . _ ~`）を表す `%XX` だけを復号する。
  ///    それ以外の `%XX` は 16 進を大文字にそろえ、符号化したまま残す
  ///    （`%2F` を `/` にすると、セグメントの区切りが変わるため）
  /// 4. 空のセグメント（`//` の重複）を 1 つにまとめる
  /// 5. 末尾の `/` を取り除く（ルート `/` を除く）
  ///
  /// [path] は正規化するパスです。クエリ文字列は含めないでください。
  ///
  /// Returns: 先頭に `/` を持ち、末尾に `/` を持たない（ルートを除く）パス。
  static String normalizePath(String path) {
    final trimmedPath = path.trim();
    final segments = <String>[];
    for (final rawSegment in trimmedPath.split('/')) {
      final parameterIndex = rawSegment.indexOf(';');
      final segment = _decodeUnreserved(
        parameterIndex < 0
            ? rawSegment
            : rawSegment.substring(0, parameterIndex),
      );
      if (segment.isNotEmpty) {
        segments.add(segment);
      }
    }
    return '/${segments.join('/')}';
  }

  /// 非予約文字を表す `%XX` だけを復号します。
  ///
  /// 16 進数 2 桁が続かない `%` は、そのまま残します。
  ///
  /// [segment] 1 セグメント分の文字列。
  ///
  /// Returns: 非予約文字を復号し、残した `%XX` の 16 進を大文字にした文字列。
  static String _decodeUnreserved(String segment) {
    if (!segment.contains('%')) {
      return segment;
    }

    final buffer = StringBuffer();
    var index = 0;
    while (index < segment.length) {
      final character = segment[index];
      if (character == '%' && index + 2 < segment.length) {
        final hex = segment.substring(index + 1, index + 3);
        final value = int.tryParse(hex, radix: 16);
        if (value != null && _isHexDigits(hex)) {
          if (_isUnreserved(value)) {
            buffer.writeCharCode(value);
          } else {
            buffer.write('%${hex.toUpperCase()}');
          }
          index += 3;
          continue;
        }
      }
      buffer.write(character);
      index++;
    }
    return buffer.toString();
  }

  /// 文字列が 16 進数字だけでできているかどうかを返します。
  ///
  /// `int.tryParse` は符号（`+` / `-`）も受け付けるため、別に確かめます。
  ///
  /// [value] 判定する文字列。
  ///
  /// Returns: 全ての文字が `0-9 A-F a-f` の場合は `true`。
  static bool _isHexDigits(String value) {
    return RegExp(r'^[0-9A-Fa-f]+$').hasMatch(value);
  }

  /// RFC 3986 の非予約文字かどうかを返します。
  ///
  /// [codeUnit] 判定する文字コード。
  ///
  /// Returns: `A-Z a-z 0-9 - . _ ~` のいずれかの場合は `true`。
  static bool _isUnreserved(int codeUnit) {
    return (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
        (codeUnit >= 0x30 && codeUnit <= 0x39) ||
        codeUnit == 0x2D ||
        codeUnit == 0x2E ||
        codeUnit == 0x5F ||
        codeUnit == 0x7E;
  }

  /// glob パターンを正規表現の断片へ変換します。
  ///
  /// [pattern] は正規化済みのパターンです。
  ///
  /// Returns: 正規表現のソース文字列。
  static String _toRegExpSource(String pattern) {
    // 末尾の `/` を取り除いて比較するため、`/js/` は `/js` になる。
    // 0.25.0 まで `/js/*` と `/js/**` が `/js/` に一致していた挙動を保つよう、
    // 末尾のワイルドカードのセグメントは省略可能にする
    if (pattern.endsWith('/**')) {
      return '${_toRegExpSource(pattern.substring(0, pattern.length - 3))}'
          '(?:/.*)?';
    }
    if (pattern.endsWith('/*') && pattern != '/*') {
      return '${_toRegExpSource(pattern.substring(0, pattern.length - 2))}'
          '(?:/[^/]*)?';
    }

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
  /// 照合の前に [normalizePath] で正規化します。
  ///
  /// Returns: 一致する場合は `true`。
  bool matches(String path) {
    return _regExp.hasMatch(normalizePath(path));
  }

  @override
  String toString() => 'PathPattern{pattern: $pattern}';
}
