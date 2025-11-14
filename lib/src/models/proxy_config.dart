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
///   cacheMaxSize: 500 * 1024 * 1024, // 500MB cache
///   connectTimeout: Duration(seconds: 5),
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
  /// * `'image/*'`: 604800 (7 days)
  /// * `'default'`: 86400 (24 hours)
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
  final Map<String, int> cacheStale;

  /// Timeout for establishing TCP connections to upstream server.
  ///
  /// If connection cannot be established within this duration,
  /// the request will be treated as a network failure.
  ///
  /// **Default**: `Duration(seconds: 10)`
  final Duration connectTimeout;

  /// Total timeout for completing HTTP requests to upstream server.
  ///
  /// Covers the entire request lifecycle from connection to response.
  /// Should be longer than [connectTimeout].
  ///
  /// **Default**: `Duration(seconds: 60)`
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

  const ProxyConfig({
    required this.origin,
    this.host = '127.0.0.1',
    this.port = 0,
    this.cacheMaxSize = 200 * 1024 * 1024,
    this.cacheTtl = const {
      'text/html': 3600,
      'text/css': 86400,
      'application/javascript': 86400,
      'image/*': 604800,
      'default': 86400,
    },
    this.cacheStale = const {
      'text/html': 86400,
      'text/css': 604800,
      'image/*': 2592000,
      'default': 259200,
    },
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 60),
    this.retryBackoffSeconds = const [1, 2, 5, 10, 20, 30],
    this.enableAdminApi = false,
    this.logLevel = 'info',
    this.startupPaths = const [],
  });

  @override
  String toString() {
    return 'ProxyConfig{origin: $origin, host: $host, port: $port}';
  }
}
