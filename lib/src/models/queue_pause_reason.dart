/// Reason why the proxy stopped sending requests from the offline queue.
///
/// While the queue is paused, requests stay in the queue in their original
/// order and nothing is sent from it. The value appears as
/// `ProxyStats.queuePausedReason` and as `queuePausedReason` in the status
/// endpoint, where it is written with its [name].
enum QueuePauseReason {
  /// A request sent from the queue was answered with one of
  /// `ProxyConfig.authRequiredStatusCodes`.
  ///
  /// The session on the upstream has most likely expired while the device was
  /// offline. Sending resumes after `OfflineWebProxy.resumeQueue()`, or when a
  /// request matching `ProxyConfig.authResumePaths` succeeds through the
  /// proxy.
  authenticationRequired,
}
