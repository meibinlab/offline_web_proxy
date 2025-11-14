// Command-line example for offline_web_proxy package
// 
// This demonstrates basic usage without Flutter UI,
// useful for server applications or CLI tools.

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:offline_web_proxy/offline_web_proxy.dart';

Future<void> main() async {
  print('Starting Offline Web Proxy CLI Example');
  
  // Create proxy instance
  final proxy = OfflineWebProxy();
  
  try {
    // Configure proxy for JSONPlaceholder API
    final config = ProxyConfig(
      origin: 'https://jsonplaceholder.typicode.com',
      port: 8080, // Fixed port for CLI usage
      cacheMaxSize: 10 * 1024 * 1024, // 10MB cache
      cacheTtl: {
        'application/json': 300, // 5 minutes
        'default': 600, // 10 minutes
      },
      logLevel: 'info',
    );
    
    // Start the proxy server
    print('Starting proxy server...');
    final port = await proxy.start(config: config);
    print('Proxy running on http://localhost:$port');
    print('Proxying requests to: ${config.origin}');
    print('');
    
    // Make some test requests
    await _makeTestRequests(port);
    
    // Show statistics
    await _showStatistics(proxy);
    
    // Keep running until user presses Enter
    print('');
    print('Press Enter to stop the proxy server...');
    stdin.readLineSync();
    
  } catch (e) {
    print('Error: $e');
  } finally {
    // Stop the proxy
    print('Stopping proxy server...');
    await proxy.stop();
    print('Proxy stopped');
  }
}

Future<void> _makeTestRequests(int port) async {
  final baseUrl = 'http://localhost:$port';
  
  print('Making test requests...');
  
  // Test different endpoints
  final endpoints = [
    '/posts/1',
    '/users/1', 
    '/posts/1/comments',
  ];
  
  for (final endpoint in endpoints) {
    try {
      print('  GET $endpoint');
      
      final response = await http.get(
        Uri.parse('$baseUrl$endpoint'),
        headers: {'Accept': 'application/json'},
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final title = data is Map ? (data['title'] ?? data['name'] ?? 'N/A') : 'N/A';
        print('    Status: ${response.statusCode} | Title/Name: $title');
      } else {
        print('    Status: ${response.statusCode}');
      }
      
      // Small delay between requests
      await Future.delayed(const Duration(milliseconds: 500));
      
    } catch (e) {
      print('    Request failed: $e');
    }
  }
}

Future<void> _showStatistics(OfflineWebProxy proxy) async {
  try {
    print('');
    print('Proxy Statistics:');
    
    final stats = await proxy.getStats();
    
    print('  Total Requests: ${stats.totalRequests}');
    print('  Cache Hits: ${stats.cacheHits}');
    print('  Cache Misses: ${stats.cacheMisses}');
    print('  Hit Rate: ${(stats.cacheHitRate * 100).toStringAsFixed(1)}%');
    print('  Queue Length: ${stats.queueLength}');
    print('  Uptime: ${_formatDuration(stats.uptime)}');
    
    // Show cache entries
    final cacheList = await proxy.getCacheList();
    print('  Cached Items: ${cacheList.length}');
    
    if (cacheList.isNotEmpty) {
      print('');
      print('Cached Content:');
      for (final entry in cacheList.take(3)) {
        print('  ${entry.url} (${entry.status.name}, ${_formatBytes(entry.sizeBytes)})');
      }
      if (cacheList.length > 3) {
        print('  ... and ${cacheList.length - 3} more items');
      }
    }
    
  } catch (e) {
    print('Failed to get statistics: $e');
  }
}

String _formatDuration(Duration duration) {
  if (duration.inDays > 0) {
    return '${duration.inDays}d ${duration.inHours % 24}h';
  } else if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes % 60}m';
  } else if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
  } else {
    return '${duration.inSeconds}s';
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  } else if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)}KB';
  } else {
    return '${bytes}B';
  }
}