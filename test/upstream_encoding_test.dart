import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = <String, List<String>>{};

/// 応答本文。圧縮の有無を判別できるよう、繰り返しの多い内容にしている。
final String _responseBody = '<html><body>${'screen ' * 500}</body></html>';

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// 圧縮を行う上流サーバのモック。
///
/// Tomcat と同じく `Cache-Control: no-store` と `Vary: accept-encoding` を
/// 常に付与する。[forceGzip] が `true` の間は `Accept-Encoding` を無視して
/// 本文を gzip 圧縮し、規約に従わないサーバを再現する。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        receivedAcceptEncodings[request.uri.path] =
            request.headers.value('accept-encoding');

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        request.response.headers.set('cache-control', 'no-store');
        request.response.headers.set('vary', 'accept-encoding');

        final plainBytes = utf8.encode(_responseBody);
        if (forceGzip) {
          request.response.headers.set('content-encoding', 'gzip');
          request.response.add(gzip.encode(plainBytes));
        } else {
          request.response.add(plainBytes);
        }
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// パスごとに上流が受信した `Accept-Encoding` ヘッダ。
  final Map<String, String?> receivedAcceptEncodings = <String, String?>{};

  /// `Accept-Encoding` を無視して圧縮するかどうか。
  bool forceGzip = false;

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

/// 実 HttpClient で読み取り要求を実行する。
///
/// [uri] は要求先です。[autoUncompress] を `false` にすると、受信した
/// バイト列を解凍せずそのまま返します。
///
/// 戻り値はステータス、受信したバイト列、および `Content-Encoding` です。
Future<
    ({
      int statusCode,
      List<int> bodyBytes,
      String? contentEncoding,
    })> _performGet(
  Uri uri, {
  bool autoUncompress = true,
}) async {
  final client = HttpClient()..autoUncompress = autoUncompress;
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return (
      statusCode: response.statusCode,
      bodyBytes: builder.takeBytes(),
      contentEncoding: response.headers.value('content-encoding'),
    );
  } finally {
    client.close(force: true);
  }
}

/// バイト列が gzip の書式かどうかを返す。
///
/// [bytes] は判定するバイト列です。
///
/// Returns: gzip のマジックナンバーで始まる場合は `true`。
bool _looksGzip(List<int> bytes) =>
    bytes.length > 1 && bytes[0] == 0x1f && bytes[1] == 0x8b;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String hiveTestDirectory;

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
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
        Directory.systemTemp.createTempSync('offline_web_proxy_encoding').path;
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

  group('上流への Accept-Encoding（doc/specs.ja.md 【8】キャッシュ整合性）', () {
    /// 転送経路が identity を送ること
    test('sends identity while forwarding a request', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        expect(
          upstream!.receivedAcceptEncodings['/app/index.html'],
          equals('identity'),
        );
      });
    });

    /// ウォームアップも転送経路と同じ identity を送ること
    test('sends identity while warming up', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        expect(port, greaterThan(0));

        await proxy.warmupCache(paths: ['/app/warm.html']);

        // 経路によって保存する応答が割れないよう、転送経路とそろえること
        expect(
          upstream!.receivedAcceptEncodings['/app/warm.html'],
          equals('identity'),
        );
      });
    });

    /// 上流が identity を無視して圧縮しても、保存内容が復元できること
    test(
        'stores a body that matches its content-encoding when the upstream '
        'compresses anyway', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.forceGzip = true;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        await proxy.warmupCache(paths: ['/app/warm.html']);
        expect((await proxy.getCacheStats()).totalEntries, equals(1));

        await _emitConnectivity(['none']);
        final uri = Uri.parse('http://127.0.0.1:$port/app/warm.html');

        // 解凍せずに受け取ると、宣言どおり gzip のバイト列であること
        final rawResponse = await _performGet(uri, autoUncompress: false);
        expect(rawResponse.statusCode, equals(HttpStatus.ok));
        expect(rawResponse.contentEncoding, equals('gzip'));
        expect(_looksGzip(rawResponse.bodyBytes), isTrue);

        // 通常のクライアントは Content-Encoding どおりに復号できること
        final decodedResponse = await _performGet(uri);
        expect(decodedResponse.statusCode, equals(HttpStatus.ok));
        expect(utf8.decode(decodedResponse.bodyBytes), equals(_responseBody));
      });
    });

    /// 転送経路で保存した内容もオフラインで復元できること
    test(
        'keeps the forwarded response consistent when the upstream '
        'compresses anyway', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.forceGzip = true;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final uri = Uri.parse('http://127.0.0.1:$port/app/index.html');
        final onlineResponse = await _performGet(uri);
        expect(utf8.decode(onlineResponse.bodyBytes), equals(_responseBody));
        expect((await proxy.getCacheStats()).totalEntries, equals(1));

        await _emitConnectivity(['none']);
        final offlineResponse = await _performGet(uri);

        expect(offlineResponse.statusCode, equals(HttpStatus.ok));
        expect(utf8.decode(offlineResponse.bodyBytes), equals(_responseBody));
      });
    });
  });
}
