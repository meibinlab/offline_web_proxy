/// エラーによりキューからドロップされたリクエストの履歴を表すクラス
class DroppedRequest {
  /// ドロップされたリクエストのURL
  final String url;
  
  /// HTTPメソッド
  final String method;
  
  /// ドロップされた日時
  final DateTime droppedAt;
  
  /// ドロップ理由（"4xx_error", "5xx_error", "network_timeout"等）
  final String dropReason;
  
  /// エラー時のHTTPステータスコード
  final int statusCode;
  
  /// 詳細なエラーメッセージ
  final String errorMessage;

  const DroppedRequest({
    required this.url,
    required this.method,
    required this.droppedAt,
    required this.dropReason,
    required this.statusCode,
    required this.errorMessage,
  });

  @override
  String toString() {
    return 'DroppedRequest{url: $url, reason: $dropReason, status: $statusCode}';
  }
}
