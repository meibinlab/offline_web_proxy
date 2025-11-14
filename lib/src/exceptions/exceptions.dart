// プロキシ操作で発生する可能性のある例外クラス群

import '../models/warmup_result.dart';

/// プロキシサーバ起動失敗
class ProxyStartException implements Exception {
  final String message;
  final Exception? cause;
  
  const ProxyStartException(this.message, this.cause);
  
  @override
  String toString() => 'ProxyStartException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// プロキシサーバ停止失敗
class ProxyStopException implements Exception {
  final String message;
  final Exception? cause;
  
  const ProxyStopException(this.message, this.cause);
  
  @override
  String toString() => 'ProxyStopException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// ポートバインド失敗
class PortBindException implements Exception {
  final int port;
  final String message;
  
  const PortBindException(this.port, this.message);
  
  @override
  String toString() => 'PortBindException: Failed to bind port $port - $message';
}

/// キャッシュ操作失敗
class CacheOperationException implements Exception {
  /// 操作種別（"clear", "get", "put"等）
  final String operation;
  final String message;
  final Exception? cause;
  
  const CacheOperationException(this.operation, this.message, this.cause);
  
  @override
  String toString() => 'CacheOperationException[$operation]: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Cookie操作失敗
class CookieOperationException implements Exception {
  /// 操作種別（"get", "clear", "save"等）
  final String operation;
  final String message;
  final Exception? cause;
  
  const CookieOperationException(this.operation, this.message, this.cause);
  
  @override
  String toString() => 'CookieOperationException[$operation]: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// キュー操作失敗
class QueueOperationException implements Exception {
  /// 操作種別（"get", "clear", "add"等）
  final String operation;
  final String message;
  final Exception? cause;
  
  const QueueOperationException(this.operation, this.message, this.cause);
  
  @override
  String toString() => 'QueueOperationException[$operation]: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// 統計情報取得失敗
class StatsOperationException implements Exception {
  final String message;
  final Exception? cause;
  
  const StatsOperationException(this.message, this.cause);
  
  @override
  String toString() => 'StatsOperationException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// ネットワークエラー
class NetworkException implements Exception {
  final String message;
  final Exception? cause;
  
  const NetworkException(this.message, this.cause);
  
  @override
  String toString() => 'NetworkException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Warmup処理失敗
class WarmupException implements Exception {
  final String message;
  /// 部分的に成功した結果
  final List<WarmupEntry> partialResults;
  final Exception? cause;
  
  const WarmupException(this.message, this.partialResults, this.cause);
  
  @override
  String toString() => 'WarmupException: $message (${partialResults.length} partial results)${cause != null ? ' (caused by: $cause)' : ''}';
}