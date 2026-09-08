import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// ページ遷移としてリクエストするためのヘッダ。
const Map<String, String> _navigationHeaders = {
  'Sec-Fetch-Mode': 'navigate',
  'Accept': 'text/html',
};

/// SPA の `fetch` としてリクエストするためのヘッダ。
const Map<String, String> _fetchHeaders = {
  'Sec-Fetch-Mode': 'cors',
  'Accept': 'application/json',
};

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// HTTP 応答の検証に必要な要素だけを保持する型。
typedef _HttpResult = ({
  int statusCode,
  Map<String, String> headers,
  String body,
});

/// 受信したリクエストを記録する上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      receivedPaths.add(request.uri.path);
      try {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 上流が受信したリクエストパスの一覧。
  final List<String> receivedPaths = <String>[];

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 上流サーバのモックを起動する。
Future<_MockUpstream> _startMockUpstream() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _MockUpstream(server);
}

/// connectivity_plus の状態変化イベントを擬似送信する。
///
/// [statuses] は `['none']` や `['wifi']` のような接続状態一覧です。
Future<void> _emitConnectivity(List<String> statuses) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'dev.fluttercommunity.plus/connectivity_status',
    const StandardMethodCodec().encodeSuccessEnvelope(statuses),
    (ByteData? _) {},
  );
}

