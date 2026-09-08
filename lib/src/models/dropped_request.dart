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

  /// アプリ側が内容を確認済みかどうか
  ///
  /// `acknowledgeDroppedRequests()` を呼ぶまで `false` のままです。
  /// 起動時に未確認の履歴が残っていることを検知する用途で使用します。
  final bool acknowledged;

  const DroppedRequest({
    required this.url,
    required this.method,
    required this.droppedAt,
    required this.dropReason,
    required this.statusCode,
    required this.errorMessage,
    this.acknowledged = false,
  });

  @override
  String toString() {
    return 'DroppedRequest{url: $url, reason: $dropReason, '
        'status: $statusCode, acknowledged: $acknowledged}';
  }
}
