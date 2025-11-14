# Offline Web Proxy Example

This example demonstrates how to use the `offline_web_proxy` package in a Flutter application.

## Features Demonstrated

- **Basic Proxy Setup**: Configure and start the offline-capable HTTP proxy
- **API Integration**: Make HTTP requests through the proxy to JSONPlaceholder API
- **Cache Management**: Clear cache and monitor cache statistics
- **Real-time Monitoring**: Display proxy statistics including hit rates and uptime
- **Offline Capability**: Automatic fallback to cached content when offline

## How to Run

1. Ensure you have Flutter installed and set up
2. Navigate to this example directory:
   ```bash
   cd example
   ```

3. Get dependencies:
   ```bash
   flutter pub get
   ```

4. Run the app:
   ```bash
   flutter run
   ```

## What the Example Shows

### 1. Proxy Configuration
```dart
final config = ProxyConfig(
  origin: 'https://jsonplaceholder.typicode.com',
  port: 0, // Auto-assign port
  cacheMaxSize: 50 * 1024 * 1024, // 50MB cache
  cacheTtl: {
    'application/json': 300, // 5 minutes for API responses
    'default': 600,
  },
  logLevel: 'info',
  startupPaths: ['/posts/1', '/users/1'], // Warmup these paths
);
```

### 2. Making Requests Through Proxy
```dart
final response = await http.get(
  Uri.parse('http://localhost:$proxyPort/posts/1'),
  headers: {'Accept': 'application/json'},
);
```

### 3. Monitoring Statistics
```dart
final stats = await proxy.getStats();
print('Cache hit rate: ${stats.cacheHitRate}');
print('Total requests: ${stats.totalRequests}');
```

## Testing Offline Functionality

1. Run the app and make some API requests
2. Turn off your internet connection
3. Make the same requests again - they should be served from cache
4. Turn internet back on and make new requests to see cache updates

## Key Learning Points

- How to configure the proxy for different content types
- Monitoring proxy performance and cache efficiency  
- Handling both online and offline scenarios seamlessly
- Managing cache lifecycle and cleanup

## API Endpoints Used

The example uses the JSONPlaceholder API which provides:
- `/posts/1`, `/posts/2` - Sample post data
- `/users/1` - User information  
- `/comments?postId=1` - Comments for posts
- `/posts` - List of all posts

These endpoints demonstrate different response sizes and caching patterns.