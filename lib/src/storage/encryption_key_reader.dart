import 'dart:convert';
import 'dart:typed_data';

import 'encryption_key_storage.dart';

/// 暗号化鍵を読み取った結果の区分です。
enum EncryptionKeyState {
  /// iOS / macOS の端末ロック中などで、一時的に読めない状態です。
  ///
  /// このとき読み取りの `null` も例外も、鍵の有無の判定には使いません。
  temporarilyUnavailable,

  /// 読み取りが例外で失敗した状態です。
  unreadable,

  /// 鍵が保存されていない状態です（読み取りの結果が `null`）。
  missing,

  /// 保存された値が鍵の形式ではない状態です（空文字、Base64 として読めない、
  /// または 32 バイトでない）。
  invalid,

  /// 鍵を読めた状態です。
  present,
}

/// 暗号化鍵を読み取った結果です。
class EncryptionKeyRead {
  /// 読み取り結果の区分です。
  final EncryptionKeyState state;

  /// 読めた鍵です。[state] が [EncryptionKeyState.present] の場合だけ値を持ちます。
  final Uint8List? key;

  /// 読み取りや形式の検証で起きたエラーです。
  final Object? error;

  /// 読み取り結果を生成します。
  ///
  /// [state] は読み取り結果の区分です。
  /// [key] は読めた鍵です。
  /// [error] は読み取りや形式の検証で起きたエラーです。
  const EncryptionKeyRead(this.state, {this.key, this.error});
}

/// secure storage から暗号化鍵を読み取り、状態を区分するクラスです。
///
/// proxy の内部実装用で、ライブラリからは公開しません。
class EncryptionKeyReader {
  /// 暗号化鍵のバイト数（AES-256）です。
  static const int keyLength = 32;

  /// 鍵の読み書きに使う窓口です。
  final EncryptionKeyStorage storage;

  /// secure storage 上で鍵を保存する名前です。
  final String storageKey;

  /// 鍵を読み直す間隔です。
  final Duration rereadInterval;

  /// 鍵を読み直す回数です（最初の読み取りを含みません）。
  final int rereadAttempts;

  /// 鍵を読み取るクラスを生成します。
  ///
  /// [storage] は鍵の読み書きに使う窓口です。
  /// [storageKey] は secure storage 上で鍵を保存する名前です。
  /// [rereadInterval] は鍵を読み直す間隔です。
  /// [rereadAttempts] は鍵を読み直す回数です。
  const EncryptionKeyReader({
    required this.storage,
    required this.storageKey,
    required this.rereadInterval,
    required this.rereadAttempts,
  });

  /// 鍵を読み取り、必要なら読み直して状態を確定します。
  ///
  /// 中身のある暗号化 Box があり、鍵が「なし」か「読み取り不能」の場合だけ、
  /// [rereadInterval] ごとに [rereadAttempts] 回読み直します。
  /// * 1 回でも値を読めた場合（形式不正を含む）は、その値で判定します
  /// * すべて同じ結果（すべて `null`、またはすべて例外）の場合だけ、その状態が
  ///   続いているとみなします
  /// * 結果が `null` と例外で入り混じる場合や、途中で一時的に読めない状態に
  ///   変わった場合は、一時的に読めない状態として扱います
  ///
  /// [hasEncryptedContent] 中身のある暗号化 Box があるかどうか。無い場合は
  ///   失うものが無いため読み直しません。
  ///
  /// Returns: 確定した読み取り結果。
  Future<EncryptionKeyRead> read({required bool hasEncryptedContent}) async {
    final first = await readOnce();
    if (!hasEncryptedContent || !_needsReread(first.state)) {
      return first;
    }

    for (var attempt = 0; attempt < rereadAttempts; attempt++) {
      await Future<void>.delayed(rereadInterval);
      final reread = await readOnce();
      if (reread.state == EncryptionKeyState.present ||
          reread.state == EncryptionKeyState.invalid) {
        return reread;
      }
      if (reread.state != first.state) {
        return EncryptionKeyRead(
          EncryptionKeyState.temporarilyUnavailable,
          error: reread.error ?? first.error,
        );
      }
    }

    return first;
  }

  /// 鍵を 1 回だけ読み取り、状態を区分します。
  ///
  /// Returns: 読み取り結果。
  Future<EncryptionKeyRead> readOnce() async {
    if (await _isProtectedDataUnavailable()) {
      return const EncryptionKeyRead(EncryptionKeyState.temporarilyUnavailable);
    }

    final String? storedKey;
    try {
      storedKey = await storage.read(storageKey);
    } catch (error) {
      // 読み取りの途中で端末がロックされた場合は、失敗を判定に使わない
      if (await _isProtectedDataUnavailable()) {
        return EncryptionKeyRead(
          EncryptionKeyState.temporarilyUnavailable,
          error: error,
        );
      }
      return EncryptionKeyRead(EncryptionKeyState.unreadable, error: error);
    }

    if (storedKey == null) {
      if (await _isProtectedDataUnavailable()) {
        return const EncryptionKeyRead(
          EncryptionKeyState.temporarilyUnavailable,
        );
      }
      return const EncryptionKeyRead(EncryptionKeyState.missing);
    }

    final List<int> decodedKey;
    try {
      decodedKey = base64Decode(storedKey);
    } on FormatException catch (error) {
      return EncryptionKeyRead(EncryptionKeyState.invalid, error: error);
    }

    if (decodedKey.length != keyLength) {
      return EncryptionKeyRead(
        EncryptionKeyState.invalid,
        error: FormatException(
          'Invalid encryption key length: ${decodedKey.length}',
        ),
      );
    }

    return EncryptionKeyRead(
      EncryptionKeyState.present,
      key: Uint8List.fromList(decodedKey),
    );
  }

  /// 読み直しの対象となる状態かどうかを返します。
  ///
  /// [state] 最初の読み取り結果の区分。
  ///
  /// Returns: 鍵が「なし」か「読み取り不能」の場合は `true`。
  bool _needsReread(EncryptionKeyState state) {
    return state == EncryptionKeyState.missing ||
        state == EncryptionKeyState.unreadable;
  }

  /// iOS / macOS で保護データを読めない状態かどうかを返します。
  ///
  /// Returns: 読めない状態の場合は `true`。iOS / macOS 以外（戻り値が `null`）
  ///   や、状態を取得できなかった場合は `false`。
  Future<bool> _isProtectedDataUnavailable() async {
    try {
      return await storage.isProtectedDataAvailable() == false;
    } catch (_) {
      // 状態を取得できない場合は利用可能とみなし、鍵の読み取りの結果で判断する
      return false;
    }
  }
}
