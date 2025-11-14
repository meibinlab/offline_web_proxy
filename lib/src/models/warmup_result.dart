/// キャッシュ事前更新（Warmup）処理の結果を表すクラス
class WarmupResult {
  /// 成功した更新数
  final int successCount;
  
  /// 失敗した更新数
  final int failureCount;
  
  /// 処理全体にかかった時間
  final Duration totalDuration;
  
  /// 各パスの詳細結果
  final List<WarmupEntry> entries;

  const WarmupResult({
    required this.successCount,
    required this.failureCount,
    required this.totalDuration,
    required this.entries,
  });

  @override
  String toString() {
    return 'WarmupResult{success: $successCount, failed: $failureCount, duration: $totalDuration}';
  }
}

/// 個別パスの更新結果
class WarmupEntry {
  /// 更新対象のパス
  final String path;
  
  /// 更新成功の可否
  final bool success;
  
  /// HTTPステータスコード（成功時のみ）
  final int? statusCode;
  
  /// エラーメッセージ（失敗時のみ）
  final String? errorMessage;
  
  /// この処理にかかった時間
  final Duration duration;

  const WarmupEntry({
    required this.path,
    required this.success,
    this.statusCode,
    this.errorMessage,
    required this.duration,
  });

  @override
  String toString() {
    return 'WarmupEntry{path: $path, success: $success, duration: $duration}';
  }
}