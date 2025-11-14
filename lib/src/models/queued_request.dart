/// オフライン時にキューイングされたリクエストの情報を表すクラス
class QueuedRequest {
  /// リクエストURL
  final String url;
  
  /// HTTPメソッド（POST, PUT, DELETE等）
  final String method;
  
  /// リクエストヘッダ（機密情報はマスク済み）
  final Map<String, String> headers;
  
  /// キューイング日時
  final DateTime queuedAt;
  
  /// 現在の再試行回数
  final int retryCount;
  
  /// 次回再試行予定日時
  final DateTime nextRetryAt;

  const QueuedRequest({
    required this.url,
    required this.method,
    required this.headers,
    required this.queuedAt,
    required this.retryCount,
    required this.nextRetryAt,
  });

  @override
  String toString() {
    return 'QueuedRequest{url: $url, method: $method, retries: $retryCount}';
  }
}