/// キャッシュシステム固有の統計情報を表すクラス
class CacheStats {
  /// 総キャッシュエントリ数
  final int totalEntries;
  
  /// Fresh状態のエントリ数
  final int freshEntries;
  
  /// Stale状態のエントリ数
  final int staleEntries;
  
  /// Expired状態のエントリ数
  final int expiredEntries;
  
  /// 総キャッシュサイズ（バイト）
  final int totalSize;
  
  /// キャッシュヒット率（0.0～1.0）
  final double hitRate;
  
  /// Staleキャッシュ使用率（オフライン対応の指標）
  final double staleUsageRate;

  const CacheStats({
    required this.totalEntries,
    required this.freshEntries,
    required this.staleEntries,
    required this.expiredEntries,
    required this.totalSize,
    required this.hitRate,
    required this.staleUsageRate,
  });

  @override
  String toString() {
    return 'CacheStats{entries: $totalEntries, hitRate: ${(hitRate * 100).toStringAsFixed(1)}%, size: ${totalSize}B}';
  }
}
