/// Exception classes for [OfflineWebProxy] operations.
///
/// This file defines all exception types that can be thrown during proxy
/// operations, providing structured error information for better debugging
/// and error handling in client applications.
///
/// ## Exception Hierarchy
///
/// All exceptions follow a consistent pattern:
/// * Descriptive error messages
/// * Optional root cause exceptions for debugging
/// * Context-specific information (operation type, port numbers, etc.)
/// * Meaningful `toString()` implementations
///
/// ## Example Usage
///
/// ```dart
/// try {
///   await proxy.start();
/// } on ProxyStartException catch (e) {
///   print('Failed to start proxy: ${e.message}');
///   if (e.cause != null) {
///     print('Root cause: ${e.cause}');
///   }
/// } on PortBindException catch (e) {
///   print('Port ${e.port} is already in use');
/// }
/// ```
library;

import '../models/storage_integrity.dart';
import '../models/warmup_result.dart';

/// Exception thrown when proxy server fails to start.
///
/// This exception indicates that the proxy server could not be initialized
/// or started properly. Common causes include port binding failures,
/// configuration errors, or system resource constraints.
///
/// ## Common Scenarios
///
/// * Invalid configuration parameters
/// * Network interface binding failures
/// * Insufficient system permissions
/// * Resource allocation errors
///
/// ## Example
///
/// ```dart
/// try {
///   await proxy.start();
/// } on ProxyStartException catch (e) {
///   if (e.message.contains('port')) {
///     // Handle port-related startup failure
///     print('Port configuration issue: ${e.message}');
///   }
/// }
/// ```
class ProxyStartException implements Exception {
  /// Descriptive error message explaining the startup failure.
  final String message;

  /// Optional underlying exception that caused this failure.
  ///
  /// Useful for debugging the root cause of startup problems.
  final Exception? cause;

  /// Creates a new proxy startup exception.
  ///
  /// [message] should describe what went wrong during startup.
  /// [cause] can provide the underlying system exception if available.
  const ProxyStartException(this.message, this.cause);

  @override
  String toString() =>
      'ProxyStartException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Exception thrown when the encrypted storage cannot be used.
///
/// Before opening the encrypted boxes (cookies, queue, quarantine and dropped
/// request history), the proxy checks them against the encryption key in
/// secure storage, because Hive truncates a box opened with the wrong key.
/// [failure] tells why the storage cannot be used, and [boxResults] carries
/// the result for every encrypted box.
///
/// `start()` throws this exception as it is. Cookie APIs, which may run the
/// same check before `start()` or after `stop()`, report it as the `cause`
/// of a [CookieOperationException].
///
/// Nothing is deleted when this exception is thrown. Retry later when
/// [failure] is [StorageIntegrityFailure.temporarilyUnavailable] or
/// [StorageIntegrityFailure.keyWriteFailed]; the recovery API cannot fix
/// either of them. For the other kinds, confirm with the user and call
/// `OfflineWebProxy.recoverEncryptedStorage()`.
class StorageIntegrityException extends ProxyStartException {
  /// Why the encrypted storage cannot be used.
  final StorageIntegrityFailure failure;

  /// Check result of every encrypted box, including the cookie box.
  final Map<ProxyStorageBox, StorageBoxCheckResult> boxResults;

  /// Original error, such as the error thrown while reading the key.
  ///
  /// Unlike [cause], this also holds errors that are not [Exception]s.
  final Object? error;

  /// Creates a new encrypted storage exception.
  ///
  /// [message] describes the failure.
  /// [failure] tells why the encrypted storage cannot be used.
  /// [boxResults] carries the check result of every encrypted box.
  /// [error] is the original error, if any.
  StorageIntegrityException(
    String message, {
    required this.failure,
    this.boxResults = const {},
    this.error,
  }) : super(message, error is Exception ? error : null);

  @override
  String toString() => 'StorageIntegrityException[${failure.name}]: $message '
      '(boxes: ${boxResults.map((box, result) => MapEntry(box.name, result.name))})'
      '${error != null ? ' (caused by: $error)' : ''}';
}

/// Exception thrown when recovering the encrypted storage fails unexpectedly.
///
/// Thrown by `OfflineWebProxy.recoverEncryptedStorage()`, for example when a
/// box file or the encryption key cannot be deleted. Running the recovery
/// again is safe: a box being rebuilt keeps its original file until the new
/// one replaces it.
class StorageRecoveryException implements Exception {
  /// Error message describing the failure.
  final String message;

