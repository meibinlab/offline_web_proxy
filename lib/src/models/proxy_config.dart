import 'drop_policy.dart';
import 'proxy_response_config.dart';
import 'queue_exclude_rule.dart';

/// Configuration settings for the [OfflineWebProxy] server.
///
/// This class defines all configurable aspects of the proxy server including
/// network settings, cache behavior, timeouts, and operational parameters.
///
/// ## Example Usage
///
/// ```dart
/// // Basic configuration
/// final config = ProxyConfig(
///   origin: 'https://api.example.com',
/// );
///
/// // Advanced configuration
/// final advancedConfig = ProxyConfig(
///   origin: 'https://api.example.com',
///   port: 8080,                    // Fixed port instead of auto-assign
///   preferredPort: 8787,           // Prefer this port, then fallback automatically
///   cacheMaxSize: 500 * 1024 * 1024, // 500MB cache
///   connectTimeout: Duration(seconds: 3),
///   cacheTtl: {
///     'application/json': 1800,    // 30 min for API responses
///     'image/*': 604800 * 4,       // 4 weeks for images
///     'default': 3600,             // 1 hour default
///   },
///   logLevel: 'debug',             // Verbose logging
///   startupPaths: ['/config', '/health'], // Warmup these paths
/// );
/// ```
class ProxyConfig {
  /// The upstream server URL that requests will be proxied to.
  ///
  /// This is the base URL of your backend API or web server. All requests
  /// received by the proxy will be forwarded to this origin when online.
  ///
  /// **Required field** - must be a valid HTTP or HTTPS URL.
  ///
  /// Example: `'https://api.example.com'`
  final String origin;

  /// The host address to bind the proxy server to.
  ///
  /// For security reasons, defaults to `'127.0.0.1'` (localhost only).
  /// This prevents external devices from accessing your proxy server.
  ///
  /// **Default**: `'127.0.0.1'`
  final String host;

  /// The port number for the proxy server to listen on.
  ///
  /// * `0` (default): Automatically assign an available port
  /// * `> 0`: Use the specified port (may fail if already in use)
  ///
  /// **Default**: `0` (auto-assign)
  final int port;

  /// Preferred port to try before falling back to an auto-assigned port.
  ///
  /// This is useful for keeping the WebView origin stable across app restarts
  /// when the preferred port is available. If binding to this port fails,
  /// the proxy will automatically fall back to an ephemeral port.
  ///
  /// **Default**: `0` (disabled)
  final int preferredPort;

  /// Maximum size of the cache storage in bytes.
  ///
  /// When cache exceeds this limit, oldest entries are removed (LRU eviction).
  /// Set based on your app's storage constraints and user expectations.
  ///
  /// **Default**: `200 * 1024 * 1024` (200 MB)
  final int cacheMaxSize;

  /// Time-to-live (TTL) settings per content type in seconds.
  ///
  /// Controls how long different types of content remain "fresh" in cache.
  /// After TTL expires, content becomes "stale" but may still be served
  /// offline until the stale period ends.
  ///
  /// **Key Format**: MIME type pattern (`'image/*'`) or `'default'`
  /// **Value**: Seconds until content becomes stale
  ///
  /// **Default TTL Values**:
  /// * `'text/html'`: 3600 (1 hour)
  /// * `'text/css'`: 86400 (24 hours)
  /// * `'application/javascript'`: 86400 (24 hours)
  /// * `'text/javascript'`: 86400 (24 hours)
  /// * `'image/*'`: 604800 (7 days)
  /// * `'default'`: 86400 (24 hours)
  ///
  /// **Note**: Supplying this map replaces the defaults entirely; the two are
  /// not merged. Keep a `'default'` entry so that unlisted content types still
  /// resolve.
  final Map<String, int> cacheTtl;

