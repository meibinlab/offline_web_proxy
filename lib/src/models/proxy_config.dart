/// プロキシサーバの設定を表すクラス
class ProxyConfig {
  /// 上流サーバのURL（必須）
  final String origin;
  
  /// バインドするホスト
  final String host;
  
  /// バインドするポート（0=自動割当）
  final int port;
  
  /// キャッシュ最大容量（バイト）
  final int cacheMaxSize;
  
  /// Content-Type別TTL設定（秒）
  final Map<String, int> cacheTtl;
  
  /// Content-Type別Stale期間設定（秒）
  final Map<String, int> cacheStale;
  
  /// 接続タイムアウト
  final Duration connectTimeout;
  
  /// リクエストタイムアウト
  final Duration requestTimeout;
  
  /// 再試行バックオフ間隔
  final List<int> retryBackoffSeconds;
  
  /// 管理API有効化（開発時のみ）
  final bool enableAdminApi;
  
  /// ログレベル
  final String logLevel;
  
  /// 起動時キャッシュ更新パス
  final List<String> startupPaths;

  const ProxyConfig({
    required this.origin,
    this.host = '127.0.0.1',
    this.port = 0,
    this.cacheMaxSize = 200 * 1024 * 1024,
    this.cacheTtl = const {
      'text/html': 3600,
      'text/css': 86400,
      'application/javascript': 86400,
      'image/*': 604800,
      'default': 86400,
    },
    this.cacheStale = const {
      'text/html': 86400,
      'text/css': 604800,
      'image/*': 2592000,
      'default': 259200,
    },
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 60),
    this.retryBackoffSeconds = const [1, 2, 5, 10, 20, 30],
    this.enableAdminApi = false,
    this.logLevel = 'info',
    this.startupPaths = const [],
  });

  @override
  String toString() {
    return 'ProxyConfig{origin: $origin, host: $host, port: $port}';
  }
}
