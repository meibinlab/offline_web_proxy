/// プロキシサーバ全体の統計情報を表すクラス
class ProxyStats {
  /// 総リクエスト数（起動からの累計）
  final int totalRequests;
  
  /// キャッシュヒット数
  final int cacheHits;
  
  /// キャッシュミス数
  final int cacheMisses;
  
  /// キャッシュヒット率（0.0～1.0）
  final double cacheHitRate;
  
  /// 現在のキュー長
  final int queueLength;
  
  /// ドロップされたリクエスト数
  final int droppedRequestsCount;
  
  /// プロキシサーバ開始日時
  final DateTime startedAt;
  
  /// 稼働時間
  final Duration uptime;

  const ProxyStats({
    required this.totalRequests,
    required this.cacheHits,
    required this.cacheMisses,
    required this.cacheHitRate,
    required this.queueLength,
    required this.droppedRequestsCount,
    required this.startedAt,
    required this.uptime,
  });

  @override
  String toString() {
    return 'ProxyStats{requests: $totalRequests, hitRate: ${(cacheHitRate * 100).toStringAsFixed(1)}%, uptime: $uptime}';
  }
}