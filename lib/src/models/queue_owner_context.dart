import 'dart:convert';

/// Function that tells who signed in, from a sign-in request and its response.
///
/// Set it as `ProxyConfig.queueOwnerResolver`. Return the identifier of the
/// user who signed in, such as an account name, or `null` when the response
/// does not show a successful sign-in. The function runs synchronously while
/// the queue waits, so keep it short and do not throw.
typedef QueueOwnerResolver = String? Function(QueueOwnerContext context);

/// Sign-in request and response passed to a [QueueOwnerResolver].
///
/// The proxy builds one when a request matching
/// `ProxyConfig.authResumePaths` is answered with a 2xx or 3xx by the
/// upstream. Bodies are passed as received from the WebView and as decoded
/// from the upstream (after removing `Content-Encoding`).
class QueueOwnerContext {
  /// HTTP method of the sign-in request, such as `POST`.
  final String method;

  /// Path of the sign-in request, starting with `/`, without the query.
  final String path;

  /// Query parameters of the sign-in request.
  final Map<String, String> queryParameters;

  /// Headers of the sign-in request sent by the WebView.
  final Map<String, String> requestHeaders;

  /// Body of the sign-in request. Empty for `GET` and `HEAD`.
  final List<int> requestBody;

  /// Status code returned by the upstream (2xx or 3xx).
  final int statusCode;

  /// Headers of the upstream response. Several `Set-Cookie` headers are
  /// joined into one value.
  final Map<String, String> responseHeaders;

  /// Body of the upstream response, decoded.
  final List<int> responseBody;

  /// Creates a sign-in context.
  ///
  /// [method] is the HTTP method of the sign-in request.
  /// [path] is its path, starting with `/`.
  /// [queryParameters] are its query parameters.
  /// [requestHeaders] are its headers.
  /// [requestBody] is its body.
  /// [statusCode] is the status code returned by the upstream.
  /// [responseHeaders] are the headers of the upstream response.
  /// [responseBody] is the decoded body of the upstream response.
  const QueueOwnerContext({
    required this.method,
    required this.path,
    this.queryParameters = const {},
    this.requestHeaders = const {},
    this.requestBody = const [],
    required this.statusCode,
    this.responseHeaders = const {},
    this.responseBody = const [],
  });

  /// Request body read as UTF-8. Malformed bytes become U+FFFD.
  String get requestBodyText => utf8.decode(requestBody, allowMalformed: true);

  /// Response body read as UTF-8. Malformed bytes become U+FFFD.
  String get responseBodyText =>
      utf8.decode(responseBody, allowMalformed: true);

  /// Request body parsed as JSON, or `null` when it is not valid JSON.
  Object? get requestJson => _tryDecodeJson(requestBodyText);

  /// Response body parsed as JSON, or `null` when it is not valid JSON.
  Object? get responseJson => _tryDecodeJson(responseBodyText);

  /// Fields of a form-encoded request body.
  ///
  /// Read only when `Content-Type` is `application/x-www-form-urlencoded`;
  /// otherwise, and when the body cannot be decoded, the map is empty. When
  /// a field appears more than once, the last value is kept.
  Map<String, String> get requestFormFields {
    final contentType = requestHeader('content-type')?.toLowerCase() ?? '';
    if (!contentType.startsWith('application/x-www-form-urlencoded')) {
      return const {};
    }
    try {
      return Uri.splitQueryString(requestBodyText);
    } on FormatException {
      return const {};
    } on ArgumentError {
      // A broken percent escape such as `%zz` is reported as an ArgumentError.
      return const {};
    }
  }

  /// Returns a request header, ignoring the case of its name.
  ///
  /// [name] is the header name.
  ///
  /// Returns: the value, or `null` when the header is absent.
  String? requestHeader(String name) => _findHeader(requestHeaders, name);

  /// Returns a response header, ignoring the case of its name.
  ///
  /// [name] is the header name.
  ///
  /// Returns: the value, or `null` when the header is absent.
  String? responseHeader(String name) => _findHeader(responseHeaders, name);

  static String? _findHeader(Map<String, String> headers, String name) {
    final lowerName = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lowerName) {
        return entry.value;
      }
    }
    return null;
  }

  static Object? _tryDecodeJson(String text) {
    if (text.trim().isEmpty) {
      return null;
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() {
    // Bodies carry credentials, so they are left out.
    return 'QueueOwnerContext{method: $method, path: $path, '
        'status: $statusCode}';
  }
}
