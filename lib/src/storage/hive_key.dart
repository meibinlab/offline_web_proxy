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
/// キーを変えないためです。255 バイトを超えるキーは、UTF-8 のバイト列の
/// SHA-256 を 16 進で表した値に [hashedHiveKeyPrefix] を付けて返します
/// （71 バイト）。同じキーからは常に同じ値になるため、保存と参照の両方で
/// この関数を通せば同じ記録を指します。
///
/// [key] 変換するキー。
///
/// Returns: Hive の文字列キーとして使える値。
String toHiveKey(String key) {
  final bytes = utf8.encode(key);
  if (bytes.length <= maxHiveStringKeyBytes) {
    return key;
  }
  return '$hashedHiveKeyPrefix${sha256.convert(bytes)}';
}
