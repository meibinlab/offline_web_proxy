/// Statistics and performance metrics for the [OfflineWebProxy] server.
///
/// This class provides comprehensive operational insights including request
/// patterns, cache efficiency, queue status, and uptime metrics. All statistics
/// are collected in real-time and provide valuable data for monitoring
/// proxy performance and reliability.
///
/// ## Example Usage
///
/// ```dart
/// // Get current proxy statistics
/// final stats = await proxy.getStats();
///
/// // Monitor cache performance
/// print('Cache hit rate: ${(stats.cacheHitRate * 100).toStringAsFixed(1)}%');
/// print('Total requests: ${stats.totalRequests}');
/// print('Cache hits: ${stats.cacheHits}, misses: ${stats.cacheMisses}');
///
/// // Check queue health
/// if (stats.queueLength > 100) {
///   print('Warning: High queue length (${stats.queueLength})');
/// }
///
/// // Monitor dropped requests
/// if (stats.droppedRequestsCount > 0) {
///   print('${stats.droppedRequestsCount} requests were dropped');
/// }
///
/// // Display uptime
/// final days = stats.uptime.inDays;
/// final hours = stats.uptime.inHours % 24;
/// print('Proxy running for $days days, $hours hours');
/// ```
class ProxyStats {
  /// Total number of HTTP requests processed since proxy startup.
  ///
  /// This includes all requests regardless of outcome (cache hit, miss, or error).
  /// Provides the primary measure of proxy traffic and load patterns.
  /// 
  /// **Note**: Counter persists for the proxy's lifetime and resets on restart.
  final int totalRequests;
  
  /// Number of requests served directly from cache without upstream contact.
  ///
  /// Cache hits provide the fastest response times and indicate good offline
  /// capability. A high hit count suggests effective caching configuration
  /// and content reuse patterns.
  final int cacheHits;
  
  /// Number of requests that required fetching from the upstream server.
  ///
  /// Cache misses occur when:
  /// * Content is not yet cached
  /// * Cached content has expired beyond its stale period  
  /// * Cache validation determines content is outdated
  /// 
  /// High miss counts may indicate need for longer TTL values or cache warming.
  final int cacheMisses;
  
  /// Cache efficiency as a ratio between 0.0 and 1.0.
  ///
  /// Calculated as `cacheHits / (cacheHits + cacheMisses)`.
  /// 
  /// **Performance Guidelines**:
  /// * `> 0.8` (80%): Excellent cache performance
  /// * `0.5-0.8` (50-80%): Good cache utilization  
  /// * `< 0.5` (50%): May need cache tuning
  /// 
  /// **Note**: Returns `0.0` if no requests have been processed yet.
  final double cacheHitRate;
  
  /// Current number of requests waiting in the offline queue.
  ///
  /// Requests enter the queue when:
  /// * Upstream server is unreachable
  /// * Network connectivity is lost
  /// * Requests timeout during processing
  /// 
  /// Queued requests are automatically retried when connectivity is restored.
  /// Persistently high queue lengths may indicate connectivity issues.
  final int queueLength;
  
  /// Number of requests that were discarded without processing.
  ///
  /// Requests are dropped when:
  /// * Queue reaches maximum capacity
  /// * Request format is invalid
  /// * Critical system errors occur
  /// 
  /// **Warning**: Dropped requests indicate potential data loss or system stress.
  /// Monitor this metric closely in production environments.
  final int droppedRequestsCount;
  
  /// Timestamp when the proxy server was started.
  ///
  /// Used as the baseline for calculating uptime and provides context for
  /// interpreting time-based metrics. Remains constant throughout the
  /// proxy's lifecycle.
  final DateTime startedAt;
  
  /// Duration the proxy server has been running continuously.
  ///
  /// Calculated as the difference between current time and [startedAt].
  /// Provides insight into proxy stability and can help correlate
  /// performance patterns with operational duration.
  final Duration uptime;

  const ProxyStats({
    required this.totalRequests,
    required this.cacheHits,
    required this.cacheMisses,
    required this.cacheHitRate,
    required this.queueLength,
    required this.droppedRequestsCount,
    required this.startedAt,
    required this.uptime,
  });

  @override
  String toString() {
    return 'ProxyStats{requests: $totalRequests, hitRate: ${(cacheHitRate * 100).toStringAsFixed(1)}%, uptime: $uptime}';
  }
}