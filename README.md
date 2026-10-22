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
- Offline fallback page that reloads itself once the upstream is reachable again, with a retry button
- Offline queue for POST, PUT, and DELETE requests
- AES-256 encrypted persistence of cookies, the queue, the quarantine store and the dropped history, with cookie restore support
- Verification of stored data against the encryption key, and a recovery API for a lost key
- Retention limits for the quarantine store and the dropped history (count, age and total size)
- Option for shared devices to never send one user's queued requests under the session of another user who signs in (`queueOwnerResolver`)
- WebView navigation helper APIs for same-origin, external, and new-window flows
- Access to the proxy limited to the WebView by default with a per-start secret (`requireAccessToken`), and no CORS headers unless origins are listed (`corsAllowedOrigins`)
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
  offline_web_proxy: ^0.26.0
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

    // requireAccessToken is on by default: put the per-start secret as a
    // cookie on the proxy origin before the WebView loads its first page.
    // Without it, every request except the health check gets 403.
    await WebViewCookieManager().setCookie(
      WebViewCookie(
        name: OfflineWebProxy.accessTokenCookieName,
        value: _proxy.accessToken!,
        domain: _proxy.baseUri!.host,
      ),
    );

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

**Put the access token cookie before loading.** Since 0.26.0 the proxy refuses, with `403`, every request that does not carry the per-start secret (`requireAccessToken` defaults to `true`). Put `accessToken` as a cookie on the proxy origin after every `start()` and before the WebView loads a page. `WebViewCookieManager` of `webview_flutter` cannot set HttpOnly, so scripts on the page can read the value; to set it HttpOnly, see [Keeping Other Apps Away from the Proxy](#keeping-other-apps-away-from-the-proxy).

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
  cacheUserScopedResponses: true,
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
  quarantineMaxCount: 1000,
  quarantineRetention: Duration(days: 30),
  quarantineMaxBytes: 20 * 1024 * 1024,
  quarantineResponseBodyMaxBytes: 0,
  droppedRequestMaxCount: 1000,
  droppedRequestRetention: Duration(days: 30),
  maxRequestBodyBytes: 10 * 1024 * 1024,
  queueMaxCount: 1000,
  queueMaxBytes: 50 * 1024 * 1024,
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
  authRequiredStatusCodes: {401},
  authResumePaths: ['/api/login.json'],
  enableAcceptedAtHeader: true,
  acceptedAtHeaderName: 'X-Offline-Accepted-At',
  enableReplayHeader: true,
  replayHeaderName: 'X-Offline-Replay',
  enableUpstreamCompression: true,
  encryptResponseCache: true,
  offlineMissResponse: ProxyResponseConfig(
    statusCode: 504,
    contentType: 'application/json; charset=utf-8',
    body: '{"offline":true}',
  ),
  retryBackoffSeconds: [1, 2, 5, 10, 20, 30],
  enableAdminApi: false,
  requireAccessToken: true,
  addCorsHeaders: false,
  corsAllowedOrigins: [],
  forwardWebViewCookieNames: {},
  logLevel: 'info',
  includeQueryInEvents: false,
  startupPaths: ['/app/config'],
  preferredPort: 8787,
  healthCheckPath: '/__offline_web_proxy/health',
  statusPath: '/__offline_web_proxy/status',
  healthCheckInterval: Duration.zero,
  serverIdleTimeout: Duration(seconds: 120),
  maxRestartAttemptsPerMinute: 5,
  enableOfflinePageAutoReload: true,
  enableAutoReloadContinuation: true,
  enableGatewayTimeoutAutoReload: false,
  autoReloadPollInterval: Duration(seconds: 3),
  autoReloadQueueWaitTimeout: Duration(seconds: 10),
);
```

Notes:

- `origin` is required and must be an absolute HTTP or HTTPS URL.
- Settings that name paths (`forceCachePaths`, `authResumePaths` and `queueExcludePaths`) share one glob notation: `*` matches within a single path segment, `**` matches across segments, and a pattern without either is matched exactly. Query strings are not part of the comparison.
  - From 0.26.0, the pattern and the path are brought to the same form before comparing: everything after `;` in each segment (`;jsessionid=...`) is dropped, only `%XX` escapes of unreserved characters (such as `%6C`) are decoded, repeated `/` are collapsed and a trailing `/` is dropped. `/api/login` therefore also matches `/api/login;jsessionid=1`, `/api/login/` and `/api/%6Cogin`. A trailing `/*` or `/**` also matches the path in front of it (`/js` for `/js/*`). See "Path Pattern Notation Used by Configuration" in [1] of [doc/specs.en.md](doc/specs.en.md).
- `host` accepts only loopback (`127.0.0.0/8` such as `127.0.0.1`, `::1` or `localhost`). `0.0.0.0` or a device address makes `start()` throw `ProxyStartException` (from 0.26.0).
- `port: 0` lets the OS assign a free local port.
- `preferredPort` tries that port first and automatically falls back to an ephemeral port if it is unavailable. The last successfully bound port is also reused on the next startup, which helps keep the WebView origin stable.
- `startupPaths` is what `warmupCache()` fetches when called without `paths`. Use it for paths whose fallback responses should be prepared in advance for offline or unreachable-upstream scenarios.
  - **`start()` does not fetch `startupPaths` by itself.** Call `warmupCache()` whenever it suits the app after the proxy has started.
  - Warmup sends the cookie jar exactly as the forwarding path does, so calling it after sign-in also warms up the APIs that require authentication.
  - `warmupCache(followReferences: true)` also fetches the resources referenced by the warmed HTML and CSS, both same-origin ones and those on an origin listed in `mirroredOrigins`. A URL assembled by JavaScript at runtime is out of reach.
    - HTML listed in `paths` is followed one level: `<script src>`, `<link href>`, `<img src>` and the `url()` / `@import` references inside `<style>` elements. A `<link>` counts only when its `rel` names a resource, such as `stylesheet`.
    - A stylesheet's `url()` and `@import` references are followed further (up to 4 levels counted from the listed path, as in HTML → CSS → font).
- `healthCheckPath` is reserved for responsiveness checks. Requests to it are never forwarded upstream and are excluded from statistics, and `GET` and `HEAD` requests to it are omitted from the request log. Change it when it collides with a route of your web application.
- `statusPath` returns the proxy state as JSON. It gets the same treatment as `healthCheckPath` — never forwarded, never counted, and `GET` requests omitted from the request log. An empty string disables it, which also stops the auto-reload of the fallback and `504` pages.
- `enableAdminApi` set to `true` exposes listing, resending and discarding of quarantined requests over HTTP. Disabled by default.
- `requireAccessToken` refuses, with `403`, every request that lacks the per-start secret (`accessToken`). **Enabled by default since 0.26.0** (it was disabled up to 0.25.0). Set it to `false` only where no other app or page on the device can reach the proxy, such as in tests. See [Keeping Other Apps Away from the Proxy](#keeping-other-apps-away-from-the-proxy).
- `addCorsHeaders` set to `true` adds CORS headers to responses other than the internal endpoints, only for the origins listed in `corsAllowedOrigins`. **Disabled by default since 0.26.0** (up to 0.25.0 it was enabled and answered `Access-Control-Allow-Origin: *` to every origin). Pages in the WebView share the proxy origin and need no CORS headers. While `requireAccessToken` is enabled (the default), a page on another origin normally cannot send the secret (except when, in the same WebView, it can send the secret cookie with `credentials: 'include'`), and even its preflight gets `403` without CORS headers, so CORS headers only take effect with `requireAccessToken: false`. See [Keeping Other Apps Away from the Proxy](#keeping-other-apps-away-from-the-proxy) for the risk of disabling it. CORS headers returned by the upstream itself are passed through regardless of these settings.
- `corsAllowedOrigins` lists the `http(s)` origins (no path, query, fragment or user info; a trailing `/` alone is allowed) that may read the proxy's responses when `addCorsHeaders` is `true`. A request whose `Origin` matches gets that origin in `Access-Control-Allow-Origin` and responses carry `Vary: Origin`; other requests get no CORS headers. `['*']` alone answers `*` to every origin. `Access-Control-Allow-Credentials` is never added. `start()` throws a `ProxyStartException` when `addCorsHeaders` is `true` with an empty list, when an entry is not an origin, or when `'*'` is mixed with other entries.
- `forwardWebViewCookieNames` lists the names of cookies sent by the WebView that are passed on to the upstream. **Empty by default since 0.26.0, so no WebView cookie reaches the upstream** (up to 0.25.0 every cookie but the access token was passed on). The upstream session lives in the proxy's Cookie Jar and is sent whatever this setting. Any page served through the proxy can set cookies on the proxy origin with `document.cookie`, so this keeps a page from planting a cookie the upstream trusts. See [Cookie APIs](#cookie-apis) for details.
  - A listed cookie is passed on only when the jar holds no cookie of the same name (the jar's value wins). Names are case-sensitive. The `Cookie` header stored with a queued request, and the resend from the queue, are filtered the same way.
  - `{'*'}` alone passes on every cookie but the access token (the behavior of 0.25.0).
  - `start()` throws a `ProxyStartException` for a name that is not an RFC 6265 token (one containing spaces, `=`, `;`, `,`, quotes and the like, or an empty string), for `OfflineWebProxy.accessTokenCookieName`, and for `'*'` mixed with other names.
- `includeQueryInEvents` set to `true` keeps the query and fragment in the URLs of events (`ProxyEvent.url` and the URL items of `requestReceived`, `redirectHandled` and `queueResendAttempted`). **Disabled by default since 0.26.0** (up to 0.25.0 the full URLs were always published): query strings often carry search terms, one-time codes or session identifiers, and events are often forwarded to log collectors. The `externalUrl` of `redirectHandled` is always the full URL whatever this setting, because the app needs it to launch the target. Forwarding, the `Location` returned to WebView and `recentResendResults` of the Dart API are not affected.
- Setting `healthCheckInterval` above zero enables a periodic check. It is disabled by default because the resume-triggered check performed by `ProxyLifecycleGuard` is the primary path.
- `offlineFallbackHtml` and `gatewayTimeoutHtml` replace the built-in offline and timeout response bodies with wording supplied by your app.
  - Both the built-in pages and replacement pages are answered with `Content-Type: text/html; charset=utf-8` and `Cache-Control: no-store`. The built-in pages carry a retry button.
  - A replacement page receives the auto-reload script only where it contains `ProxyConfig.recoveryScriptPlaceholder` (`<!--offline-web-proxy:recovery-->`). Write it where a `<script>` element may appear, such as inside `body`. When the marker appears more than once, only the first occurrence receives the script and the rest are removed. Add your own retry button as well.
  - The script is inserted when `statusPath` is not empty and, for the fallback page, `enableOfflinePageAutoReload` is on, or, for the `504` page, any of `enableOfflinePageAutoReload`, `enableAutoReloadContinuation` or `enableGatewayTimeoutAutoReload` is on. Otherwise the marker is replaced with an empty string.
  - A `Content-Security-Policy` meta element that forbids inline scripts stops the script.
- `enableOfflinePageAutoReload`, `enableAutoReloadContinuation`, `enableGatewayTimeoutAutoReload`, `autoReloadPollInterval` and `autoReloadQueueWaitTimeout` control the auto-reload of the pages the proxy generates. `autoReloadPollInterval` must be between 100 milliseconds and 24 hours, and `autoReloadQueueWaitTimeout` must not be negative. See [Auto-reload of the offline fallback page](#auto-reload-of-the-offline-fallback-page).
- `upstreamFailureThreshold` is how many consecutive unreachable attempts stop forwarding. It prevents every request from waiting for the timeout when the link layer is up but the upstream is down. Set it to `0` to disable the behavior.
- `upstreamProbePath`, `upstreamProbeMethod`, `upstreamProbeTimeout` and `upstreamProbeBackoffSeconds` control the reachability probe used while forwarding is stopped. Any response counts as reachable, regardless of status code.
- `queuedResponse` and `offlineMissResponse` define the responses the proxy generates itself. Both default to JSON so that `response.json()` succeeds in the web app.
- `dropPolicy` decides what happens to an update request the upstream rejected with 4xx (other than the codes listed in `authRequiredStatusCodes`). 408 and 429 are temporary and are retried like a 5xx instead; a `Retry-After` is honoured (up to one hour), and nothing else is sent from the queue during a 429. A 303 is taken as delivered. The default `quarantine` keeps it, body included, so `getQuarantinedRequests()` can surface it for a resend-or-discard decision (a request that alone exceeds `quarantineMaxBytes` is not quarantined; it is recorded in the dropped history as `quarantine_too_large`, without its body). `drop` discards it and keeps only a history entry, as before.
- `quarantineMaxCount` (1000 by default), `quarantineRetention` (30 days), `quarantineMaxBytes` (20 MB), `droppedRequestMaxCount` (1000) and `droppedRequestRetention` (30 days) limit what the quarantine store and the dropped history keep. `0` (`Duration.zero`) removes a limit, and a negative value makes `start()` throw `ProxyStartException`. See [Retention limits for quarantine and dropped history](#retention-limits-for-quarantine-and-dropped-history).
- `maxRequestBodyBytes` (10 MiB by default) caps the request body the proxy accepts, and `queueMaxCount` (1000) and `queueMaxBytes` (50 MiB) cap the queue (from 0.26.0). A request whose body exceeds the limit is neither forwarded nor queued and gets `413`; a request that would push the queue over a limit is not stored and gets `503` with `{"queued":false,"error":"queue_full"}`. Values outside the ranges (`maxRequestBodyBytes` 1024 to 256 MiB, `queueMaxCount` 1 to 100000, `queueMaxBytes` 1 MiB to 1 GiB) make `start()` throw `ProxyStartException`. See [Queue and request body limits](#queue-and-request-body-limits).
- `quarantineResponseBodyMaxBytes` above 0 keeps the start of the refusing response body as `QuarantinedRequest.responseBodyPreview` when a resend is quarantined after a 4xx, so that the app can check why the upstream refused it. The default is `0` (nothing kept), and a value outside 0 to 65536 makes `start()` throw `ProxyStartException`.
  - Only bodies whose `Content-Type` is `text/*`, `application/json` or a `+json` type, in UTF-8 or US-ASCII (or without a charset), are kept. A gzip body is decompressed first when it is at most 256 KB; other `Content-Encoding` values keep nothing. The text is never cut inside a UTF-8 character, so it may be a few bytes shorter than the limit.
  - It is encrypted with the quarantined request and counted toward `quarantineMaxBytes`, so older quarantined requests are moved out sooner. When the text would make a single request exceed `quarantineMaxBytes`, the request is quarantined without it.
  - It is read only through `getQuarantinedRequests()`; the admin API list, events, the status endpoint and the dropped history never carry it. It is removed when `retryQuarantinedRequest()` sends the request again.
  - **It can contain personal data, such as the values the user entered.** Enable it only when needed, and show it only to the user who sent the request.
- `enableIdempotencyKey` attaches an idempotency key to update requests. The first forward and every resend carry the same key, so a request whose response was lost is not applied twice. **Deduplication itself must be implemented on the upstream server.** When a request with the key the page attached is already queued, the same owner and content (method, URL and body) get the ID of that request, while another owner or content is not stored and gets `422` with `{"queued":false,"error":"idempotency_key_conflict"}` (from 0.26.0).
- `forceCachePaths` lists the paths stored even when the response says `Cache-Control: no-store`. On a server that sends `no-store` everywhere, the default policy leaves nothing to serve offline. It is empty by default, and there is deliberately no switch that relaxes `no-store` handling proxy-wide.
  - Even on a match, a response carrying `Set-Cookie`, a response carrying `Vary` (unless it names `Accept-Encoding` alone), or a request carrying `Authorization`, is not stored. A skipped response raises `ProxyEventType.cacheSkipped` with the reason, so a path that never becomes available offline can be diagnosed.
  - A `Vary` naming `Accept-Encoding` alone is stored because the proxy sends the same `Accept-Encoding` on every upstream route and decompresses gzip before storing, so the response cannot vary. Tomcat, nginx and Apache all add that `Vary` by default once compression is on, so skipping on it would remove the screen's HTML, JS and CSS in one go. A `Vary` naming `*` or any other header is still skipped.
  - For a matching path the upstream `max-age` and `Expires` are ignored and `cacheTtl` decides the expiry, because `no-store` is usually paired with `max-age=0`, which would make the entry stale the moment it is stored.
  - The response cache is encrypted by default. With `encryptResponseCache` switched off, the body of a listed path stays on the device in the clear. Even when encrypted, the box keys (the SHA-256 of the URL) stay readable, so weigh what the screen contains before listing it.
- `cacheUserScopedResponses` decides whether responses that belong to one user are kept in the response cache. `true` by default (from 0.26.0).
  - A response carrying `Set-Cookie`, or saying `Cache-Control: private`, always belongs to one user. A response for which the proxy sent `Authorization` or cookies upstream does too, unless its `Cache-Control` says `public`, by which the upstream allows sharing it (following RFC 9111 section 3.5, only `public` counts: `s-maxage` and `must-revalidate` assume revalidation, which the proxy does not do offline). Even with `public`, a response whose `Vary` names `Cookie`, `Authorization` or `*` belongs to one user.
  - **With an upstream that keeps its session in a cookie, cookies go with almost every request once one exists, so nearly every response, static resources included, belongs to one user unless the upstream marks it `public`.** With `false`, practically nothing is cached after sign-in. When responses are kept per owner, those static resources too must be fetched again after the user changes before they can be served offline.
  - With `false`, they are not stored, and `ProxyEventType.cacheSkipped` (`reason: userScoped`) is raised.
  - With `true` and `queueOwnerResolver`, a stored response is bound to the owner current when it was fetched and is served from the cache only while that owner is signed in ("Shared devices"). Without `queueOwnerResolver`, it is served to anyone, as in 0.25.0.
  - Either way, `Set-Cookie` and `Set-Cookie2` are removed from the stored headers; the response returned to the WebView keeps them. Entries stored by 0.25.0 and earlier are not rewritten, so their `Set-Cookie` stays on the device until they expire or `clearCache()` is called (it is never served from the cache).
- `mirroredOrigins` lists other origins fetched through the proxy. On a screen that loads its UI library from a CDN, the absolute URL in the HTML never passes through 127.0.0.1, so caching, fallback and warmup all miss it. A listed origin is relayed by the proxy and joins the ordinary cache and offline fallback. Empty by default.
  - A matching absolute URL is rewritten to `/__offline_web_proxy/ext/<scheme>/<host>[:port]/<original path>` in `<script src>`, `<link href>`, `<img src>` and `<style>` elements of a `text/html` response, and in the `url()` and `@import` references of a `text/css` response. A `<link>` counts only when its `rel` names a resource, such as `stylesheet`.
  - When a stylesheet loads its font files from another origin, as Google Fonts does, list both origins (for example `https://fonts.googleapis.com` and `https://fonts.gstatic.com`).
  - A stylesheet holding an absolute URL on a listed origin, or a relayed stylesheet holding a root-relative URL such as `/img/x.png`, is rewritten and its bytes change, so a `<link>` carrying an `integrity` attribute fails its check. A path-relative URL such as `../x` is left alone.
  - The rewrite reuses the warmup reference scan, so **a rewritten resource is always collected by `warmupCache(followReferences: true)`**.
  - Rewriting happens on the way out rather than on the way in, so HTML and CSS served from cache while offline go through the same transformation. Removing an origin from the configuration restores the original URLs.
  - Only `GET` and `HEAD` are relayed. Any other method answers `405` and is never queued. A path naming an origin that is not listed answers `404` and is never passed through to the configured origin.
  - Matching is exact on scheme, host and port. A value carrying a path or query raises `ProxyStartException` at startup.
  - **`Authorization`, `Origin`, `Referer` and the client's `Cookie` are never sent to a relayed origin.** Only jar entries matching the relayed domain are sent.
  - A `Set-Cookie` from a relayed origin whose scope would also reach the host of the configured origin (a parent-domain `Domain`, or the same host on another port) is not saved to the Cookie Jar (the acceptance rules in [Cookie APIs](#cookie-apis)).
  - **A `Set-Cookie` from a relayed origin is not returned to the WebView.** It is only saved to the Cookie Jar and sent to the relayed origin on later relays. Returned to the WebView, it would be stored as a cookie of the proxy origin and sent with requests to the configured origin too. A page that reads a relayed origin's cookie from script can no longer read it after the update.
  - A URL that JavaScript assembles at runtime is out of reach. A rewritten URL becomes same-origin with the proxy, so a page that returns a `Content-Security-Policy` has to allow `'self'`. HTML served from `assets/static/` is not rewritten.
- `queueExcludePaths` keeps update requests out of the offline queue when sending them later would be meaningless — a register sign-in or a sign-out, where the immediate `202 Accepted` also reads as success. Each rule carries its own response, so every screen can show the wording it already knows. Empty by default.
  - The rules apply while offline, when the upstream is unreachable, and when the upstream answered 5xx. A 5xx response is still returned as-is, because the upstream did answer; only the queueing is skipped.
  - The answer carries `X-Offline-Queued: 0` and `X-Offline-Excluded: 1`.
- `authRequiredStatusCodes` and `authResumePaths` hold queued requests until the user signs in again, when the upstream session expired while the device was offline, instead of quarantining them. Both are empty by default, so every 4xx still leaves the queue according to `dropPolicy`.
  - When a request sent from the queue is answered with one of `authRequiredStatusCodes` (for example `{401}`), the request stays in the queue (its retry count is not increased) and the queue pauses. Later requests are not sent either, so their order is kept.
  - A pause raises `ProxyEventType.authenticationRequired` once, and `queuePausedReason` in `getStats()` and in the status endpoint becomes `authenticationRequired`. A status query by key keeps answering `queued`.
  - The queue resumes when `resumeQueue()` is called, or when a request matching `authResumePaths` (the sign-in) is answered with 2xx or 3xx through the proxy. A 3xx counts because a sign-in form usually redirects after it succeeds. If the same request is answered with the same code again, the queue pauses again.
  - A request that signing in does not fix is moved out with `skipPausedRequest()`, to the quarantine store or the dropped history according to `dropPolicy` (reason `authentication_required`), and the rest are sent.
  - Codes from 300 to 499 are accepted, so a redirect to the sign-in page (such as `302`) can be listed. Unless listed, a `303` is taken as delivered, so list `303` when the upstream answers an expired session with it. **A code that is also returned for other reasons, such as `403` for a missing permission, pauses the queue on a request that signing in cannot fix.** So does a request that carries a CSRF token of the old session.
  - The pause is not persisted. It ends when the proxy stops, and the next start sends from the head of the queue again.
- `queueOwnerResolver` tells who signed in, so that queued requests of another user are never sent. It is `null` by default (the behavior of 0.24.0) and requires `authResumePaths`. See [Shared devices](#shared-devices).
- `enableAcceptedAtHeader` and `acceptedAtHeaderName` tell the upstream when the proxy first accepted a request. The same UTC ISO 8601 value is sent on the first forward and on every resend, so the upstream needs one rule — use this header when the payload carries no business timestamp — to stop offline sales from being recorded at reconnection time. Enabled by default.
  - The value survives a quarantine retry. `queuedAt` cannot be reused because a retry updates it.
  - **The value comes from the device clock.** A device whose clock is wrong while offline reports a wrong time.
- `enableReplayHeader` and `replayHeaderName` add `X-Offline-Replay: 1` to update requests sent from the queue, so the upstream can tell them from requests forwarded as soon as the screen sent them. For example, when the content no longer matches what the upstream has on record, it can reject the first forward and let the user check again on the screen, yet accept the same request from the queue. Enabled by default.
  - Answer 4xx to reject a first forward. A 5xx answer puts the request in the queue, and it is sent again with this header. So is a 4xx answer that never reaches the proxy, for example after a timeout, so give the same answer from the queue to a request already rejected under the same idempotency key.
  - A header of the same name sent by the screen is removed from every request forwarded as the screen sent it (read requests included) and replaced with the proxy's value on requests sent from the queue.
  - **This is not authentication.** Any request that reaches the upstream without the proxy can carry the header.
- With `enableUpstreamCompression` on (the default), the proxy sends `Accept-Encoding: gzip` upstream and decompresses a gzip body before returning it to the WebView, which cuts the traffic on the upstream link.
  - The same value is sent on every route: forwarding, requests sent from the queue, warmup and mirrored origins. Caching, HTML and CSS rewriting and the response to the WebView all use the decompressed body.
  - A body that cannot be decompressed (corrupt, truncated, or larger than 64 MB once decompressed) is returned as is and not cached. Codings other than gzip, such as br, are passed through as before. A request carrying `Range` is sent `identity`.
  - Set it to `false` to send `Accept-Encoding: identity`, as 0.19.0 and earlier did.
- `cacheMaxSize` caps the total body size of the response cache (200 MB by default, `0` for no limit). Beyond it, entries are removed oldest stored first until the total fits within 90% of the limit, and `ProxyEventType.cacheEvicted` is raised. A response whose body alone exceeds the limit is not stored.
- While `encryptResponseCache` is on (the default), the response cache is stored encrypted with the same key as the cookies, the queue and the quarantine store.
  - Bodies are read one at a time when served, so the whole cache is neither decrypted nor loaded into memory. Opening it still reads the whole file, so the time grows with its size (about 0.75 s for 200 MB on a desktop CPU, about 30 ms per MB on an Android emulator), with or without encryption.
  - After an update from 0.21.0 or earlier, the cache in the old format (such as a plain `proxy_cache`) is moved into the encrypted pair and the old files are deleted (about 7.5 s for 200 MB on a desktop CPU; over 40 s is expected on the emulator). The deletion is an ordinary file deletion and does not guarantee that the storage is erased.
  - The response cache is opened in the background after `start()`, migration included. `start()` returns without waiting; until the cache is open, responses to online GETs are not stored, and requests answered from the cache wait for up to `requestTimeout`. Use `await proxy.cacheReady;` before showing a screen offline right after startup. When the cache cannot be opened, the proxy keeps running without it (`ProxyEventType.errorOccurred`, `phase: cacheOpen`).
  - Set it to `false` to store the cache in plain form; the encrypted cache is then deleted without being restored in plain form. When the key does not match, the cache is emptied instead of failing startup.
  - The box keys (the SHA-256 of the normalized URL) stay readable.
- `cacheTtl` and `cacheStale` **replace** the default maps rather than merging with them. Always keep a `default` entry so that unlisted content types still resolve.
- `text/html` defaults to a 1 hour TTL and a 1 day stale period, so a page drops out of the fallback set roughly 25 hours after it was last fetched online. **Long offline operation requires tuning both `cacheTtl` and `cacheStale`.** `cacheStale` has no JavaScript entry, so scripts fall back to `default` (3 days).

### Shared devices

In a business app used by several people on one device, user A may leave queued requests behind and user B may then sign in. A resend uses the cookies at the time it is sent, so A's updates would be sent with B's session. With `queueOwnerResolver`, the proxy tells the user from the sign-in request and response, and removes queued requests of another owner without sending them.

```dart
final config = ProxyConfig(
  origin: 'https://api.example.com',
  authRequiredStatusCodes: {401},
  authResumePaths: ['/api/login.json'],
  // Tell the user from the sign-in body {"account": "..."}
  queueOwnerResolver: (context) => switch (context.requestJson) {
    {'account': final String account} => account,
    _ => null, // Unknown (a failed sign-in, for example): keep the owner
  },
);
```

- The function is called synchronously when a request matching `authResumePaths` is answered with a 2xx or 3xx by the upstream. It receives the request and the response (with the decoded body) as a `QueueOwnerContext`, readable through `requestJson`, `responseJson`, `requestFormFields`, `requestHeader()`, `responseHeader()` and so on.
- A non-empty string becomes the current owner. `null` or an empty string leaves the current owner unchanged; return it when the server answers a failed sign-in with `200`.
- The owner at the time the proxy received a request is recorded with it (it does not change when another user signs in while the upstream is still answering) and compared with the current owner right before each resend. When they differ, the request is not sent and leaves the queue according to `dropPolicy`, with the reason `owner_changed` and status code `0`. `requestQuarantined` / `requestDropped` and `recentResendResults` report it. It can be sent again with `retryQuarantinedRequest()` after its owner signs in again.
- A request whose owner, or the current owner, is unknown (queued before this setting was used, or while nobody was signed in) is sent as before.
- Nothing is sent from the queue while a sign-in is being forwarded. With several sign-ins forwarded at once, the cookies and the owner are settled together in the order the responses arrive.
- Changing the session outside a sign-in is handled as well (from 0.26.0). Pass the user of the restored session to `restoreCookies()` as `queueOwnerId`: that user becomes the owner; without it, the queue pauses with `ownerUnresolved`. `clearCookies()` removing every cookie or a domain sent to the host of the configured origin also pauses the queue with `ownerUnresolved`. Requests of the previous owner are kept in both cases. Before the first start, whether a function is set is not known, so `queueOwnerId` is not used; call these methods after `start()`.
- When the function throws, or the owner cannot be determined or saved, `errorOccurred` (`phase: queueOwnerResolve` / `queueOwnerPersist`) is raised, the signed-in user is treated as an unknown owner, and the queue pauses with `ownerUnresolved`. `resumeQueue()`, or a later sign-in resolved to an owner, resumes it. After a restart while the owner is still unknown, the queue stays paused with `ownerUnresolved`, so requests of the previous owner are not moved out (also after `clearCookies()`, `restoreCookies()` without `queueOwnerId`, or a sign-in interrupted by the app ending).
- The identifier is never stored as given: only its HMAC-SHA256 is kept, and it never appears in events, the status endpoint or the admin API. The current owner survives a restart. It is stored in the unencrypted port preference box, so the record carries a tag that detects changes. When a start finds the tag does not match, or finds requests with an owner but no record, it raises `errorOccurred` (`phase: queueOwnerLoad`) and pauses the queue with `ownerUnresolved`. A 0.25.0 record (without a tag) is accepted once and saved again with a tag.
- **Requests queued with a session signed in before this setting was introduced are not protected until the next sign-in.** Keep the upstream's own checks as well.
- With `enableWebStorageInheritance`, the web storage snapshot is kept on the device independently of the owner. Call `clearWebStorageSnapshot()` when the user signs out or hands the device over ([Web storage snapshot](#web-storage-snapshot)).
- The response cache is handled per owner too (from 0.26.0). The cache key is the URL alone, so a user-scoped response (such as one fetched with cookies) is stored with the owner current when it was fetched. Offline or while the upstream is unreachable, it is served only while that owner is current; another user, or a changed owner, gets a miss (`ProxyEventType.cacheMiss`, `reason: ownerMismatch`). A response stored while the owner is unresolved (`ownerUnresolved`) is served only until the owner changes. A response is not stored when a sign-in or `restoreCookies()` starts while it is fetched (`cacheSkipped`, `reason: ownerChanged`). Before anyone signs in, responses are stored with a "no owner" mark and served only while there is no owner: not after someone signs in, nor after `clearCookies()`. To keep no user-scoped response on a shared device at all, set `cacheUserScopedResponses: false`.

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

An offline read with no cached entry answers with `504` and `{"offline":true}` by default, so `response.ok` is false and normal error handling applies. Only page navigations (`Sec-Fetch-Mode: navigate`) receive the readable HTML fallback page (`200`).

When the link layer is up but the upstream cannot be reached, anything but a page navigation receives the same body. A page navigation receives the HTML `504` page with a retry button (replaceable via `gatewayTimeoutHtml`). Once the circuit breaker opens, requests take the offline path and page navigations receive the fallback page. A `504` the proxy returns because the upstream is unreachable carries `X-Offline-Source: none`, so it can be told apart from a `504` the upstream itself returned.
- The supported configuration entry point is `ProxyConfig`. The package does not currently load an external YAML file automatically.

### Auto-reload of the offline fallback page

An offline navigation to an uncached screen receives a `200` fallback page. The WebView sees no error, so without help the page would stay on screen after connectivity returns. The built-in fallback page reads `statusPath` on its own origin at a fixed interval and reloads itself once the upstream is reachable again.

- After reading `isUpstreamReachable: true` twice in a row, the page waits until `queueLength` is zero, or at most `autoReloadQueueWaitTimeout`, and reloads. Reloading before the queue is resent can show a screen without the updates made offline, which invites entering them twice.
- The decision uses `isUpstreamReachable`, not `isOnline`. `isOnline` reflects the link layer only and stays `true` while the device is on Wi-Fi but the upstream is down.
- "Reachable" is the proxy's own decision, not proof that the upstream answered. A reload right after airplane mode is turned off can still end in a `504` while the network settles.
- When an automatic reload lands on the `504` page, that page waits ten seconds and reloads again once it reads `isUpstreamReachable: true` (`enableAutoReloadContinuation`, on by default). After three automatic reloads in a row that land on a proxy page, the page stops and leaves the retry button.
- Reloading the `504` page from the moment it is shown (`enableGatewayTimeoutAutoReload`) is off by default. Even when enabled, it acts only after the proxy detected the upstream as unreachable (the circuit breaker opening or the link layer dropping) and then reachable again.
- While the status cannot be read (the proxy stopped or moved to another port), the page does not reload; it keeps reading at an interval that grows up to 30 seconds. Recovering the proxy itself is the job of `ProxyLifecycleGuard`.
- For `requestTimeout` plus 30 seconds after `beforeunload`, the reload is put off so a navigation started from the page is not cancelled. A navigation that never replaces the page (a `204` response, a download, a navigation stopped by the app, an external scheme) delays the reload for that long as well, and a navigation that takes longer can still be cancelled. Whether WKWebView on iOS fires `beforeunload` has not been verified.
- The script needs JavaScript in the WebView. Inside an iframe, each frame acts on its own.
- The consecutive count of automatic reloads is kept in the web app origin's `sessionStorage`, under keys starting with `__offline_web_proxy_recovery:`; keys not updated for ten minutes are removed. Without `sessionStorage`, the consecutive-reload limit and the continuation do not work.
- When an automatic reload passes through a redirect and lands on another URL, continuation does not act for that one reload. A `504` page reached that way keeps only its retry button unless `enableGatewayTimeoutAutoReload` is on.
- An empty `statusPath` leaves the page with the retry button only.
- `GET` requests to the status path and `GET` / `HEAD` requests to the health check path are omitted from the request log. The request log never shows query strings; a request with a query is written as `/path?…`.

When your app shows its own error screen from an HTTP error callback (`NavigationDelegate.onHttpError` in webview_flutter, `onReceivedHttpError` in flutter_inappwebview), every automatic reload that lands on a `504` triggers that callback again, up to three times in a row. A `504` generated by the proxy carries `X-Offline-Source: none`.

- If you use the built-in `504` page, or a replacement page with its own retry button, you can skip the app's error screen for a main-frame `504` carrying `X-Offline-Source: none`, provided JavaScript is enabled in the WebView.
- Compare the header name case-insensitively.
- If you still show an error screen, take care with when you dismiss it. Dismissing it when the `504` page itself finishes loading may make it disappear right after it appears. The order of the HTTP error callback and the page-finished callback depends on the WebView implementation, so confirm it on a device before relying on it.
- If the two conflict, set `enableAutoReloadContinuation: false`.

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

The offline fallback page reloads itself by reading the status endpoint. The `504` page reloads only when it was reached by an automatic reload (`enableAutoReloadContinuation`) or when `enableGatewayTimeoutAutoReload` is on (see [Auto-reload of the offline fallback page](#auto-reload-of-the-offline-fallback-page)). `ProxyLifecycleGuard` covers the other case, where the proxy socket itself stops responding.

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
- `lastCookieStorageDiscardedAt` and `lastCookieStorageDiscardReason` show when and why this instance discarded the cookie storage (see [When the encryption key is lost](#when-the-encryption-key-is-lost)).

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

`statusCode` is `0` when the upstream could not be reached, when the request was not sent because it belongs to another owner (`dropReason` `owner_changed`), and when it was not sent because, after `origin` was changed, its stored destination differs from the configured origin, even when listed in `mirroredOrigins` (`dropReason` `origin_changed`). The outcomes are held in memory for monitoring only and are lost when the app process ends. `recentResendResults` keeps the full URL including the query, while the `url` of the event drops the query and fragment unless `includeQueryInEvents` is `true`.

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
  "queuePausedReason": null,
  "queuePausedUntil": null,
  "recentResendResults": []
}
```

- `queuePausedReason` tells why sending from the queue is stopped: `null` when it is not, `"authenticationRequired"` while it waits for a sign-in (`authRequiredStatusCodes`), `"rateLimited"` while it is held after the upstream answered 429, `"ownerUnresolved"` while `queueOwnerResolver` could not tell who signed in. The page can use `"authenticationRequired"` to ask the user to sign in.
- `queuePausedUntil` is when sending resumes (UTC ISO 8601) for `"rateLimited"`, `null` otherwise.
- `recentResendResults` lists the latest resend outcomes. Because the page can read them, `url` never carries the query or fragment, whatever `includeQueryInEvents` says.
- `GET` only, never forwarded upstream, excluded from statistics, and omitted from the request log.
- Only callers on the proxy's own origin are served. A request carrying another `Origin` is answered with `403`, and `Access-Control-Allow-Origin` is never attached, whatever `corsAllowedOrigins` says.
- A request without an `Origin` is allowed, so if `requireAccessToken` is disabled, other apps on the device can reach it too ("Keeping Other Apps Away from the Proxy").
- Setting `statusPath` to an empty string disables it, which also stops the auto-reload of the fallback and `504` pages.
- `queueLength`, `quarantinedCount` and `unacknowledgedDroppedCount` include entries still waiting for migration from the storage of 0.14.0 or earlier (see [Migrating from 0.14.0 or earlier](#migrating-from-0140-or-earlier)).

#### Looking up a request by its key

When the page sends an update request with its own key in `Idempotency-Key` (or the header named by `idempotencyHeaderName`), it can ask where that request stands by passing `idempotencyKey`. Use it to keep showing a request as unsent after the page is reopened, or to notice that the upstream rejected it and ask for it again.

```javascript
const query = requestIds
  .map((id) => `idempotencyKey=${encodeURIComponent(id)}`)
  .join("&");
const response = await fetch(`/__offline_web_proxy/status?${query}`, {
  cache: "no-store",
});
if (!response.ok) {
  // 503 means the stores cannot be read. Keep the saved keys and ask again later
  return;
}
for (const item of (await response.json()).requests) {
  // item.state is queued / quarantined / delivered / dropped / unknown
}
```

- `state` is one of `queued` (waiting in the queue, including while the queue is paused for a sign-in), `quarantined` (rejected with 4xx), `delivered` (sent from the queue and answered with 2xx or 303, for `idempotencyRetention`), `dropped` (in the dropped history) or `unknown` (found nowhere). `quarantined` and `dropped` carry `statusCode`.
- When the same key sits in several places, the first match in the order `delivered` → `queued` → `quarantined` → `dropped` wins.
- A request the upstream answered on its first forward with anything but 5xx is `unknown`, because the page receives that answer directly. A 5xx or an unreachable upstream puts the request in the queue, so it is `queued` (a request matching `queueExcludePaths` is never queued, so it stays `unknown`).
- Up to 50 keys of up to 200 characters each; beyond that the answer is `400`. When the stores cannot be read the answer is `503`, never `unknown`.
- Another app on the device that knows a key can look it up. Use keys that cannot be guessed, such as version 4 UUIDs.
- From Dart, `getRequestStatuses()` makes the same decision.

### Operating the quarantine store from the page

A sale quarantined by a 4xx is resent once the cause — a closed stocktake, for example — is resolved. When the person doing that stands at the screen, `enableAdminApi: true` exposes the same operations over HTTP.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/__offline_web_proxy/admin/quarantine` | List quarantined requests (never the body) |
| `POST` | `/__offline_web_proxy/admin/quarantine/<id>/retry` | Put one back on the queue |
| `DELETE` | `/__offline_web_proxy/admin/quarantine/<id>` | Discard one |

- The list is ordered by `quarantinedAt`, oldest first, and every item carries `pendingMigration`. The start of the response body kept by `quarantineResponseBodyMaxBytes` is not included.
- Responses to resending and discarding:
  - Success: `200` with `{"retried": true}` or `{"discarded": true}`
  - No matching item: `404`
  - An item still waiting for migration from the storage of 0.14.0 or earlier (`pendingMigration: true`): `409`. It cannot be operated on until the migration finishes
  - With `404` and `409`, `retried` or `discarded` is `false` and `error` carries the reason
  - The quarantine lock cannot be acquired within 30 seconds: `500` (`text/plain`)

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

**Warning**: Disabled by default. Same-origin also means *every script running on the page*. Enabling it while the page still loads third-party scripts from a CDN would let such a script reach as far as discarding a quarantined request. Move those files under `assets/static/` first. A request without an `Origin` is also allowed, so if `requireAccessToken` is disabled, other apps on the device can reach the endpoints. Keep it enabled (the default; "Keeping Other Apps Away from the Proxy").

## Keeping Other Apps Away from the Proxy

The proxy listens on loopback, but it cannot tell which process a request came from. Without a check, other apps and browser pages on the device could send requests to the proxy, and on the forwarding path those requests would go upstream with the authenticated sessions in the proxy's Cookie Jar. The proxy therefore accepts only requests that carry a per-start secret known to the WebView (`requireAccessToken`, enabled by default since 0.26.0). The app has to put the secret as a cookie before the WebView loads its first page.

```dart
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

final proxy = OfflineWebProxy();
await proxy.start(
  config: const ProxyConfig(
    origin: 'https://api.example.com',
    // requireAccessToken: true (default) refuses requests without the
    // secret with 403. addCorsHeaders: false (default) adds no CORS headers,
    // which pages in the WebView do not need.
  ),
);

// Put it as an HttpOnly cookie before the WebView loads its first page
await CookieManager.instance().setCookie(
  url: WebUri(proxy.baseUri!.toString()),
  name: OfflineWebProxy.accessTokenCookieName,
  value: proxy.accessToken!,
  isHttpOnly: true,
);
```

- `accessToken` changes on every `start()` and is never returned over HTTP. After calling `start()` again, put the new value before loading. A rebind by automatic recovery keeps it.
- `WebViewCookieManager` of `webview_flutter` cannot set HttpOnly, so scripts on the page can read a cookie put with it (as in the Quick Start). To keep it from scripts, use a platform cookie manager that can set HttpOnly (Android's `CookieManager`, for example) or `flutter_inappwebview`.
- Requests that do not come from the WebView, such as those sent with `HttpClient` from the app, also need the secret. Send it in the header below.
- Calls that can set headers, such as `fetch`, may send the value in `X-Offline-Web-Proxy-Token` (`OfflineWebProxy.accessTokenHeaderName`) instead.
- Only `GET` / `HEAD` on `healthCheckPath` is exempt. The forwarding path, bundled assets, the mirrored-origin path, the status endpoint, the administrative endpoints and the WebStorage bridge are all covered.
- Cookies are kept per host and do not distinguish ports. If you use both `127.0.0.1` and `localhost`, put one on each. The secret is also sent to any other server on the same host.
- With `SameSite=Strict`, the cookie is not sent when a page on another site navigates to the proxy, but a navigation back from an external login then gets `403` too.
- A `fetch` with `credentials: "omit"` sends no cookies and gets `403`. Use `same-origin` (the default).
- Whatever the setting, the secret cookie and header are never forwarded upstream or stored in the queue, and a `Set-Cookie` of the same name from the upstream is not passed to the WebView.
- Scripts running in the WebView reach the proxy as same-origin requests that carry the secret. This does not protect against third-party scripts.
- So that a page on another site cannot reach the proxy by pointing its own host name at loopback (DNS rebinding), a request whose `Host` header does not name the proxy itself (`ProxyConfig.host`, `127.0.0.1`, `localhost` or `[::1]` with the port in use) is refused with `403` before the secret check, the health check included. Load URLs with these host names, such as `baseUri`, in the WebView.
- A request whose path hides `.` or `..` behind encoding or the like, such as `..%2F` or `%5C..`, is refused with `400` so that it cannot point at a different resource upstream (`errorOccurred` with `phase: requestPath`). The path is checked after the access token, so a request without the token gets `403` and raises no such event.
- A request carrying `X-Forwarded-Host` or `X-Forwarded-Proto` is refused with `403` whatever the value, because dart:io builds the request URL from these values and they can rewrite even the path and user info. The WebView never sends these headers.
- Other headers that claim the requester or the original URL, such as `X-Forwarded-For`, `Forwarded`, `X-Real-IP` and `X-Original-URL`, are never passed on: not when forwarding, relaying, storing in the queue or resending. See "Headers That Claim the Requester" in [14] of [doc/specs.en.md](doc/specs.en.md) for the full list.

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

- A `Set-Cookie` in an upstream response is checked against the acceptance rules of RFC 6265 / RFC 6265bis before it is saved to the Cookie Jar, and is not saved when it breaks one. The response returned to the WebView is not affected by these rules.
  - A `Domain` the request host does not domain-match (`domainMismatch`), a `Domain` other than the host itself for an IP-address host (`ipDomain`), and a `Domain` without a `.` (`singleLabelDomain`; one equal to the host, such as `localhost`, is accepted as host-only)
  - A cookie from a relayed origin (`mirroredOrigins`) whose scope would also reach the host of the configured origin (`mirroredOriginDomain`)
  - `Secure` from a response other than `https` (`insecureSecure`), a `__Secure-` / `__Host-` name that does not meet its requirements (`securePrefix` / `hostPrefix`), and overwriting, deleting or shadowing (through a parent domain or an overlapping path) a `Secure` cookie from a response other than `https` (`secureOverwrite`)
  - A cookie that is not saved is reported with `errorOccurred` (`operation: cookieSave`) carrying `reason` and `cookieName`, never the value. The check is simplified and does not use the Public Suffix List. See "Acceptance Rules for Upstream Set-Cookie" in [4] of the specification for details.
  - `Expires` is parsed with the algorithm of RFC 6265 and also accepts `Wed, 21-Oct-2026 07:28:00 GMT`, two-digit years and asctime. `Max-Age` is taken only when it matches `^-?\d+$`, and an invalid value is ignored. The expiry is capped at 400 days after receipt. When `Path` is empty or does not start with `/`, the default-path computed from the request path is used.
- Cookies passed to `restoreCookies()` are values from the app, so the acceptance rules above are not applied.
- With `queueOwnerResolver` set, pass the user of the restored session as `restoreCookies(entries, queueOwnerId: '...')`. Without it, and when `clearCookies()` removes every cookie or a domain sent to the host of the configured origin, the owner of queued requests becomes unknown and the queue pauses with `ownerUnresolved` ([Shared devices](#shared-devices)).
- Of the cookies the WebView sends to the proxy, only the names listed in `forwardWebViewCookieNames` are passed on to the upstream (empty by default). An upstream `Set-Cookie` is still returned to the WebView and saved to the Cookie Jar, so a session cookie set by the upstream is sent from the jar without any setting. A `Set-Cookie` from a relayed origin (`mirroredOrigins`) is not returned to the WebView.
  - **Migrating from 0.25.0**: If cookies set by page scripts (`document.cookie`) or with `WebViewCookieManager` were sent to the upstream, list their names.

    ```dart
    const ProxyConfig(
      origin: 'https://api.example.com',
      // Send the language and consent cookies that page scripts set
      forwardWebViewCookieNames: {'locale', 'consent'},
    )
    ```

  - If you do not know which cookies are sent, `{'*'}` restores the behavior of 0.25.0. It passes on any cookie a page script sets, so replace it with a list once the needed names are known.
  - Requests queued by 0.25.0 or earlier are filtered with the same setting when they are resent.
  - A cookie the acceptance rules kept out of the Cookie Jar (for example a `Secure` cookie from an `http` upstream) reached the upstream through the WebView up to 0.25.0, but is no longer sent upstream from 0.26.0. You can confirm that it was not saved from `reason` and `cookieName` of `errorOccurred` (`operation: cookieSave`).
- `getCookies()` returns masked values for inspection.
- `getCookieHeaderForUrl()` only accepts URLs that match the configured origin.
- Stored data is checked against the encryption key in `start()` and in a cookie API called before `start()` or after `stop()`. See [When the encryption key is lost](#when-the-encryption-key-is-lost).
  - When the key is unusable (missing, unreadable or invalid) and only the cookie box has content, or when the other boxes are fine and only the cookie box does not match the key, is damaged at its head or had its check aborted, the cookies are discarded and startup continues; the user must sign in again.
  - When a queue, quarantine or dropped-history box does not match the key, is damaged at its head or had its check aborted, or when the key is unusable (missing, unreadable or invalid) and one of those boxes has content, startup fails without deleting anything.
  - When the check fails in a cookie API called before `start()` or after `stop()`, the API throws `CookieOperationException` with `StorageIntegrityException` as its `cause`.

## Cache, Queue, and Monitoring APIs

```dart
await proxy.clearCache();
await proxy.clearExpiredCache();
await proxy.clearCacheForUrl('https://api.example.com/app/dashboard');
// Removes the web storage snapshot (enableWebStorageInheritance)
await proxy.clearWebStorageSnapshot();

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

// Where a request stands, by the idempotency key the page attached
final statuses = await proxy.getRequestStatuses(['3f0c...']);
print(statuses.single.state); // RequestState.queued, for example

// 上流に拒否されて再送を打ち切ったリクエスト
final quarantined = await proxy.getQuarantinedRequests();
for (final request in quarantined) {
  // 原因を解消したら再送、送らないと判断したら破棄する
  await proxy.retryQuarantinedRequest(request.id);
}

// A queue paused for a sign-in (authRequiredStatusCodes) resumes after the
// user signs in again; a request that still fails can be moved out
await proxy.resumeQueue();
await proxy.skipPausedRequest();

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
    // Always the full URL with its query: launch it, but do not log it
    launchUrl(Uri.parse(event.data['externalUrl'] as String)); // url_launcher
  }
});
```

Notes:

- Online GET/HEAD requests are forwarded upstream and are not short-circuited by the proxy cache.
- The proxy cache is used only as a substitute response for offline requests or GET/HEAD requests that could not reach the upstream. Connection refused, a dropped connection, and exceeding `requestTimeout` are covered, while a 4xx / 5xx returned by the upstream is passed through. When no eligible cache exists, 504 is returned.
- `warmupCache()` is intended to prepare fallback responses in advance, not to optimize normal online browsing. While the upstream is considered unreachable, it returns a failure entry for each path instead of waiting, and its results feed the reachability decision.
- `getQueuedRequests()`, `getQuarantinedRequests()` and `getDroppedRequests()` are ordered by the stored time (`queuedAt`, `quarantinedAt`, `droppedAt`), oldest first.
- The `limit` of `getQuarantinedRequests()` and `getDroppedRequests()` counts from the head after sorting.
- `getQueuedRequests()` replaces the value of any header that may carry secrets with `***`.
  - Masked: with the name lower-cased and `_` read as `-`, a name equal to `cookie`, `authorization` or `proxy-authorization`, or containing any of `auth`, `token`, `secret`, `session`, `csrf`, `xsrf`, `key`, `pass`, `credential`, `signature`, `jwt` or `cookie`
  - Never masked: the header named by `idempotencyHeaderName`
  - Only the headers the client sent are stored; the headers the proxy adds are attached when sending
  - **The query of the URL is not masked**
  - Resends use the stored values
- An item whose `pendingMigration` is `true` is still waiting for migration from the storage of 0.14.0 or earlier (see [Migrating from 0.14.0 or earlier](#migrating-from-0140-or-earlier)).

The event stream is useful for observing cache hits, queue activity, request-resolution metadata, and redirect handling metadata. `redirectHandled` includes fields such as `redirectStatusCode`, `locationHeader`, `redirectAction`, `resolvedProxyUrl`, and `externalUrl`.
By default the URLs in events (`event.url` and URL fields such as `locationHeader`) drop the query and fragment; set `includeQueryInEvents: true` to receive them in full. The `externalUrl` of `redirectHandled` is the exception: for an external launch the WebView only gets `204`, so it always carries the full URL (a map search term, the `?subject=` of `mailto:`, the `?q=` of `geo:`). **`externalUrl` is meant to be executed by the app and contains the query, so do not write it to logs.** Likewise, when a response cannot be stored in the cache, `errorOccurred` (`phase: cacheResponse`) carries only the exception type and `reason: storageFailure`. When a cookie from the upstream is not saved, `errorOccurred` (`operation: cookieSave`) carries, for a cookie breaking the acceptance rules, the reason for the rejection in `reason` and the cookie name in `cookieName`; for any other failure, only the exception type in `error` and `invalidSetCookie` or `storageFailure` in `reason`. The `Set-Cookie` value is never included.
Connection recovery emits `serverRecovered` and `serverUnavailable`, which carry `cause`, `previousPort`, `newPort`, `downtimeMs`, `restartCount`, and `probeError`.

## Data Stored on the Device

### What is stored

The proxy stores data in Hive boxes and in secure storage. In an encrypted box only the values are encrypted; the box keys (the IDs of queued requests and the like, and the domain, path and name of a cookie) are stored in the clear. **The queue and the quarantine store keep the request headers and body as they were sent.**

| Location | Content | Encryption | Retention |
| --- | --- | --- | --- |
| `proxy_cookies_secure` | Cookies (name, value, domain, path, expiry, attributes). Keys consist of the domain, path, name and so on (the SHA-256 when over 255 bytes in UTF-8) | Values only (AES-256) | An expired cookie is removed when the cookies to send are looked up. `clearCookies()` removes them |
| `proxy_queue_secure` | Unsent update requests (URL with query, method, headers, body, acceptance time, idempotency key and so on; the HMAC of the owner when `queueOwnerResolver` is set). Keys are IDs derived from the time the request was stored | Values only (AES-256) | Until the request is sent, or moved to the quarantine store or the dropped history. Limited to 1000 requests and 50 MiB by default; requests beyond that are not stored (see [Queue and request body limits](#queue-and-request-body-limits)) |
| `proxy_quarantined_requests_secure` | Requests the upstream rejected with 4xx: the queued content (headers and body included) plus the quarantine time, status code and reason. With `quarantineResponseBodyMaxBytes` set, also the start of the refusing response body | Values only (AES-256) | Until resent or discarded. Limited to 30 days, 1000 entries and 20 MB by default |
| `proxy_dropped_requests_secure` | History of requests removed from the queue or the quarantine store (URL with query, method, time, reason, status code, error message, whether acknowledged). No headers or body | Values only (AES-256) | 30 days by default. The count limit (1000 by default) applies to acknowledged entries only |
| `proxy_cache_index_secure`, `proxy_cache_body_secure` | Response cache (the default). The metadata box (`proxy_cache_index_secure`) holds the status code, stored time, expiry, Content-Type and body size; the body box (`proxy_cache_body_secure`) holds the headers (without `Set-Cookie` and `Set-Cookie2`) and body. With `queueOwnerResolver`, a user-scoped response also holds the owner's HMAC. Keys are the SHA-256 of the normalized URL | Values only (AES-256) | Entries past their stale period and entries beyond `cacheMaxSize` are removed. Deleted, never restored in plain form, when `encryptResponseCache` is switched off |
| `proxy_cache_index`, `proxy_cache_body` | Response cache when `encryptResponseCache` is `false`. Same content and keys as the encrypted pair | None | Same as the encrypted pair. The boxes are compacted after explicit deletion (`clearCache()`, `clearCacheForUrl()`, and `clearExpiredCache()`, which also runs every hour). Eviction beyond `cacheMaxSize` does not compact them, so evicted entries may stay in the file until Hive compacts the box on its own. Moved into the encrypted pair and deleted once `encryptResponseCache` is enabled |
| `proxy_cache`, `proxy_cache_secure` | Response cache of 0.21.0 and earlier, holding the metadata and body in one value. `proxy_cache_secure` is the one written by 0.21.0 with `encryptResponseCache` enabled | `proxy_cache`: none; `proxy_cache_secure`: values only (AES-256) | Moved into the new pair and deleted at startup. With `encryptResponseCache` off, `proxy_cache_secure` is deleted without being moved |
| `proxy_web_storage_secure` | Web storage snapshot received from the page when `enableWebStorageInheritance` is on (see [Web storage snapshot](#web-storage-snapshot)) | Values only (AES-256) | Until the next snapshot overwrites it or `clearWebStorageSnapshot()` removes it |
| `proxy_web_storage` | Web storage snapshot of 0.25.0 and earlier | None | Moved into `proxy_web_storage_secure` and deleted at startup when `enableWebStorageInheritance` is on; deleted without being moved when it is off |
| `proxy_idempotency` | Idempotency keys that reached the upstream, with the time they were recorded. From 0.26.0 the box key is `h1:` followed by the HMAC-SHA256 of the idempotency key (with a key derived from the storage encryption key), so the key the page sent is not stored. Records of 0.25.0 and earlier keep the key as sent (the SHA-256 when over 255 bytes in UTF-8) and are still looked up | None | Keys older than `idempotencyRetention` (24 hours by default) are removed every hour, and the box is then compacted. Records of 0.25.0 and earlier disappear the same way |
| `proxy_port_preferences` | The port last bound for each host. With `queueOwnerResolver` set, also the HMAC of the current owner, a fingerprint of the key, and whether a sign-in is being forwarded | None | Ports: until the next bind overwrites them. Owner: until it is saved again; a value whose key fingerprint does not match is deleted at startup. The box is compacted whenever the owner record changes |
| `offline_web_proxy.cookie_box_encryption_key` in secure storage | The key of the encrypted boxes, shared by cookies, the queue, the quarantine store, the dropped history (and the response cache when encrypted) | Kept in secure storage | Until `recoverEncryptedStorage()` deletes it, or an unusable key (missing, unreadable or invalid) is replaced by a new one. A new key is written when no queue, quarantine or dropped-history box has content (see [When the encryption key is lost](#when-the-encryption-key-is-lost)) |
| `proxy_queue`, `proxy_quarantined_requests`, `proxy_dropped_requests`, `proxy_cookies` | Content stored in the clear by 0.14.0 or earlier (cookies: before 0.4.0) | None | Deleted after migration to the encrypted boxes. The old queue, quarantine and dropped-history boxes are emptied before deletion |

### Retention limits for quarantine and dropped history

| Setting | Default | Behavior |
| --- | --- | --- |
| `quarantineMaxCount` | 1000 | Moves the oldest requests beyond the limit to the dropped history (`dropReason: quarantine_limit`) |
| `quarantineRetention` | 30 days | Moves requests older than this, counted from `quarantinedAt`, to the dropped history (`quarantine_expired`) |
| `quarantineMaxBytes` | 20 MB | Estimated total of bodies, headers and the kept start of response bodies. Moves the oldest requests beyond it to the dropped history (`quarantine_limit`) |
| `droppedRequestMaxCount` | 1000 | Removes the oldest acknowledged entries beyond the limit. Unacknowledged entries are never removed by count |
| `droppedRequestRetention` | 30 days | Removes entries older than this, counted from `droppedAt`, acknowledged or not |

- `0` (`Duration.zero`) removes that limit. A negative value makes `start()` throw `ProxyStartException`.
- A request leaving the quarantine store is recorded in the dropped history before it is removed, keeping the `statusCode` and `errorMessage` it was quarantined with. `requestDropped` carries its `quarantineId`.
- A single request larger than `quarantineMaxBytes` neither enters the quarantine store nor pushes others out. Its body is dropped, it is recorded in the dropped history as `quarantine_too_large`, and it is removed from the queue.
- "Oldest" follows the stored time (`quarantinedAt`, `droppedAt`).
- The limits are checked at startup, whenever a quarantined request or a history entry is added, after a deferred migration, and every hour.
  - They also apply to the quarantine store and dropped history carried over from 0.14.0 or earlier (see [Migrating from 0.14.0 or earlier](#migrating-from-0140-or-earlier)).
  - Events raised by the check at startup do not reach an app that subscribes after `start()`; `ProxyStats.unacknowledgedDroppedCount` still shows the result.
- Hive deletes logically. The boxes are compacted after the checks at startup, after a deferred migration and every hour, but erasure from flash storage is not guaranteed. The same applies to the compaction of the unencrypted boxes (the plain response cache, `proxy_idempotency`, `proxy_port_preferences`) and to the deletion of the web storage boxes.
- Hive loads every value into memory when it opens a box, so opening the quarantine box may briefly use about twice `quarantineMaxBytes`.
- For the limits of the queue, see [Queue and request body limits](#queue-and-request-body-limits).

### Queue and request body limits

From 0.26.0 the request body and the queue are limited, so a broken page or a malicious web page that keeps sending large requests is less likely to use up the memory and storage of the device (up to 0.25.0 neither had a limit).

| Setting | Default | Range | When exceeded |
| --- | --- | --- | --- |
| `maxRequestBodyBytes` | 10 MiB | 1024 to 268435456 (256 MiB) | A request whose body exceeds it is neither forwarded nor queued and gets `413` |
| `queueMaxCount` | 1000 | 1 to 100000 | Not stored; answered with `503` and `{"queued":false,"error":"queue_full"}` |
| `queueMaxBytes` | 50 MiB | 1 MiB to 1 GiB | Not stored; answered with `503` and `{"queued":false,"error":"queue_full"}` |

- A value outside the range makes `start()` throw `ProxyStartException`. `0` cannot remove these limits.
- The `413` is the same online and offline, and the request is never queued. It carries `Cache-Control: no-store`, `X-Offline-Queued: 0` and `Connection: close`, with the body `{"queued":false,"error":"request_body_too_large"}`. `Content-Length` is checked first, and a body over the limit is never kept. So that the client can read the `413`, up to 16 MiB beyond the limit is read and discarded before answering; beyond that the proxy answers without reading and closes the connection (the client may then see the connection closed while sending).
- The bridge of `enableWebStorageInheritance` uses the smaller of `maxRequestBodyBytes` and 5 MiB.
- The size of the queue is the sum, over its requests, of the UTF-8 length of the URL and of the header names and values, plus the length of the body. It is checked before a request is stored. A request that would exceed a limit (including a single request larger than `queueMaxBytes`) is not stored and gets `503` with `{"queued":false,"error":"queue_full"}` and `X-Offline-Queued: 0` (the body tells it apart from `{"queued":false}` for a queue that cannot be written), and `ProxyEventType.errorOccurred` (`phase: queueLimit`, `limit: count` or `bytes`) is raised. An update request answered with an upstream 5xx still gets the upstream answer as is. Bookkeeping fields and the overhead of the stored format are not counted, so memory and storage use are only roughly bounded.
- Requests already queued are never removed because of the limits. When the queue is over a limit at startup (for example after lowering it), nothing is removed either; new requests are refused until sending or quarantining brings the queue under the limit. `retryQuarantinedRequest()` is not refused by the limits.

### Web storage snapshot

With `enableWebStorageInheritance`, the page can save a snapshot of its web storage through `/__offline_web_proxy/web_storage` and read it back after a restart. From 0.26.0:

- The snapshot is stored in the encrypted box `proxy_web_storage_secure`. The plain box `proxy_web_storage` of 0.25.0 and earlier is moved into it at startup (unless the encrypted box already holds a snapshot), then emptied, compacted and deleted. When `enableWebStorageInheritance` is off, no box is opened and the plain box is deleted.
- Only pages of the proxy's own origin are accepted. The origin is compared with the proxy itself (`http`, the port the request came in on, and a host name accepted by the `Host` check, so `127.0.0.1` and `localhost` are treated alike), not with the configured upstream origin.
  - `POST` requires `Origin`. `GET` without `Origin` is accepted.
  - A request whose `Sec-Fetch-Site` is present and neither `same-origin` nor `none` is refused with `403`.
  - Methods other than `GET` and `POST` get `405` (`Allow: GET, POST`).
- Every answer carries `Cache-Control: no-store`. The endpoint is internal: it gets no CORS headers and is not counted in the statistics.
- When `enableWebStorageInheritance` is off, the path is answered with `404` and is never forwarded upstream.
- With `requireAccessToken: false`, another app on the device can read the snapshot with a `GET` without `Origin`. Keep `requireAccessToken` enabled when `enableWebStorageInheritance` is on.
- When the encrypted box is damaged, it is rebuilt, `errorOccurred` (`phase: webStorageRecovery`) is raised, and startup continues.
- If moving the plain box fails, or deleting it with the bridge off fails, startup continues and `errorOccurred` (`phase: webStorageMigration`, `error` is the exception type) is raised; the plain box is kept and handled again at the next start.
- `clearWebStorageSnapshot()` removes the snapshot, for example before signing out or handing the device to someone else. While the box is open it is emptied and compacted; otherwise the files of both boxes are deleted. It can be called whether or not the proxy is running. It throws `CacheOperationException` (`operation: clearWebStorageSnapshot`) when it fails.

### When the encryption key is lost

The encrypted boxes share one key kept in secure storage. Hive truncates a box opened with the wrong key, so before opening the boxes the proxy reads their files, checks them against the key, and acts as follows. The check runs in `start()` and in a cookie API called before `start()` or after `stop()` (after `stop()`, the next `start()` or cookie API checks again).

| Situation | Behavior |
| --- | --- |
| The key cannot be read for now, for example while the device is locked (iOS / macOS) | Startup fails with `StorageIntegrityException` (`temporarilyUnavailable`). Nothing is deleted |
| The key is present and every encrypted box with content matches it (an ordinary update from 0.14.0) | Starts as usual |
| No encrypted box has content (including an update from 0.14.0 whose cookie box is empty) | With a key, starts as usual. With a missing, unreadable or invalid key, a new key is written and the proxy starts |
| The key is present, the queue, quarantine and dropped-history boxes are fine, and the cookie box does not match the key, is damaged at its head or had its check aborted | The cookie box is discarded and startup continues. The user must sign in again |
| The key is unusable (missing or unreadable after rereading, or invalid) and only the cookie box has content | The cookie box is discarded, a new key is written, and startup continues. The user must sign in again |
| The key is present and a queue, quarantine or dropped-history box does not match it, is damaged at its head or had its check aborted | Startup fails with `StorageIntegrityException`. Nothing is deleted |
| The key is unusable and a queue, quarantine or dropped-history box has content | Startup fails with `StorageIntegrityException`. Nothing is deleted |

- Discarding the cookie box raises `ProxyEventType.cookieStorageDiscarded` with the reason in `data['reason']`.
  - The discard happens inside `start()` or a cookie API called before `start()` or after `stop()`, so an app that subscribes later never receives the event.
  - After startup, read `lastCookieStorageDiscardedAt` and `lastCookieStorageDiscardReason` from `getDiagnostics()`.
  - Deletion by the recovery API raises no such event and leaves the diagnostics unchanged.
- A cookie box that passes the check but that Hive still cannot open, or that holds a value that cannot be read as a cookie (a record in the middle is broken), is discarded as `corrupted`, and startup continues. This covers records written by 0.21.0 and earlier with a key over 255 bytes in UTF-8. When the idempotency key records (`proxy_idempotency`) cannot be opened for the same reason, or hold a value that cannot be read as a recorded time, they are rebuilt, startup continues, and `errorOccurred` (`phase: idempotencyStoreRecovery`) reports it.
  - Hive also reports the failed open as an unhandled error in the zone, even after the proxy catches it. On that start, the app's error reporting (such as Crashlytics) may record a `HiveError` or a similar error.
- When the check fails in a cookie API (such as `restoreCookies()`) called before `start()` or after `stop()`, the API throws `CookieOperationException` with `StorageIntegrityException` as its `cause`. The failure is not kept; the next call or `start()` checks again.
- `StorageIntegrityException.failure` tells why:
  - `temporarilyUnavailable`: protected data cannot be read, for example while the device is locked (iOS / macOS). The read result is not used to decide whether a key exists
  - `keyUnreadable`: reading the key keeps throwing
  - `keyMissing`: there is no key
  - `keyInvalid`: the key is malformed (empty, not Base64, or not 32 bytes). ASCII whitespace, such as a trailing newline, is ignored when reading the key, and the error never contains the key string
  - `keyMismatch`, `corrupted`, `verificationAborted`: a box does not match the key, a box is damaged at its head, or checking a box exceeded the time limit
  - `keyWriteFailed`: a new key could not be written
- When an encrypted box has content and the key is missing or unreadable, the key is read up to three more times, 500 milliseconds apart. A value read even once is used. If the results mix `null` and errors, or the device gets locked in the meantime, the key is treated as temporarily unavailable.
- A box whose first record does not match the key, or is only partly written, is searched in full for a record that matches the key, in a separate isolate.
  - A match further in means the box is damaged at its head.
  - No match after a first record that does not match the key means the box does not match the key.
  - No match after a partly written first record means the box stopped during its first write, and it is opened as usual.
  - The search takes at most 10 seconds per box, and the four boxes are checked one after another. A longer search is aborted.
  - When a queue, quarantine or dropped-history box is damaged at its head, does not match the key or had its check aborted, startup fails (`corrupted`, `keyMismatch`, `verificationAborted`) and nothing is deleted. When only the cookie box is in that state, the cookie box is discarded and startup continues.
- A queue, quarantine or dropped-history box damaged at its head is not repaired at startup, because repairing it loses the records at its head. Confirm with the user and call `recoverEncryptedStorage()`.
- The recovery API cannot fix `temporarilyUnavailable` or `keyWriteFailed`. Retry `start()` later.

### Recovering encrypted storage

Call `recoverEncryptedStorage()` when `start()` fails with `StorageIntegrityException` and retries do not help, after explaining to the user what will be lost and obtaining consent.

```dart
// Example for when StorageIntegrityException persists after retrying start()
try {
  await proxy.start(config: config);
} on StorageIntegrityException catch (error) {
  if (error.failure == StorageIntegrityFailure.temporarilyUnavailable ||
      error.failure == StorageIntegrityFailure.keyWriteFailed) {
    // The recovery API cannot fix these. Retry start() later.
    rethrow;
  }

  // Recover only after explaining what will be lost and obtaining consent.
  // askUserToConfirm is a placeholder for a function the app provides.
  if (!await askUserToConfirm(error.failure)) {
    rethrow;
  }
  final result = await proxy.recoverEncryptedStorage();
  if (!result.performed &&
      result.rejection != StorageRecoveryRejection.startWillSucceed) {
    // temporarilyUnavailable / proxyActive / verificationTimedOut: retry later
    rethrow;
  }
  await proxy.start(config: config);
}
```

- Right before deleting anything, the recovery API reads the key again and checks the boxes with the same time limit as `start()`, then acts as follows.
  - Key present and no problem in the queue, quarantine or dropped-history boxes: nothing is done and `startWillSucceed` is returned, because `start()` discards a problematic cookie box on its own.
  - Key present and a problem in some queue, quarantine or dropped-history box: the key is kept, and every box, the cookie box included, is handled as follows.
    - A box that does not match the key is deleted (`deletedBoxes`).
    - A box damaged at its head is rebuilt from the first record that matches the key (`rebuiltBoxes`). **The records at its head are lost, and how many is unknown.**
    - A box whose check exceeded the time limit is checked again after the boxes are closed, with a limit of 2 minutes per box, and handled by that result. A box damaged at its head is checked again the same way to find where to rebuild from.
      - When it does not match the key, it is deleted (`deletedBoxes`).
      - When it is damaged at its head, it is rebuilt (`rebuiltBoxes`).
      - When its first record is only partly written and no record matches the key, it is truncated to 0 bytes (`rebuiltBoxes`). Hive would truncate it on open anyway, so nothing is lost.
    - A box with content and no problem is kept (`keptBoxes`).
  - Key malformed, or missing or unreadable (when an encrypted box has content, still so after rereading):
    - When a queue, quarantine or dropped-history box has content, every encrypted box (cookies, queue, quarantine, dropped history) is deleted, and then the key (`keyDeleted`). **Cookies, and with them the sign-in state, are lost as well.**
    - When no queue, quarantine or dropped-history box has content (only the cookie box has content, or no box has any), nothing is deleted and `startWillSucceed` is returned, because `start()` discards the cookie box or writes a new key on its own. A startup that failed with `keyWriteFailed` falls into this case too.
  - The key cannot be read for now: `temporarilyUnavailable`. A proxy in this isolate is running or starting: `proxyActive`. Checking a box again took longer than 2 minutes: `verificationTimedOut` (new in 0.26.0). Nothing is deleted or rebuilt in any of these cases.
  - On the path for an unusable key, the response cache and the web storage snapshot encrypted with the deleted key are deleted as well (they are not listed in the result).
- The number of encrypted records cannot be read, so the result does not carry it. **After startup fails with `StorageIntegrityException`, `getStats()` reports zero for the queue, quarantine and dropped-history counts, so do not base the confirmation screen on it.**
- Recover from `keyUnreadable` or `keyMissing` only when it persists across retries. A device restored from an Android backup can end up in either state (not verified on a device).
- The plain boxes of 0.14.0 or earlier are not deleted.
- After recovery, `start()` can be called without restarting the process.
- An unexpected failure, such as a box file or the key that cannot be deleted, throws `StorageRecoveryException`.
  - Running the recovery again carries out the rest. Boxes already deleted or rebuilt by an earlier run are not in the new `deletedBoxes` or `rebuiltBoxes`.
  - When, on the path for an unusable key, only deleting the key failed after the encrypted boxes were deleted, running it again returns `startWillSucceed`. The next `start()` replaces the unusable key.
- When the host app calls `FlutterSecureStorage().deleteAll()` with the default options, this key is deleted too.

### Migrating from 0.14.0 or earlier

Starting with 0.15.0, the queue, the quarantine store and the dropped history are stored in encrypted boxes with new names (`proxy_queue_secure`, `proxy_quarantined_requests_secure`, `proxy_dropped_requests_secure`). The plain boxes of 0.14.0 or earlier (`proxy_queue`, `proxy_quarantined_requests`, `proxy_dropped_requests`) are migrated automatically. Their keys are kept, so `X-Offline-Queue-Id` and the quarantine IDs do not change.

- When the key already exists, as in an ordinary update from 0.14.0, the boxes are migrated inside `start()` before resending begins.
- When the proxy instance generated the key itself (including in a cookie API called before `start()`), the migration is put off until 30 seconds after the key was generated, on every platform.
  - Secure storage on Android writes to disk asynchronously, so reading the key back in the same process does not prove it was written.
  - Whether iOS and other platforms commit the write immediately has not been verified on devices either.
  - With no way to confirm that the write was committed, the proxy waits instead. The wait does not guarantee the commit (not verified on a device).
- While the migration waits:
  - Resending from the encrypted queue continues. Requests in the old queue are not sent until they are migrated, so they go after the others. Once migrated, they are sent in stored-time order.
  - `getStats()`, the counts of the status endpoint, and lists such as `getQueuedRequests()` include the old boxes, with `pendingMigration` set to `true` on those items.
  - A quarantined request in the old box can be neither resent nor discarded: `retryQuarantinedRequest()` and `discardQuarantinedRequest()` return `false`, and the administrative endpoints answer `409`.
  - `acknowledgeDroppedRequests()`, `clearQuarantinedRequests()` and `clearDroppedRequests()` also apply to the old boxes.
- If the file of an old box cannot be deleted, the box has already been emptied, so processing continues and `errorOccurred` is raised with `operation: legacyStorageDelete`.
  - When an old box is deleted inside `start()` (the migration when the key already exists, and the deletion of an old box left empty), an app that subscribes after `start()` does not receive this event.
  - An old box left empty is deleted again by the next `start()`.
- **The default retention limits also apply to the quarantine store and dropped history carried over from 0.14.0 or earlier, at the first startup after the update** (after the migration, when it is deferred).
  - Quarantined requests beyond the limits move to the dropped history, which keeps neither their body nor their headers.
  - Dropped history entries older than 30 days are removed even when unacknowledged. Acknowledged entries beyond the count limit are removed as well.
  - To keep them, set the corresponding settings (`quarantineMaxCount`, `quarantineRetention`, `quarantineMaxBytes`, `droppedRequestMaxCount`, `droppedRequestRetention`) to `0` (`Duration.zero` for the periods).
- **Rolling back to 0.14.0 or earlier hides the migrated queue, quarantine store and dropped history.**
  - While rolled back, the migrated unsent queue is not sent.
  - Upgrading to 0.15.0 or later again migrates the requests stored while rolled back as well.
- As before, the legacy plain cookie box (`proxy_cookies`) is migrated when the storage is initialized by `start()` or by a cookie API called before `start()` or after `stop()`. Since 0.15.0, a cookie that already exists in the encrypted box is not overwritten.

### Android Auto Backup

Android Auto Backup may include both Hive's storage directory and the secure storage data (not verified on a device). On a device restored from such a backup, the key for the restored encrypted boxes may be unreadable (`keyUnreadable`) or missing (`keyMissing`) (neither verified on a device). Excluding them from backup in the app is recommended.

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

- Hive encrypts each value with AES-256-CBC but adds no message authentication code (MAC). The CRC detects accidental damage, but a tampered encrypted box is not detected as such: a crafted file can make a value fail to decode or decode into a different value. The proxy keeps the key in secure storage and relies on the app sandbox to protect the files.

- One `OfflineWebProxy` instance forwards application requests to one configured upstream origin. Another origin that only serves resources can be relayed through `mirroredOrigins`, but only for `GET` and `HEAD`.
- `ProxyConfig` is the supported configuration path. External YAML configuration loading is not implemented.
- Static resources under `assets/static/` are served for `GET` and `HEAD` only. An update request on the same path is forwarded upstream instead. Range requests are not supported.
- If `AssetManifest.json` or its runtime equivalent cannot be loaded, the proxy continues with no indexed static resources and falls back to normal upstream resolution.
- Using several `OfflineWebProxy` instances at the same time in one app is not supported. Storage initialization and recovery are serialized across instances within one isolate, but the exclusion for queue draining, retention limits and migration, and the owner of queued requests (`queueOwnerResolver`), belong to each instance. Cookies are shared across instances, so a sign-in through one instance changes the session of the others as well. **The queue of another instance may therefore send requests of the previous owner with the new session (`queueOwnerResolver` does not protect them).** When the proxy is used from several isolates at once, even storage initialization and recovery are not serialized.

## Example and Reference

- See `example/` for a working WebView integration sample focused on navigation delegates.
- The API reference is published on [pub.dev](https://pub.dev/documentation/offline_web_proxy/latest/).
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

### Recovery script regression test

The auto-reload script for the offline fallback page is tested in headless Chrome. You need Node.js and one of Chrome, Chromium, or Microsoft Edge (verified with Node.js 24 and Chrome). CI runs the same steps in the `Recovery Script Test` job.

```bash
dart run tool/offline_recovery_harness/generate_pages.dart build/offline_recovery_harness
node tool/offline_recovery_harness/run.mjs build/offline_recovery_harness
```

- If the `CHROME_PATH` environment variable is set, that executable is used; otherwise the browser is looked up in its standard install locations.
- Add scenario names after the directory passed to `run.mjs` to run only those scenarios. The names are listed in `buildScenarios` in `run.mjs` (for example, `node tool/offline_recovery_harness/run.mjs build/offline_recovery_harness queue_wait_timeout`).
- Running all scenarios took about three and a half minutes on Windows.

### Example e2e tests

CI does not run the e2e tests under `example/integration_test/`. Run them on an Android device or emulator by passing a test file (this procedure was verified on an emulator).

```bash
cd example
flutter test integration_test/offline_web_proxy_offline_page_recovery_e2e_test.dart -d <device id>
```

Find the device ID with `flutter devices`.

`offline_web_proxy_storage_e2e_test.dart` deletes the cookie, queue, quarantine, and dropped-request boxes (including the legacy plain boxes) and the encryption key of the example app before each test. The first test waits for the migration delay of the legacy plain queue (30 seconds), so it takes more than 30 seconds.

The other e2e tests put the secret cookie with `WebViewCookieManager` before loading (`integration_test/support/access_token.dart`), since `requireAccessToken` is enabled by default.

`offline_web_proxy_access_token_e2e_test.dart` checks the steps for using a proxy with `requireAccessToken` from the WebView. The secret cookie is put as HttpOnly with Android's `CookieManager`. The last test prints `OWP_E2E_EXTERNAL_PROBE_PORT=<port>` and then waits 40 seconds. During that window you can send requests from another process, such as `nc` in `adb shell`, to a path other than the health check (`/page`, for example) and confirm that they get `403` and never reach the upstream. The requests are sent by hand from outside the test (the test passes without them). To set HttpOnly, the test imports a file under `src/` of `webview_flutter_android` directly, so a plugin update may break it.

### Dependency updates

Dependabot (`.github/dependabot.yml`) opens pull requests every Monday at 10:00 (UTC) for the pub dependencies of the package and `example/`, and for GitHub Actions.

- Minor and patch pub updates are grouped into one pull request each for the package and `example/`. A major update gets its own pull request per dependency. GitHub Actions updates, majors included, are grouped into one pull request
- The usual CI (tests on Flutter 3.22.0 / 3.24.0, static analysis, package validation) runs on each pull request. Merge only those that pass
- Known vulnerabilities are detected by Dependabot alerts, enabled in the repository settings, and Dependabot security updates open pull requests that fix them
- The e2e tests of `example/` (`integration_test/`) do not run in CI. When a pull request for `example/` updates the WebView packages (such as `webview_flutter`), run the e2e tests on an emulator before merging (see "Example e2e tests")
- The following updates are excluded from Dependabot and are done by hand
  - Majors of `flutter_secure_storage`: it holds the encryption key, so raise it after checking that the stored format stays compatible
  - Majors of dependencies shared by the package and `example/` (`flutter_secure_storage`, `hive_flutter`, `http`, `flutter_lints`): raising only one side breaks the resolution of `example/`, so raise `pubspec.yaml` and `example/pubspec.yaml` to the same version in one pull request
  - Versions that do not work on Flutter 3.22.0 (Dart 3.4) (`flutter_lints` 5 and later, `webview_flutter` 4.10.0 and later): revisit them together with the ignore rules in `.github/dependabot.yml` when the minimum supported Flutter is raised

## Release Process

- Update `pubspec.yaml` and `CHANGELOG.md` first, then commit those changes to `main`.
- Do not run `dart pub publish` manually for releases. This repository publishes via the GitHub Actions `release` job.
- Create and push a version tag such as `v0.8.0`. The `v*` tag push triggers GitHub Actions to run validation, publish to pub.dev, and create the GitHub Release.

## License

MIT License
