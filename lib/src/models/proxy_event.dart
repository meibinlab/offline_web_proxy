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

  /// ネットワーク復旧
  networkOnline,

  /// ネットワーク切断
  networkOffline,

  /// キャッシュクリア
  cacheCleared,

  /// エラー発生
  errorOccurred,
}
