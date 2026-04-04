import 'proxy_navigation_resolution.dart';

/// WebView delegate 向けの推奨アクションです。
enum ProxyWebViewNavigationAction {
  /// 現在の navigation をそのまま許可します。
  allow,

  /// 現在の navigation をキャンセルします。
  cancel,

  /// proxy URL を明示的に読み込ませます。
  loadProxyUrl,

  /// 正規化済み URL を外部へ委譲します。
  launchExternal,
}

/// WebView delegate 向けの推奨処理結果です。
class ProxyWebViewNavigationRecommendation {
  /// 推奨アクションです。
  final ProxyWebViewNavigationAction action;

  /// 元になった URL 解決結果です。
  final ProxyNavigationResolution resolution;

  /// WebView に読み込ませる proxy URL です。
  final Uri? webViewUri;

  /// 外部起動に利用する正規化済み URL です。
  final Uri? externalUri;

  const ProxyWebViewNavigationRecommendation._({
    required this.action,
    required this.resolution,
    required this.webViewUri,
    required this.externalUri,
  });

  /// navigation をそのまま許可する推奨結果を生成します。
  ///
  /// [resolution] は元になった URL 解決結果です。
  ///
  /// Returns: allow を表す推奨結果。
  const ProxyWebViewNavigationRecommendation.allow({
    required ProxyNavigationResolution resolution,
  }) : this._(
          action: ProxyWebViewNavigationAction.allow,
          resolution: resolution,
          webViewUri: null,
          externalUri: null,
        );

  /// navigation をキャンセルする推奨結果を生成します。
  ///
  /// [resolution] は元になった URL 解決結果です。
  ///
  /// Returns: cancel を表す推奨結果。
  const ProxyWebViewNavigationRecommendation.cancel({
    required ProxyNavigationResolution resolution,
  }) : this._(
          action: ProxyWebViewNavigationAction.cancel,
          resolution: resolution,
          webViewUri: null,
          externalUri: null,
        );

  /// proxy URL の再読み込みを推奨する結果を生成します。
  ///
  /// [resolution] は元になった URL 解決結果です。
  /// [webViewUri] は WebView に読み込ませる proxy URL です。
  ///
  /// Returns: loadProxyUrl を表す推奨結果。
  const ProxyWebViewNavigationRecommendation.loadProxyUrl({
    required ProxyNavigationResolution resolution,
    required Uri webViewUri,
  }) : this._(
          action: ProxyWebViewNavigationAction.loadProxyUrl,
          resolution: resolution,
          webViewUri: webViewUri,
          externalUri: null,
        );

  /// 外部委譲を推奨する結果を生成します。
  ///
  /// [resolution] は元になった URL 解決結果です。
  /// [externalUri] は外部起動に利用する正規化済み URL です。
  ///
  /// Returns: launchExternal を表す推奨結果。
  const ProxyWebViewNavigationRecommendation.launchExternal({
    required ProxyNavigationResolution resolution,
    required Uri externalUri,
  }) : this._(
          action: ProxyWebViewNavigationAction.launchExternal,
          resolution: resolution,
          webViewUri: null,
          externalUri: externalUri,
        );

  /// delegate 側で既定動作を抑止すべきかどうかを返します。
  ///
  /// Returns: allow 以外なら `true`。
  bool get shouldPreventDefault {
    return action != ProxyWebViewNavigationAction.allow;
  }

  @override
  String toString() {
    return 'ProxyWebViewNavigationRecommendation{action: $action, webViewUri: $webViewUri, externalUri: $externalUri, resolution: $resolution}';
  }
}
