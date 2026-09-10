import 'package:flutter/widgets.dart';

import '../../offline_web_proxy.dart';

/// 復旧結果を受け取るコールバック関数です。
typedef ProxyRecoveryCallback = void Function(ProxyRecoveryResult result);

/// 現在表示中の URL を返すコールバック関数です。
typedef ProxyCurrentUrlProvider = String? Function();

/// アプリのライフサイクルに連動して proxy の稼働確認と復旧を行うオブザーバです。
///
/// 端末のサスペンドやプロセス再開により proxy のソケットが応答しなくなる場合があるため、
/// アプリが `resumed` へ遷移した契機で稼働確認を行い、必要なときだけ再バインドします。
///
/// WebView の再読込は本クラスでは行いません。[onRecovered] が受け取る
/// `reloadUri` を使って、アプリ側が読み込みを実行します。
///
/// proxy が返すオフライン代替ページは、状態通知を読んで自分で再読込します
/// （`ProxyConfig.enableOfflinePageAutoReload`）。504 ページが再読込するのは、
/// 自動再読込の結果として表示された場合（`ProxyConfig.enableAutoReloadContinuation`）
/// と、`ProxyConfig.enableGatewayTimeoutAutoReload` を有効にした場合です。
/// 本クラスが担うのは、proxy のソケット自体が応答しなくなった場合の復旧です。
///
/// ## 使用例
///
/// ```dart
/// final guard = ProxyLifecycleGuard(
///   proxy: proxy,
///   currentUrlProvider: () => currentPageUrl,
///   onRecovered: (result) {
///     final reloadUri = result.reloadUri;
///     if (reloadUri != null) {
///       controller.loadRequest(reloadUri);
///     } else {
///       controller.reload();
///     }
///   },
/// );
/// WidgetsBinding.instance.addObserver(guard);
/// ```
class ProxyLifecycleGuard extends WidgetsBindingObserver {
  /// 監視対象のプロキシサーバです。
  final OfflineWebProxy proxy;

  /// 再バインドが発生した場合に呼ばれるコールバックです。
  final ProxyRecoveryCallback onRecovered;

  /// 復旧できなかった場合に呼ばれるコールバックです。
  final ProxyRecoveryCallback? onFailed;

  /// 現在表示中の URL を返すコールバックです。
  final ProxyCurrentUrlProvider? currentUrlProvider;

  /// 稼働確認のタイムアウトです。
  final Duration probeTimeout;

  /// `paused` へ遷移した日時です。停止推定時間の算出に使用します。
  DateTime? _pausedAt;

  /// 復旧処理の実行中を示すフラグです。多重実行を防ぎます。
  bool _recovering = false;

  /// ライフサイクル連動のオブザーバを生成します。
  ///
  /// [proxy] は監視対象のプロキシサーバです。
  /// [onRecovered] は再バインドが発生した場合に呼ばれるコールバックです。
  /// [onFailed] は復旧できなかった場合に呼ばれるコールバックです。
  /// [currentUrlProvider] は現在表示中の URL を返すコールバックです。
  /// [probeTimeout] は稼働確認のタイムアウトです。
  ProxyLifecycleGuard({
    required this.proxy,
    required this.onRecovered,
    this.onFailed,
    this.currentUrlProvider,
    this.probeTimeout = const Duration(seconds: 2),
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        _pausedAt = DateTime.now();
      case AppLifecycleState.resumed:
        // 復帰時のみ稼働確認を行う（バックグラウンド中はタイマーが動作しない）
        // ignore: discarded_futures
        _handleResume();
      default:
        break;
    }
  }

  /// 復帰時の稼働確認と復旧を実行します。
  ///
  /// Returns: 処理完了を表す Future。
  Future<void> _handleResume() async {
    if (_recovering) {
      return;
    }

    _recovering = true;
    try {
      final pausedAt = _pausedAt;
      _pausedAt = null;
      final downtime =
          pausedAt == null ? null : DateTime.now().difference(pausedAt);

      final result = await proxy.ensureRunning(
        probeTimeout: probeTimeout,
        downtime: downtime,
      );

      if (result.cause == ProxyRecoveryCause.recoveryFailed) {
        onFailed?.call(result);
        return;
      }

      if (!result.restarted) {
        return;
      }

      onRecovered(_withProvidedReloadUri(result));
    } finally {
      _recovering = false;
    }
  }

  /// 表示中 URL から算出した再読込先を復旧結果へ反映します。
  ///
  /// [result] は `ensureRunning()` の復旧結果です。
  ///
  /// Returns: 再読込先を補った復旧結果。
  ProxyRecoveryResult _withProvidedReloadUri(ProxyRecoveryResult result) {
    final currentUrl = currentUrlProvider?.call();
    if (currentUrl == null || currentUrl.isEmpty) {
      return result;
    }

    final reloadUri = proxy.resolveReloadUri(currentUrl);
    if (reloadUri == null) {
      return result;
    }

    return ProxyRecoveryResult(
      cause: result.cause,
      restarted: result.restarted,
      port: result.port,
      portChanged: result.portChanged,
      reloadUri: reloadUri,
      downtimeMs: result.downtimeMs,
      error: result.error,
    );
  }
}
