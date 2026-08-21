/// 稼働確認と復旧処理の判定種別です。
enum ProxyRecoveryCause {
  /// 応答があり再バインドは不要でした。
  healthy,

  /// `start()` 前のため復旧対象外です。
  notStarted,

  /// 応答が無く再バインドを実行しました。
  socketDead,

  /// ポート不一致のため URL の読み替えが必要でした。
  stalePort,

  /// proxy と無関係な失敗のため何も行いませんでした。
  unrelated,

  /// 再バインドに失敗、または試行上限を超過しました。
  recoveryFailed,
}

/// 稼働確認と復旧処理の結果を表すクラスです。
///
/// `ensureRunning()` および `recoverFromWebResourceError()` の戻り値として使用します。
/// 利用者向けの表示文言は含みません。表示内容はアプリ側で決定します。
class ProxyRecoveryResult {
  /// 判定結果の種別です。
  final ProxyRecoveryCause cause;

  /// 再バインドを実行した場合は `true` です。
  final bool restarted;

  /// 復旧後のポート番号です。未起動時は `null` です。
  final int? port;

  /// 再バインドによってポートが変化した場合は `true` です。
  final bool portChanged;

  /// アプリが再読込すべき URI です。読み替え対象が無い場合は `null` です。
  final Uri? reloadUri;

  /// 直近の停止推定時間（ミリ秒）です。不明な場合は `null` です。
  final int? downtimeMs;

  /// 復旧に失敗した場合の原因です。成功時は `null` です。
  final Object? error;

  /// 復旧結果を生成します。
  ///
  /// [cause] は判定結果の種別です。
  /// [restarted] は再バインドを実行したかどうかです。
  /// [port] は復旧後のポート番号です。
  /// [portChanged] はポートが変化したかどうかです。
  /// [reloadUri] はアプリが再読込すべき URI です。
  /// [downtimeMs] は直近の停止推定時間（ミリ秒）です。
  /// [error] は復旧に失敗した原因です。
  const ProxyRecoveryResult({
    required this.cause,
    this.restarted = false,
    this.port,
    this.portChanged = false,
    this.reloadUri,
    this.downtimeMs,
    this.error,
  });

  @override
  String toString() {
    return 'ProxyRecoveryResult{cause: $cause, restarted: $restarted, '
        'port: $port, portChanged: $portChanged, reloadUri: $reloadUri, '
        'downtimeMs: $downtimeMs, error: $error}';
  }
}