  /// Original error, if any.
  final Object? error;

  /// Creates a new storage recovery exception.
  ///
  /// [message] describes the failure.
  /// [error] is the original error, if any.
  const StorageRecoveryException(this.message, [this.error]);

  @override
  String toString() =>
      'StorageRecoveryException: $message${error != null ? ' (caused by: $error)' : ''}';
}

/// Exception thrown when proxy server fails to stop cleanly.
///
/// This exception occurs when the server shutdown process encounters errors,
/// potentially leaving resources in an inconsistent state.
///
/// ## Common Scenarios
///
/// * Active connections preventing clean shutdown
/// * File system errors during cleanup
/// * Resource disposal failures
///
/// **Note**: Even if stop fails, the server may still be partially shut down.
class ProxyStopException implements Exception {
  /// Error message describing the shutdown failure.
  final String message;

  /// Optional underlying exception that prevented clean shutdown.
  final Exception? cause;

  /// Creates a new proxy stop exception.
  const ProxyStopException(this.message, this.cause);

  @override
  String toString() =>
      'ProxyStopException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Exception thrown when unable to bind to the specified network port.
///
/// This typically occurs when the requested port is already in use by another
/// process or when the application lacks sufficient permissions.
///
/// ## Resolution Strategies
///
/// * Try a different port number
/// * Check for conflicting processes using the port
/// * Verify application has network binding permissions
/// * Use port `0` for automatic assignment
///
/// ## Example
///
/// ```dart
/// try {
///   final config = ProxyConfig(origin: 'https://api.example.com', port: 8080);
///   await proxy.start(config);
/// } on PortBindException catch (e) {
///   print('Port ${e.port} unavailable: ${e.message}');
///   // Retry with automatic port assignment
///   final autoConfig = ProxyConfig(origin: 'https://api.example.com', port: 0);
///   await proxy.start(autoConfig);
/// }
/// ```
class PortBindException implements Exception {
  /// The port number that failed to bind.
  final int port;

  /// Additional details about the binding failure.
  final String message;

  /// Creates a new port binding exception.
  ///
  /// [port] is the port number that could not be bound.
  /// [message] provides additional context about the failure.
  const PortBindException(this.port, this.message);

  @override
  String toString() =>
      'PortBindException: Failed to bind port $port - $message';
}

/// Exception thrown when cache operations fail.
///
/// Cache operations include storing, retrieving, clearing, and managing
/// cached content. This exception provides context about which operation
/// failed and why.
///
/// ## Common Operations
///
/// * `'get'`: Reading cached content
/// * `'put'`: Storing new content in cache
/// * `'clear'`: Removing cached content
/// * `'cleanup'`: Maintenance operations
/// * `'stats'`: Statistics gathering
///
/// ## Example
///
/// ```dart
/// try {
///   await proxy.clearCache();
/// } on CacheOperationException catch (e) {
///   if (e.operation == 'clear') {
///     print('Failed to clear cache: ${e.message}');
///     // Maybe cache is corrupted, try rebuilding
///   }
/// }
/// ```
class CacheOperationException implements Exception {
  /// The type of cache operation that failed.
  ///
  /// Common values: `'clear'`, `'get'`, `'put'`, `'cleanup'`, `'stats'`
  final String operation;

  /// Detailed error message explaining the failure.
  final String message;

  /// Optional underlying exception from the storage system.
  final Exception? cause;

  /// Creates a new cache operation exception.
  ///
  /// [operation] should identify which cache operation failed.
  /// [message] should explain what went wrong.
  /// [cause] can provide the underlying storage exception if available.
  const CacheOperationException(this.operation, this.message, this.cause);

  @override
  String toString() =>
      'CacheOperationException[$operation]: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Exception thrown when cookie operations fail.
///
/// Cookie management includes reading, storing, and clearing HTTP cookies
/// that are intercepted during proxy operations. This exception indicates
/// problems with the cookie storage or processing system.
class CookieOperationException implements Exception {
  /// The type of cookie operation that failed.
  ///
  /// Common values: `'get'`, `'clear'`, `'save'`, `'parse'`
  final String operation;

