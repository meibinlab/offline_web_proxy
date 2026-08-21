import 'proxy_recovery_result.dart';

/// 死活監視と復旧の診断情報を表すクラスです。
///
/// 障害発生時の原因切り分けやログ出力に使用します。
class ProxyDiagnostics {
  /// 内部フラグ上の稼働状態です。実際の応答可否は保証しません。
  final bool isRunning;

  /// 現在バインドしているポート番号です。未起動時は `null` です。
  final int? port;

  /// 設定された優先ポートです。
  final int preferredPort;

  /// 永続化された直前のバインドポートです。記録が無い場合は `null` です。
  final int? persistedPort;

  /// サーバの起動日時です。未起動時は `null` です。
  final DateTime? startedAt;

  /// 最終稼働確認の日時です。未実施の場合は `null` です。
  final DateTime? lastProbeAt;

  /// 最終稼働確認の結果です。未実施の場合は `null` です。
  final bool? lastProbeSucceeded;

  /// 再バインドを実行した回数です。
  final int restartCount;

  /// 最終復旧処理の判定種別です。未実施の場合は `null` です。
  final ProxyRecoveryCause? lastRecoveryCause;

  /// 最終復旧処理が失敗した場合の内容です。
  final String? lastRecoveryError;

  /// 直近の停止推定時間（ミリ秒）です。不明な場合は `null` です。
  final int? lastDowntimeMs;

  /// 診断情報を生成します。
  ///
  /// [isRunning] は内部フラグ上の稼働状態です。
  /// [port] は現在のポート番号です。
  /// [preferredPort] は設定された優先ポートです。
  /// [persistedPort] は永続化された直前のバインドポートです。
  /// [startedAt] はサーバの起動日時です。
  /// [lastProbeAt] は最終稼働確認の日時です。
  /// [lastProbeSucceeded] は最終稼働確認の結果です。
  /// [restartCount] は再バインドを実行した回数です。
  /// [lastRecoveryCause] は最終復旧処理の判定種別です。
  /// [lastRecoveryError] は最終復旧処理の失敗内容です。
  /// [lastDowntimeMs] は直近の停止推定時間（ミリ秒）です。
  const ProxyDiagnostics({
    required this.isRunning,
    required this.port,
    required this.preferredPort,
    required this.persistedPort,
    required this.startedAt,
    required this.lastProbeAt,
    required this.lastProbeSucceeded,
    required this.restartCount,
    required this.lastRecoveryCause,
    required this.lastRecoveryError,
    required this.lastDowntimeMs,
  });

  @override
  String toString() {
    return 'ProxyDiagnostics{isRunning: $isRunning, port: $port, '
        'preferredPort: $preferredPort, persistedPort: $persistedPort, '
        'startedAt: $startedAt, lastProbeAt: $lastProbeAt, '
        'lastProbeSucceeded: $lastProbeSucceeded, '
        'restartCount: $restartCount, lastRecoveryCause: $lastRecoveryCause, '
        'lastRecoveryError: $lastRecoveryError, '
        'lastDowntimeMs: $lastDowntimeMs}';
  }
}
