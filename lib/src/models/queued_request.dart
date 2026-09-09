/// オフライン時にキューイングされたリクエストの情報を表すクラス
class QueuedRequest {
  /// リクエストURL
  final String url;

  /// HTTPメソッド（POST, PUT, DELETE等）
  final String method;

  /// リクエストヘッダ（機密情報はマスク済み）
  final Map<String, String> headers;

  /// キューイング日時
  ///
  /// 隔離領域から再送した場合は、再送を受け付けた時点に更新されます。
  /// 最初に受け付けた時点は [acceptedAt] を参照してください。
  final DateTime queuedAt;

  /// proxy が最初にこのリクエストを受け付けた日時
  ///
  /// 隔離と再送を経ても変わりません。オフラインで行った操作の発生時刻として
  /// 上流へ伝える値です。
  final DateTime acceptedAt;

  /// 現在の再試行回数
  final int retryCount;

  /// 次回再試行予定日時
  final DateTime nextRetryAt;

  const QueuedRequest({
    required this.url,
    required this.method,
    required this.headers,
    required this.queuedAt,
    required this.acceptedAt,
    required this.retryCount,
    required this.nextRetryAt,
  });

  @override
  String toString() {
    return 'QueuedRequest{url: $url, method: $method, retries: $retryCount}';
  }
}
