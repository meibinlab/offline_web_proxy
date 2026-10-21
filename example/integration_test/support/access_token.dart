/// e2e テストで proxy の秘密値を WebView と HTTP 要求へ渡す補助です。
///
/// 0.26.0 から [ProxyConfig.requireAccessToken] の既定が `true` になり、
/// 秘密値を持たない要求は `403` になります。利用側の手順と同じく、
/// WebView が読み込む前に [OfflineWebProxy.accessTokenCookieName] の Cookie を
/// proxy の origin へ置き、WebView 以外からの要求には
/// [OfflineWebProxy.accessTokenHeaderName] ヘッダを付けます。
///
/// `webview_flutter` の [WebViewCookieManager] は HttpOnly を指定できない
/// ため、ここで置く Cookie はページのスクリプトから読めます。HttpOnly で
/// 置く手順は `offline_web_proxy_access_token_e2e_test.dart` を参照して
/// ください。
library;

import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 秘密値を渡す対象として登録した proxy。
final Set<OfflineWebProxy> _trackedProxies = <OfflineWebProxy>{};

/// [proxy] を秘密値の受け渡しの対象に登録します。
///
/// [proxy] 登録する proxy。
///
/// Returns: 呼び出し側で続けて使えるよう、[proxy] そのもの。
OfflineWebProxy trackAccessToken(OfflineWebProxy proxy) {
  _trackedProxies.add(proxy);
  return proxy;
}

/// [uri] のポートで稼働中の登録済み proxy を返します。
///
/// [uri] 要求先。
///
/// Returns: 該当する proxy。無ければ `null`。
OfflineWebProxy? _runningProxyFor(Uri uri) {
  for (final proxy in _trackedProxies) {
    if (proxy.accessToken != null && proxy.port == uri.port) {
      return proxy;
    }
  }
  return null;
}

/// [uri] 宛ての要求に付ける秘密値のヘッダを返します。
///
/// [uri] 要求先。
///
/// Returns: 登録済みで稼働中の proxy 宛てなら秘密値のヘッダ 1 件。
/// それ以外は空。
Map<String, String> accessTokenHeadersFor(Uri uri) {
  final token = _runningProxyFor(uri)?.accessToken;
  if (token == null) {
    return const <String, String>{};
  }
  return <String, String>{OfflineWebProxy.accessTokenHeaderName: token};
}

/// [proxy] の秘密値を WebView の Cookie として proxy の origin へ置きます。
///
/// [proxy] 稼働中の proxy。
///
/// Returns: Cookie を置き終えた時点で完了する Future。
///
/// Throws:
///   * [StateError] [proxy] が稼働していない場合。
Future<void> putAccessTokenCookie(OfflineWebProxy proxy) async {
  final baseUri = proxy.baseUri;
  final token = proxy.accessToken;
  if (baseUri == null || token == null) {
    throw StateError('proxy is not running');
  }

  await WebViewCookieManager().setCookie(
    WebViewCookie(
      name: OfflineWebProxy.accessTokenCookieName,
      value: token,
      domain: baseUri.host,
    ),
  );
}

/// [uri] のポートで稼働中の登録済み proxy があれば、その秘密値を
/// WebView の Cookie として置きます。
///
/// 再起動で秘密値が変わった後の読み込みにも対応するため、読み込みの
/// たびに呼びます。
///
/// [uri] WebView が読み込む URL。
///
/// Returns: Cookie を置き終えた時点（対象が無ければ直ちに）完了する Future。
Future<void> putAccessTokenCookieFor(Uri uri) async {
  final proxy = _runningProxyFor(uri);
  if (proxy != null) {
    await putAccessTokenCookie(proxy);
  }
}
