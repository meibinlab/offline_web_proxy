/// 保存されているCookieの情報を表すクラス（値はセキュリティ上マスクされる）
class CookieInfo {
  /// Cookie名
  final String name;

  /// Cookie値（セキュリティ上"***"でマスク）
  final String value;

  /// 有効ドメイン
  final String domain;

  /// 有効パス
  final String path;

  /// 有効期限（null=セッションCookie）
  final DateTime? expires;

  /// Secure属性の有無
  final bool secure;

  /// SameSite属性（"Strict", "Lax", "None"）
  final String? sameSite;

  const CookieInfo({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    this.expires,
    required this.secure,
    this.sameSite,
  });

  @override
  String toString() {
    return 'CookieInfo{name: $name, domain: $domain, secure: $secure}';
  }
}
