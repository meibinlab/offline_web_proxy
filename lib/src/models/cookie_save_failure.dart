/// 上流の `Set-Cookie` を保存できなかった理由の区分です。
///
/// `errorOccurred`（`operation: cookieSave`）の `reason` に載せます。例外の
/// 文言には `Set-Cookie` の値が含まれ得るため、イベントには文言ではなく
/// この区分と例外の型名だけを載せます。受け入れ規則で保存しなかった場合は、
/// [CookieRejectionReason.code] を載せます。
/// proxy の内部実装用で、ライブラリからは公開しません。
library;

import 'cookie_rejection.dart';

/// 保存領域の失敗を表す `reason` の値です。
///
/// Cookie の保存（`operation: cookieSave`）と応答の保存
/// （`phase: cacheResponse`）の `errorOccurred` で共通に使います。
const String storageFailureEventReason = 'storageFailure';

/// `Set-Cookie` を解釈できなかったことを表す区分です。
const String cookieSaveReasonInvalidSetCookie = 'invalidSetCookie';

/// 保存領域の失敗など、解釈以外で保存できなかったことを表す区分です。
const String cookieSaveReasonStorageFailure = storageFailureEventReason;

/// Cookie の保存に失敗した理由の区分を返します。
///
/// [error] 保存の途中で起きた例外。
///
/// Returns: [CookieRejectedException]（受け入れ規則に外れた場合）は
///   その [CookieRejectionReason.code]、[FormatException] か
///   [ArgumentError]（`Set-Cookie` を解釈できなかった場合）は
///   [cookieSaveReasonInvalidSetCookie]、それ以外は
///   [cookieSaveReasonStorageFailure]。
String cookieSaveFailureReason(Object error) {
  if (error is CookieRejectedException) {
    return error.reason.code;
  }
  if (error is FormatException || error is ArgumentError) {
    return cookieSaveReasonInvalidSetCookie;
  }
  return cookieSaveReasonStorageFailure;
}
