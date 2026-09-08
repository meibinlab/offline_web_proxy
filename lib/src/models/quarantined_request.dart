/// 上流に拒否され、隔離領域へ退避した更新系リクエストを表すクラス
///
/// 隔離されたリクエストは本文を保持したまま残るため、原因を解消してから
/// 再送するか、内容を確認したうえで破棄するかを利用側で判断できます。
class QuarantinedRequest {
  /// 隔離領域内での識別子
  final String id;

  /// 隔離されたリクエストのURL
  final String url;

  /// HTTPメソッド
  final String method;

  /// 隔離された日時
  final DateTime quarantinedAt;

  /// 最初にキューへ保存された日時
  final DateTime queuedAt;

  /// 隔離理由（"4xx_error" 等）
  final String reason;

  /// 上流から返されたHTTPステータスコード
  final int statusCode;

  /// 詳細なエラーメッセージ
  final String errorMessage;

  const QuarantinedRequest({
    required this.id,
    required this.url,
    required this.method,
    required this.quarantinedAt,
    required this.queuedAt,
    required this.reason,
    required this.statusCode,
    required this.errorMessage,
  });

  @override
  String toString() {
    return 'QuarantinedRequest{id: $id, url: $url, method: $method, '
        'status: $statusCode}';
  }
}