  /// Stale period settings per content type in seconds.
  ///
  /// After TTL expires, content enters "stale" period where it can still
  /// be served offline or as fallback. Beyond stale period, content is
  /// considered expired and will be removed during cleanup.
  ///
  /// **Key Format**: MIME type pattern (`'image/*'`) or `'default'`
  /// **Value**: Additional seconds after TTL before content expires
  ///
  /// **Default Stale Periods**:
  /// * `'text/html'`: 86400 (1 day)
  /// * `'text/css'`: 604800 (7 days)
  /// * `'image/*'`: 2592000 (30 days)
  /// * `'default'`: 259200 (3 days)
  ///
  /// **Note**: There is no JavaScript entry, so scripts fall back to
  /// `'default'`. Supplying this map replaces the defaults entirely.
  final Map<String, int> cacheStale;

  /// Paths whose responses are cached even when they carry
  /// `Cache-Control: no-store`.
  ///
  /// Many existing web systems send `no-store` on every response, which leaves
  /// the proxy with nothing to serve offline. Listing the paths a screen needs
  /// makes those responses cacheable without weakening the rule everywhere:
  /// there is deliberately no switch that disables `no-store` handling as a
  /// whole.
  ///
  /// Only `GET` responses are stored, and a listed path is still skipped when
  /// keeping the response would leak or corrupt per-user state:
  ///
  /// * the response carries `Set-Cookie`, which would persist a session on the
  ///   device and replay it later
  /// * the response carries `Vary`, which the URL-only cache key cannot honour
  /// * the request carried `Authorization`, so the response belongs to one user
  ///
  /// A skipped response raises `ProxyEventType.cacheSkipped` with the reason,
  /// so a path that never becomes available offline can be diagnosed.
  ///
  /// **Security**: `no-store` asks the client not to write the response to
  /// storage at all. The response cache is not encrypted, so the body of a
  /// listed path is kept on the device in the clear. Weigh that against what
  /// the screen contains before listing it.
  ///
  /// **Freshness**: A response that says `no-store` usually says `max-age=0`
  /// as well. Honouring it would make the entry stale the moment it is stored,
  /// so the upstream freshness directives are ignored for a listed path and
  /// [cacheTtl] decides the TTL instead.
  ///
  /// Patterns use `*` for one path segment and `**` across segments; a pattern
  /// without either is matched exactly. Query strings are not part of the
  /// comparison.
  ///
  /// **Example**: `['/app/**', '/js/*.js']`
  /// **Default**: `[]` (no path is force-cached)
  final List<String> forceCachePaths;

  /// Number of consecutive unreachable upstream attempts that opens the
  /// upstream circuit breaker.
  ///
  /// Link-layer connectivity does not prove that the upstream is reachable.
  /// When a device is attached to a network whose upstream is down, every
  /// request would otherwise wait for [requestTimeout] before falling back.
  /// Once this many consecutive attempts fail to reach the upstream, the proxy
  /// treats the upstream as unavailable and serves requests from cache or the
  /// queue immediately, without waiting.
  ///
  /// Only unreachable errors count: connection failures, name resolution
  /// failures, TLS handshake failures and timeouts. A 4xx or 5xx response means
  /// the upstream answered, so it resets the counter instead.
  ///
  /// Set to `0` to disable the circuit breaker.
  ///
  /// **Default**: `3`
  final int upstreamFailureThreshold;

  /// Path requested to check whether the upstream became reachable again.
  ///
  /// Used only while the upstream circuit breaker is open. Any HTTP response,
  /// including 4xx and 5xx, counts as reachable because the goal is to detect
  /// reachability rather than health.
  ///
  /// **Default**: `'/'`
  final String upstreamProbePath;

  /// HTTP method used for the upstream reachability probe.
  ///
  /// `HEAD` keeps the probe cheap. Change it when the upstream does not accept
  /// `HEAD` on [upstreamProbePath].
  ///
  /// **Default**: `'HEAD'`
  final String upstreamProbeMethod;

  /// Timeout applied to the upstream reachability probe.
  ///
  /// Kept short so that a failing probe does not delay the next attempt.
  ///
  /// **Default**: `Duration(seconds: 3)`
  final Duration upstreamProbeTimeout;

