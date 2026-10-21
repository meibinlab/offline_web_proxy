/// Hive の文字列キーの長さの制限に合わせてキーを整える部品です。
///
/// Hive 2.2.3 は文字列キーの UTF-8 のバイト数を 1 バイトの欄に書きます。
/// 255 バイトを超えるキーは assert が無効なリリースビルドでは拒否されず、
/// 長さの欄が桁あふれした壊れたフレームがそのまま書かれます。次に Box を
/// 開くと Hive が例外を送出し、proxy が起動できなくなるため、書く前に
/// ここで長さを制限します。
/// proxy の内部実装用で、ライブラリからは公開しません。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hive の文字列キーにできる UTF-8 のバイト数の上限です。
const int maxHiveStringKeyBytes = 255;

/// 長いキーを置き換えた値に付ける接頭辞です。
///
/// 置き換えた値であることを、保存したデータから見分けられるようにします。
const String hashedHiveKeyPrefix = 'sha256:';

/// [key] を Hive の文字列キーとして使える値に変換します。
///
/// UTF-8 で 255 バイト以下のキーはそのまま返します。既存の保存データの
/// キーを変えないためです。255 バイトを超えるキーと、長さによらず
/// [hashedHiveKeyPrefix] で始まるキーは、UTF-8 のバイト列の SHA-256 を
/// 16 進で表した値に [hashedHiveKeyPrefix] を付けて返します（71 バイト）。
/// 接頭辞で始まるキーもハッシュにするのは、`sha256:<64 桁の 16 進>` の
/// 短いキー（べき等性キーなど外から与えられる値）が、別の長いキーを
/// 置き換えた値と同じ記録を指さないようにするためです。同じキーからは常に
/// 同じ値になるため、保存と参照の両方でこの関数を通せば同じ記録を指します。
///
/// [key] 変換するキー。
///
/// Returns: Hive の文字列キーとして使える値。
String toHiveKey(String key) {
  final bytes = utf8.encode(key);
  if (bytes.length <= maxHiveStringKeyBytes &&
      !key.startsWith(hashedHiveKeyPrefix)) {
    return key;
  }
  return '$hashedHiveKeyPrefix${sha256.convert(bytes)}';
}

/// [key] を、0.25.0 以前の [toHiveKey] と同じ規則で Hive の文字列キーに
/// 変換します。
///
/// UTF-8 で 255 バイト以下のキーは、[hashedHiveKeyPrefix] で始まる場合も
/// 含めてそのまま返し、255 バイトを超えるキーは [toHiveKey] と同じく
/// SHA-256 に置き換えます。0.25.0 以前に記録したべき等性キーを照会する
/// ためだけに使い、新しく書く記録には使いません。
///
/// [key] 変換するキー。
///
/// Returns: 0.25.0 以前に Hive の文字列キーとして使っていた値。
String legacyToHiveKey(String key) {
  final bytes = utf8.encode(key);
  if (bytes.length <= maxHiveStringKeyBytes) {
    return key;
  }
  return '$hashedHiveKeyPrefix${sha256.convert(bytes)}';
}
