/// What the current link-layer online decision is based on.
///
/// Used for on-site troubleshooting: it tells whether the proxy is acting on a
/// value read at startup or on a change event reported afterwards.
enum OnlineDecisionSource {
  /// Read once during `start()` from the current connectivity.
  ///
  /// Also used when connectivity could not be read and the proxy fell back to
  /// treating the device as online.
  initial,

  /// Reported by a connectivity change event after startup.
  linkLayer,
}
