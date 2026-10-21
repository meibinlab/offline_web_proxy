/// `Set-Cookie` の `Expires` 属性の日付を解釈する部品です。
///
/// RFC 6265 5.1.1 の手順で解釈します。`HttpDate.parse` は RFC 1123、
/// RFC 850、asctime の 3 形式しか受け付けず、`Wed, 21-Oct-2026 07:28:00 GMT`
/// のように実際のサーバが返す形式を解釈できないため、この部品を使います。
/// proxy の内部実装用で、ライブラリからは公開しません。
library;

/// 日付の字句を区切る文字かどうかを返します。
///
/// RFC 6265 の delimiter（%x09 / %x20-2F / %x3B-40 / %x5B-60 / %x7B-7E）です。
///
/// [codeUnit] 判定する文字の符号。
///
/// Returns: 区切り文字なら `true`。
bool _isCookieDateDelimiter(int codeUnit) {
  return codeUnit == 0x09 ||
      (codeUnit >= 0x20 && codeUnit <= 0x2F) ||
      (codeUnit >= 0x3B && codeUnit <= 0x40) ||
      (codeUnit >= 0x5B && codeUnit <= 0x60) ||
      (codeUnit >= 0x7B && codeUnit <= 0x7E);
}

/// 時刻（`hh:mm:ss`、各 1～2 桁、後ろに数字以外が続いてもよい）の字句です。
final RegExp _timePattern =
    RegExp(r'^(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\D[\s\S]*)?$');

/// 日（1～2 桁、後ろに数字以外が続いてもよい）の字句です。
final RegExp _dayOfMonthPattern = RegExp(r'^(\d{1,2})(?:\D[\s\S]*)?$');

/// 年（2～4 桁、後ろに数字以外が続いてもよい）の字句です。
final RegExp _yearPattern = RegExp(r'^(\d{2,4})(?:\D[\s\S]*)?$');

/// 月名の先頭 3 文字（小文字）です。並び順が月の番号に対応します。
const List<String> _monthNames = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

/// `Expires` 属性の値を RFC 6265 5.1.1 の手順で解釈します。
///
/// 区切り文字で字句に分け、先頭から時刻・日・月・年の順に最初に当てはまる
/// ものを採ります。2 桁の年は 70～99 を 1900 年代、0～69 を 2000 年代と
/// みなします。いずれかが見つからない場合、日が 1～31 の範囲外、年が 1601
/// 未満、時・分・秒が範囲外、または存在しない日付（2 月 30 日など）の
/// 場合は解釈できないものとします。
///
/// [value] `Expires` 属性の値。
///
/// Returns: 解釈できた日時（UTC）。解釈できない場合は `null`。
DateTime? parseCookieDate(String value) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  for (final codeUnit in value.codeUnits) {
    if (_isCookieDateDelimiter(codeUnit)) {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
    } else {
      buffer.writeCharCode(codeUnit);
    }
  }
  if (buffer.isNotEmpty) {
    tokens.add(buffer.toString());
  }

  int? hour;
  int? minute;
  int? second;
  int? day;
  int? month;
  int? year;

  for (final token in tokens) {
    if (hour == null) {
      final match = _timePattern.firstMatch(token);
      if (match != null) {
        hour = int.parse(match.group(1)!);
        minute = int.parse(match.group(2)!);
        second = int.parse(match.group(3)!);
        continue;
      }
    }
    if (day == null) {
      final match = _dayOfMonthPattern.firstMatch(token);
      if (match != null) {
        day = int.parse(match.group(1)!);
        continue;
      }
    }
    if (month == null && token.length >= 3) {
      final index = _monthNames.indexOf(token.substring(0, 3).toLowerCase());
      if (index != -1) {
        month = index + 1;
        continue;
      }
    }
    if (year == null) {
      final match = _yearPattern.firstMatch(token);
      if (match != null) {
        year = int.parse(match.group(1)!);
        continue;
      }
    }
  }

  if (hour == null ||
      minute == null ||
      second == null ||
      day == null ||
      month == null ||
      year == null) {
    return null;
  }

  if (year >= 70 && year <= 99) {
    year += 1900;
  } else if (year >= 0 && year <= 69) {
    year += 2000;
  }

  if (day < 1 ||
      day > 31 ||
      year < 1601 ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }

  final result = DateTime.utc(year, month, day, hour, minute, second);
  // DateTime は 2 月 30 日などを翌月へ繰り越すため、存在しない日付を弾く
  if (result.month != month || result.day != day) {
    return null;
  }
  return result;
}
