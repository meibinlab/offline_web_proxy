# offline_web_proxy

[![CI/CD Pipeline](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml)
[![Pub Version](https://img.shields.io/pub/v/offline_web_proxy.svg)](https://pub.dev/packages/offline_web_proxy)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Coverage](https://codecov.io/gh/meibinlab/offline_web_proxy/branch/main/graph/badge.svg)](https://codecov.io/gh/meibinlab/offline_web_proxy)

offline_web_proxy is a local HTTP proxy for Flutter WebView that keeps existing web applications usable inside a mobile app even when connectivity becomes unstable or temporarily unavailable.

It runs on 127.0.0.1, forwards requests to one configured upstream origin while online, serves cached responses while offline, queues mutating requests, and provides helper APIs for WebView navigation, cookie reuse, and runtime monitoring.

## Highlights

- Local proxy server for Flutter WebView
- RFC-aware cache handling with offline stale fallback
- Offline queue for POST, PUT, and DELETE requests
- AES-256 encrypted cookie persistence with restore support
- WebView navigation helper APIs for same-origin, external, and new-window flows
- Runtime stats and event stream for monitoring and debugging

## Requirements

- Flutter 3.22.0 or later
- Dart 3.4.0 or later
- One configured upstream origin per proxy instance

## Installation

Add the package to your app:

```yaml
dependencies:
  offline_web_proxy: ^0.6.1
  # Example app and CI currently use this WebView version range.
  webview_flutter: ^4.8.0
```

Then run:

```bash
flutter pub get
```

If you want the proxy to recognize bundled static files, declare them in your app's `pubspec.yaml` so they are included in `AssetManifest.json`. Files that are only placed on disk and not registered as Flutter assets are not classified as proxy-local static resources.

## Quick Start

The current WebView integration pattern is based on `WebViewController`, `WebViewWidget`, and the navigation helper APIs added in 0.5.0 and 0.6.0.

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:webview_flutter/webview_flutter.dart';

class ProxyPage extends StatefulWidget {
  const ProxyPage({super.key});

  @override
  State<ProxyPage> createState() => _ProxyPageState();
}

class _ProxyPageState extends State<ProxyPage> {
  final OfflineWebProxy _proxy = OfflineWebProxy();

  WebViewController? _controller;
  String? _currentUrl;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final port = await _proxy.start(
      config: const ProxyConfig(
        origin: 'https://api.example.com',
        startupPaths: ['/app/config', '/app/bootstrap'],
      ),
    );

    final homeUrl = Uri.parse('http://127.0.0.1:$port/app');
    final controller = WebViewController();

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            _currentUrl = url;
          },
          onNavigationRequest: (NavigationRequest request) {
            final recommendation = _proxy.recommendMainFrameNavigation(
              targetUrl: request.url,
              sourceUrl: _currentUrl,
            );

            switch (recommendation.action) {
              case ProxyWebViewNavigationAction.allow:
                return NavigationDecision.navigate;
              case ProxyWebViewNavigationAction.loadProxyUrl:
                unawaited(controller.loadRequest(recommendation.webViewUri!));
                return NavigationDecision.prevent;
              case ProxyWebViewNavigationAction.launchExternal:
                // Hand off recommendation.externalUri to url_launcher or native code.
                return NavigationDecision.prevent;
              case ProxyWebViewNavigationAction.cancel:
                return NavigationDecision.prevent;
            }
          },
        ),
      );

    await controller.loadRequest(homeUrl);

    if (!mounted) {
      return;
    }

    setState(() {
      _controller = controller;
      _currentUrl = homeUrl.toString();
    });
  }

  @override
  void dispose() {
    unawaited(_proxy.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('offline_web_proxy demo')),
      body: WebViewWidget(controller: controller),
    );
  }
}
```

## Configure the Proxy

Pass configuration through `ProxyConfig` when calling `start()`.

```dart
const config = ProxyConfig(
  origin: 'https://api.example.com',
  host: '127.0.0.1',
  port: 0,
  cacheMaxSize: 200 * 1024 * 1024,
  cacheTtl: {
    'text/html': 3600,
    'text/css': 86400,
    'application/javascript': 86400,
    'image/*': 604800,
    'default': 86400,
  },
  cacheStale: {
    'text/html': 86400,
    'text/css': 604800,
    'image/*': 2592000,
    'default': 259200,
  },
  connectTimeout: Duration(seconds: 10),
  requestTimeout: Duration(seconds: 60),
  retryBackoffSeconds: [1, 2, 5, 10, 20, 30],
  enableAdminApi: false,
  logLevel: 'info',
  startupPaths: ['/app/config'],
);
```

Notes:

- `origin` is required and must be an absolute HTTP or HTTPS URL.
- `port: 0` lets the OS assign a free local port.
- `startupPaths` is used by `warmupCache()` and the startup warmup flow.
- The supported configuration entry point is `ProxyConfig`. The package does not currently load an external YAML file automatically.

## WebView Navigation Helper APIs

Use the URL resolution APIs when your WebView needs to decide whether a target should stay inside the proxy, be rewritten to a proxy URL, or be delegated outside the app.

```dart
final resolution = proxy.resolveNavigationTarget(
  targetUrl: 'tel:+81012345678',
  sourceUrl: 'http://127.0.0.1:$port/app/orders/detail',
);

