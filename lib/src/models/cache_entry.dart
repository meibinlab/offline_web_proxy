/// キャッシュエントリの情報を表すクラス
class CacheEntry {
  /// キャッシュされたリソースの元URL
  final String url;

  /// HTTPステータスコード（200, 404等）
  final int statusCode;

  /// Content-Typeヘッダの値
  final String contentType;

  /// キャッシュ作成日時
  final DateTime createdAt;

  /// キャッシュ有効期限
  final DateTime expiresAt;

  /// キャッシュ状態
  final CacheStatus status;

  /// キャッシュファイルのサイズ（バイト）
  final int sizeBytes;

  const CacheEntry({
    required this.url,
    required this.statusCode,
    required this.contentType,
    required this.createdAt,
    required this.expiresAt,
    required this.status,
    required this.sizeBytes,
  });

  @override
  String toString() {
    return 'CacheEntry{url: $url, status: $status, size: ${sizeBytes}B}';
  }
}

/// キャッシュの状態
enum CacheStatus {
  /// TTL期限内で使用可能
  fresh,

  /// TTL期限切れだがStale期間内
  stale,

  /// Stale期間も超過、削除対象
  expired,
}
