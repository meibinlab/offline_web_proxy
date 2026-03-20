import 'cookie_record.dart';

/// 外部から復元する Cookie 情報を表します。
///
/// 構造化データとして直接生成するか、`Set-Cookie` ヘッダ文字列から
/// 生成して `OfflineWebProxy.restoreCookies` に渡します。
class CookieRestoreEntry {
  /// Cookie 名です。
  final String name;

  /// Cookie の実値です。
  final String value;

  /// 有効ドメインです。
  final String domain;

  /// 有効パスです。
  final String path;

  /// 有効期限です。`null` の場合はセッション Cookie です。
  final DateTime? expires;

  /// Secure 属性の有無です。
  final bool secure;

  /// HttpOnly 属性の有無です。
  final bool httpOnly;

  /// SameSite 属性です。
  final String? sameSite;

  /// ホスト限定 Cookie かどうかです。
  final bool hostOnly;

  /// 復元時の作成日時です。
  final DateTime? createdAt;

  /// 構造化データから Cookie 復元エントリを生成します。
  ///
  /// [name] は Cookie 名です。
  /// [value] は Cookie 値です。
  /// [domain] は対象ドメインです。
  /// [path] は対象パスです。
  /// [expires] は有効期限です。
  /// [secure] は Secure 属性の有無です。
  /// [httpOnly] は HttpOnly 属性の有無です。
  /// [sameSite] は SameSite 属性です。
  /// [hostOnly] はホスト限定 Cookie かどうかです。
  /// [createdAt] は Cookie の作成日時です。省略時は復元時刻が使用されます。
  const CookieRestoreEntry({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.expires,
    this.secure = false,
    this.httpOnly = false,
    this.sameSite,
    this.hostOnly = false,
    this.createdAt,
  });

  /// `Set-Cookie` ヘッダ文字列から Cookie 復元エントリを生成します。
  ///
  /// [setCookieHeader] は `Set-Cookie` の 1 行分です。
  /// [requestUrl] は Cookie を受信した絶対 URL です。
  /// [receivedAt] は Cookie の受信日時です。省略時は現在時刻が使用されます。
  /// 戻り値は生成された [CookieRestoreEntry] です。
  factory CookieRestoreEntry.fromSetCookieHeader({
    required String setCookieHeader,
    required String requestUrl,
    DateTime? receivedAt,
  }) {
    final requestUri = Uri.tryParse(requestUrl);
    if (requestUri == null ||
        !requestUri.hasScheme ||
        requestUri.host.isEmpty) {
      throw ArgumentError.value(requestUrl, 'requestUrl', '絶対 URL を指定してください');
    }

    final cookieRecord = CookieRecord.fromSetCookieHeader(
      setCookieHeader: setCookieHeader,
      requestUri: requestUri,
      receivedAt: receivedAt,
    );

    return CookieRestoreEntry._fromCookieRecord(cookieRecord);
  }

  /// 内部 Cookie レコードへ変換します。
  ///
  /// [restoredAt] は [createdAt] が未指定の場合に補完する日時です。
  /// 戻り値は変換後の [CookieRecord] です。
  CookieRecord toCookieRecord({DateTime? restoredAt}) {
    return CookieRecord(
      name: name,
      value: value,
      domain: domain.toLowerCase(),
      path: path.isEmpty ? '/' : (path.startsWith('/') ? path : '/$path'),
      expires: expires,
      secure: secure,
      httpOnly: httpOnly,
      sameSite: sameSite,
      hostOnly: hostOnly,
      createdAt: createdAt ?? restoredAt ?? DateTime.now(),
    );
  }

  /// 内部レコードから復元エントリを生成します。
  ///
  /// [cookieRecord] は変換元の内部 Cookie レコードです。
  /// 戻り値は生成された [CookieRestoreEntry] です。
  factory CookieRestoreEntry._fromCookieRecord(CookieRecord cookieRecord) {
    return CookieRestoreEntry(
      name: cookieRecord.name,
      value: cookieRecord.value,
      domain: cookieRecord.domain,
      path: cookieRecord.path,
      expires: cookieRecord.expires,
      secure: cookieRecord.secure,
      httpOnly: cookieRecord.httpOnly,
      sameSite: cookieRecord.sameSite,
      hostOnly: cookieRecord.hostOnly,
      createdAt: cookieRecord.createdAt,
    );
  }
}