  /// Backoff intervals between upstream reachability probes.
  ///
  /// Applied in order while the circuit stays open. After the last interval,
  /// probes keep using the final value.
  ///
  /// **Default**: `[1, 2, 5, 10, 30]` (seconds)
  final List<int> upstreamProbeBackoffSeconds;

  /// Timeout for establishing TCP connections to upstream server.
  ///
  /// If connection cannot be established within this duration,
  /// the request will be treated as a network failure.
  ///
  /// **Default**: `Duration(seconds: 5)`
  final Duration connectTimeout;

  /// Total time budget for one upstream request.
  ///
  /// Acts as a deadline covering the whole attempt: waiting for a free
  /// upstream connection slot, opening the connection, receiving the response
  /// headers and receiving the body. Once the budget is spent, the attempt
  /// fails and the proxy falls back to cache or to the queue.
  ///
  /// A person is usually waiting in front of a WebView, so the default is kept
  /// short. Should be longer than [connectTimeout].
  ///
  /// **Default**: `Duration(seconds: 20)`
  final Duration requestTimeout;

  /// Backoff intervals for retrying failed queued requests.
  ///
  /// When queued requests fail, they are retried with increasing delays
  /// according to this schedule. After the last interval, retries continue
  /// using the final value with jitter.
  ///
  /// **Default**: `[1, 2, 5, 10, 20, 30]` (seconds)
  final List<int> retryBackoffSeconds;

  /// Enable administrative API endpoints for debugging.
  ///
  /// **Security Warning**: Only enable during development. Provides access
  /// to cache inspection, statistics, and internal server state.
  ///
  /// **Default**: `false` (production safe)
  final bool enableAdminApi;

  /// Enable a lightweight WebStorage inheritance bridge for WebView pages.
  ///
  /// When enabled, the proxy can inject a small script into HTML responses and
  /// expose snapshot endpoints so the app can transfer localStorage and
  /// IndexedDB data across origin changes.
  ///
  /// **Default**: `false`
  final bool enableWebStorageInheritance;

  /// Logging verbosity level.
  ///
  /// Controls how much detail is logged during proxy operation:
  /// * `'error'`: Only errors and critical issues
  /// * `'warn'`: Errors and warnings
  /// * `'info'`: General operational information (default)
  /// * `'debug'`: Detailed debugging information
  ///
  /// **Default**: `'info'`
  final String logLevel;

  /// List of paths to warm up (pre-cache) during server startup.
  ///
  /// These paths will be requested from the upstream server when the proxy
  /// starts, ensuring they are available immediately for offline use.
  /// Useful for critical app resources like configuration or user profiles.
  ///
  /// **Example**: `['/config', '/user/profile', '/app/version']`
  /// **Default**: `[]` (no warmup)
  final List<String> startupPaths;

  /// Path used to check whether the proxy actually responds.
  ///
  /// `GET` and `HEAD` requests to this path are answered locally with
  /// `204 No Content` and are never forwarded upstream. Other methods are
  /// handled through the normal proxy path. Change it when the path collides
  /// with a route of the proxied web application.
  ///
  /// Must be a fixed path starting with `/`. Values containing route parameter
  /// syntax (`<`, `>`), `?`, `#`, or whitespace are rejected by `start()` with
  /// a `ProxyStartException`. An empty value falls back to the default.
  ///
  /// **Default**: `'/__offline_web_proxy/health'`
  final String healthCheckPath;

  /// Interval of the periodic health check performed while the app runs.
  ///
  /// [Duration.zero] disables the periodic check. Timers do not fire while the
  /// app is in the background, so recovery after a long idle period relies on
  /// the `resumed` check performed by `ProxyLifecycleGuard`.
  ///
  /// **Default**: [Duration.zero] (disabled)
  final Duration healthCheckInterval;

  /// Idle timeout applied to the internal HTTP server.
  ///
  /// Keep-alive connections that receive no request within this duration are
  /// closed by the server.
  ///
  /// **Default**: `Duration(seconds: 120)`
  final Duration serverIdleTimeout;

