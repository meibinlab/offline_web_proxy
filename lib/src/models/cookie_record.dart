import 'dart:io';

import '../storage/hive_key.dart';
import 'cookie_date.dart';
import 'cookie_rejection.dart';

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
  /// パスや名前が長く UTF-8 で 255 バイトを超える場合は、Hive のキーの上限に
  /// 収めるため、組み合わせの SHA-256 に置き換えます（[toHiveKey]）。
  ///
  /// Returns: Hive のキーの上限に収めた永続化キー。
  String get storageKey => storageKeyFor(
        domain: domain,
        path: path,
        name: name,
        hostOnly: hostOnly,
      );

  /// 上流の `Set-Cookie` から受け入れる有効期限の上限です（RFC 6265bis）。
  ///
  /// `Max-Age` と `Expires` がこれより先を指す場合は、受信日時からこの期間後に
  /// 丸めます。巨大な `Max-Age` で日時の計算があふれないようにするためでも
  /// あります。
  static const Duration maxLifetime = Duration(days: 400);

  /// `Max-Age` 属性として受け付ける値の形（RFC 6265 5.2.2）です。
  static final RegExp _maxAgePattern = RegExp(r'^-?\d+$');

  /// 指定した属性の組み合わせの永続化キーを返します。
  ///
  /// [storageKey] と同じ規則で求めます。保存済みの Cookie を、レコードを
  /// 読まずにキーで探すために使います。
  ///
  /// [domain] 有効ドメイン。
  /// [path] 有効パス。
  /// [name] Cookie 名。
  /// [hostOnly] ホスト限定 Cookie かどうか。
  ///
  /// Returns: Hive のキーの上限に収めた永続化キー。
  static String storageKeyFor({
    required String domain,
    required String path,
    required String name,
    required bool hostOnly,
  }) =>
      toHiveKey('$domain\t$path\t$name\t${hostOnly ? 'host' : 'domain'}');

  /// 指定時刻時点で期限切れかどうかを返します。
  ///
  /// [at] 判定日時です。
  /// 戻り値は期限切れなら `true` です。
  bool isExpiredAt(DateTime at) => expires != null && !expires!.isAfter(at);

  /// この Cookie が `Secure` で、`https` 以外の応答の [incoming] に上書き・
  /// 削除されるか影で覆われるかどうかを返します（RFC 6265bis 5.7）。
  ///
  /// 次のすべてを満たす場合に `true` です。ホスト限定かどうかは問いません。
  ///
  /// - 名前が等しい
  /// - この Cookie が `Secure` で、[at] の時点で期限内
  /// - ドメインのどちらかがもう一方に domain-match する（親ドメインの
  ///   Cookie で子ドメインの `Secure` の Cookie を覆う場合を含む）
  /// - [incoming] のパスが、この Cookie のパスに path-match する
  ///
  /// [incoming] `https` 以外の応答から受け取った Cookie。
  /// [at] 期限切れ判定の日時。
  ///
  /// Returns: [incoming] を保存してはいけない場合は `true`。
  bool isSecureShadowedBy(CookieRecord incoming, {required DateTime at}) {
    if (name != incoming.name || !secure || isExpiredAt(at)) {
      return false;
    }
    final existingDomain = domain.toLowerCase();
    final incomingDomain = incoming.domain.toLowerCase();
    final domainsOverlap = domainMatches(existingDomain, incomingDomain) ||
        domainMatches(incomingDomain, existingDomain);
    return domainsOverlap && matchesPath(incoming.path);
  }

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
    final normalizedRequestPath = requestPath.isEmpty
        ? '/'
        : (requestPath.startsWith('/') ? requestPath : '/$requestPath');
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
  /// `Expires` 属性は RFC 6265 5.1.1 の手順（[parseCookieDate]）で解釈し、
  /// 解釈できない値は無視します。`Max-Age` 属性は `^-?\d+$` に合う値だけを
  /// 採り（RFC 6265 5.2.2）、合わない値は無視して先に採った値を保ちます。
  /// `Max-Age` は `Expires` より優先し、0 以下は即時の失効です。どちらも
  /// 受信日時から [maxLifetime] より先を指す場合は、その時点に丸めます。
  /// `Path` 属性が空か `/` で始まらない場合は、要求先のパスから求めた
  /// default-path を使います（RFC 6265 5.2.4）。
  ///
  /// [applyAcceptanceRules] が `true` の場合は、上流応答の `Set-Cookie` を
  /// Cookie Jar へ保存する前の受け入れ規則（RFC 6265、RFC 6265bis）で
  /// 確かめ、外れたら [CookieRejectedException] を送出します。
  ///
  /// - `Domain` 属性: 要求先ホストが IP アドレスなら、ホストと等しい場合だけ
  ///   ホスト限定として受け入れます（外れたら `ipDomain`）。`.` を含まない値は、
  ///   ホストと等しい場合だけホスト限定として受け入れます（外れたら
  ///   `singleLabelDomain`）。それ以外は要求先ホストが domain-match しなければ
  ///   `domainMismatch` です。公開サフィックスリストは使いません。
  /// - [fromMirroredOrigin] が `true` で、Cookie を送る範囲が
  ///   [configuredOriginHost] を含む場合は `mirroredOriginDomain` です。
  /// - `https` 以外の応答の `Secure` 属性は `insecureSecure` です。
  /// - 名前が `__Secure-` で始まる（大文字小文字を区別しない）Cookie は
  ///   `Secure` と `https` が必要です（外れたら `securePrefix`）。
  /// - 名前が `__Host-` で始まる（大文字小文字を区別しない）Cookie は
  ///   `Secure`、`https`、`Domain` 属性なし、`Path` 属性があり解決後のパス
  ///   （空か `/` で始まらない値は default-path）が `/` であることが必要です
  ///   （外れたら `hostPrefix`）。
  ///
  /// `false`（既定）の場合は規則を適用せず、属性をそのまま取り込みます。
  /// アプリが渡す値（`OfflineWebProxy.restoreCookies`）を解釈するための
  /// 動作です。
  ///
  /// [setCookieHeader] は `Set-Cookie` の 1 行分です。
  /// [requestUri] は Cookie を受信したリクエスト URL です。
  /// [receivedAt] は受信日時です。省略時は現在時刻を使用します。
  /// [applyAcceptanceRules] 受け入れ規則を適用する場合は `true`。
  /// [fromMirroredOrigin] 設定済み origin 以外（中継先）の応答の場合は
  ///   `true`。[applyAcceptanceRules] が `true` の場合だけ使います。
  /// [configuredOriginHost] 設定済み origin のホスト。
  ///   [fromMirroredOrigin] が `true` の場合だけ使います。
  ///
  /// Returns: 生成された [CookieRecord]。
  ///
  /// Throws:
  ///   FormatException: `Set-Cookie` の形式が不正な場合。
  ///   CookieRejectedException: [applyAcceptanceRules] が `true` で、
  ///     受け入れ規則に外れた場合。
  factory CookieRecord.fromSetCookieHeader({
    required String setCookieHeader,
    required Uri requestUri,
    DateTime? receivedAt,
    bool applyAcceptanceRules = false,
    bool fromMirroredOrigin = false,
    String? configuredOriginHost,
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
      // ヘッダの値にはセッション識別子などが入るため、文言に含めない
      throw FormatException('Cookie 名または値の形式が不正です');
    }

    final name = nameValue.substring(0, separatorIndex).trim();
    final value = nameValue.substring(separatorIndex + 1);

    final requestHost = requestUri.host.toLowerCase();
    // 属性として指定された値。受け入れ規則で、指定の有無と値を確かめる
    String? domainAttribute;
    // `Path` 属性を指定した場合の解決後の値。指定がなければ `null`
    String? pathAttribute;
    DateTime? expires;
    var secure = false;
    var httpOnly = false;
    String? sameSite;
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
          final normalizedDomain =
              attributeValue.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
          if (normalizedDomain.isNotEmpty) {
            domainAttribute = normalizedDomain;
          }
          break;
        case 'path':
          // 空か `/` で始まらない値は default-path を使う（RFC 6265 5.2.4）
          pathAttribute = attributeValue.startsWith('/')
              ? attributeValue
              : _defaultPath(requestUri.path);
          break;
        case 'expires':
          // 解釈できない値は属性ごと無視する（RFC 6265 5.2.1）
          final parsedExpires = parseCookieDate(attributeValue);
          if (parsedExpires != null) {
            expires = parsedExpires;
          }
          break;
        case 'max-age':
          // 形の合わない値は属性ごと無視する（RFC 6265 5.2.2）
          if (_maxAgePattern.hasMatch(attributeValue)) {
            maxAgeSeconds = _parseMaxAgeSeconds(attributeValue);
          }
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

    var domain = requestHost;
    var hostOnly = true;
    if (domainAttribute != null) {
      if (!applyAcceptanceRules) {
        domain = domainAttribute;
        hostOnly = false;
      } else if (_isIpAddress(requestHost)) {
        // IP アドレスには親ドメインがないため、ホスト自身だけを認める
        if (domainAttribute != requestHost) {
          throw CookieRejectedException(CookieRejectionReason.ipDomain, name);
        }
      } else if (!domainAttribute.contains('.')) {
        // `com` のような 1 ラベルの値は、それ自体がホストの場合だけ認める
        if (domainAttribute != requestHost) {
          throw CookieRejectedException(
            CookieRejectionReason.singleLabelDomain,
            name,
          );
        }
      } else if (!domainMatches(requestHost, domainAttribute)) {
        throw CookieRejectedException(
          CookieRejectionReason.domainMismatch,
          name,
        );
      } else {
        domain = domainAttribute;
        hostOnly = false;
      }
    }
    final path = pathAttribute ?? _defaultPath(requestUri.path);

    if (applyAcceptanceRules) {
      _checkAcceptanceRules(
        name: name,
        requestUri: requestUri,
        domain: domain,
        hostOnly: hostOnly,
        hasDomainAttribute: domainAttribute != null,
        pathAttribute: pathAttribute,
        secure: secure,
        fromMirroredOrigin: fromMirroredOrigin,
        configuredOriginHost: configuredOriginHost,
      );
    }

    if (maxAgeSeconds != null) {
      expires = maxAgeSeconds <= 0
          ? createdAt.subtract(Duration(seconds: 1))
          : createdAt.add(Duration(seconds: maxAgeSeconds));
    }
    final latestExpires = createdAt.add(maxLifetime);
    if (expires != null && expires.isAfter(latestExpires)) {
      expires = latestExpires;
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

  /// `Domain` 以外の受け入れ規則（中継先、`Secure`、名前の接頭辞）を確かめます。
  ///
  /// [name] Cookie 名。
  /// [requestUri] Cookie を受信したリクエスト URL。
  /// [domain] 決まった有効ドメイン。
  /// [hostOnly] ホスト限定 Cookie かどうか。
  /// [hasDomainAttribute] `Domain` 属性が指定されていたかどうか。
  /// [pathAttribute] `Path` 属性を指定した場合の解決後の値。指定がなければ
  ///   `null`。
  /// [secure] `Secure` 属性の有無。
  /// [fromMirroredOrigin] 中継先の応答かどうか。
  /// [configuredOriginHost] 設定済み origin のホスト。
  ///
  /// Throws:
  ///   CookieRejectedException: 規則に外れた場合。
  static void _checkAcceptanceRules({
    required String name,
    required Uri requestUri,
    required String domain,
    required bool hostOnly,
    required bool hasDomainAttribute,
    required String? pathAttribute,
    required bool secure,
    required bool fromMirroredOrigin,
    required String? configuredOriginHost,
  }) {
    final originHost = configuredOriginHost?.toLowerCase() ?? '';
    if (fromMirroredOrigin && originHost.isNotEmpty) {
      // 中継先が、設定済み origin へ送られる Cookie を置けないようにする
      final coversOrigin =
          hostOnly ? originHost == domain : domainMatches(originHost, domain);
      if (coversOrigin) {
        throw CookieRejectedException(
          CookieRejectionReason.mirroredOriginDomain,
          name,
        );
      }
    }

    final isSecureScheme = requestUri.scheme.toLowerCase() == 'https';
    if (secure && !isSecureScheme) {
      throw CookieRejectedException(CookieRejectionReason.insecureSecure, name);
    }

    final lowerName = name.toLowerCase();
    if (lowerName.startsWith('__secure-') && !(secure && isSecureScheme)) {
      throw CookieRejectedException(CookieRejectionReason.securePrefix, name);
    }
    if (lowerName.startsWith('__host-') &&
        !(secure &&
            isSecureScheme &&
            !hasDomainAttribute &&
            pathAttribute == '/')) {
      throw CookieRejectedException(CookieRejectionReason.hostPrefix, name);
    }
  }

  /// [host] が [domain] に domain-match するかどうかを返します（RFC 6265 5.1.3）。
  ///
  /// [host] 小文字にしたホスト。
  /// [domain] 小文字にしたドメイン。
  ///
  /// Returns: 等しいか、[host] が IP アドレスでなく `.` + [domain] で終わる
  ///   場合は `true`。
  static bool domainMatches(String host, String domain) {
    if (host == domain) {
      return true;
    }
    return !_isIpAddress(host) && host.endsWith('.$domain');
  }

  /// [host] が IP アドレスかどうかを返します。
  ///
  /// [host] 判定するホスト。IPv6 は角括弧を付けずに渡します（[Uri.host]
  ///   の形）。
  ///
  /// Returns: IPv4 か IPv6 のアドレスなら `true`。
  static bool _isIpAddress(String host) =>
      InternetAddress.tryParse(host) != null;

  /// `^-?\d+$` に合う `Max-Age` の値を秒数にします。
  ///
  /// [value] `Max-Age` 属性の値。`^-?\d+$` に合うものだけを渡します。
  ///
  /// Returns: 負の値は 0、[maxLifetime] を超える値はその秒数に丸めた秒数。
  ///   桁数の多い値も int に変換せずに丸めるため、あふれません。
  static int _parseMaxAgeSeconds(String value) {
    if (value.startsWith('-')) {
      return 0;
    }
    final maxSeconds = maxLifetime.inSeconds;
    final digits = value.replaceFirst(RegExp(r'^0+'), '');
    if (digits.isEmpty) {
      return 0;
    }
    // 上限の桁数（8 桁）を超える値は、int に変換する前に上限へ丸める
    if (digits.length > maxSeconds.toString().length) {
      return maxSeconds;
    }
    final seconds = int.parse(digits);
    return seconds > maxSeconds ? maxSeconds : seconds;
  }

  /// 要求先のパスから default-path を求めます（RFC 6265 5.1.4）。
  ///
  /// [requestPath] 要求先のパス。
  ///
  /// Returns: 最後の `/` より前の部分。求められない場合は `/`。
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