/// 実 HttpClient でリクエストを実行し、応答内容を返す。
Future<_HttpResult> _performRequest(
  Uri uri, {
  String method = 'GET',
  String? body,
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.write(body);
    }
    final response = await request.close();
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      responseHeaders[name.toLowerCase()] = values.join(', ');
    });
    final responseBody = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      headers: responseHeaders,
      body: responseBody,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String hiveTestDirectory;

  setUpAll(() {
    const pathProviderChannel =
        MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel,
            (MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        // Hive の保存先をテスト用ディレクトリに固定する
        return hiveTestDirectory;
      }
      return null;
    });

    const stringCodec = StringCodec();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (ByteData? message) async {
      final assetKey = stringCodec.decodeMessage(message);
      if (assetKey == 'AssetManifest.json') {
        return stringCodec.encodeMessage(jsonEncode(_mockAssetManifest));
      }
      return null;
    });
  });

  late OfflineWebProxy proxy;
  _MockUpstream? upstream;

  setUp(() async {
    hiveTestDirectory =
        Directory.systemTemp.createTempSync('offline_web_proxy_contract').path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    proxy = OfflineWebProxy();
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream?.close();
    upstream = null;
  });

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: _RealHttpOverrides().createHttpClient,
    );
  }

  /// オフライン状態の proxy を起動し、ポート番号を返す。
  Future<int> startOfflineProxy({ProxyConfig? config}) async {
    upstream = await _startMockUpstream();
    final port = await proxy.start(
      config: config ?? ProxyConfig(origin: upstream!.origin),
    );
    await _emitConnectivity(['none']);
    return port;
  }

  group('オフライン応答の契約（doc/specs.ja.md 【10】オフライン応答）', () {
    /// オフライン時の更新系リクエストが JSON として解釈できること
    test('answers a queued update with parseable JSON', () async {
      await withRealHttpClient(() async {
        final port = await startOfflineProxy();

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/api/sales_histories.json'),
          method: 'POST',
          body: '{"total":1000}',
          headers: _fetchHeaders,
        );

        // 上流の処理結果ではないことを示す 202 を返すこと
        expect(result.statusCode, equals(HttpStatus.accepted));
        // ヘッダだけでキュー投入を判別できること
        expect(result.headers['x-offline-queued'], equals('1'));
        expect(result.headers['x-offline-queue-id'], isNotNull);
        // Web アプリ側の JSON 解析が成功すること
        expect(result.headers['content-type'], contains('application/json'));
        expect(jsonDecode(result.body), equals({'queued': true}));
      });
    });

    /// キャッシュが無いオフライン時の fetch が JSON として解釈できること
    test('answers an uncached offline read with parseable JSON', () async {
      await withRealHttpClient(() async {
        final port = await startOfflineProxy();

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/api/sales_histories.json'),
          headers: _fetchHeaders,
        );

        // 成功に見えないよう 504 を返すこと
        expect(result.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(result.headers['x-offline'], equals('1'));
        expect(result.headers['x-offline-source'], equals('none'));
        // Web アプリ側の JSON 解析が成功すること
        expect(jsonDecode(result.body), equals({'offline': true}));
      });
    });

    /// ページ遷移には従来どおり HTML のフォールバックを返すこと
    test('keeps the HTML fallback for page navigations', () async {
      await withRealHttpClient(() async {
        final port = await startOfflineProxy(
          config: ProxyConfig(
            origin: upstream?.origin ?? 'http://127.0.0.1:1',
            offlineFallbackHtml: '<html>offline-page</html>',
          ),
        );

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/orders'),
          headers: _navigationHeaders,
        );

        // 人が読める画面を返すこと
        expect(result.statusCode, equals(HttpStatus.ok));
        expect(result.headers['content-type'], contains('text/html'));
        expect(result.body, equals('<html>offline-page</html>'));
      });
    });

    /// 応答内容を設定で差し替えられること
    test('applies the configured queued and offline responses', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            queuedResponse: const ProxyResponseConfig(
              statusCode: 200,
              contentType: 'application/json; charset=utf-8',
              body: '{"accepted":true}',
            ),
            offlineMissResponse: const ProxyResponseConfig(
              statusCode: 503,
              contentType: 'application/json; charset=utf-8',
              body: '{"unavailable":true}',
            ),
          ),
        );
        await _emitConnectivity(['none']);

        final queued = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          method: 'POST',
          body: '{}',
          headers: _fetchHeaders,
        );
        // 指定したステータスと本文で応答すること
        expect(queued.statusCode, equals(HttpStatus.ok));
        expect(jsonDecode(queued.body), equals({'accepted': true}));
        // 設定を変えても判別用ヘッダは維持されること
        expect(queued.headers['x-offline-queued'], equals('1'));

        final read = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/api/sales'),
          headers: _fetchHeaders,
        );
        // 指定したステータスと本文で応答すること
        expect(read.statusCode, equals(HttpStatus.serviceUnavailable));
        expect(jsonDecode(read.body), equals({'unavailable': true}));
      });
    });

    /// 上流が 5xx を返してキューへ入れた場合も、判別用ヘッダを付けること
    test('marks a passthrough 5xx that was queued for resend', () async {
      await withRealHttpClient(() async {
        final failingUpstream =
            await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        failingUpstream.listen((HttpRequest request) async {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('upstream-error');
          await request.response.close();
        });

        try {
          final port = await proxy.start(
            config: ProxyConfig(
              origin: 'http://127.0.0.1:${failingUpstream.port}',
            ),
          );

          final result = await _performRequest(
            Uri.parse('http://127.0.0.1:$port/api/sales'),
            method: 'POST',
            body: '{}',
            headers: _fetchHeaders,
          );

          // upstream の応答はそのまま返すこと
          expect(result.statusCode, equals(HttpStatus.internalServerError));
          expect(result.body, equals('upstream-error'));
          // 再送予定であることを Web アプリ側が判別できること
          expect(result.headers['x-offline-queued'], equals('1'));
          expect(result.headers['x-offline-queue-id'], isNotNull);
          expect(await proxy.getQueuedRequests(), hasLength(1));
        } finally {
          await failingUpstream.close(force: true);
        }
      });
    });

    /// ヘッダを持たない要求はページ遷移として扱わないこと
    test('treats a request without navigation hints as a subresource',
        () async {
      await withRealHttpClient(() async {
        final port = await startOfflineProxy();

        final result = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/assets/app.css'),
        );

        // 画像やスタイルシートに HTML を返さないこと
        expect(result.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(result.headers['content-type'], contains('application/json'));
      });
    });
  });
}