  /// Maximum number of rebinds allowed per minute during recovery.
  ///
  /// Exceeding this limit skips the rebind and reports a failed recovery,
  /// which prevents an endless restart and reload loop. Zero or less disables
  /// rebinding entirely, so recovery always reports `recoveryFailed`.
  ///
  /// **Default**: `5`
  final int maxRestartAttemptsPerMinute;

  /// Whether the proxy attaches an idempotency key to queued update requests.
  ///
  /// A queued request is resent without knowing whether the upstream already
  /// received the original attempt, so a request the upstream completed just
  /// before the response was lost would otherwise be applied twice. The proxy
  /// keeps one stable key per queued request and sends it on every attempt, so
  /// the upstream can recognize the repeat.
  ///
  /// A key supplied by the client is kept as-is; otherwise the proxy generates
  /// one. Deduplication itself has to happen on the upstream server: the proxy
  /// cannot tell a lost response from a request that never arrived.
  ///
  /// **Default**: `true`
  final bool enableIdempotencyKey;

  /// Name of the header carrying the idempotency key.
  ///
  /// Change it when the upstream expects a different header.
  ///
  /// **Default**: `'Idempotency-Key'`
  final String idempotencyHeaderName;

  /// How long a completed idempotency key is remembered.
  ///
  /// Used to skip resending a request the proxy already delivered. After this
  /// period the key is forgotten and a request carrying it is treated as new.
  ///
  /// **Default**: `Duration(hours: 24)`
  final Duration idempotencyRetention;

  /// Update requests that must not be stored in the offline queue.
  ///
  /// An update that only makes sense at the moment it is made — a register
  /// sign-in, a sign-out, a session refresh — cannot be replayed later, and
  /// answering [queuedResponse] for one makes the web app believe it
  /// succeeded. A matching request is answered with the rule's own response
  /// instead, carrying `X-Offline-Queued: 0` and `X-Offline-Excluded: 1` so
  /// the decision can be made on a header.
  ///
  /// Rules apply wherever the proxy would otherwise queue an update: while
  /// offline, when the upstream answered 5xx, and when the upstream could not
  /// be reached. A 5xx response is still returned as-is, because the upstream
  /// did answer; only the queueing is skipped.
  ///
  /// Each rule carries its own response, so a screen can receive the wording
  /// it already knows how to display.
  ///
  /// **Default**: `[]` (every update request is queued)
  final List<QueueExcludeRule> queueExcludePaths;

  /// Whether the proxy tells the upstream when it first accepted an update.
  ///
  /// A request stored while offline reaches the upstream only after the
  /// connection returns, so a server that stamps its own clock records the
  /// wrong business time: a sale rung up at midnight becomes a sale of the
  /// next morning, and every daily total built on it is wrong.
  ///
  /// The proxy sends the moment it first accepted the request, and sends the
  /// same value on every resend, so the upstream can use it whenever the
  /// payload itself carries no business timestamp.
  ///
  /// **Note**: The value comes from the device clock. A device whose clock is
  /// wrong while offline reports a wrong time.
  ///
  /// **Default**: `true`
  final bool enableAcceptedAtHeader;

  /// Name of the header carrying the acceptance time.
  ///
  /// The value is an ISO 8601 timestamp in UTC, such as
  /// `2026-09-09T08:03:41.474467Z`. Change the name when the upstream expects
  /// a different one.
  ///
  /// **Default**: `'X-Offline-Accepted-At'`
  final String acceptedAtHeaderName;

  /// What happens to a queued update request the upstream rejected with 4xx.
  ///
  /// Resending cannot change a 4xx result, so the request leaves the queue.
  /// [DropPolicy.quarantine] keeps it, body included, in a quarantine store so
  /// that it can be resent after the cause is fixed, or discarded on purpose.
  /// [DropPolicy.drop] discards it and keeps only a history entry.
  ///
  /// The default keeps the request, because silently discarding business data
  /// such as a sales record is rarely acceptable.
  ///
  /// **Default**: [DropPolicy.quarantine]
  final DropPolicy dropPolicy;

