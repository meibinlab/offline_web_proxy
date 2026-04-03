/// WebView 遷移先の解決結果を表すクラスです。
class ProxyNavigationResolution {
  /// 呼び出し元が渡した元のターゲット URL です。
  final String inputUrl;

  /// 解決に利用した元のソース URL です。
  final Uri? sourceUri;

  /// 相対解決後を含む正規化済みターゲット URL です。
  final Uri? normalizedTargetUri;

  /// proxy URL から復元、または同一 origin として判定した upstream URL です。
  final Uri? upstreamUri;

  /// WebView にロードさせるための proxy URL です。
  final Uri? proxyUri;

  /// 遷移先の判定結果です。
  final ProxyNavigationDisposition disposition;

  /// 判定理由です。
  final ProxyNavigationReason reason;

  /// `sourceUrl` を使って相対 URL を解決した場合は `true` です。
  final bool usedSourceUrl;

  /// `localhost` と `127.0.0.1` の別名を吸収した場合は `true` です。
  final bool usedLoopbackAlias;

  /// proxy 内の静的リソースとして扱う場合は `true` です。
  final bool isStaticResource;

  const ProxyNavigationResolution({
    required this.inputUrl,
    required this.sourceUri,
    required this.normalizedTargetUri,
    required this.upstreamUri,
    required this.proxyUri,
    required this.disposition,
    required this.reason,
    required this.usedSourceUrl,
    required this.usedLoopbackAlias,
    required this.isStaticResource,
  });

  @override
  String toString() {
    return 'ProxyNavigationResolution{disposition: $disposition, reason: $reason, target: $normalizedTargetUri, upstream: $upstreamUri, proxy: $proxyUri}';
  }
}

/// WebView 遷移先の取り扱い種別です。
enum ProxyNavigationDisposition {
  /// proxy 経由で WebView 内に遷移させます。
  inWebView,

  /// proxy 内のローカル専用リソースとして扱います。
  localOnly,

  /// 外部アプリや OS へ委譲する候補です。
  external,

  /// 情報不足のため解決できませんでした。
  unresolved,

  /// URL 自体が不正です。
  invalid,
}

/// WebView 遷移先の判定理由です。
enum ProxyNavigationReason {
  /// proxy URL から upstream URL を復元しました。
  proxyUrl,

  /// 設定済み origin の URL をそのまま採用しました。
  configuredOriginUrl,

  /// proxy の静的リソースと判定しました。
  staticResource,

  /// 非 HTTP(S) スキームのため外部委譲候補です。
  nonHttpScheme,

  /// 設定済み origin 外の URL です。
  externalOrigin,

  /// proxy の loopback URL らしいが自インスタンスと断定できませんでした。
  unknownLoopbackUrl,

  /// 相対 URL の解決に必要な source URL が不足しています。
  relativeUrlWithoutSource,

  /// source URL が不正です。
  invalidSourceUrl,

  /// 設定済み origin が無いため upstream URL を構築できません。
  missingConfiguredOrigin,

  /// 設定済み origin 配下だが proxy の対象パス外です。
  outsideProxyScope,

  /// URL が不正です。
  invalidUrl,
}
