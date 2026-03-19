import 'cookie_record.dart';

/// 指定 URI 向けの Cookie ヘッダ値を構築します。
///
/// [cookies] は候補となる Cookie 一覧です。
/// [uri] は送信対象の URI です。
/// [at] は判定日時です。省略時は現在時刻を使用します。
/// 戻り値は `Cookie` ヘッダ値です。該当 Cookie がない場合は `null` です。
String? buildCookieHeaderForUri(
  Iterable<CookieRecord> cookies,
  Uri uri, {
  DateTime? at,
}) {
  final matchedCookies = cookies
      .where((cookie) => cookie.matchesUri(uri, at: at))
      .toList()
    ..sort(CookieRecord.compareForRequest);

  if (matchedCookies.isEmpty) {
    return null;
  }

  return matchedCookies
      .map((cookie) => cookie.toRequestHeaderValue())
      .join('; ');
}