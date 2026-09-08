/// State of the upstream reachability circuit breaker.
///
/// Link-layer connectivity does not prove that the upstream server can be
/// reached. The proxy tracks consecutive unreachable attempts and stops
/// forwarding requests while the upstream is considered unavailable, so a
/// WebView is not left waiting for the request timeout on every request.
enum UpstreamCircuitState {
  /// The upstream is considered reachable and requests are forwarded.
  closed,

  /// The upstream is considered unreachable.
  ///
  /// Requests are answered from cache or stored in the queue immediately, and
  /// reachability probes run with backoff.
  open,

  /// A reachability probe is in flight.
  ///
  /// Requests are still answered without contacting the upstream until the
  /// probe finishes.
  halfOpen,
}
