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

  /// 隔離される前にキューへ保存された日時
  ///
  /// 隔離領域から再送すると、再送を受け付けた時点に更新されます。
  /// 最初に受け付けた時点は [acceptedAt] を参照してください。
  final DateTime queuedAt;

  /// proxy が最初にこのリクエストを受け付けた日時
  ///
  /// 隔離と再送を経ても変わりません。
  final DateTime acceptedAt;

  /// 隔離理由（"4xx_error" 等）
  final String reason;

  /// 上流から返されたHTTPステータスコード
  final int statusCode;

  /// 詳細なエラーメッセージ
  final String errorMessage;

  /// 暗号化する前の保存領域に残り、移行を待っているかどうか
  ///
  /// この proxy インスタンスで暗号化鍵を生成した場合、旧版の保存領域からの
  /// 移行を一定時間遅らせます。その間、旧版の保存領域にある項目は `true` に
  /// なり、再送も破棄もできません（`retryQuarantinedRequest()` と
  /// `discardQuarantinedRequest()` は `false` を返します）。
  final bool pendingMigration;

  const QuarantinedRequest({
    required this.id,
    required this.url,
    required this.method,
    required this.quarantinedAt,
    required this.queuedAt,
    required this.acceptedAt,
    required this.reason,
    required this.statusCode,
    required this.errorMessage,
    this.pendingMigration = false,
  });

  @override
  String toString() {
    return 'QuarantinedRequest{id: $id, url: $url, method: $method, '
        'status: $statusCode}';
  }
}
