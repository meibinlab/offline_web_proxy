import 'proxy_response_config.dart';

/// An update request that must not be stored in the offline queue.
///
/// Some update requests lose their meaning once the moment has passed. A
/// register sign-in, a sign-out or a session refresh cannot be replayed
/// minutes later, and answering `202 Accepted` for one makes the web app
/// believe it succeeded. A rule keeps such a request out of the queue and
/// answers it immediately instead.
///
/// ## Example Usage
///
/// ```dart
/// const config = ProxyConfig(
///   origin: 'https://api.example.com',
///   queueExcludePaths: [
///     QueueExcludeRule(
///       path: '/api/registers/auth.json',
///       response: ProxyResponseConfig(
///         statusCode: 503,
///         contentType: 'application/json; charset=utf-8',
///         body: '{"message":"オフラインのためレジ認証できません"}',
///       ),
///     ),
///   ],
/// );
/// ```
class QueueExcludeRule {
  /// Path pattern the rule applies to.
  ///
  /// `*` matches within one path segment, `**` matches across segments, and a
  /// pattern without either is matched exactly. Query strings are not part of
  /// the comparison.
  final String path;

  /// HTTP methods the rule applies to.
  ///
  /// An empty list covers every update method the proxy would otherwise queue.
  /// Comparison ignores case.
  ///
  /// **Default**: `[]` (every update method)
  final List<String> methods;

  /// Response returned instead of queueing the request.
  ///
  /// Give it a body the web app already understands, so that no front-end
  /// change is needed to show the right message. The default keeps the shape
  /// of the queued response so that the two can be told apart by their
  /// `queued` field alone.
  ///
  /// **Default**: `503` / `application/json; charset=utf-8` /
  /// `{"queued":false,"offline":true}`
  final ProxyResponseConfig response;

  /// Creates a queue exclusion rule.
  ///
  /// [path] is the path pattern the rule applies to.
  /// [methods] are the HTTP methods it covers; empty means every update method.
  /// [response] is what the proxy answers instead of queueing.
  const QueueExcludeRule({
    required this.path,
    this.methods = const [],
    this.response = const ProxyResponseConfig(
      statusCode: 503,
      contentType: 'application/json; charset=utf-8',
      body: '{"queued":false,"offline":true}',
    ),
  });

  @override
  String toString() {
    return 'QueueExcludeRule{path: $path, methods: $methods, '
        'statusCode: ${response.statusCode}}';
  }
}