  /// Response returned when an update request is stored in the offline queue.
  ///
  /// A queued request has not reached the upstream yet, so the front end must
  /// be able to tell this response apart from a real one. The default is
  /// `202 Accepted` with a JSON body, and the proxy always adds
  /// `X-Offline-Queued: 1` plus `X-Offline-Queue-Id` so the decision can be
  /// made on a header instead of the body.
  ///
  /// **Default**: `202` / `application/json; charset=utf-8` / `{"queued":true}`
  final ProxyResponseConfig queuedResponse;

  /// Response returned when an offline read cannot be served from cache.
  ///
  /// Applies to requests that are not page navigations, such as `fetch` and
  /// `XMLHttpRequest` calls, images and stylesheets. Page navigations keep
  /// receiving the HTML fallback page instead, so that a person sees a
  /// readable screen.
  ///
  /// The default status is `504` so that `response.ok` is false in the front
  /// end. Returning `200` with an HTML body would make a JSON request look
  /// successful and then fail while parsing.
  ///
  /// **Default**: `504` / `application/json; charset=utf-8` / `{"offline":true}`
  final ProxyResponseConfig offlineMissResponse;

  /// HTML body returned instead of the built-in offline fallback page.
  ///
  /// Supply the wording that suits your app. `null` keeps the built-in page.
  ///
  /// **Default**: `null`
  final String? offlineFallbackHtml;

  /// HTML body returned instead of the built-in upstream timeout page.
  ///
  /// Supply the wording that suits your app. `null` keeps the built-in page.
  ///
  /// **Default**: `null`
  final String? gatewayTimeoutHtml;

  const ProxyConfig({
    required this.origin,
    this.host = '127.0.0.1',
    this.port = 0,
    this.preferredPort = 0,
    this.cacheMaxSize = 200 * 1024 * 1024,
    this.cacheTtl = const {
      'text/html': 3600,
      'text/css': 86400,
      'application/javascript': 86400,
      'text/javascript': 86400,
      'image/*': 604800,
      'default': 86400,
    },
    this.cacheStale = const {
      'text/html': 86400,
      'text/css': 604800,
      'image/*': 2592000,
      'default': 259200,
    },
    this.forceCachePaths = const [],
    this.upstreamFailureThreshold = 3,
    this.upstreamProbePath = '/',
    this.upstreamProbeMethod = 'HEAD',
    this.upstreamProbeTimeout = const Duration(seconds: 3),
    this.upstreamProbeBackoffSeconds = const [1, 2, 5, 10, 30],
    this.connectTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 20),
    this.retryBackoffSeconds = const [1, 2, 5, 10, 20, 30],
    this.enableAdminApi = false,
    this.enableWebStorageInheritance = false,
    this.logLevel = 'info',
    this.startupPaths = const [],
    this.healthCheckPath = '/__offline_web_proxy/health',
    this.healthCheckInterval = Duration.zero,
    this.serverIdleTimeout = const Duration(seconds: 120),
    this.maxRestartAttemptsPerMinute = 5,
    this.offlineFallbackHtml,
    this.gatewayTimeoutHtml,
    this.enableIdempotencyKey = true,
    this.idempotencyHeaderName = 'Idempotency-Key',
    this.idempotencyRetention = const Duration(hours: 24),
    this.queueExcludePaths = const [],
    this.enableAcceptedAtHeader = true,
    this.acceptedAtHeaderName = 'X-Offline-Accepted-At',
    this.dropPolicy = DropPolicy.quarantine,
    this.queuedResponse = const ProxyResponseConfig(
      statusCode: 202,
      contentType: 'application/json; charset=utf-8',
      body: '{"queued":true}',
    ),
    this.offlineMissResponse = const ProxyResponseConfig(
      statusCode: 504,
      contentType: 'application/json; charset=utf-8',
      body: '{"offline":true}',
    ),
  });

  @override
  String toString() {
    return 'ProxyConfig{origin: $origin, host: $host, port: $port}';
  }
}
