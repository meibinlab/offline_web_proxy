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

  /// A request sent from the queue was answered with `429 Too Many Requests`.
  ///
  /// Sending resumes on its own at `ProxyStats.queuePausedUntil`, when that
  /// request is due again (its `Retry-After`, up to one hour, or the usual
  /// backoff). The hold is kept in memory only and ends when the proxy stops.
  /// When the queue is also paused by [authenticationRequired], that reason
  /// is reported instead, because it needs the user to act.
  rateLimited,

  /// `ProxyConfig.queueOwnerResolver` threw for a successful sign-in, or the
  /// owner could not be determined or saved, so the proxy cannot tell who
  /// signed in.
  ///
  /// Sending the queue under the new session could deliver another user's
  /// updates, so the queue waits. The proxy then treats the signed-in user as
  /// a new, unknown owner: queued requests recorded for a known owner are
  /// moved out of the queue with the reason `owner_changed` once sending
  /// resumes. Sending resumes after `OfflineWebProxy.resumeQueue()`, or when
  /// a later sign-in is resolved to an owner. The pause is kept in memory
  /// only and ends when the proxy stops, while the unknown owner is saved: on
  /// the next start, queued requests of a known owner are moved out without
  /// waiting for the user.
  ownerUnresolved,
}
