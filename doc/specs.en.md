# offline_web_proxy Specification

A local proxy server with offline support that runs within a Flutter app.
The purpose is to enable existing web systems to work as apps without being aware of online/offline status.

This proxy server relays HTTP requests sent from WebView, forwarding them to the upstream server when online, and returning responses from cache when offline. Additionally, it provides seamless offline support by storing update requests (POST/PUT/DELETE) in a queue when offline and automatically sending them when connectivity is restored.

---

## [1] Basic Configuration

### Architecture Overview

- **Base Technology**: shelf (Dart's lightweight HTTP server framework), shelf_router (routing), shelf_proxy (proxy functionality)
- **Communication Path**: WebView → http://127.0.0.1:<port> → (proxy) → Upstream Server
- **Data Persistence**: Local storage using Hive
- **Cache-Control Support**: RFC-compliant cache control combined with offline support

### Data Processing Strategy

- **Cache**: Store GET request responses in file-based storage. Achieve fast offline responses while considering Cache-Control headers
- **Queue**: Manage POST/PUT/DELETE requests in FIFO (First In First Out). Send sequentially when network recovers
- **Offline Response**: Return cache when cache hit, display fallback page when uncached
- **Static Resources**: Serve files bundled in the app's assets/ folder locally (CSS, JS, images, etc.)

### Proxy Target

Relays to the upstream origin server (e.g., https://sample.com). Supports a single origin server.

## [2] Port and Connection Specifications

### Port Management

- **Automatic Assignment**: System automatically selects an available port. Avoids port conflicts
- **Return Value**: Returns the actual port number used when proxy server starts
- **Bind Target**: Only 127.0.0.1 (local loopback). Prevents external access

### Security Considerations

- **HTTPS Not Required**: localhost is treated as a secure context by browsers, so HTTP is sufficient
- **External Access Restriction**: Completely blocks access from outside the device by binding to 127.0.0.1

## [3] Static Resource Detection

### Detection Logic

Automatically detects static resources by checking if a local file exists under `assets/static/` corresponding to the request path. No explicit specification in configuration files is required; files are automatically recognized as static resources simply by placement.

### Automatic Mapping Feature

Correspondence between request URL and local files:

```
Request: http://127.0.0.1:8080/app.css
           ↓
File Check: assets/static/app.css
           ↓
If exists: Return local file
If not exists: Proxy forward to upstream server or use cache
```

### URL Normalization Processing

- **Slash Compression**: Convert `//` to `/`
- **Relative Path Resolution**: Properly resolve `../` and `./`
- **Path Traversal Prevention**: Reject paths containing `../`, strictly limit to under `assets/static/`
- **Case Sensitivity**: Always distinguish case regardless of file system

### Processing Flow

1. Normalize request URL
2. Check for path traversal attacks
3. Check for corresponding file under `assets/static/`
4. If exists: Return local file (auto-detect Content-Type)
5. If not exists: Proxy forward to upstream server

### Performance Optimization

- **Existence Check Cache**: Memory cache file existence check results
- **Content-Type Cache**: Cache Content-Type determination results based on extensions
- **Startup Scan**: Scan `assets/static/` at app startup to build an in-memory list of existing files

### Security Measures

- **Path Restriction**: Only accessible under `assets/static/`
- **Path Traversal Prevention**: Strictly check `../`, `./`, absolute paths, etc.
- **Filename Validation**: Reject invalid filename patterns

### Automatic Content-Type Detection

Automatic Content-Type setting based on extensions:

```
.html → text/html; charset=utf-8
.css  → text/css; charset=utf-8
.js   → application/javascript; charset=utf-8
.json → application/json; charset=utf-8
.png  → image/png
.jpg  → image/jpeg
.woff2 → font/woff2
(Others) → application/octet-stream
```

## [4] Cookie Jar Persistence and Protection

### Storage Strategy

- **Persistence Required**: Persist all cookies in file-based storage. Retain even after app restart
- **Encryption**: Encrypt and save cookie data using AES-256
- **Memory Cache**: Cache cookies loaded from files in memory for fast access

### Cookie Evaluation Criteria

Implement RFC-compliant cookie evaluation:

- **Domain**: Validate the domain for which the cookie is valid
- **Path**: Validate the path for which the cookie is valid
- **Expires/Max-Age**: Manage cookie expiration
- **Secure**: Control cookies that are only sent over HTTPS connections
- **SameSite**: Process SameSite attribute for CSRF attack prevention

### Management Methods

Provides methods for cookie management. See [20] API Reference for details.

- **`getCookies()`**: Get list of currently stored cookies (values returned masked)
- **`clearCookies()`**: Delete all cookies

## [5] Queue Resend Policy

### Queue Management

- **FIFO Guarantee**: Strictly maintain request order. Preserve data consistency
- **Persistence**: Save queue state with Hive. Continue resending after app restart

### Retry Strategy

- **Exponential Backoff**: Gradually increase wait time after initial failure (1 sec → 2 sec → 4 sec...)
- **Infinite Retry**: Retry persistently in case of network errors
- **Jitter**: Add ±20% random wait time to avoid load concentration from simultaneous retries

### Drop Conditions

Remove requests from queue in the following cases:

- **4xx Errors**: Client errors (authentication failure, invalid request, etc.)
- **5xx Errors**: Server errors where retry is meaningless

### History Management

Provides methods for queue management. See [20] API Reference for details.

- **`getDroppedRequests()`**: Get history of dropped requests. Useful for debugging and troubleshooting

## [6] Idempotency

### Duplicate Request Prevention

Use idempotency keys to prevent duplicate execution of the same request.

### Supported Headers

- **Idempotency-Key**: Standard idempotency key (priority)
- **X-Request-ID**: Custom request ID (alternative)

### Retention Period

- **24 Hours**: Retain idempotency key for 24 hours. After expiration, treat as new request
- **Storage**: Persist with Hive. Valid even after app restart

## [7] Response Compression

### Coordination with Upstream Server

- **Accept-Encoding Management**: Properly convey client's compression support status to upstream server
- **Decompression Processing**: Decompress compressed responses (gzip, deflate) from upstream server at the proxy and forward to client
  - Communication with upstream server remains compressed to save bandwidth
  - Forward uncompressed to client (local communication, so bandwidth is not an issue)
  - Remove Content-Encoding header and update Content-Length

### Uncompressed Option

- **identity Specification**: Can force uncompressed response by specifying `Accept-Encoding: identity`
- **Use Case**: Useful for debugging or direct examination of response content

## [8] Cache Consistency

### Cache-Control Support and Offline Strategy

#### Cache-Control Processing When Online

Control cache behavior based on response Cache-Control header:

- **max-age**: Set cache expiration time with specified seconds
- **no-cache**: Do not use cache without validation, but **exceptionally use cache when offline**
- **no-store**: Do not save to cache (can be overridden by configuration for offline support)
- **must-revalidate**: Must validate with upstream server when expired
- **public/private**: Control cache shareability
- **s-maxage**: Proxy cache-specific expiration time (takes priority over max-age)

#### Special Rules for Offline Support

In addition to standard Cache-Control directives, implement special behavior for offline support:

1. **Ignore no-cache**: Even if `no-cache` is specified, use cache when offline
2. **Relax no-store**: Can ignore `no-store` and save cache depending on configuration
3. **Allow Expired**: Return expired cache with `X-Cache-Status: stale` header when offline
4. **Force Cache**: Important resources are forcibly cached regardless of Cache-Control

#### Cache Expiration Calculation Priority

1. **Cache-Control: s-maxage** (proxy-specific)
2. **Cache-Control: max-age** (general expiration time)
3. **Expires** header (HTTP/1.0 compatibility)
4. **Default TTL in configuration file** (when all above are unspecified)

#### Conditional Request Support

Process the following headers for cache validation:

- **If-Modified-Since / Last-Modified**: Validation by modification date
- **If-None-Match / ETag**: Validation by entity tag
- **304 Not Modified**: Response when cache is valid

### Cache File Format

Integrate metadata and content into a single file to simplify management:

#### File Structure

```
[Header Section]
CACHE_VERSION: 1.0
CREATED_AT: 2024-01-01T12:00:00Z
EXPIRES_AT: 2024-01-02T12:00:00Z
STATUS_CODE: 200
CONTENT_TYPE: text/html; charset=utf-8
CONTENT_LENGTH: 1234
CACHE_CONTROL: max-age=3600, public
ETAG: "abc123"
LAST_MODIFIED: Mon, 01 Jan 2024 12:00:00 GMT
X_ORIGINAL_URL: https://example.com/page

[Body Section]
<html>Actual response content</html>
```

#### Benefits of HTTP Protocol Compliance

- **Standards Compliance**: Same header/body separation method as HTTP/1.1 specification
- **Easy Parsing**: Can reuse existing HTTP parser libraries
- **Readability**: Intuitive and easy to understand for developers
- **Debug Efficiency**: Can directly check cache files with HTTP tools

#### Separation Method Details

- **Header Terminator**: Separate header and body sections with CRLF CRLF (`\r\n\r\n`)
- **Line Separator**: Separate each header line with CRLF (`\r\n`)
- **Compatibility**: Flexibly support environments with LF only (`\n\n`)

#### Benefits

- **Atomicity Guarantee**: Metadata and content synchronized with a single file write
- **Eliminate Fragment Problem**: Metadata and content always consistent
- **Simplified Management**: File count reduced by half, disk capacity also reduced
- **Read Efficiency**: Get metadata and content with a single file access
- **HTTP Compatibility**: Saved in standard HTTP message format

#### Drawbacks and Countermeasures

- **No Partial Reading**: Must read entire file even when only metadata is needed
  → **Countermeasure**: Keep header section size small (usually under 1KB), minimize impact
- **Large File Processing**: High cost of checking metadata for large files
  → **Countermeasure**: Read only fixed number of bytes (e.g., 4KB) from file beginning to parse headers

### Atomic Operations

Greatly simplified by single file format:

- **Via Temporary File**: Write header and body sections to temporary file simultaneously with response reception
- **Atomic Move**: After write completion, move to official cache file with rename operation
- **Exclusive Control**: Prevent race conditions during file operations
- **No Backup Needed**: Single file format reduces risk of partial corruption

### Consistency Check (Simplified)

- **Header Validation**: Check if header format at file beginning is correct
- **Separator Confirmation**: Confirm existence of CRLF CRLF (`\r\n\r\n`) or LF LF (`\n\n`)
- **Size Consistency**: Verify actual body section size against `CONTENT_LENGTH`
- **When Corruption Detected**: Delete entire file (no partial repair)

### Performance Optimization

Optimization leveraging single file format advantages:

#### Cache Index

- **Hive Index**: Index by URL, expiration time, file size, etc.
- **Metadata Cache**: Keep frequently accessed metadata in memory
- **Lazy Loading**: Read body section only when necessary

#### Streaming Support

- **Large Files**: Stream body section after reading header section
- **Range Specification**: Can partially deliver within single file for future Range support

#### HTTP Parser Utilization

- **Library Reuse**: Parse header section with existing HTTP message parser
- **Validation**: Directly utilize HTTP header validation functionality
- **Extensibility**: Automatically support future new HTTP headers

### File Naming Convention

```
cache/
├── content/
│   ├── ab/
│   │   ├── cd1234abcd5678ef90...cache     # Integrated cache file
│   │   └── ef9876543210abcd...cache       # Other cache
│   └── gh/
│       └── ij5678901234cdef...cache
└── index.hive                             # Cache index
```

#### URL Hashing

Perform normalization processing before hashing URL to generate consistent hash values:

##### Normalization Steps

1. **URL Decode**: Decode all percent-encoding (%20, etc.)
2. **Scheme Normalization**: Unify `HTTP` → `http`, `HTTPS` → `https`
3. **Hostname Normalization**: Convert uppercase to lowercase (`Example.COM` → `example.com`)
4. **Port Normalization**: Omit default ports (http:80, https:443)
5. **Path Normalization**:
   - Compress consecutive slashes (`//` → `/`)
   - Resolve dot notation (`./`, `../`)
   - Unify trailing slash (add/remove according to configuration)
6. **Query Parameter Normalization**:
   - Sort parameters by key name
   - URL encode values (UTF-8, RFC 3986 compliant)
7. **Fragment Removal**: Remove `#fragment` part (does not affect cache key)
8. **UTF-8 Encoding**: Finally encode in UTF-8 before hashing

##### Normalization Example

```
Input URL: https://Example.COM:443/path//to/../page?b=2&a=1#fragment
                                  ↓
After normalization: https://example.com/path/page?a=1&b=2
                                  ↓
SHA-256: a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456
```

##### Hash Collision Countermeasure

- **SHA-256**: Hash URL with SHA-256 and use for filename
- **Collision Detection**: Verify actual URL with `X_ORIGINAL_URL` header in file
- **Processing on Collision**:
  1. Read cache file
  2. Compare `X_ORIGINAL_URL` with normalized URL
  3. Treat as cache miss if mismatch
  4. Overwrite with new cache file

##### Hierarchical Directory Structure

- **Subdirectory**: Create subdirectory with first 2 characters of hash
- **Load Distribution**: Limit number of files per directory (usually under 1000 files)
- **Example**: Hash `abcd1234...` → `cache/content/ab/cd1234...cache`

## [9] Content Type and Character Encoding

### Content-Type Processing

- **Upstream Priority**: Prioritize upstream server's Content-Type header
- **Character Encoding Completion**: Automatically append `charset=utf-8` if character encoding is unspecified for text-type Content-Type
- **Default**: Use `application/octet-stream` if Content-Type is completely unspecified

## [10] Offline Response

### Response Types and Headers

Add custom headers for debugging to offline responses:

#### On Cache Hit

- **Status**: 200 OK
- **Custom Headers**:
  - `X-Offline: 1`
  - `X-Offline-Source: cache`
  - `X-Cache-Status: hit` (cache within expiration)
  - `X-Cache-Status: stale` (cache expired but used because offline)
  - `X-Cache-Control-Override: 1` (when no-cache, etc. ignored)
- **Content**: Return cached response as-is

#### On Fallback

- **Status**: 200 OK
- **Custom Headers**: `X-Offline-Source: fallback`
- **Content**: Pre-prepared fallback page ("You are offline", etc.)

#### When Unsupported

- **Status**: 504 Gateway Timeout
- **Custom Headers**: `X-Offline-Source: none`
- **Content**: Error page for offline not supported

### Processing Cache-Control Response Headers

Preserve original Cache-Control header as much as possible even in offline responses:

- **Original Retention**: Save original value in `X-Original-Cache-Control` header
- **Expiration Display**: Add `Cache-Control: no-cache` for expired cache
- **Offline Identification**: Add `offline-fallback` extension to `Cache-Control` (for debugging)

## [11] Root Path Processing

### Path Interpretation

- **Handling `/`**: Process root path `/` as-is, do not automatically redirect to `index.html`
- **Reason**: Should not be changed on proxy side as it depends on upstream server routing configuration

## [12] Range Request: Not Supported

### Reason for Non-Support

- **Implementation Complexity**: Partial request processing is complexly intertwined with cache mechanism
- **Limited Use**: Mainly used for video streaming, etc., low necessity in general web apps
- **Alternative**: Cache entire content and partially use on client side

## [13] ServiceWorker: Not Supported

### Reason for Non-Support

- **Avoid Conflict**: If both ServiceWorker and proxy server exist, request processing may conflict
- **Complexity**: Management of ServiceWorker registration/update/deletion is complex
- **Alternative**: Proxy server substitutes for ServiceWorker role

## [14] Header Rewriting Granularity

### Hop-by-hop Headers

- **Processing**: Fixed drop (remove headers valid only between proxies like Connection, Upgrade)

### Authorization Header

- **passthrough**: Forward as-is
- **inject**: Inject configured authentication information
- **off**: Remove header

### Cookie Header

- **jar**: Use cookies managed by Cookie Jar
- **passthrough**: Forward cookies from client as-is
- **off**: Remove Cookie header

### Set-Cookie Header

- **capture**: Save cookies in Cookie Jar
- **passthrough**: Pass through as-is

### Origin/Referer Headers

- **replace**: Rewrite to upstream server's origin
- **passthrough**: Forward as-is
- **remove**: Remove header

### Accept-Encoding Header

- **managed**: Proxy manages compression
- **passthrough**: Forward client settings as-is
- **identity-downstream**: Send uncompressed to downstream

### Location Header

- **rewrite**: Rewrite to proxy server's URL
- **passthrough**: Pass through as-is

## [15] Timeout/Retry Default Values

### Timeout Settings

- **connectTimeout**: 10 seconds (TCP connection establishment time limit)
- **sendTimeout**: 15 seconds (request send time limit)
- **receiveTimeout**: 30 seconds (response receive time limit)
- **requestTimeout**: 60 seconds (entire request time limit)

### Backoff Strategy

- **Interval**: Gradual extension of [1, 2, 5, 10, 20, 30] seconds
- **Retry**: Infinite retry (in case of network errors)
- **Jitter**: Add ±20% random element for load distribution

### Queue Processing

- **Drain Interval**: Check queue every 3 seconds and process unsent requests

## [16] Cache Capacity and TTL

### Capacity Limit

- **maxCacheBytes**: 200MB (default value)
- **LRU Deletion**: Delete oldest cache first when capacity exceeded
- **Priority Management by Importance**: Differentiate deletion priority between static resources and API responses

### TTL (Time to Live) and Stale Period Management

Flexible TTL calculation and stale period setting considering Cache-Control headers:

#### Calculation Logic

1. **Cache-Control: s-maxage=X**: Use X seconds as TTL (proxy-specific)
2. **Cache-Control: max-age=X**: Use X seconds as TTL
3. **Expires**: Calculate TTL as difference from Date header
4. **Default TTL**: Apply default value according to Content-Type if all above are unspecified
   - text/html: 1 hour
   - text/css, application/javascript: 24 hours
   - image/\*: 7 days
   - Others: ttlDays in configuration file

#### Cache State Management

Cache is managed in the following 3 states and is not immediately deleted even after TTL expiration:

##### 1. Fresh

- **Condition**: Within TTL period
- **Behavior**: Use cache regardless of online/offline
- **Header**: `X-Cache-Status: hit`

##### 2. Stale

- **Condition**: TTL expired, but within stale period
- **Behavior**:
  - **When Online**: Validate with upstream server (conditional request), use stale on error
  - **When Offline**: Use stale cache
- **Header**: `X-Cache-Status: stale`

##### 3. Expired

- **Condition**: Stale period also exceeded
- **Behavior**: Do not use cache, target for deletion
- **Deletion**: Deleted in next purge process

#### Stale Period Setting

```yaml
cache:
  stalePeriod:
    "text/html": 86400 # 1 day (retain as stale for 1 day after TTL expiration)
    "text/css": 604800 # 7 days
    "image/*": 2592000 # 30 days
    "default": 259200 # 3 days
  maxStalePeriod: 2592000 # Maximum stale period (30 days)
```

#### Special Directive Processing

- **no-cache**: Validate every time when online, can use stale when offline
- **no-store**: Can be ignored by configuration (`ignoreNoStore: true`)
- **must-revalidate**: Mark forced validation when expired (ignore when offline and use stale)

### Cache Deletion Timing

#### Automatic Deletion (Periodic Purge)

- **Execution Interval**: Every 1 hour
- **Deletion Target**:
  1. **Expired state** cache (stale period also exceeded)
  2. **Corrupted cache** (consistency check failed)
  3. **LRU deletion when capacity exceeded** (target for deletion even in stale state)

#### Manual Deletion Methods

Provides methods for cache management. See [20] API Reference for details.

- **`clearCache()`**: Delete all cache immediately
- **`clearExpiredCache()`**: Delete only Expired state cache
- **`clearCacheForUrl(String url)`**: Delete cache for specific URL

#### Emergency Deletion

- **Disk Space Shortage**: Delete even in stale state when free space falls below configured value
- **Corruption Detection**: Delete immediately when corruption detected during file reading

#### App Lifecycle Integration

- **App Startup**: Detect and delete corrupted cache
- **App Termination**: Clear memory cache (retain file cache)
- **Configuration Change**: Recalculate expiration of existing cache when TTL settings change

### Cache Usage Priority

Judgment order during request processing:

#### When Online

1. **Fresh state**: Use as-is
2. **Stale state**: Validate with conditional request
   - **304 Not Modified**: Continue using cache (reset TTL)
   - **200 OK**: Update cache with new response
   - **Network Error**: Use stale cache
3. **Expired/Uncached**: Fetch from upstream server

#### When Offline

1. **Fresh state**: Use as-is
2. **Stale state**: Use as-is (`X-Cache-Status: stale`)
3. **Expired/Uncached**: Fallback or 504 error

### Maintenance

- **Purge Execution**: Automatically execute Expired cache deletion and LRU cleanup every 1 hour
- **Cache-Control Validation**: Periodically re-evaluate Cache-Control information of saved cache
- **Statistics**: Log output of cache hit rate, stale usage rate, no-cache ignore count, etc.

### Configuration Example

```yaml
# Offline Web Proxy Configuration File
# assets/config/config.yaml
#
# All configuration items are optional.
# Default values shown below are automatically used for unset items.

proxy:
  # Server basic settings
  server:
    port: 0 # 0=automatic assignment
    host: "127.0.0.1" # Local bind
    origin: "" # Upstream server URL (default is empty, required setting)
      # Example: "https://api.example.com"

  # Cache settings
  cache:
    maxSizeBytes: 209715200 # 200MB
    purgeIntervalSeconds: 3600 # Every 1 hour

    # Startup update settings
    startup:
      enabled: false # Enable startup update
      paths: [] # Path list to update at startup (default is empty)
        # - "/config"
        # - "/user/profile"
        # - "/assets/app.css"
      timeout: 30 # Timeout for each path (seconds)
      maxConcurrency: 3 # Number of concurrent executions
      onFailure: "continue" # continue/abort

    # TTL settings (seconds)
    ttl:
      "text/html": 3600 # 1 hour
      "text/css": 86400 # 24 hours
      "application/javascript": 86400 # 24 hours
      "image/*": 604800 # 7 days
      "default": 86400 # 24 hours

    # Stale period settings (retention period after TTL expiration)
    stale:
      "text/html": 86400 # 1 day
      "text/css": 604800 # 7 days
      "image/*": 2592000 # 30 days
      "default": 259200 # 3 days
      maxPeriodSeconds: 2592000 # Maximum 30 days

    # Cache-Control override
    override:
      ignoreNoStore: true # Ignore no-store
      ignoreMustRevalidate: true # Ignore must-revalidate when offline
      forceCache: # Force cache targets
        - "/static/*"
        - "*.woff2"
        - "*.ttf"

  # Request queue settings
  queue:
    drainIntervalSeconds: 3 # Queue drain interval
    retryBackoffSeconds: [1, 2, 5, 10, 20, 30, 60] # Backoff interval
    jitterPercent: 20 # ±20%

  # Timeout settings (seconds)
  timeouts:
    connect: 10 # TCP connection establishment
    send: 15 # Request send
    receive: 30 # Response receive
    request: 60 # Entire request

  # Idempotency settings
  idempotency:
    retentionHours: 24 # Idempotency key retention period

  # Header rewriting settings (default is empty, configure as needed)
  headers: {} # Empty object=default behavior (default)
    # authorization: "passthrough"  # Example: passthrough/inject/off
    # cookies: "jar"                # Example: jar/passthrough/off
    # setCookies: "capture"         # Example: capture/passthrough
    # origin: "replace"             # Example: replace/passthrough/remove
    # referer: "replace"            # Example: replace/passthrough/remove
    # acceptEncoding: "managed"     # Example: managed/passthrough/identity-downstream
    # location: "rewrite"           # Example: rewrite/passthrough

  # Fallback settings
  fallback:
    offlinePage: "assets/fallback/offline.html"
    errorPage: "assets/fallback/error.html"

  # Logging settings
  logging:
    level: "info" # debug/info/warn/error
    maskSensitiveHeaders: true # Mask Authorization/Cookie, etc.

  # Development/debug settings
  debug:
    enableAdminApi: false # Security-focused, recommend true only during development
    cacheInspection: false # Security-focused, recommend true only during development
    detailedHeaders: false # Performance-focused, recommend true only during development
```

## [17] Thread Safety

### Synchronization Control

Cache operations (put/get/purge) implement exclusive control through serialization (mutex). Guarantees data consistency even when multiple requests access cache simultaneously.

### Implementation Policy

- **Read-Write Separation**: Execute read-only operations concurrently as much as possible
- **Write Exclusion**: Completely exclusive control for write operations
- **Deadlock Avoidance**: Unify lock acquisition order to prevent deadlock

## [18] Logging and Personal Information Protection

### Log Level

- **Default Level**: info (level suitable for production operation)
- **Debug**: Do not output confidential information even when debug is specified

### Masking Targets

- **Authorization**: Authentication information such as Bearer token
- **Cookie**: Confidential cookie values such as session ID
- **Set-Cookie**: Cookie values set in response

### Log Output Example

```
INFO: GET /api/user → 200 OK (Authorization: ***, Cookie: ***)
```

## [19] Platform-Specific Notes

### iOS (App Transport Security)

- **ATS Exception**: Configuration required to allow HTTP connection to 127.0.0.1
- **Info.plist Configuration**:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

### Android (Network Security Config)

- **cleartext Exception**: Allow HTTP connection to 127.0.0.1
- **network_security_config.xml Configuration**:

```xml
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
```

### Recommendations

- **Use IP Address**: Recommend using `127.0.0.1` over `localhost`
- **Reason**: Name resolution of localhost may be unstable depending on platform

## [20] API Reference

### Basic Operations

#### `Future<int> start({ProxyConfig? config})`

Starts the proxy server.

- **Parameters**:
  - `config`: Configuration object (uses default or file configuration when omitted)
- **Return Value**: Actually used port number
- **Exceptions**:
  - `ProxyStartException`: When server startup fails
  - `PortBindException`: When port binding fails

```dart
final proxy = OfflineWebProxy();
final port = await proxy.start();
print('Proxy started on port: $port');
```

#### `Future<void> stop()`

Stops the proxy server.

- **Return Value**: None
- **Exceptions**:
  - `ProxyStopException`: When server stop fails

```dart
await proxy.stop();
```

#### `bool get isRunning`

Gets the operational state of the proxy server.

- **Return Value**: `true` if server is running

### Cache Management

#### `Future<void> clearCache()`

Deletes all cache immediately.

- **Return Value**: None
- **Exceptions**:
  - `CacheOperationException`: When cache deletion fails

```dart
await proxy.clearCache();
```

#### `Future<void> clearExpiredCache()`

Deletes only Expired state cache.

- **Return Value**: None
- **Exceptions**:
  - `CacheOperationException`: When cache deletion fails

```dart
await proxy.clearExpiredCache();
```

#### `Future<void> clearCacheForUrl(String url)`

Deletes cache for a specific URL.

- **Parameters**:
  - `url`: URL to delete (normalized then hashed)
- **Return Value**: None
- **Exceptions**:
  - `ArgumentError`: When invalid URL is specified
  - `CacheOperationException`: When cache deletion fails

```dart
await proxy.clearCacheForUrl('https://example.com/api/data');
```

#### `Future<List<CacheEntry>> getCacheList({int? limit, int? offset})`

Gets list of cache entries.

- **Parameters**:
  - `limit`: Upper limit of items to retrieve (default: 100)
  - `offset`: Starting position for retrieval (default: 0)
- **Return Value**: List of cache entries
- **Exceptions**:
  - `CacheOperationException`: When cache retrieval fails

```dart
final cacheList = await proxy.getCacheList(limit: 50);
for (final entry in cacheList) {
  print('URL: ${entry.url}, Status: ${entry.status}');
}
```

#### `Future<CacheStats> getCacheStats()`

Gets cache statistics.

- **Return Value**: Cache statistics
- **Exceptions**:
  - `CacheOperationException`: When statistics retrieval fails

```dart
final stats = await proxy.getCacheStats();
print('Cache size: ${stats.totalSize} bytes');
```

#### `Future<WarmupResult> warmupCache({List<String>? paths, int? timeout, int? maxConcurrency, WarmupProgressCallback? onProgress, WarmupErrorCallback? onError})`

Batch updates cache for specified path list.

- **Parameters**:
  - `paths`: Path list to update (uses startup.paths in configuration file when omitted)
  - `timeout`: Timeout seconds for each path (uses configuration value when omitted)
  - `maxConcurrency`: Number of concurrent executions (uses configuration value when omitted)
  - `onProgress`: Progress callback function
  - `onError`: Error callback function
- **Return Value**: Detailed information of update results
- **Exceptions**:
  - `ArgumentError`: When invalid path is included
  - `WarmupException`: When entire update process fails

```dart
// Update with path list from configuration file
final result = await proxy.warmupCache();

// Update with custom path list
final result = await proxy.warmupCache(
  paths: [
    '/config',
    '/user/profile',
  ],
  timeout: 10,
  maxConcurrency: 2,
  onProgress: (completed, total) {
    print('Progress: $completed/$total');
  },
  onError: (path, error) {
    print('Failed to update $path: $error');
  },
);

print('Success: ${result.successCount}, Failed: ${result.failureCount}');
```

### Cookie Management

#### `Future<List<CookieInfo>> getCookies({String? domain})`

Gets list of currently stored cookies.

- **Parameters**:
  - `domain`: Domain to filter (all domains when omitted)
- **Return Value**: List of cookie information (values masked for security)
- **Exceptions**:
  - `CookieOperationException`: When cookie retrieval fails

```dart
final cookies = await proxy.getCookies(domain: 'example.com');
for (final cookie in cookies) {
  print('Name: ${cookie.name}, Domain: ${cookie.domain}');
}
```

#### `Future<void> clearCookies({String? domain})`

Deletes cookies.

- **Parameters**:
  - `domain`: Domain to delete (deletes all cookies when omitted)
- **Return Value**: None
- **Exceptions**:
  - `CookieOperationException`: When cookie deletion fails
- **Note**: Deletes from both file and memory cache simultaneously

```dart
await proxy.clearCookies(); // Delete all cookies (file + memory)
await proxy.clearCookies(domain: 'example.com'); // Delete only specific domain
```

### Queue Management

#### `Future<List<QueuedRequest>> getQueuedRequests()`

Gets list of requests currently stored in queue.

- **Return Value**: List of queued requests
- **Exceptions**:
  - `QueueOperationException`: When queue retrieval fails

```dart
final queued = await proxy.getQueuedRequests();
print('Queued requests: ${queued.length}');
```

#### `Future<List<DroppedRequest>> getDroppedRequests({int? limit})`

Gets history of dropped requests.

- **Parameters**:
  - `limit`: Upper limit of items to retrieve (default: 100)
- **Return Value**: List of dropped requests
- **Exceptions**:
  - `QueueOperationException`: When history retrieval fails

```dart
final dropped = await proxy.getDroppedRequests();
for (final request in dropped) {
  print('URL: ${request.url}, Reason: ${request.dropReason}');
}
```

#### `Future<void> clearDroppedRequests()`

Clears history of dropped requests.

- **Return Value**: None
- **Exceptions**:
  - `QueueOperationException`: When history deletion fails

```dart
await proxy.clearDroppedRequests();
```

### Statistics and Monitoring

#### `Future<ProxyStats> getStats()`

Gets proxy server statistics.

- **Return Value**: Proxy statistics
- **Exceptions**:
  - `StatsOperationException`: When statistics retrieval fails

```dart
final stats = await proxy.getStats();
print('Total requests: ${stats.totalRequests}');
print('Cache hit rate: ${stats.cacheHitRate}%');
print('Queue length: ${stats.queueLength}');
```

#### `Stream<ProxyEvent> get events`

Gets event stream of proxy server.

- **Return Value**: Stream of proxy events
- **Use**: Real-time monitoring, log output

```dart
proxy.events.listen((event) {
  switch (event.type) {
    case ProxyEventType.cacheHit:
      print('Cache hit: ${event.url}');
      break;
    case ProxyEventType.requestQueued:
      print('Request queued: ${event.url}');
      break;
  }
});
```

### Data Class Definitions

#### `CacheEntry`

Class representing cache entry information.

```dart
class CacheEntry {
  final String url; // Original URL of cached resource
  final int statusCode; // HTTP status code (200, 404, etc.)
  final String contentType; // Value of Content-Type header
  final DateTime createdAt; // Cache creation date/time
  final DateTime expiresAt; // Cache expiration time
  final CacheStatus status; // Cache state (fresh, stale, expired)
  final int sizeBytes; // Size of cache file (bytes)
}

enum CacheStatus {
  fresh, // Within TTL period and usable
  stale, // TTL expired but within Stale period
  expired // Stale period also exceeded, target for deletion
}
```

#### `CookieInfo`

Class representing stored cookie information (values masked for security).

```dart
class CookieInfo {
  final String name; // Cookie name
  final String value; // Cookie value (masked with "***" for security)
  final String domain; // Valid domain
  final String path; // Valid path
  final DateTime? expires; // Expiration time (null=session cookie)
  final bool secure; // Presence of Secure attribute
  final String? sameSite; // SameSite attribute ("Strict", "Lax", "None")
}
```

#### `QueuedRequest`

Class representing information of requests queued when offline.

```dart
class QueuedRequest {
  final String url; // Request URL
  final String method; // HTTP method (POST, PUT, DELETE, etc.)
  final Map<String, String> headers; // Request headers (sensitive info already masked)
  final DateTime queuedAt; // Queuing date/time
  final int retryCount; // Current retry count
  final DateTime nextRetryAt; // Next retry scheduled date/time
}
```

#### `DroppedRequest`

Class representing history of requests dropped from queue due to errors.

```dart
class DroppedRequest {
  final String url; // URL of dropped request
  final String method; // HTTP method
  final DateTime droppedAt; // Date/time dropped
  final String dropReason; // Drop reason ("4xx_error", "5xx_error", "network_timeout", etc.)
  final int statusCode; // HTTP status code at error
  final String errorMessage; // Detailed error message
}
```

#### `ProxyStats`

Class representing overall proxy server statistics.

```dart
class ProxyStats {
  final int totalRequests; // Total request count (cumulative since startup)
  final int cacheHits; // Cache hit count
  final int cacheMisses; // Cache miss count
  final double cacheHitRate; // Cache hit rate (0.0~1.0)
  final int queueLength; // Current queue length
  final int droppedRequestsCount; // Dropped request count
  final DateTime startedAt; // Proxy server start date/time
  final Duration uptime; // Operation time
}
```

#### `CacheStats`

Class representing cache system-specific statistics.

```dart
class CacheStats {
  final int totalEntries; // Total cache entry count
  final int freshEntries; // Fresh state entry count
  final int staleEntries; // Stale state entry count
  final int expiredEntries; // Expired state entry count
  final int totalSize; // Total cache size (bytes)
  final double hitRate; // Cache hit rate (0.0~1.0)
  final double staleUsageRate; // Stale cache usage rate (offline support indicator)
}
```

#### `WarmupResult`

Class representing results of cache pre-update (Warmup) process.

```dart
class WarmupResult {
  final int successCount; // Number of successful updates
  final int failureCount; // Number of failed updates
  final Duration totalDuration; // Time taken for entire process
  final List<WarmupEntry> entries; // Detailed results for each path
}

/// Type definition for Warmup progress callback function
typedef WarmupProgressCallback = void Function(int completed, int total);

/// Type definition for Warmup error callback function
typedef WarmupErrorCallback = void Function(String path, String error);

class WarmupEntry {
  final String path; // Path to update
  final bool success; // Success/failure of update
  final int? statusCode; // HTTP status code (only on success)
  final String? errorMessage; // Error message (only on failure)
  final Duration duration; // Time taken for this process
}
```

#### `ProxyConfig`

Class representing proxy server configuration.

```dart
class ProxyConfig {
  final String origin; // Upstream server URL (required)
  final String host; // Host to bind (default: "127.0.0.1")
  final int port; // Port to bind (0=automatic assignment)
  final int cacheMaxSize; // Maximum cache capacity (bytes)
  final Map<String, int> cacheTtl; // TTL setting by Content-Type (seconds)
  final Map<String, int> cacheStale; // Stale period setting by Content-Type (seconds)
  final Duration connectTimeout; // Connection timeout
  final Duration requestTimeout; // Request timeout
  final List<int> retryBackoffSeconds; // Retry backoff interval
  final bool enableAdminApi; // Enable admin API (development only)
  final String logLevel; // Log level ("debug", "info", "warn", "error")
  final List<String> startupPaths; // Startup cache update paths
}
```

#### `ProxyEvent`

Class representing proxy server event information (for real-time monitoring).

```dart
class ProxyEvent {
  final ProxyEventType type; // Event type
  final String url; // Related URL
  final DateTime timestamp; // Event occurrence date/time
  final Map<String, dynamic> data; // Additional information
}

enum ProxyEventType {
  serverStarted, // Server started
  serverStopped, // Server stopped
  requestReceived, // Request received
  cacheHit, // Cache hit
  cacheMiss, // Cache miss
  cacheStaleUsed, // Stale cache used
  requestQueued, // Request queued
  queueDrained, // Queue send completed
  requestDropped, // Request dropped
  networkOnline, // Network restored
  networkOffline, // Network disconnected
  cacheCleared, // Cache cleared
  errorOccurred // Error occurred
}
```

#### Exception Classes

Exception classes that may occur during proxy operations.

```dart
// Proxy server startup failure
class ProxyStartException implements Exception {
  final String message;
  final Exception? cause;
}

// Proxy server stop failure
class ProxyStopException implements Exception {
  final String message;
  final Exception? cause;
}

// Port binding failure
class PortBindException implements Exception {
  final int port;
  final String message;
}

// Cache operation failure
class CacheOperationException implements Exception {
  final String operation; // "clear", "get", "put", etc.
  final String message;
  final Exception? cause;
}

// Cookie operation failure
class CookieOperationException implements Exception {
  final String operation; // "get", "clear", "save", etc.
  final String message;
  final Exception? cause;
}

// Queue operation failure
class QueueOperationException implements Exception {
  final String operation; // "get", "clear", "add", etc.
  final String message;
  final Exception? cause;
}

// Statistics retrieval failure
class StatsOperationException implements Exception {
  final String message;
  final Exception? cause;
}

// Network error
class NetworkException implements Exception {
  final String message;
  final Exception? cause;
}

// Warmup process failure
class WarmupException implements Exception {
  final String message;
  final List<WarmupEntry> partialResults; // Partially successful results
  final Exception? cause;
}
```