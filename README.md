# offline_web_proxy

[![CI/CD Pipeline](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/meibinlab/offline_web_proxy/actions/workflows/ci.yml)
[![Pub Version](https://img.shields.io/pub/v/offline_web_proxy.svg)](https://pub.dev/packages/offline_web_proxy)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Coverage](https://codecov.io/gh/meibinlab/offline_web_proxy/branch/main/graph/badge.svg)](https://codecov.io/gh/meibinlab/offline_web_proxy)

An offline-compatible local proxy server that operates within Flutter WebView. It aims to enable existing web systems to function seamlessly in mobile apps without requiring awareness of online/offline states.

## Features

### Core Functions
- Intercepts HTTP requests from WebView through a local proxy server
- Forwards requests to upstream server when online, serves responses from cache when offline
- Queues update requests (POST/PUT/DELETE) when offline
- Automatically sends queued requests upon online recovery for seamless offline support
- Local serving of static resources

### Offline Support
- Combines RFC-compliant cache control with offline compatibility
- Intelligent cache management based on Cache-Control and Expires headers
- Ignores no-cache directives and uses stale cache when offline
- Prevents duplicate execution through idempotency guarantees

### Queuing System
- Guarantees request order through FIFO (First In, First Out)
- Automatic retry with exponential backoff
- Persistence for continued processing after restarts

### Cookie Management
- RFC-compliant cookie evaluation and management
- AES-256 encrypted persistence
- High-speed access through memory caching

## Installation

Add the following to your `pubspec.yaml`:

```yaml
dependencies:
  offline_web_proxy: ^0.2.1
  # Add the following if using WebView
  # webview_flutter: ^4.4.2
```

## Usage

### Basic Setup

```dart
import 'package:offline_web_proxy/offline_web_proxy.dart';
// Note: Add the following dependency if using WebView
// import 'package:webview_flutter/webview_flutter.dart';

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late OfflineWebProxy proxy;
  int? proxyPort;
  
  @override
  void initState() {
    super.initState();
    _startProxy();
  }
  
  Future<void> _startProxy() async {
    proxy = OfflineWebProxy();
    
    // Configuration object (optional)
    final config = ProxyConfig(
      origin: 'https://api.example.com', // Upstream server URL
      cacheMaxSize: 200 * 1024 * 1024,   // Maximum cache size (200MB)
    );
    
    // Start proxy server
    proxyPort = await proxy.start(config: config);
    print('Proxy server started: http://127.0.0.1:$proxyPort');
    
    setState(() {});
  }
  
  @override
  void dispose() {
    proxy.stop();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    if (proxyPort == null) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    
    return Scaffold(
      appBar: AppBar(title: Text('Offline-Ready WebView')),
      body: WebView(
        initialUrl: 'http://127.0.0.1:$proxyPort/app',
        javascriptMode: JavascriptMode.unrestricted,
      ), // Note: webview_flutter dependency required
    );
  }
}
```

### Advanced Configuration with Configuration File

Create `assets/config/config.yaml` for detailed configuration:

```yaml
proxy:
  server:
    origin: "https://api.example.com"
    
  cache:
    maxSizeBytes: 209715200 # 200MB
    ttl:
      "text/html": 3600      # HTML: 1 hour
      "text/css": 86400      # CSS: 24 hours
      "image/*": 604800      # Images: 7 days
      "default": 86400       # Others: 24 hours
    
    # Startup cache update
    startup:
      enabled: true
      paths:
        - "/config"
        - "/user/profile"
        - "/assets/app.css"
      
  queue:
    drainIntervalSeconds: 3  # Queue processing interval
    retryBackoffSeconds: [1, 2, 5, 10, 20, 30] # Retry intervals
    
  timeouts:
    connect: 10   # Connection timeout
    request: 60   # Request timeout
```

### Static Resource Serving

Place files in the app's `assets/static/` folder for local serving:

```
assets/
├── static/
│   ├── app.css      # Served at http://127.0.0.1:port/app.css
│   ├── app.js       # Served at http://127.0.0.1:port/app.js
│   └── images/
│       └── logo.png # Served at http://127.0.0.1:port/images/logo.png
└── config/
    └── config.yaml
```

### Cache Management

```dart
// Clear all cache
await proxy.clearCache();

// Clear only expired cache
await proxy.clearExpiredCache();

// Clear cache for specific URL
await proxy.clearCacheForUrl('https://api.example.com/data');

// Get cache statistics
final stats = await proxy.getCacheStats();
print('Cache hit rate: ${stats.hitRate}%');

// Get cache list
final cacheList = await proxy.getCacheList();
for (final entry in cacheList) {
  print('URL: ${entry.url}, Status: ${entry.status}');
}

// Pre-warm cache
final result = await proxy.warmupCache(
  paths: ['/config', '/user/profile'],
  onProgress: (completed, total) {
    print('Progress: $completed/$total');
  },
);
```

### Cookie Management

```dart
// Get cookie list (values are masked)
final cookies = await proxy.getCookies();
for (final cookie in cookies) {
  print('${cookie.name}: ${cookie.value} (${cookie.domain})');
}

// Clear all cookies
await proxy.clearCookies();

// Clear cookies for specific domain
await proxy.clearCookies(domain: 'example.com');
```

### Queue Management

```dart
// Check queued requests
final queued = await proxy.getQueuedRequests();
print('Queued: ${queued.length} requests');

// Get dropped request history
final dropped = await proxy.getDroppedRequests();
for (final request in dropped) {
  print('${request.url}: ${request.dropReason}');
}

// Clear drop history
await proxy.clearDroppedRequests();
```

### Real-time Monitoring

```dart
// Monitor proxy events
proxy.events.listen((event) {
  switch (event.type) {
    case ProxyEventType.cacheHit:
      print('Cache hit: ${event.url}');
      break;
    case ProxyEventType.requestQueued:
      print('Queued: ${event.url}');
      break;
    case ProxyEventType.queueDrained:
      print('Queue drained: ${event.url}');
      break;
  }
});

// Get statistics
final stats = await proxy.getStats();
print('Total requests: ${stats.totalRequests}');
print('Cache hit rate: ${stats.cacheHitRate}%');
print('Uptime: ${stats.uptime}');
```

## Architecture

### Communication Flow

```
WebView → http://127.0.0.1:<port> → OfflineWebProxy
                                           ↓
                                    [Online Check]
                                           ↓
                              ┌──────────────────────┐
                              │                      │
                         [Online]               [Offline]
                              │                      │
                              ↓                      ↓
                      ┌─────────────┐        ┌─────────────┐
                      │Forward to   │        │Serve from   │
                      │upstream     │        │cache        │
                      └─────────────┘        └─────────────┘
                              │                      │
                              ↓                      ↓
                      ┌─────────────┐        ┌─────────────┐
                      │Save response│        │Queue        │
                      │to cache     │        │POST/PUT/    │
                      └─────────────┘        │DELETE       │
                                             └─────────────┘
```

### Cache Strategy

1. **Fresh**: Within TTL → Use directly
2. **Stale**: TTL expired but within stale period
   - Online: Validate with conditional requests
   - Offline: Use stale cache
3. **Expired**: Stale period also exceeded → Deletion target

### Security

- **Local Binding**: Bind only to 127.0.0.1 to prevent external access
- **Cookie Encryption**: Persist cookies with AES-256 encryption
- **Path Traversal Prevention**: Restrict access to `assets/static/` subdirectory
- **Log Masking**: Mask sensitive information like Authorization and Cookie headers

## Platform Support

### iOS Configuration

Add ATS exception to `ios/Runner/Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

### Android Configuration

Create `android/app/src/main/res/xml/network_security_config.xml`:

```xml
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
```

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<application
    android:networkSecurityConfig="@xml/network_security_config">
```

## License

MIT License

## Dependencies

This plugin uses the following packages:

- [shelf](https://pub.dev/packages/shelf) - HTTP server framework
- [shelf_proxy](https://pub.dev/packages/shelf_proxy) - Proxy functionality
- [shelf_router](https://pub.dev/packages/shelf_router) - Routing
- [connectivity_plus](https://pub.dev/packages/connectivity_plus) - Network status monitoring
- [hive](https://pub.dev/packages/hive) - Database (SQLite alternative)
- [path_provider](https://pub.dev/packages/path_provider) - File path access

## Support

Please report bugs and feature requests to [GitHub Issues](https://github.com/meibinlab/offline_web_proxy/issues).

## Developer Guide

### Debug Features

Debug features available during development:

```yaml
debug:
  enableAdminApi: true        # Enable admin API
  cacheInspection: true       # Cache content inspection
  detailedHeaders: true       # Detailed header information
```

**Note**: Always set to `false` in production environments.

### Log Level

```yaml
logging:
  level: "debug"                    # debug/info/warn/error
  maskSensitiveHeaders: true        # Mask sensitive information
```

### Performance Monitoring

```dart
// Periodic statistics collection
Timer.periodic(Duration(minutes: 5), (timer) async {
  final stats = await proxy.getStats();
  print('Cache hit rate: ${stats.cacheHitRate}%');
  print('Queue length: ${stats.queueLength}');
});
```
