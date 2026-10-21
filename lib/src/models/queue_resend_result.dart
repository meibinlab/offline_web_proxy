/// Outcome of one attempt to resend a queued update request.
///
/// A queued request is resent in the background, so its response never reaches
/// the page that created it. An app that has to reconcile what the upstream
/// actually recorded — a point of sale comparing a printed receipt against the
/// stored sale, for example — needs to see those outcomes.
///
/// The request body is never included. These results are meant for monitoring
/// and are surfaced through `ProxyEventType.queueResendAttempted` and
/// `OfflineWebProxy.recentResendResults`.
class QueueResendResult {
  /// URL the request was sent to.
  final String url;

  /// HTTP method of the request.
  final String method;

  /// Status code returned by the upstream.
  ///
  /// `0` when the upstream could not be reached at all, or when the request
  /// was not sent because it belongs to another user (`dropReason`
  /// `owner_changed`) or because its saved destination is no longer the
  /// configured origin (`dropReason` `origin_changed`).
  final int statusCode;

  /// Whether the upstream accepted the request.
  ///
  /// `true` once the upstream answered with 2xx or `303`, or when the
  /// idempotency key shows the request had already been delivered.
  final bool success;

  /// Idempotency key sent with the request, when one was attached.
  final String? idempotencyKey;

  /// Why the request left the queue without succeeding.
  ///
  /// `null` while the request is still queued or when it succeeded.
  final String? dropReason;

  /// Whether the request stays in the queue for another attempt.
  final bool willRetry;

  /// When the attempt finished, in UTC.
  ///
  /// Kept in UTC so that the ISO 8601 form produced by [toMap] cannot be
  /// misread as local time.
  final DateTime attemptedAt;

  /// Creates a resend result.
  ///
  /// [url] is the URL the request was sent to.
  /// [method] is the HTTP method.
  /// [statusCode] is the upstream status code, or `0` when unreachable or
  /// not sent.
  /// [success] is whether the upstream accepted the request.
  /// [idempotencyKey] is the key sent with the request, when any.
  /// [dropReason] is why it left the queue without succeeding.
  /// [willRetry] is whether it stays queued for another attempt.
  /// [attemptedAt] is when the attempt finished.
  const QueueResendResult({
    required this.url,
    required this.method,
    required this.statusCode,
    required this.success,
    required this.idempotencyKey,
    required this.dropReason,
    required this.willRetry,
    required this.attemptedAt,
  });

  /// Converts the result into a JSON-compatible map.
  ///
  /// Used by the proxy to publish the result over HTTP and events. The status
  /// endpoint always passes `includeQuery: false`, and events follow
  /// `ProxyConfig.includeQueryInEvents`.
  ///
  /// [includeQuery] whether `url` keeps its query string and fragment. When
  /// `false`, everything from the first `?` or `#` is removed. Defaults to
  /// `true`.
  ///
  /// Returns: a map holding every field of this result.
  Map<String, dynamic> toMap({bool includeQuery = true}) {
    return {
      'url': includeQuery ? url : _withoutQueryAndFragment(url),
      'method': method,
      'statusCode': statusCode,
      'success': success,
      'idempotencyKey': idempotencyKey,
      'dropReason': dropReason,
      'willRetry': willRetry,
      'attemptedAt': attemptedAt.toIso8601String(),
    };
  }

  /// Removes the query string and fragment from [value].
  ///
  /// Works on unparsable values too by cutting at the first `?` or `#`.
  ///
  /// [value] the URL to trim.
  ///
  /// Returns: [value] without its query string and fragment.
  static String _withoutQueryAndFragment(String value) {
    final cut = value.indexOf(RegExp(r'[?#]'));
    return cut == -1 ? value : value.substring(0, cut);
  }

  @override
  String toString() {
    return 'QueueResendResult{url: $url, method: $method, '
        'statusCode: $statusCode, success: $success}';
  }
}
