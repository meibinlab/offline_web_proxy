import 'dart:io';

/// 上流レスポンスヘッダのスナップショットです。
///
/// 通常ヘッダは既存実装互換のため 1 行文字列へ平坦化しつつ、
/// `Set-Cookie` だけは raw 値の配列を別保持します。
class ResponseHeaderSnapshot {
  /// 既存レスポンス互換のために平坦化したヘッダです。
  final Map<String, String> flattenedHeaders;

  /// `Set-Cookie` の raw 値一覧です。
  final List<String> setCookieHeaders;

  /// ヘッダスナップショットを生成します。
  const ResponseHeaderSnapshot({
    required this.flattenedHeaders,
    required this.setCookieHeaders,
  });

  /// [HttpHeaders] からスナップショットを生成します。
  ///
  /// [headers] は上流レスポンスヘッダです。
  /// 戻り値は生成された [ResponseHeaderSnapshot] です。
  factory ResponseHeaderSnapshot.fromHttpHeaders(HttpHeaders headers) {
    final rawHeaders = <String, List<String>>{};
    headers.forEach((name, values) {
      rawHeaders[name] = List<String>.from(values);
    });
    return ResponseHeaderSnapshot.fromRawHeaders(rawHeaders);
  }

  /// raw ヘッダマップからスナップショットを生成します。
  ///
  /// [rawHeaders] は `header-name -> values` 形式のマップです。
  /// 戻り値は生成された [ResponseHeaderSnapshot] です。
  factory ResponseHeaderSnapshot.fromRawHeaders(
      Map<String, List<String>> rawHeaders) {
    final flattenedHeaders = <String, String>{};
    final setCookieHeaders = <String>[];

    rawHeaders.forEach((name, values) {
      if (name.toLowerCase() == 'set-cookie') {
        setCookieHeaders.addAll(values);
      }
      flattenedHeaders[name] = values.join(', ');
    });

    return ResponseHeaderSnapshot(
      flattenedHeaders: Map.unmodifiable(flattenedHeaders),
      setCookieHeaders: List.unmodifiable(setCookieHeaders),
    );
  }
}