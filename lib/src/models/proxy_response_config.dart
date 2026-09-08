/// A response the proxy generates on its own instead of forwarding upstream.
///
/// Used for the two cases a web front end has to tell apart from a real
/// upstream response: a request stored in the offline queue, and a read that
/// could not be served offline.
///
/// ## Example Usage
///
/// ```dart
/// const config = ProxyConfig(
///   origin: 'https://api.example.com',
///   queuedResponse: ProxyResponseConfig(
///     statusCode: 202,
///     contentType: 'application/json; charset=utf-8',
///     body: '{"queued": true, "message": "保存しました"}',
///   ),
/// );
/// ```
class ProxyResponseConfig {
  /// HTTP status code of the generated response.
  final int statusCode;

  /// Value of the `Content-Type` header.
  final String contentType;

  /// Response body.
  ///
  /// Keep it parseable by the front end. The default bodies are JSON so that
  /// `await response.json()` succeeds in a single-page application.
  final String body;

  /// Creates a generated response definition.
  ///
  /// [statusCode] is the HTTP status code.
  /// [contentType] is the value of the `Content-Type` header.
  /// [body] is the response body.
  const ProxyResponseConfig({
    required this.statusCode,
    required this.contentType,
    required this.body,
  });

  @override
  String toString() {
    return 'ProxyResponseConfig{statusCode: $statusCode, '
        'contentType: $contentType}';
  }
}
