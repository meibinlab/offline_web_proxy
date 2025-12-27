import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:offline_web_proxy/offline_web_proxy.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('offline_web_proxy e2e (emulator/device)', () {
    late HttpServer upstream;
    bool upstreamClosed = false;

    Future<void> closeUpstream() async {
      if (upstreamClosed) return;
      upstreamClosed = true;
      await upstream.close(force: true);
    }

    setUpAll(() async {
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      unawaited(() async {
        await for (final HttpRequest req in upstream) {
          try {
            final path = req.uri.path;

            if (req.method == 'GET' && path == '/bin') {
              final bytes = Uint8List.fromList(
                List<int>.generate(256, (i) => i),
              );
              req.response.statusCode = 200;
              req.response.headers.contentType =
                  ContentType('application', 'octet-stream');
              req.response.add(bytes);
              await req.response.close();
              continue;
            }

            if (req.method == 'GET' && path == '/text') {
              const body = 'hello-offline-web-proxy';
              req.response.statusCode = 200;
              req.response.headers.contentType =
                  ContentType('text', 'plain', charset: 'utf-8');
              req.response.write(body);
              await req.response.close();
              continue;
            }

            if (req.method == 'POST' && path == '/echo') {
              final builder = BytesBuilder(copy: false);
              await for (final chunk in req) {
                builder.add(chunk);
              }
              final bodyBytes = builder.takeBytes();
              req.response.statusCode = 200;
              req.response.headers.contentType =
                  ContentType('application', 'octet-stream');
              req.response.add(bodyBytes);
              await req.response.close();
              continue;
            }

            req.response.statusCode = 404;
            req.response.write('not found');
            await req.response.close();
          } catch (_) {
            try {
              req.response.statusCode = 500;
              await req.response.close();
            } catch (_) {
              // ignore
            }
          }
        }
      }());
    });

    tearDownAll(() async {
      await closeUpstream();
    });

    testWidgets(
      'starts proxy, forwards requests, caches binary, serves cached when upstream is down',
      (tester) async {
        final proxy = OfflineWebProxy();
        final origin = 'http://127.0.0.1:${upstream.port}';

        final proxyPort = await proxy.start(
          config: ProxyConfig(
            origin: origin,
            port: 0,
          ),
        );

        final proxyBase = 'http://127.0.0.1:$proxyPort';

        final bin1 = await http.get(Uri.parse('$proxyBase/bin'));
        expect(bin1.statusCode, 200);
        expect(bin1.bodyBytes.length, 256);
        expect(bin1.bodyBytes.first, 0);
        expect(bin1.bodyBytes.last, 255);

        // Kill upstream to ensure proxy must serve from cache.
        await closeUpstream();

        final bin2 = await http.get(Uri.parse('$proxyBase/bin'));
        expect(bin2.statusCode, 200);
        expect(bin2.bodyBytes, bin1.bodyBytes);

        // Non-GET queue path sanity (does not assert drain; just ensures it doesn't hang/crash)
        final post = await http.post(
          Uri.parse('$proxyBase/echo'),
          body: Uint8List.fromList(List<int>.filled(1024, 7)),
        );
        expect(post.statusCode, anyOf(200, 500, 502, 503, 504));

        await proxy.stop();

        // If periodic timers were leaked, errors often show up after stop.
        await Future.delayed(const Duration(seconds: 6));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
