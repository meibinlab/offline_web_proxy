import 'dart:io';

/// 内部保存用の Cookie レコードを表します。
///
/// 公開 API 用の `CookieInfo` とは異なり、実値を含む Cookie 属性を
/// 永続化するための内部モデルです。
class CookieRecord {
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

  /// Domain 属性が未指定で、ホスト限定 Cookie かどうかです。
  final bool hostOnly;

  /// レコード作成日時です。
  final DateTime createdAt;

  /// Cookie レコードを生成します。
  const CookieRecord({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.expires,
    required this.secure,
    required this.httpOnly,
    required this.sameSite,
    required this.hostOnly,
    required this.createdAt,
  });

  /// 永続化キーを返します。
  ///
  /// 名前、ドメイン、パス、および hostOnly の組み合わせで一意化します。
  String get storageKey =>
      '$domain\t$path\t$name\t${hostOnly ? 'host' : 'domain'}';

  /// 指定時刻時点で期限切れかどうかを返します。
  ///
  /// [at] 判定日時です。
  /// 戻り値は期限切れなら `true` です。
  bool isExpiredAt(DateTime at) => expires != null && !expires!.isAfter(at);

  /// 指定 URI に送信可能な Cookie かどうかを返します。
  ///
  /// [uri] 判定対象のリクエスト URI です。
  /// [at] 判定日時です。省略時は現在時刻を使用します。
  /// 戻り値は送信可能なら `true` です。
  bool matchesUri(Uri uri, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    if (isExpiredAt(now)) {
      return false;
    }
    if (secure && uri.scheme.toLowerCase() != 'https') {
      return false;
    }
    if (!matchesDomain(uri.host)) {
      return false;
    }
    if (!matchesPath(uri.path)) {
      return false;
    }
    return true;
  }

  /// 指定ホストに対して Domain 条件を満たすかどうかを返します。
  ///
  /// [host] 判定対象ホストです。
  /// 戻り値は一致する場合に `true` です。
  bool matchesDomain(String host) {
    final normalizedHost = host.toLowerCase();
    final normalizedDomain = domain.toLowerCase();

    if (hostOnly) {
      return normalizedHost == normalizedDomain;
    }

    return normalizedHost == normalizedDomain ||
        normalizedHost.endsWith('.$normalizedDomain');
  }

  /// 指定パスに対して Path 条件を満たすかどうかを返します。
  ///
  /// [requestPath] 判定対象のリクエストパスです。
  /// 戻り値は一致する場合に `true` です。
  bool matchesPath(String requestPath) {
    final normalizedRequestPath =
        requestPath.isEmpty ? '/' : (requestPath.startsWith('/') ? requestPath : '/$requestPath');
    final normalizedCookiePath = path.isEmpty ? '/' : path;

    if (normalizedRequestPath == normalizedCookiePath) {
      return true;
    }
    if (!normalizedRequestPath.startsWith(normalizedCookiePath)) {
      return false;
    }
    if (normalizedCookiePath.endsWith('/')) {
      return true;
    }

    return normalizedRequestPath.length > normalizedCookiePath.length &&
        normalizedRequestPath[normalizedCookiePath.length] == '/';
  }

  /// Cookie ヘッダ用の `name=value` 形式を返します。
  String toRequestHeaderValue() => '$name=$value';

  /// リクエスト送信順序用の比較を行います。
  ///
  /// より長い path を優先し、同一長の場合は古い Cookie を優先します。
  static int compareForRequest(CookieRecord left, CookieRecord right) {
    final pathLengthCompare = right.path.length.compareTo(left.path.length);
    if (pathLengthCompare != 0) {
      return pathLengthCompare;
    }
    return left.createdAt.compareTo(right.createdAt);
  }

