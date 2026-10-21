/// テストの HTTP 要求へ proxy の秘密値を自動で付ける補助です。
///
/// 0.26.0 から [ProxyConfig.requireAccessToken] の既定が `true` になり、
/// 秘密値を持たない要求は `403` になります。秘密値そのものを検証しない
/// テストが、既定の設定のまま WebView と同じ条件で proxy を呼べるよう、
/// [trackAccessToken] で登録した proxy 宛ての要求に
/// [OfflineWebProxy.accessTokenHeaderName] ヘッダを付けます。
///
/// 使い方:
///
/// ```dart
/// final proxy = trackAccessToken(OfflineWebProxy());
/// await HttpOverrides.runZoned(
///   () async { /* proxy へ要求する */ },
///   createHttpClient: AccessTokenHttpOverrides().createHttpClient,
/// );
/// ```
library;

import 'dart:io';

import 'package:offline_web_proxy/offline_web_proxy.dart';

/// 秘密値を付ける対象として登録した proxy。
///
/// テストファイルごとに別の isolate で動くため、ファイル内で生成した
/// インスタンス数を超えて増えない。
final Set<OfflineWebProxy> _trackedProxies = <OfflineWebProxy>{};

/// [proxy] を秘密値の自動付与の対象に登録します。
///
/// 登録した proxy が稼働中の間、そのポート宛ての要求に秘密値のヘッダを
/// 付けます。再起動で秘密値が変わっても、要求のたびに読み直します。
///
/// [proxy] 登録する proxy。
///
/// Returns: 呼び出し側で続けて使えるよう、[proxy] そのもの。
OfflineWebProxy trackAccessToken(OfflineWebProxy proxy) {
  _trackedProxies.add(proxy);
  return proxy;
}

/// [uri] 宛ての要求に付ける秘密値を返します。
///
/// [uri] 要求先。
///
/// Returns: 登録済みで稼働中の proxy のポート宛てなら、その秘密値。
/// それ以外（上流のモックなど）は `null`。
String? accessTokenFor(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host != '127.0.0.1' && host != 'localhost' && host != '::1') {
    return null;
  }

  for (final proxy in _trackedProxies) {
    final token = proxy.accessToken;
    if (token != null && proxy.port == uri.port) {
      return token;
    }
  }
  return null;
}

/// 実通信の [HttpClient] を返し、登録した proxy 宛ての要求へ秘密値を
/// 付ける [HttpOverrides]。
///
/// flutter_test の既定の HttpClient はモックのため、実通信には dart:io の
/// 実装を使います。
class AccessTokenHttpOverrides extends HttpOverrides {
  /// 秘密値を付ける [HttpClient] を生成します。
  ///
  /// [context] TLS の設定。
  ///
  /// Returns: dart:io の実装を包んだクライアント。
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return AccessTokenHttpClient(super.createHttpClient(context));
  }
}

/// 登録した proxy 宛ての要求に秘密値のヘッダを付ける [HttpClient]。
///
/// 要求の生成以外は包んだクライアントへそのまま委ねます。テストが
/// 明示的に秘密値のヘッダを付けた場合は上書きしません。
class AccessTokenHttpClient implements HttpClient {
  /// [_inner] を包んだクライアントを生成します。
  ///
  /// [_inner] 実際に通信するクライアント。
  AccessTokenHttpClient(this._inner);

  /// 実際に通信するクライアント。
  final HttpClient _inner;

  /// 生成した要求へ、宛先に応じて秘密値のヘッダを付けます。
  ///
  /// [pending] 包んだクライアントが生成中の要求。
  ///
  /// Returns: ヘッダを付けた要求。
  Future<HttpClientRequest> _withToken(
      Future<HttpClientRequest> pending) async {
    final request = await pending;
    final token = accessTokenFor(request.uri);
    if (token != null &&
        request.headers.value(OfflineWebProxy.accessTokenHeaderName) == null) {
      request.headers.set(OfflineWebProxy.accessTokenHeaderName, token);
    }
    return request;
  }

  @override
  Duration get idleTimeout => _inner.idleTimeout;

  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;

  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;

  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _withToken(_inner.open(method, host, port, path));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _withToken(_inner.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _withToken(_inner.get(host, port, path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _withToken(_inner.getUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _withToken(_inner.post(host, port, path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _withToken(_inner.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _withToken(_inner.put(host, port, path));

  @override
  Future<HttpClientRequest> putUrl(Uri url) => _withToken(_inner.putUrl(url));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _withToken(_inner.delete(host, port, path));

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _withToken(_inner.deleteUrl(url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _withToken(_inner.patch(host, port, path));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _withToken(_inner.patchUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _withToken(_inner.head(host, port, path));

  @override
  Future<HttpClientRequest> headUrl(Uri url) => _withToken(_inner.headUrl(url));

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;

  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void close({bool force = false}) => _inner.close(force: force);
}
