/// Where an update request stands, looked up by its idempotency key.
///
/// Returned inside [RequestStatus] by `OfflineWebProxy.getRequestStatuses` and
/// by the status endpoint when it is called with `idempotencyKey`.
enum RequestState {
  /// Waiting in the queue to be sent, including a request whose attempts keep
  /// failing with 5xx or an unreachable upstream, and a request held while the
  /// queue is paused by `ProxyConfig.authRequiredStatusCodes`.
  queued,

  /// Rejected by the upstream with 4xx and kept in quarantine.
  quarantined,

  /// Sent from the queue and answered with 2xx by the upstream, within
  /// `ProxyConfig.idempotencyRetention`.
  ///
  /// A request the upstream answered on its first forward with anything but
  /// 5xx is not recorded, because the page receives that answer directly; it is
  /// reported as [unknown]. A 5xx on the first forward puts the request in the
  /// queue, so it is reported as [queued], unless its path matches
  /// `ProxyConfig.queueExcludePaths`.
  delivered,

  /// Recorded in the dropped-request history.
  dropped,

  /// Found nowhere.
  ///
  /// Also reported once a record has left every store — after a quarantined
  /// request is discarded, a dropped record expires, or a delivered record
  /// passes its retention — and for every key while
  /// `ProxyConfig.enableIdempotencyKey` is `false`.
  unknown,
}

/// State of one update request, looked up by its idempotency key.
///
/// Carries no body, headers or query string, so that a page can only learn
/// about the requests it asked for.
class RequestStatus {
  /// Idempotency key that was looked up, with surrounding whitespace removed.
  final String idempotencyKey;

  /// Where the request stands.
  final RequestState state;

  /// When the proxy first accepted the request, in UTC.
  ///
  /// `null` when it is not known: always for [RequestState.delivered] and
  /// [RequestState.unknown], and for dropped records made before 0.19.0.
  final DateTime? acceptedAt;

  /// Status code the upstream returned.
  ///
  /// Set only for [RequestState.quarantined] and [RequestState.dropped].
  /// `0` when a dropped record has no status code.
  final int? statusCode;

  /// Creates a request status.
  ///
  /// [idempotencyKey] is the key that was looked up.
  /// [state] is where the request stands.
  /// [acceptedAt] is when the proxy first accepted it, when known.
  /// [statusCode] is the upstream status code for quarantined and dropped
  /// requests.
  const RequestStatus({
    required this.idempotencyKey,
    required this.state,
    this.acceptedAt,
    this.statusCode,
  });

  /// Converts the status into a JSON-compatible map.
  ///
  /// Used by the proxy to publish the status over HTTP. `acceptedAt` and
  /// `statusCode` are left out when they are `null`.
  ///
  /// Returns: a map with `idempotencyKey`, `state` and, when known,
  /// `acceptedAt` (UTC ISO 8601) and `statusCode`.
  Map<String, dynamic> toMap() {
    final acceptedAt = this.acceptedAt;
    final statusCode = this.statusCode;
    return {
      'idempotencyKey': idempotencyKey,
      'state': state.name,
      if (acceptedAt != null)
        'acceptedAt': acceptedAt.toUtc().toIso8601String(),
      if (statusCode != null) 'statusCode': statusCode,
    };
  }

  @override
  String toString() {
    return 'RequestStatus{idempotencyKey: $idempotencyKey, '
        'state: ${state.name}, statusCode: $statusCode}';
  }
}
