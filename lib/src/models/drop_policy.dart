/// How the proxy handles a queued update request the upstream rejected.
///
/// A 4xx response means resending cannot change the result, so the request
/// leaves the queue. What happens next depends on how costly losing the
/// request is for the application.
enum DropPolicy {
  /// Move the request to a quarantine store instead of discarding it.
  ///
  /// The request keeps its body, so an operator can resend it after fixing the
  /// cause, or discard it deliberately. Use this when losing a request means
  /// losing business data, such as a sales record.
  quarantine,

  /// Discard the request and keep only a history entry.
  ///
  /// The body is not retained, so the request cannot be resent.
  drop,
}
