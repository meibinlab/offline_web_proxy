/// 受け付けた要求の宛先（`Host` ヘッダとパス）を検査する関数群です。
///
/// proxy は WebView からの要求だけを想定しています。別のサイトのページから
/// DNS rebinding で届いた要求や、上流でパスの解釈がずれる要求を、ルーターや
/// 上流への転送より前に見分けるために使います。
library;

/// 要求のパスを受け付けない理由です。
enum RequestPathRejection {
  /// `%` の後に 16 進数 2 桁が続かない。
  malformedPercentEncoding,

  /// 符号化や `\`、`;` で隠した `.` または `..` のセグメントを含む。
  dotSegment,
}

/// 要求のパスを受け付けない理由を返します。
///
/// dart:io は要求行を解釈する際に、`/` で区切られた `.` と `..`（`%2E` で
/// 書いたものを含む）を先に解決します。一方、`..%2F` や `%5C..` のように
/// 区切りを符号化した場合は解決されないまま届き、上流のサーバが復号してから
/// 解決すると、proxy が見たパスとは別の資源を指します。そこで、セグメント
/// ごとに `%XX` を復号し、`/` と `\` で分けた各部分（`;` 以降のパス
/// パラメータを除いたもの）が `.` か `..` になる場合を拒否します。
///
/// `a%2Fb` のように、区切りを符号化していても `.` と `..` を伴わない
/// パスは受け付けます。
///
/// [RequestPathRejection.malformedPercentEncoding] は多重防御です。通常は
/// dart:io が不正な `%` を `%25` に直してから渡すため起きません。
///
/// 上流が多重に復号する場合（二重に符号化した値を復号する、`%5C` を
/// パスの区切りとして扱うなど）の解釈のずれは対象外です。
///
/// [rawPath] 符号化されたままの要求のパス（`Uri.path`）。
///
/// Returns: 受け付けない理由。受け付ける場合は `null`。
RequestPathRejection? findRequestPathRejection(String rawPath) {
  for (final rawSegment in rawPath.split('/')) {
    final decoded = _percentDecodeToCodeUnits(rawSegment);
    if (decoded == null) {
      return RequestPathRejection.malformedPercentEncoding;
    }
    for (final part in decoded.split(RegExp(r'[/\\]'))) {
      final parameterIndex = part.indexOf(';');
      final name =
          parameterIndex < 0 ? part : part.substring(0, parameterIndex);
      if (name == '.' || name == '..') {
        return RequestPathRejection.dotSegment;
      }
    }
  }
  return null;
}

/// `%XX` を 1 バイトずつ文字コードへ復号します。
///
/// `.`、`/`、`\`、`;` の判定だけに使うため、UTF-8 として解釈せず、
/// 復号したバイトをそのまま文字コードにします。この検査では、UTF-8 として
/// 不正なバイト列を理由に拒否しません。ただし、不正な UTF-8 を含むパスは、
/// shelf がミドルウェアのパイプラインより前に `400` にします。
///
/// [segment] 符号化されたままの 1 セグメント。
///
/// Returns: 復号した文字列。`%` の後に 16 進数 2 桁が続かない場合は `null`。
String? _percentDecodeToCodeUnits(String segment) {
  if (!segment.contains('%')) {
    return segment;
  }

  final buffer = StringBuffer();
  var index = 0;
  while (index < segment.length) {
    final character = segment[index];
    if (character != '%') {
      buffer.write(character);
      index++;
      continue;
    }
    if (index + 2 >= segment.length) {
      return null;
    }
    final hex = segment.substring(index + 1, index + 3);
    if (!_hexPairPattern.hasMatch(hex)) {
      return null;
    }
    buffer.writeCharCode(int.parse(hex, radix: 16));
    index += 3;
  }
  return buffer.toString();
}

/// 16 進数 2 桁に一致する正規表現。
final RegExp _hexPairPattern = RegExp(r'^[0-9A-Fa-f]{2}$');

/// `Host` ヘッダを解釈した結果です。
typedef HostHeaderParts = ({String name, int? port});

/// `Host` ヘッダの値をホスト名とポートに分けます。
///
/// ホスト名は小文字にそろえます。IPv6 アドレスは `[::1]` のように角括弧を
/// 含めたまま返します。末尾のドット（`localhost.`）は取り除かず、別の
/// ホスト名として扱います。
///
/// [value] `Host` ヘッダの値。
///
/// Returns: ホスト名とポート（ポートが無い場合は `null`）。解釈できない
/// 値（空、角括弧で囲まない IPv6、空のポート、数字以外のポート、範囲外の
/// ポート）は `null`。
HostHeaderParts? parseHostHeader(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final String name;
  final String? portText;
  if (trimmed.startsWith('[')) {
    final closeIndex = trimmed.indexOf(']');
    if (closeIndex < 0) {
      return null;
    }
    name = trimmed.substring(0, closeIndex + 1);
    final rest = trimmed.substring(closeIndex + 1);
    if (rest.isEmpty) {
      portText = null;
    } else if (rest.startsWith(':')) {
      portText = rest.substring(1);
    } else {
      return null;
    }
  } else {
    final colonIndex = trimmed.indexOf(':');
    if (colonIndex < 0) {
      name = trimmed;
      portText = null;
    } else if (trimmed.indexOf(':', colonIndex + 1) >= 0) {
      // 角括弧で囲まない IPv6 アドレスは Host ヘッダの形式に合わない
      return null;
    } else {
      name = trimmed.substring(0, colonIndex);
      portText = trimmed.substring(colonIndex + 1);
    }
  }

  if (name.isEmpty || name == '[]') {
    return null;
  }

  int? port;
  if (portText != null) {
    if (!_portPattern.hasMatch(portText)) {
      return null;
    }
    port = int.parse(portText);
    if (port < 1 || port > 65535) {
      return null;
    }
  }
  return (name: name.toLowerCase(), port: port);
}

/// ポート番号の表記（1 から 5 桁の数字）に一致する正規表現。
final RegExp _portPattern = RegExp(r'^[0-9]{1,5}$');
