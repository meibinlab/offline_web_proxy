import 'online_decision_source.dart';
import 'proxy_recovery_result.dart';
import 'storage_integrity.dart';
import 'upstream_circuit_state.dart';

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

  /// リンク層の接続状態に基づくオンライン判定です。
  /// 上流へ到達できるかどうかは [isUpstreamReachable] で確認します。
  final bool isOnline;

  /// [isOnline] の判定根拠です。
  final OnlineDecisionSource onlineDecisionSource;

  /// 上流へリクエストを転送できる状態かどうかです。
  /// リンク層が接続済みで、かつサーキットブレーカが遮断していない場合に `true` です。
  final bool isUpstreamReachable;

  /// 上流到達性のサーキットブレーカ状態です。
  final UpstreamCircuitState upstreamCircuitState;

  /// 上流へ到達できなかった連続回数です。上流が応答した時点で 0 に戻ります。
  /// 復帰確認の失敗は含まず、転送を試みたリクエストの失敗だけを数えます。
  final int consecutiveUpstreamFailures;

  /// 最後に上流へ到達できた日時です。未到達の場合は `null` です。
  final DateTime? lastUpstreamSuccessAt;

  /// このインスタンスが最後に Cookie の暗号化 Box を破棄した日時です。
  /// 破棄していない場合は `null` です。
  ///
  /// 暗号化鍵と Cookie Box が合わず、ほかの暗号化 Box に問題が無い場合、
  /// proxy は Cookie Box を破棄して処理を続けます（再ログインが必要に
  /// なります）。破棄は `start()` や起動前の Cookie API の中で起きるため、
  /// 後から購読したアプリにはイベントが届きません。この値で確認できます。
  final DateTime? lastCookieStorageDiscardedAt;

  /// このインスタンスが最後に Cookie の暗号化 Box を破棄した理由です。
  /// 破棄していない場合は `null` です。
  final StorageIntegrityFailure? lastCookieStorageDiscardReason;

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
  /// [isOnline] はリンク層の接続状態に基づくオンライン判定です。
  /// [onlineDecisionSource] は [isOnline] の判定根拠です。
  /// [isUpstreamReachable] は上流へ転送できる状態かどうかです。
  /// [upstreamCircuitState] は上流到達性のサーキットブレーカ状態です。
  /// [consecutiveUpstreamFailures] は上流へ到達できなかった連続回数です。
  /// [lastUpstreamSuccessAt] は最後に上流へ到達できた日時です。
  /// [lastCookieStorageDiscardedAt] は最後に Cookie Box を破棄した日時です。
  /// [lastCookieStorageDiscardReason] は最後に Cookie Box を破棄した理由です。
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
    required this.isOnline,
    required this.onlineDecisionSource,
    required this.isUpstreamReachable,
    required this.upstreamCircuitState,
    required this.consecutiveUpstreamFailures,
    required this.lastUpstreamSuccessAt,
    this.lastCookieStorageDiscardedAt,
    this.lastCookieStorageDiscardReason,
  });

  @override
  String toString() {
    return 'ProxyDiagnostics{isRunning: $isRunning, port: $port, '
        'preferredPort: $preferredPort, persistedPort: $persistedPort, '
        'startedAt: $startedAt, lastProbeAt: $lastProbeAt, '
        'lastProbeSucceeded: $lastProbeSucceeded, '
        'restartCount: $restartCount, lastRecoveryCause: $lastRecoveryCause, '
        'lastRecoveryError: $lastRecoveryError, '
        'lastDowntimeMs: $lastDowntimeMs, '
        'isOnline: $isOnline, '
        'onlineDecisionSource: $onlineDecisionSource, '
        'isUpstreamReachable: $isUpstreamReachable, '
        'upstreamCircuitState: $upstreamCircuitState, '
        'consecutiveUpstreamFailures: $consecutiveUpstreamFailures, '
        'lastUpstreamSuccessAt: $lastUpstreamSuccessAt, '
        'lastCookieStorageDiscardedAt: $lastCookieStorageDiscardedAt, '
        'lastCookieStorageDiscardReason: $lastCookieStorageDiscardReason}';
  }
}