  /// 永続化用のマップへ変換します。
  ///
  /// 戻り値は Hive 保存用のマップです。
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'value': value,
      'domain': domain,
      'path': path,
      'expires': expires?.toIso8601String(),
      'secure': secure,
      'httpOnly': httpOnly,
      'sameSite': sameSite,
      'hostOnly': hostOnly,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  /// 永続化マップから Cookie レコードを復元します。
  ///
  /// [data] 永続化されたマップです。
  /// 戻り値は復元された [CookieRecord] です。
  factory CookieRecord.fromMap(Map data) {
    return CookieRecord(
      name: data['name'] as String? ?? '',
      value: data['value'] as String? ?? '',
      domain: data['domain'] as String? ?? '',
      path: data['path'] as String? ?? '/',
      expires: data['expires'] != null
          ? DateTime.parse(data['expires'] as String)
          : null,
      secure: data['secure'] as bool? ?? false,
      httpOnly: data['httpOnly'] as bool? ?? false,
      sameSite: data['sameSite'] as String?,
      hostOnly: data['hostOnly'] as bool? ?? false,
      createdAt: DateTime.parse(
        data['createdAt'] as String? ?? DateTime.now().toIso8601String(),
      ),
    );
  }

  /// `Set-Cookie` ヘッダ文字列から内部 Cookie レコードを生成します。
  ///
  /// [setCookieHeader] は `Set-Cookie` の 1 行分です。
  /// [requestUri] は Cookie を受信したリクエスト URL です。
  /// [receivedAt] は受信日時です。省略時は現在時刻を使用します。
  /// 戻り値は復元された [CookieRecord] です。
  factory CookieRecord.fromSetCookieHeader({
    required String setCookieHeader,
    required Uri requestUri,
    DateTime? receivedAt,
  }) {
    final createdAt = receivedAt ?? DateTime.now();
    final segments = setCookieHeader
        .split(';')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();

    if (segments.isEmpty) {
      throw FormatException('Set-Cookie ヘッダが空です');
    }

    final nameValue = segments.first;
    final separatorIndex = nameValue.indexOf('=');
    if (separatorIndex <= 0) {
      throw FormatException('Cookie 名または値の形式が不正です: $setCookieHeader');
    }

    final name = nameValue.substring(0, separatorIndex).trim();
    final value = nameValue.substring(separatorIndex + 1);

    var domain = requestUri.host.toLowerCase();
    var path = _defaultPath(requestUri.path);
    DateTime? expires;
    var secure = false;
    var httpOnly = false;
    String? sameSite;
    var hostOnly = true;
    int? maxAgeSeconds;

    for (final attribute in segments.skip(1)) {
      final attributeSeparator = attribute.indexOf('=');
      final attributeName = (attributeSeparator == -1
              ? attribute
              : attribute.substring(0, attributeSeparator))
          .trim()
          .toLowerCase();
      final attributeValue = attributeSeparator == -1
          ? ''
          : attribute.substring(attributeSeparator + 1).trim();

      switch (attributeName) {
        case 'domain':
          if (attributeValue.isNotEmpty) {
            domain = attributeValue.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
            hostOnly = false;
          }
          break;
        case 'path':
          if (attributeValue.isNotEmpty) {
            path = attributeValue.startsWith('/') ? attributeValue : '/$attributeValue';
          }
          break;
        case 'expires':
          if (attributeValue.isNotEmpty) {
            expires = DateTime.tryParse(attributeValue) ?? _tryParseHttpDate(attributeValue);
          }
          break;
        case 'max-age':
          maxAgeSeconds = int.tryParse(attributeValue);
          break;
        case 'secure':
          secure = true;
          break;
        case 'httponly':
          httpOnly = true;
          break;
        case 'samesite':
          sameSite = attributeValue.isEmpty ? null : attributeValue;
          break;
      }
    }

    if (maxAgeSeconds != null) {
      expires = maxAgeSeconds <= 0
          ? createdAt.subtract(Duration(seconds: 1))
          : createdAt.add(Duration(seconds: maxAgeSeconds));
    }

    return CookieRecord(
      name: name,
      value: value,
      domain: domain,
      path: path,
      expires: expires,
      secure: secure,
      httpOnly: httpOnly,
      sameSite: sameSite,
      hostOnly: hostOnly,
      createdAt: createdAt,
    );
  }

  static DateTime? _tryParseHttpDate(String value) {
    try {
      return HttpDate.parse(value).toUtc();
    } catch (_) {
      return null;
    }
  }

  static String _defaultPath(String requestPath) {
    if (requestPath.isEmpty || !requestPath.startsWith('/')) {
      return '/';
    }
    if (requestPath == '/') {
      return '/';
    }

    final lastSlashIndex = requestPath.lastIndexOf('/');
    if (lastSlashIndex <= 0) {
      return '/';
    }

    return requestPath.substring(0, lastSlashIndex);
  }
}