if (resolution.disposition == ProxyNavigationDisposition.external) {
  print('Open externally: ${resolution.normalizedTargetUri}');
}

final upstreamUri = proxy.tryResolveUpstreamUrl(
  'http://127.0.0.1:$port/app/orders/42',
);

final newWindowRecommendation = proxy.recommendNewWindowNavigation(
  targetUrl: 'https://www.google.com/maps/search/?api=1&query=Tokyo+Station',
  sourceUrl: 'http://127.0.0.1:$port/app',
);
```

Use cases:

- `tryResolveUpstreamUrl(String url)` for converting a proxy URL or same-origin URL into the upstream URL
- `resolveNavigationTarget(...)` for detailed metadata including reason, normalized target URI, and proxy/upstream URIs
- `recommendMainFrameNavigation(...)` for standard WebView main-frame delegate handling
- `recommendNewWindowNavigation(...)` for target=_blank or equivalent new-window flows

Relative URLs and scheme-relative URLs depend on `sourceUrl`. If `sourceUrl` is missing, some targets remain unresolved by design.
At startup, the proxy scans `AssetManifest.json` for files under `assets/static/` and exposes only those entries as proxy-local static resources. For example, `assets/static/app.css` is matched by the proxy URL `/app.css`, while an unlisted `/test.css` still resolves upstream.
If the manifest cannot be loaded in the current runtime, startup still continues with an empty static-resource index and those URLs resolve upstream instead of failing proxy startup.

## Cookie APIs

Cookies are persisted in encrypted storage and can be restored before the proxy starts.

```dart
await proxy.restoreCookies([
  CookieRestoreEntry.fromSetCookieHeader(
    setCookieHeader: 'SESSION=abc123; Path=/app; Secure; HttpOnly',
    requestUrl: 'https://api.example.com/login',
  ),
]);

final cookies = await proxy.getCookies();
final cookieHeader =
    await proxy.getCookieHeaderForUrl('https://api.example.com/app/dashboard');

await proxy.clearCookies();
await proxy.clearCookies(domain: 'example.com');
```

Notes:

- `getCookies()` returns masked values for inspection.
- `getCookieHeaderForUrl()` only accepts URLs that match the configured origin.
- If the secure-storage encryption key is lost, previously encrypted cookies can no longer be decrypted and the user must sign in again.

## Cache, Queue, and Monitoring APIs

```dart
await proxy.clearCache();
await proxy.clearExpiredCache();
await proxy.clearCacheForUrl('https://api.example.com/app/dashboard');

final cacheEntries = await proxy.getCacheList(limit: 20);
final cacheStats = await proxy.getCacheStats();
final warmupResult = await proxy.warmupCache(
  paths: ['/app/config', '/app/bootstrap'],
  onProgress: (completed, total) {
    print('warmup: $completed/$total');
  },
);

final queued = await proxy.getQueuedRequests();
final dropped = await proxy.getDroppedRequests(limit: 50);
await proxy.clearDroppedRequests();

final stats = await proxy.getStats();
print('requests=${stats.totalRequests} hitRate=${stats.cacheHitRate}');

proxy.events.listen((event) {
  if (event.type == ProxyEventType.requestReceived) {
    print(event.data['resolvedUpstreamUrl']);
    print(event.data['navigationDisposition']);
  }
});
```

The event stream is useful for observing cache hits, queue activity, and request-resolution metadata such as `resolvedUpstreamUrl`, `resolvedProxyUrl`, `navigationDisposition`, and `navigationReason`.

## Platform Setup

### iOS

Allow local networking in `ios/Runner/Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

### Android

Allow cleartext access to the local loopback proxy.

Create `android/app/src/main/res/xml/network_security_config.xml`:

```xml
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
```

Reference it from `android/app/src/main/AndroidManifest.xml`:

```xml
<application
    android:networkSecurityConfig="@xml/network_security_config">
```

## Current Limitations

- One `OfflineWebProxy` instance supports one configured upstream origin.
- `ProxyConfig` is the supported configuration path. External YAML configuration loading is not implemented.
- Static-resource serving from `assets/static/` is not implemented yet. Only files discovered from `AssetManifest.json` under `assets/static/` are classified as static resources, and the current server response is a 404 placeholder.
- If `AssetManifest.json` or its runtime equivalent cannot be loaded, the proxy continues with no indexed static resources and falls back to normal upstream resolution.

## Example and Reference

- See `example/` for a working WebView integration sample focused on navigation delegates.
- API reference is published under `doc/api/` in this repository.
- Release notes are tracked in `CHANGELOG.md`.

## Developer Setup

This repository includes a native Git pre-commit hook.

```bash
git config core.hooksPath .githooks
```

The hook runs:

- `dart fix --apply`
- `dart format .`
- `dart analyze --fatal-warnings`

If a Dart file is reformatted or auto-fixed, the hook stops the commit so you can review and stage the changes.

## License

MIT License