  /// Detailed error message explaining the cookie operation failure.
  final String message;

  /// Optional underlying exception from the cookie storage system.
  final Exception? cause;

  /// Creates a new cookie operation exception.
  const CookieOperationException(this.operation, this.message, this.cause);

  @override
  String toString() =>
      'CookieOperationException[$operation]: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Exception thrown when offline request queue operations fail.
///
/// The offline queue stores requests that couldn't be completed due to
/// network unavailability. This exception indicates problems with queue
/// management, storage, or processing.
///
/// ## Example
///
/// ```dart
/// try {
///   final queuedRequests = await proxy.getQueuedRequests();
/// } on QueueOperationException catch (e) {
///   if (e.operation == 'get') {
///     print('Could not retrieve queued requests: ${e.message}');
///   }
/// }
/// ```
class QueueOperationException implements Exception {
  /// The type of queue operation that failed.
  ///
  /// Common values: `'get'`, `'clear'`, `'add'`, `'process'`, `'retry'`
  final String operation;

  /// Detailed error message explaining the queue operation failure.
  final String message;

  /// Optional underlying exception from the queue storage system.
  final Exception? cause;

  /// Creates a new queue operation exception.
  const QueueOperationException(this.operation, this.message, this.cause);

  @override
  String toString() =>
      'QueueOperationException[$operation]: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Exception thrown when statistics collection or retrieval fails.
///
/// Statistics provide insight into proxy performance and health.
/// This exception indicates problems gathering or calculating metrics.
class StatsOperationException implements Exception {
  /// Error message describing the statistics operation failure.
  final String message;

  /// Optional underlying exception from the statistics system.
  final Exception? cause;

  /// Creates a new statistics operation exception.
  const StatsOperationException(this.message, this.cause);

  @override
  String toString() =>
      'StatsOperationException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Exception thrown when network operations fail.
///
/// Network exceptions cover connectivity issues, timeouts, DNS resolution
/// failures, and other problems communicating with upstream servers.
///
/// ## Common Network Issues
///
/// * Connection timeouts
/// * DNS resolution failures
/// * SSL/TLS certificate errors
/// * HTTP protocol errors
/// * Upstream server unavailability
///
/// ## Example
///
/// ```dart
/// try {
///   // Network request through proxy
/// } on NetworkException catch (e) {
///   print('Network error: ${e.message}');
///   // Maybe retry with exponential backoff
/// }
/// ```
class NetworkException implements Exception {
  /// Error message describing the network failure.
  final String message;

  /// Optional underlying exception from the network layer.
  final Exception? cause;

  /// Creates a new network exception.
  const NetworkException(this.message, this.cause);

  @override
  String toString() =>
      'NetworkException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Exception thrown when cache warmup operations fail.
///
/// Warmup pre-loads specified paths into cache during startup to ensure
/// immediate availability. This exception may include partial results
/// if some paths succeeded while others failed.
///
/// ## Example
///
/// ```dart
/// try {
///   await proxy.warmupCache(paths: ['/api/config', '/api/user']);
/// } on WarmupException catch (e) {
///   print('Warmup failed: ${e.message}');
///   print('Successfully warmed ${e.partialResults.length} paths');
///
///   // Continue with partial warmup results
///   for (final entry in e.partialResults) {
///     if (entry.success) {
///       print('✓ ${entry.path} (${entry.duration.inMilliseconds}ms)');
///     }
///   }
/// }
/// ```
class WarmupException implements Exception {
  /// Error message describing the warmup failure.
  final String message;

  /// Results from paths that were successfully warmed up before the failure.
  ///
  /// This allows applications to benefit from partial warmup success
  /// even when the overall operation fails.
  final List<WarmupEntry> partialResults;

  /// Optional underlying exception that caused the warmup failure.
  final Exception? cause;

  /// Creates a new warmup exception.
  ///
  /// [message] should describe what went wrong during warmup.
  /// [partialResults] contains any successful warmup entries before failure.
  /// [cause] can provide the underlying network or cache exception if available.
  const WarmupException(this.message, this.partialResults, this.cause);

  @override
  String toString() =>
      'WarmupException: $message (${partialResults.length} partial results)${cause != null ? ' (caused by: $cause)' : ''}';
}
