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
  /// `0` when the upstream could not be reached at all.
  final int statusCode;

  /// Whether the upstream accepted the request.
  ///
  /// `true` once the upstream answered with 2xx, or when the idempotency key
  /// shows the request had already been delivered.
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
  /// [statusCode] is the upstream status code, or `0` when unreachable.
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
  /// Used by the proxy to publish the result over HTTP and events.
  ///
  /// Returns: a map holding every field of this result.
  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'method': method,
      'statusCode': statusCode,
      'success': success,
      'idempotencyKey': idempotencyKey,
      'dropReason': dropReason,
      'willRetry': willRetry,
      'attemptedAt': attemptedAt.toIso8601String(),
    };
  }

  @override
  String toString() {
    return 'QueueResendResult{url: $url, method: $method, '
        'statusCode: $statusCode, success: $success}';
  }
}
