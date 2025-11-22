import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:offline_web_proxy/offline_web_proxy.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Web Proxy Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ProxyExampleScreen(),
    );
  }
}

class ProxyExampleScreen extends StatefulWidget {
  const ProxyExampleScreen({super.key});

  @override
  State<ProxyExampleScreen> createState() => _ProxyExampleScreenState();
}

class _ProxyExampleScreenState extends State<ProxyExampleScreen> {
  late OfflineWebProxy _proxy;
  String _proxyUrl = 'Not started';
  String _responseData = 'No data yet';
  bool _isProxyRunning = false;
  ProxyStats? _stats;
  int _totalErrorCount = 0;

  final List<String> _apiEndpoints = [
    '/posts/1',
    '/posts/2',
    '/users/1',
    '/comments?postId=1',
  ];

  @override
  void initState() {
    super.initState();
    _proxy = OfflineWebProxy();
    _initializeProxy();
  }

  Future<void> _initializeProxy() async {
    try {
      // Configure proxy for JSONPlaceholder API
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

      final port = await _proxy.start(config: config);

      // 開発/検証時はバックグラウンドタスクを有効化してキュー消化を行う
      // デフォルト実装ではテストの切り分け用に無効になっているため明示的に有効化する
      _proxy.setDisableBackgroundTasksForDebug(false);

      setState(() {
        _proxyUrl = 'localhost:$port';
        _isProxyRunning = true;
      });

      // Update stats periodically
      _updateStatsLoop();
    } catch (e) {
      setState(() {
        _responseData = 'Failed to start proxy: $e';
      });
    }
  }

  Future<void> _updateStatsLoop() async {
    while (_isProxyRunning) {
      try {
        final stats = await _proxy.getStats();
        if (mounted) {
          setState(() {
            _stats = stats;
          });
        }
        await Future.delayed(const Duration(seconds: 2));
      } catch (e) {
        break;
      }
    }
  }

  Future<void> _makeRequest(String endpoint) async {
    try {
      setState(() {
        _responseData = 'Loading...';
      });

      // Make request through the proxy
      final proxyBaseUrl =
          _proxyUrl.replaceAll('http://', '').replaceAll('https://', '');
      final response = await http.get(
        Uri.parse('http://$proxyBaseUrl$endpoint'),
        headers: {'Accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final prettyJson = const JsonEncoder.withIndent('  ').convert(data);

        setState(() {
          _responseData =
              'Success! Status: ${response.statusCode}\n\n$prettyJson';
        });
      } else {
        setState(() {
          _responseData =
              'Error: HTTP ${response.statusCode}\n${response.body}';
        });
      }
    } catch (e) {
      setState(() {
        _responseData = 'Request failed: $e';
      });
    }
  }

  Future<void> _clearCache() async {
    try {
      await _proxy.clearCache();
      setState(() {
        _responseData = 'Cache cleared successfully!';
      });
    } catch (e) {
      setState(() {
        _responseData = 'Failed to clear cache: $e';
      });
    }
  }

  Future<void> _stressTest() async {
    if (!_isProxyRunning) return;

    setState(() {
      _responseData = 'Starting stress test...';
    });

    final proxyBaseUrl =
        _proxyUrl.replaceAll('http://', '').replaceAll('https://', '');

    // 低負荷再現用: 合計を少なくし並列数を下げる
    const int total = 50;
    // 並列数を制限して上流や端末のソケット枯渇を避ける
    const int concurrency = 3;
    int successCount = 0;

    final endpoints = List<String>.generate(
      total,
      (i) => _apiEndpoints[i % _apiEndpoints.length],
    );

    for (int i = 0; i < endpoints.length; i += concurrency) {
      final batch = endpoints.skip(i).take(concurrency).toList();
      final batchStartIndex = i;
      int batchErrorCount = 0;
      final List<String> batchErrorDetails = [];
      final futures = batch.map((endpoint) async {
        try {
          final res = await http
              .get(Uri.parse('http://$proxyBaseUrl$endpoint'))
              .timeout(const Duration(seconds: 10));
          return res;
        } catch (e) {
          // 個別の失敗はここでカウントしてバッチ単位でまとめる
          batchErrorCount++;
          batchErrorDetails.add('$endpoint: $e');
          return null;
        }
      }).toList();

      final results = await Future.wait(futures);
      int batchSuccess = 0;
      for (final r in results) {
        if (r != null && r.statusCode == 200) batchSuccess++;
      }
      successCount += batchSuccess;
      _totalErrorCount += batchErrorCount;

      // バッチ単位で進捗とエラー数を表示（UI負荷を抑える）
      final processed = (batchStartIndex + batch.length).clamp(0, endpoints.length);

      // ログにも出力して後で解析しやすくする
      // 重要: debugPrint で出力すると `flutter logs` に表示されます
      if (batchErrorCount > 0) {
        debugPrint('StressTest batch: processed=$processed batchSuccess=$batchSuccess batchErrors=$batchErrorCount totalErrors=$_totalErrorCount');
        for (final d in batchErrorDetails) {
          debugPrint('StressTest error detail: $d');
        }
      } else {
        debugPrint('StressTest batch: processed=$processed batchSuccess=$batchSuccess batchErrors=0 totalErrors=$_totalErrorCount');
      }
      if (mounted) {
        setState(() {
          _responseData = 'Stress test running... processed: $processed / $total (success +$batchSuccess, errors +$batchErrorCount)';
        });
      }

      // 小休止を挟んでメインスレッド負荷を軽減
      await Future.delayed(const Duration(milliseconds: 20));
    }

    setState(() {
      _responseData = 'Stress test complete. Success: $successCount / $total Errors: $_totalErrorCount';
    });
    debugPrint('StressTest complete: success=$successCount totalErrors=$_totalErrorCount');
  }

  @override
  void dispose() {
    _isProxyRunning = false;
    _proxy.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Offline Web Proxy Example'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Proxy Status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Proxy Status',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text('URL: $_proxyUrl'),
                    Text('Status: ${_isProxyRunning ? "Running" : "Stopped"}'),
                    if (_stats != null) ...[
                      const SizedBox(height: 8),
                      Text('Total Requests: ${_stats!.totalRequests}'),
                      Text('Cache Hits: ${_stats!.cacheHits}'),
                      Text(
                          'Cache Hit Rate: ${(_stats!.cacheHitRate * 100).toStringAsFixed(1)}%'),
                      Text('Queue Length: ${_stats!.queueLength}'),
                      Text(
                          'Uptime: ${_stats!.uptime.toString().split('.')[0]}'),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // API Endpoints
            Text(
              'Test API Endpoints',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),

            Wrap(
              spacing: 8,
              children: _apiEndpoints.map((endpoint) {
                return ElevatedButton(
                  onPressed:
                      _isProxyRunning ? () => _makeRequest(endpoint) : null,
                  child: Text(endpoint),
                );
              }).toList(),
            ),

            const SizedBox(height: 16),

            // Cache Controls
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _isProxyRunning ? _clearCache : null,
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear Cache'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed:
                      _isProxyRunning ? () => _makeRequest('/posts') : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Fetch Posts'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _isProxyRunning ? _stressTest : null,
                  icon: const Icon(Icons.bolt),
                  label: const Text('Stress Test'),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Response Display
            Expanded(
              child: Card(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16.0),
                  child: SingleChildScrollView(
                    child: Text(
                      _responseData,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
