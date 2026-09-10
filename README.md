# offline_web_proxy

[![CI/CD Pipeline](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml)
[![Pub Version](https://img.shields.io/pub/v/offline_web_proxy.svg)](https://pub.dev/packages/offline_web_proxy)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Coverage](https://codecov.io/gh/meibinlab/offline_web_proxy/branch/main/graph/badge.svg)](https://codecov.io/gh/meibinlab/offline_web_proxy)

offline_web_proxy is a local HTTP proxy for Flutter WebView that keeps existing web applications usable inside a mobile app even when connectivity becomes unstable or temporarily unavailable.

It runs on 127.0.0.1, forwards requests to one configured upstream origin while online, and limits proxy-cache usage to substitute responses when offline or when the upstream is unreachable (connection failure or request timeout). Mutating requests are queued, and helper APIs are provided for WebView navigation, cookie reuse, and runtime monitoring.

## Highlights

- Local proxy server for Flutter WebView
- Serving of static resources bundled under `assets/static/`, so CDN-hosted files can be shipped inside the app
- Fetching and caching of another origin's resources, such as a CDN, through the proxy (`mirroredOrigins`)
- Fallback cache limited to offline and unreachable-upstream recovery
- Offline queue for POST, PUT, and DELETE requests
- AES-256 encrypted cookie persistence with restore support
- WebView navigation helper APIs for same-origin, external, and new-window flows
- Connection recovery that verifies responsiveness on resume and rebinds automatically
- Runtime stats and event stream for monitoring and debugging

## Requirements

- Flutter 3.22.0 or later
- Dart 3.4.0 or later
- One configured upstream origin per proxy instance

## Installation

Add the package to your app:

```yaml
dependencies:
  offline_web_proxy: ^0.12.0
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
    'text/javascript': 86400,
    'image/*': 604800,
    'default': 86400,
  },
  cacheStale: {
    'text/html': 86400,
    'text/css': 604800,
    'image/*': 2592000,
    'default': 259200,
  },
  forceCachePaths: ['/app/**'],
  mirroredOrigins: ['https://cdn.example.com'],
  connectTimeout: Duration(seconds: 5),
  requestTimeout: Duration(seconds: 20),
  upstreamFailureThreshold: 3,
  upstreamProbePath: '/',
  upstreamProbeMethod: 'HEAD',
  upstreamProbeTimeout: Duration(seconds: 3),
  upstreamProbeBackoffSeconds: [1, 2, 5, 10, 30],
  queuedResponse: ProxyResponseConfig(
    statusCode: 202,
    contentType: 'application/json; charset=utf-8',
    body: '{"queued":true}',
  ),
  dropPolicy: DropPolicy.quarantine,
  enableIdempotencyKey: true,
  idempotencyHeaderName: 'Idempotency-Key',
  idempotencyRetention: Duration(hours: 24),
  queueExcludePaths: [
    QueueExcludeRule(
      path: '/api/registers/auth.json',
      response: ProxyResponseConfig(
        statusCode: 503,
        contentType: 'application/json; charset=utf-8',
        body: '{"message":"オフラインのためレジ認証できません"}',
      ),
    ),
  ],
  enableAcceptedAtHeader: true,
  acceptedAtHeaderName: 'X-Offline-Accepted-At',
  offlineMissResponse: ProxyResponseConfig(
    statusCode: 504,
    contentType: 'application/json; charset=utf-8',
    body: '{"offline":true}',
  ),
  retryBackoffSeconds: [1, 2, 5, 10, 20, 30],
  enableAdminApi: false,
  logLevel: 'info',
  startupPaths: ['/app/config'],
  preferredPort: 8787,
  healthCheckPath: '/__offline_web_proxy/health',
  statusPath: '/__offline_web_proxy/status',
  healthCheckInterval: Duration.zero,
  serverIdleTimeout: Duration(seconds: 120),
  maxRestartAttemptsPerMinute: 5,
);
```

Notes:

- `origin` is required and must be an absolute HTTP or HTTPS URL.
- Settings that name paths (such as `forceCachePaths`) share one glob notation: `*` matches within a single path segment, `**` matches across segments, and a pattern without either is matched exactly. Query strings are not part of the comparison.
- `port: 0` lets the OS assign a free local port.
- `preferredPort` tries that port first and automatically falls back to an ephemeral port if it is unavailable. The last successfully bound port is also reused on the next startup, which helps keep the WebView origin stable.
- `startupPaths` is used by `warmupCache()` for paths whose fallback responses should be prepared in advance for offline or unreachable-upstream scenarios.
  - Warmup sends the cookie jar exactly as the forwarding path does, so calling it after sign-in also warms up the APIs that require authentication.
  - `warmupCache(followReferences: true)` also fetches the resources referenced by the warmed HTML (`<script src>`, `<link href>`, `<img src>`), both same-origin ones and those on an origin listed in `mirroredOrigins`. Only one level is followed, and a URL assembled by JavaScript at runtime is out of reach. A `<link>` counts only when its `rel` names a resource, such as `stylesheet`.
- `healthCheckPath` is reserved for responsiveness checks. Requests to it are never forwarded upstream and are excluded from statistics. Change it when it collides with a route of your web application.
- `statusPath` returns the proxy state as JSON. It gets the same treatment as `healthCheckPath` — never forwarded, never counted — and an empty string disables it.
- `enableAdminApi` set to `true` exposes listing, resending and discarding of quarantined requests over HTTP. Disabled by default.
- Setting `healthCheckInterval` above zero enables a periodic check. It is disabled by default because the resume-triggered check performed by `ProxyLifecycleGuard` is the primary path.
- `offlineFallbackHtml` and `gatewayTimeoutHtml` replace the built-in offline and timeout response bodies with wording supplied by your app.
- `upstreamFailureThreshold` is how many consecutive unreachable attempts stop forwarding. It prevents every request from waiting for the timeout when the link layer is up but the upstream is down. Set it to `0` to disable the behavior.
- `upstreamProbePath`, `upstreamProbeMethod`, `upstreamProbeTimeout` and `upstreamProbeBackoffSeconds` control the reachability probe used while forwarding is stopped. Any response counts as reachable, regardless of status code.
- `queuedResponse` and `offlineMissResponse` define the responses the proxy generates itself. Both default to JSON so that `response.json()` succeeds in the web app.
- `dropPolicy` decides what happens to an update request the upstream rejected with 4xx. The default `quarantine` keeps it, body included, so `getQuarantinedRequests()` can surface it for a resend-or-discard decision. `drop` discards it and keeps only a history entry, as before.
- `enableIdempotencyKey` attaches an idempotency key to update requests. The first forward and every resend carry the same key, so a request whose response was lost is not applied twice. **Deduplication itself must be implemented on the upstream server.**
- `forceCachePaths` lists the paths stored even when the response says `Cache-Control: no-store`. On a server that sends `no-store` everywhere, the default policy leaves nothing to serve offline. It is empty by default, and there is deliberately no switch that relaxes `no-store` handling proxy-wide.
  - Even on a match, a response carrying `Set-Cookie`, a response carrying `Vary` (unless it names `Accept-Encoding` alone), or a request carrying `Authorization`, is not stored. A skipped response raises `ProxyEventType.cacheSkipped` with the reason, so a path that never becomes available offline can be diagnosed.
  - A `Vary` naming `Accept-Encoding` alone is stored because the proxy pins `Accept-Encoding: identity` on every upstream request, so the response cannot vary. Tomcat, nginx and Apache all add that `Vary` by default once compression is on, so skipping on it would remove the screen's HTML, JS and CSS in one go. A `Vary` naming `*` or any other header is still skipped.
  - For a matching path the upstream `max-age` and `Expires` are ignored and `cacheTtl` decides the expiry, because `no-store` is usually paired with `max-age=0`, which would make the entry stale the moment it is stored.
  - **The response cache is not encrypted.** The body of a listed path stays on the device in the clear, so weigh what the screen contains before listing it.
- `mirroredOrigins` lists other origins fetched through the proxy. On a screen that loads its UI library from a CDN, the absolute URL in the HTML never passes through 127.0.0.1, so caching, fallback and warmup all miss it. A listed origin is relayed by the proxy and joins the ordinary cache and offline fallback. Empty by default.
  - In a `text/html` response the proxy serves, a matching absolute URL in `<script src>`, `<link href>` or `<img src>` is rewritten to `/__offline_web_proxy/ext/<scheme>/<host>[:port]/<original path>`. A `<link>` counts only when its `rel` names a resource, such as `stylesheet`.
  - The rewrite reuses the warmup reference scan, so **a rewritten resource is always collected by `warmupCache(followReferences: true)`**.
  - Rewriting happens on the way out rather than on the way in, so HTML served from cache while offline goes through the same transformation. Removing an origin from the configuration restores the original URLs.
  - Only `GET` and `HEAD` are relayed. Any other method answers `405` and is never queued. A path naming an origin that is not listed answers `404` and is never passed through to the configured origin.
  - Matching is exact on scheme, host and port. A value carrying a path or query raises `ProxyStartException` at startup.
  - **`Authorization`, `Origin`, `Referer` and the client's `Cookie` are never sent to a relayed origin.** Only jar entries matching the relayed domain are sent.
  - A URL that JavaScript assembles at runtime is out of reach. A rewritten URL becomes same-origin with the proxy, so a page that returns a `Content-Security-Policy` has to allow `'self'`. HTML served from `assets/static/` is not rewritten.
- `queueExcludePaths` keeps update requests out of the offline queue when sending them later would be meaningless — a register sign-in or a sign-out, where the immediate `202 Accepted` also reads as success. Each rule carries its own response, so every screen can show the wording it already knows. Empty by default.
  - The rules apply while offline, when the upstream is unreachable, and when the upstream answered 5xx. A 5xx response is still returned as-is, because the upstream did answer; only the queueing is skipped.
  - The answer carries `X-Offline-Queued: 0` and `X-Offline-Excluded: 1`.
- `enableAcceptedAtHeader` and `acceptedAtHeaderName` tell the upstream when the proxy first accepted a request. The same UTC ISO 8601 value is sent on the first forward and on every resend, so the upstream needs one rule — use this header when the payload carries no business timestamp — to stop offline sales from being recorded at reconnection time. Enabled by default.
  - The value survives a quarantine retry. `queuedAt` cannot be reused because a retry updates it.
  - **The value comes from the device clock.** A device whose clock is wrong while offline reports a wrong time.
- `cacheTtl` and `cacheStale` **replace** the default maps rather than merging with them. Always keep a `default` entry so that unlisted content types still resolve.
- `text/html` defaults to a 1 hour TTL and a 1 day stale period, so a page drops out of the fallback set roughly 25 hours after it was last fetched online. **Long offline operation requires tuning both `cacheTtl` and `cacheStale`.** `cacheStale` has no JavaScript entry, so scripts fall back to `default` (3 days).

### Handling offline responses in the web app

An update stored while offline has not reached the upstream, so the web app must be able to tell it apart from a success. The proxy answers with `202 Accepted` and `{"queued":true}` by default, plus headers that make the decision explicit.

```js
const res = await fetch('/api/sales_histories.json', {
  method: 'POST',
  body: JSON.stringify(sale),
});

if (res.headers.get('X-Offline-Queued') === '1') {
  // Not sent upstream yet; the proxy resends it once connectivity returns
  showPendingBadge(res.headers.get('X-Offline-Queue-Id'));
  return;
}

const saved = await res.json();
```

An offline read with no cached entry answers with `504` and `{"offline":true}` by default, so `response.ok` is false and normal error handling applies. Only page navigations (`Sec-Fetch-Mode: navigate`) receive the readable HTML fallback page.

The same body is returned when the link layer is up but the upstream cannot be reached. That response carries `X-Offline-Source: none`, so it can be told apart from a `504` the upstream itself returned.
- The supported configuration entry point is `ProxyConfig`. The package does not currently load an external YAML file automatically.

### Waiting times for WebView front ends

The defaults (`connectTimeout` 5 seconds, `requestTimeout` 20 seconds) are tuned for sitting in front of a WebView. A person is waiting for the screen, so a stalled upstream must not keep them waiting; a browser engine only opens a handful of connections per origin, so a few stalled requests can freeze the whole page.

`requestTimeout` is the deadline for one whole request. Waiting for a free connection slot, establishing the connection, receiving the headers and receiving the body share that single budget, so per-stage waits never stack up.

Link-layer connectivity is not proof that the upstream is reachable. When the device is attached to a network whose upstream is down, the first few requests still wait for `requestTimeout` until the upstream circuit breaker opens; after that they fall back to cache or the queue without waiting. The worst-case wait is `requestTimeout` × `upstreamFailureThreshold`, so tune the two values together.

Consider shortening `serverIdleTimeout` (120 seconds by default) to 30-60 seconds as well, so idle WebView connections do not linger.

For background-synchronization workloads that can afford to wait, extend them:

```dart
const config = ProxyConfig(
  origin: 'https://api.example.com',
  connectTimeout: Duration(seconds: 10),
  requestTimeout: Duration(seconds: 60),
);
```

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

A URL that matches the index is answered with the bundled asset itself, so a file previously loaded from a CDN can ship inside the app and be served from a same-origin URL such as `/js/haori.iife.js`.

```
assets/static/js/haori.iife.js  →  http://127.0.0.1:<port>/js/haori.iife.js
```

- Only `GET` and `HEAD` are served this way. An update request on the same path is forwarded upstream instead
- An `ETag` derived from the content and `Cache-Control: no-cache` are attached, and a matching `If-None-Match` is answered with `304`
- If the asset is indexed but cannot be read, the proxy does not answer `404`; it forwards the request upstream
For upstream `301`, `302`, `303`, `307`, and `308` responses returned to WebView, the proxy resolves `Location` explicitly instead of relying on `HttpClient` auto-follow. Same-origin redirects are rewritten to proxy URLs, relative `Location` values are resolved against the upstream request URL, and external-launch redirects are surfaced through `ProxyEventType.redirectHandled`.

## Connection Recovery APIs

After device suspension or a process resume, the socket can stop responding even though the internal state still reports the server as running. In that state the WebView shows its own native error page (a message about not being able to connect to `127.0.0.1:...`), so the proxy verifies responsiveness and rebinds when the app resumes.

```dart
// Hook into the app lifecycle
final guard = ProxyLifecycleGuard(
  proxy: proxy,
  currentUrlProvider: () => currentPageUrl,
  onRecovered: (result) {
    final reloadUri = result.reloadUri;
    if (reloadUri != null) {
      controller.loadRequest(reloadUri);
    } else {
      controller.reload();
    }
  },
  onFailed: (result) => showAppNotice(),
);
WidgetsBinding.instance.addObserver(guard);

// Route WebView resource errors into recovery
onWebResourceError: (error) async {
  final result = await proxy.recoverFromWebResourceError(
    errorCode: error.errorCode,
    failingUrl: error.url,
    isMainFrame: error.isForMainFrame ?? true,
  );
  if (result.cause == ProxyRecoveryCause.recoveryFailed ||
      result.cause == ProxyRecoveryCause.unrelated) {
    showAppNotice();
    return;
  }
  final reloadUri = result.reloadUri;
  if (reloadUri != null) {
    await controller.loadRequest(reloadUri);
  } else {
    await controller.reload();
  }
}

// Check whenever you need to
if (!await proxy.probe()) {
  await proxy.ensureRunning();
}

final diagnostics = await proxy.getDiagnostics();
print('port=${diagnostics.port} restarts=${diagnostics.restartCount}');
```

Notes:

- `isRunning` only returns the internal flag. Use `probe()` to verify that the server actually responds.
- `ensureRunning()` rebinds only when there is no response and keeps cache, queue, and cookie storage open. It never throws; the outcome is carried in `ProxyRecoveryResult`.
- A rebind prioritizes keeping the port the WebView already holds. When the port changes, read `portChanged` and `port`.
- A URL that differs only by port can be rewritten with `resolveReloadUri()`. The navigation APIs treat it as `ProxyNavigationReason.stalePortUrl` and recommend loading the current port.
- To prevent a restart-and-reload loop, consecutive failures wait before retrying and rebinds are limited by `maxRestartAttemptsPerMinute`.
- This package carries no end-user wording. Decide what to show from `onFailed` or from the result of `recoverFromWebResourceError()`.
- See `example/lib/main.dart` for a working integration.

### Upstream reachability diagnostics

`getDiagnostics()` reports upstream reachability alongside the proxy's own state, which is what on-site troubleshooting needs.

```dart
final diagnostics = await proxy.getDiagnostics();

print('link=${diagnostics.isOnline} (${diagnostics.onlineDecisionSource})');
print('upstream=${diagnostics.isUpstreamReachable} '
    '(${diagnostics.upstreamCircuitState})');
print('failures=${diagnostics.consecutiveUpstreamFailures} '
    'lastSuccess=${diagnostics.lastUpstreamSuccessAt}');
```

- `isOnline` is the link-layer decision and `onlineDecisionSource` says what it is based on: the value read at startup, or a later change event.
- `isUpstreamReachable` is whether requests can actually be forwarded, reflecting both the link layer and the circuit breaker.
- `consecutiveUpstreamFailures` and `lastUpstreamSuccessAt` show how long the upstream has been out of reach.

### Reading resend outcomes

A queued request is resent in the background, so its response never reaches the page that made it. Subscribe to the event, or read the recent outcomes, when the app has to reconcile what the upstream recorded.

```dart
proxy.events
    .where((event) => event.type == ProxyEventType.queueResendAttempted)
    .listen((event) {
  debugPrint('resend: ${event.data['statusCode']} ${event.url}');
});

// Inspect the last 20 outcomes later (never includes the body)
for (final result in proxy.recentResendResults) {
  debugPrint('${result.method} ${result.url} -> ${result.statusCode}');
}
```

The outcomes are held in memory for monitoring only and are lost when the app process ends.

## Reading the proxy state from the web app

The unsent count and the online state are available from the Dart API, but when the screen itself has to show them or act on them, the status endpoint removes the need for a bridge in the app.

```js
const res = await fetch('/__offline_web_proxy/status');
const status = await res.json();

if (status.queueLength > 0) {
  // Do not allow a settlement while something is unsent
  disableSettlement(`${status.queueLength} request(s) not yet sent`);
}
if (!status.isOnline) {
  // Hide the register sign-in while offline
  hideRegisterAuth();
}
```

The response looks like this.

```json
{
  "isOnline": true,
  "onlineDecisionSource": "connectivity",
  "isUpstreamReachable": true,
  "upstreamCircuitState": "closed",
  "queueLength": 0,
  "quarantinedCount": 0,
  "unacknowledgedDroppedCount": 0,
  "recentResendResults": []
}
```

- `GET` only, never forwarded upstream, and excluded from statistics.
- Only callers on the proxy's own origin are served. A request carrying another `Origin` is answered with `403`, and `Access-Control-Allow-Origin: *` is never attached.
- Setting `statusPath` to an empty string disables it.

### Operating the quarantine store from the page

A sale quarantined by a 4xx is resent once the cause — a closed stocktake, for example — is resolved. When the person doing that stands at the screen, `enableAdminApi: true` exposes the same operations over HTTP.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/__offline_web_proxy/admin/quarantine` | List quarantined requests (never the body) |
| `POST` | `/__offline_web_proxy/admin/quarantine/<id>/retry` | Put one back on the queue |
| `DELETE` | `/__offline_web_proxy/admin/quarantine/<id>` | Discard one |

```js
const res = await fetch('/__offline_web_proxy/admin/quarantine');
const { requests } = await res.json();

for (const request of requests) {
  // Resend the ones whose cause has been resolved
  await fetch(`/__offline_web_proxy/admin/quarantine/${request.id}/retry`, {
    method: 'POST',
  });
}
```

**Warning**: Disabled by default. Same-origin also means *every script running on the page*. Enabling it while the page still loads third-party scripts from a CDN would let such a script reach as far as discarding a quarantined request. Move those files under `assets/static/` first.

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

// 上流に拒否されて再送を打ち切ったリクエスト
final quarantined = await proxy.getQuarantinedRequests();
for (final request in quarantined) {
  // 原因を解消したら再送、送らないと判断したら破棄する
  await proxy.retryQuarantinedRequest(request.id);
}

final stats = await proxy.getStats();
print('requests=${stats.totalRequests} hitRate=${stats.cacheHitRate}');
print('quarantined=${stats.quarantinedCount} '
    'unacknowledged=${stats.unacknowledgedDroppedCount}');

proxy.events.listen((event) {
  if (event.type == ProxyEventType.requestReceived) {
    print(event.data['resolvedUpstreamUrl']);
    print(event.data['navigationDisposition']);
  }
  if (event.type == ProxyEventType.redirectHandled &&
      event.data['redirectAction'] ==
          ProxyWebViewNavigationAction.launchExternal.name) {
    print(event.data['externalUrl']);
  }
});
```

Notes:

- Online GET/HEAD requests are forwarded upstream and are not short-circuited by the proxy cache.
- The proxy cache is used only as a substitute response for offline requests or GET/HEAD requests that could not reach the upstream. Connection refused, a dropped connection, and exceeding `requestTimeout` are covered, while a 4xx / 5xx returned by the upstream is passed through. When no eligible cache exists, 504 is returned.
- `warmupCache()` is intended to prepare fallback responses in advance, not to optimize normal online browsing. While the upstream is considered unreachable, it returns a failure entry for each path instead of waiting, and its results feed the reachability decision.

The event stream is useful for observing cache hits, queue activity, request-resolution metadata, and redirect handling metadata. `redirectHandled` includes fields such as `redirectStatusCode`, `locationHeader`, `redirectAction`, `resolvedProxyUrl`, and `externalUrl`.
Connection recovery emits `serverRecovered` and `serverUnavailable`, which carry `cause`, `previousPort`, `newPort`, `downtimeMs`, `restartCount`, and `probeError`.

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

- One `OfflineWebProxy` instance forwards application requests to one configured upstream origin. Another origin that only serves resources can be relayed through `mirroredOrigins`, but only for `GET` and `HEAD`.
- `ProxyConfig` is the supported configuration path. External YAML configuration loading is not implemented.
- Static resources under `assets/static/` are served for `GET` and `HEAD` only. An update request on the same path is forwarded upstream instead. Range requests are not supported.
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

## Release Process

- Update `pubspec.yaml` and `CHANGELOG.md` first, then commit those changes to `main`.
- Do not run `dart pub publish` manually for releases. This repository publishes via the GitHub Actions `release` job.
- Create and push a version tag such as `v0.8.0`. The `v*` tag push triggers GitHub Actions to run validation, publish to pub.dev, and create the GitHub Release.

## License

MIT License
