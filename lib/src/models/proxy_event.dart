/// プロキシサーバのイベント情報を表すクラス（リアルタイム監視用）
class ProxyEvent {
  /// イベントタイプ
  final ProxyEventType type;

  /// 関連するURL
  final String url;

  /// イベント発生日時
  final DateTime timestamp;

  /// 追加情報
  final Map<String, dynamic> data;

  const ProxyEvent({
    required this.type,
    required this.url,
    required this.timestamp,
    required this.data,
  });

  @override
  String toString() {
    return 'ProxyEvent{type: $type, url: $url, time: $timestamp}';
  }
}

/// プロキシイベントの種別
enum ProxyEventType {
  /// サーバ開始
  serverStarted,

  /// サーバ停止
  serverStopped,

  /// リクエスト受信
  requestReceived,

  /// 上流 redirect を解決して処理
  redirectHandled,

  /// キャッシュヒット
  cacheHit,

  /// キャッシュミス
  cacheMiss,

  /// Staleキャッシュ使用
  cacheStaleUsed,

  /// リクエストキューイング
  requestQueued,

  /// キュー送信完了
  queueDrained,

  /// リクエストドロップ
  requestDropped,

  /// リクエストを隔離領域へ退避
  requestQuarantined,

  /// ネットワーク復旧
  networkOnline,

  /// ネットワーク切断
  networkOffline,

  /// キャッシュクリア
  cacheCleared,

  /// エラー発生
  errorOccurred,

  /// 稼働確認に失敗し復旧できなかった
  serverUnavailable,

  /// 再バインドにより復旧した
  serverRecovered,

  /// 上流へ到達できないと判定し、転送を停止した
  upstreamCircuitOpened,

  /// 上流への到達を確認し、転送を再開した
  upstreamCircuitClosed,
}
