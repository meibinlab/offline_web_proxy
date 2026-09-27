/// エラーによりキューからドロップされたリクエストの履歴を表すクラス
class DroppedRequest {
  /// ドロップされたリクエストのURL
  final String url;

  /// HTTPメソッド
  final String method;

  /// ドロップされた日時
  final DateTime droppedAt;

  /// ドロップ理由
  ///
  /// キューからの除外は `"4xx_error"` など、隔離の保持上限による追い出しは
  /// `"quarantine_limit"`（件数・合計バイト数）と `"quarantine_expired"`（期間）、
  /// 1 件で隔離の合計バイト数の上限を超えた場合は `"quarantine_too_large"` です。
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

  /// 暗号化する前の保存領域に残り、移行を待っているかどうか
  ///
  /// この proxy インスタンスで暗号化鍵を生成した場合、旧版の保存領域からの
  /// 移行を一定時間遅らせます。その間、旧版の保存領域にある項目は `true` に
  /// なります。確認済みへの変更と全削除は、旧版の保存領域にも適用されます。
  final bool pendingMigration;

  /// 上流へ送っていたべき等性キー
  ///
  /// 0.19.0 より前に記録した履歴と、`enableIdempotencyKey` が `false` の間に
  /// 受け付けたリクエストでは `null` です。
  final String? idempotencyKey;

  /// proxy が最初にこのリクエストを受け付けた日時
  ///
  /// 0.19.0 より前に記録した履歴では `null` です。
  final DateTime? acceptedAt;

  const DroppedRequest({
    required this.url,
    required this.method,
    required this.droppedAt,
    required this.dropReason,
    required this.statusCode,
    required this.errorMessage,
    this.acknowledged = false,
    this.pendingMigration = false,
    this.idempotencyKey,
    this.acceptedAt,
  });

  @override
  String toString() {
    return 'DroppedRequest{url: $url, reason: $dropReason, '
        'status: $statusCode, acknowledged: $acknowledged}';
  }
}
