/// 上流の `Set-Cookie` を受け入れなかった理由と、その例外です。
///
/// 上流応答の `Set-Cookie` を Cookie Jar へ保存する前に、RFC 6265 と
/// RFC 6265bis の受け入れ規則で確かめ、外れたものは保存しません。理由は
/// `errorOccurred`（`operation: cookieSave`）の `reason` に載せます。
/// proxy の内部実装用で、ライブラリからは公開しません。
library;

/// `Set-Cookie` を受け入れなかった理由です。
enum CookieRejectionReason {
  /// `Domain` 属性が要求先ホストに domain-match しません。
  domainMismatch('domainMismatch'),

  /// 要求先ホストが IP アドレスで、`Domain` 属性がホストと異なります。
  ipDomain('ipDomain'),

  /// `Domain` 属性に `.` がなく（`com` など）、要求先ホストと異なります。
  singleLabelDomain('singleLabelDomain'),

  /// 中継先（`ProxyConfig.mirroredOrigins`）の応答の Cookie が、設定済み
  /// origin のホストへも送られる範囲を指しています。
  mirroredOriginDomain('mirroredOriginDomain'),

  /// `https` 以外の応答が `Secure` 属性の Cookie を置こうとしました。
  insecureSecure('insecureSecure'),

  /// `__Host-` で始まる名前の Cookie が、`Secure`・`https`・`Domain` なし・
  /// `Path` 属性があり解決後のパスが `/`、のいずれかを満たしていません。
  hostPrefix('hostPrefix'),

  /// `__Secure-` で始まる名前の Cookie が、`Secure` と `https` のいずれかを
  /// 満たしていません。
  securePrefix('securePrefix'),

  /// `https` 以外の応答が、同じ名前・ドメイン・パスの `Secure` の Cookie を
  /// 上書きまたは削除しようとしました。
  secureOverwrite('secureOverwrite');

  /// 理由を生成します。
  ///
  /// [code] イベントの `reason` に載せる文字列。
  const CookieRejectionReason(this.code);

  /// イベントの `reason` に載せる文字列です。
  final String code;
}

/// `Set-Cookie` を受け入れ規則により保存しなかったことを表す例外です。
///
/// Cookie の値は持たず、理由と Cookie 名だけを持ちます。
class CookieRejectedException implements Exception {
  /// 例外を生成します。
  ///
  /// [reason] 受け入れなかった理由。
  /// [cookieName] 受け入れなかった Cookie の名前。
  const CookieRejectedException(this.reason, this.cookieName);

  /// 受け入れなかった理由です。
  final CookieRejectionReason reason;

  /// 受け入れなかった Cookie の名前です。
  final String cookieName;

  /// 例外の内容を文字列で返します。値は含めません。
  ///
  /// Returns: 理由と Cookie 名を含む文字列。
  @override
  String toString() =>
      'CookieRejectedException(${reason.code}, cookieName: $cookieName)';
}
