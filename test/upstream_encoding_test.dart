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
/// 常に付与する。既定では `Accept-Encoding` に gzip があれば本文を gzip で
/// 圧縮する。[mode] で、規約に従わないサーバや壊れた本文を再現する。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        receivedAcceptEncodings[request.uri.path] =
            request.headers.value('accept-encoding');

        final statusCode = statusCodes[request.uri.path] ?? HttpStatus.ok;
        request.response.statusCode = statusCode;
        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        request.response.headers.set('cache-control', 'no-store');
        request.response.headers.set('vary', 'accept-encoding');

        final plainBytes =
            utf8.encode(bodies[request.uri.path] ?? _responseBody);
        final acceptsGzip =
            (request.headers.value('accept-encoding') ?? '').contains('gzip');
        if (statusCode == HttpStatus.noContent ||
            statusCode == HttpStatus.notModified) {
          // 本文を持たない応答にも、宣言だけ付けるサーバを再現する
          request.response.headers.set('content-encoding', 'gzip');
          await request.response.close();
          return;
        }

        final range = request.headers.value('range');
        switch (mode) {
          case _UpstreamMode.forceGzip when range != null:
            // 圧縮した表現の先頭だけを範囲として返すサーバを再現する
            final compressed = gzip.encode(plainBytes);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set('content-encoding', 'gzip');
            request.response.headers.set(
              'content-range',
              'bytes 0-9/${compressed.length}',
            );
            request.response.add(compressed.sublist(0, 10));
          case _UpstreamMode.negotiate when acceptsGzip:
          case _UpstreamMode.forceGzip:
            request.response.headers.set('content-encoding', 'gzip');
            request.response.add(gzip.encode(plainBytes));
          case _UpstreamMode.xGzip:
            request.response.headers.set('content-encoding', 'x-gzip');
            request.response.add(gzip.encode(plainBytes));
          case _UpstreamMode.gzipWithIdentity:
            request.response.headers.set('content-encoding', 'gzip, identity');
            request.response.add(gzip.encode(plainBytes));
          case _UpstreamMode.truncatedGzip:
            final compressed = gzip.encode(plainBytes);
            request.response.headers.set('content-encoding', 'gzip');
            request.response.add(compressed.sublist(0, compressed.length - 20));
          case _UpstreamMode.brokenGzip:
            request.response.headers.set('content-encoding', 'gzip');
            request.response.add(plainBytes);
          case _UpstreamMode.brotli:
            // 解凍できない方式として、宣言だけ br にした本文を返す
            request.response.headers.set('content-encoding', 'br');
            request.response.add(plainBytes);
          case _UpstreamMode.negotiate:
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

  /// パスごとの状態コード。未登録のパスは `200` を返す。
  final Map<String, int> statusCodes = <String, int>{};

  /// パスごとの応答本文。未登録のパスは [_responseBody] を返す。
  final Map<String, String> bodies = <String, String>{};

  /// 本文の圧縮のしかた。
  _UpstreamMode mode = _UpstreamMode.negotiate;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 上流サーバのモックが本文を圧縮するしかた。
enum _UpstreamMode {
  /// `Accept-Encoding` に gzip があれば gzip で圧縮する。
  negotiate,

  /// `Accept-Encoding` を無視して常に gzip で圧縮する。
  forceGzip,

  /// `Content-Encoding: gzip` を付けるが、本文は gzip ではない。
  brokenGzip,

  /// `Content-Encoding: br` を付ける（proxy が求めない方式）。
  brotli,

  /// `Content-Encoding: x-gzip` を付けて gzip で圧縮する。
  xGzip,

  /// `Content-Encoding: gzip, identity` を付けて gzip で圧縮する。
  gzipWithIdentity,

  /// gzip の末尾を切り落とした本文を返す。
  truncatedGzip,
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
/// 戻り値はステータス、受信したバイト列、`Content-Encoding`、`Content-Length`
/// （無い場合は -1）です。
Future<
    ({
      int statusCode,
      List<int> bodyBytes,
      String? contentEncoding,
      int contentLength,
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
      contentLength: response.contentLength,
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

  group('上流との通信の圧縮（doc/specs.ja.md 【7】レスポンス圧縮）', () {
    /// 転送経路が gzip を求めること
    test('asks for gzip while forwarding a request', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        expect(
          upstream!.receivedAcceptEncodings['/app/index.html'],
          equals('gzip'),
        );
      });
    });

    /// ウォームアップも転送経路と同じ値を送ること
    test('asks for gzip while warming up', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        await proxy.warmupCache(paths: ['/app/warm.html']);

        expect(
          upstream!.receivedAcceptEncodings['/app/warm.html'],
          equals('gzip'),
        );
      });
    });

    /// 解凍した本文を、Content-Encoding を外して WebView へ返すこと
    test('returns the decompressed body without content-encoding', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
          autoUncompress: false,
        );
        // 前提: 上流へ gzip を求め、上流が gzip で返していること
        expect(
          upstream!.receivedAcceptEncodings['/app/index.html'],
          equals('gzip'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.contentEncoding, isNull);
        expect(_looksGzip(response.bodyBytes), isFalse);
        expect(utf8.decode(response.bodyBytes), equals(_responseBody));
        expect(
          response.contentLength,
          anyOf(equals(-1), equals(response.bodyBytes.length)),
        );
      });
    });

    /// 転送経路で保存した内容を、解凍した形でオフラインでも返すこと
    test('caches the decompressed body from a forwarded request', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );
        await proxy.cacheReady;
        final uri = Uri.parse('http://127.0.0.1:$port/app/index.html');

        await _performGet(uri);
        // 前提: 上流が gzip で返していること
        expect(
          upstream!.receivedAcceptEncodings['/app/index.html'],
          equals('gzip'),
        );
        expect((await proxy.getCacheStats()).totalEntries, equals(1));

        await _emitConnectivity(['none']);
        final offlineResponse = await _performGet(uri, autoUncompress: false);

        expect(offlineResponse.statusCode, equals(HttpStatus.ok));
        expect(offlineResponse.contentEncoding, isNull);
        expect(utf8.decode(offlineResponse.bodyBytes), equals(_responseBody));
      });
    });

    /// ウォームアップで保存した内容も、解凍した形で返すこと
    test('caches the decompressed body during warmup', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        await proxy.warmupCache(paths: ['/app/warm.html']);
        // 前提: 上流が gzip で返していること
        expect(
          upstream!.receivedAcceptEncodings['/app/warm.html'],
          equals('gzip'),
        );
        expect((await proxy.getCacheStats()).totalEntries, equals(1));

        await _emitConnectivity(['none']);
        final offlineResponse = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/warm.html'),
          autoUncompress: false,
        );

        expect(offlineResponse.statusCode, equals(HttpStatus.ok));
        expect(offlineResponse.contentEncoding, isNull);
        expect(utf8.decode(offlineResponse.bodyBytes), equals(_responseBody));
      });
    });

    /// ウォームアップの参照の抽出も、解凍した本文から行うこと
    test('follows references found in a compressed html', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.bodies['/app/warm.html'] =
            '<html><head><script src="/app/app.js"></script></head></html>';
        await proxy.start(config: ProxyConfig(origin: upstream!.origin));

        await proxy.warmupCache(
          paths: ['/app/warm.html'],
          followReferences: true,
        );

        expect(upstream!.receivedAcceptEncodings, contains('/app/app.js'));
      });
    });

    /// 別 origin の書き換えも、解凍した本文に対して行うこと
    test('rewrites a mirrored origin in a compressed html', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.bodies['/index.html'] =
            '<html><script src="https://cdn.example.com/lib/app.js">'
            '</script></html>';
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: const ['https://cdn.example.com'],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/index.html'),
          autoUncompress: false,
        );
        final body = utf8.decode(response.bodyBytes);

        // 前提: 上流が gzip で返していること
        expect(
          upstream!.receivedAcceptEncodings['/index.html'],
          equals('gzip'),
        );
        expect(response.contentEncoding, isNull);
        expect(body, isNot(contains('src="https://cdn.example.com')));
        expect(body, contains('/lib/app.js'));
      });
    });

    /// HEAD の応答からも Content-Encoding を外し、GET と見え方を揃えること
    test('removes content-encoding from a HEAD response', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final client = HttpClient()..autoUncompress = false;
        try {
          final request = await client.openUrl(
            'HEAD',
            Uri.parse('http://127.0.0.1:$port/app/index.html'),
          );
          final response = await request.close();
          await response.drain<void>();

          expect(response.statusCode, equals(HttpStatus.ok));
          expect(response.headers.value('content-encoding'), isNull);
          // 前提: 上流へは gzip を求めていること
          expect(
            upstream!.receivedAcceptEncodings['/app/index.html'],
            equals('gzip'),
          );
        } finally {
          client.close(force: true);
        }
      });
    });

    /// 解凍できない本文は、宣言どおりのまま返し、保存しないこと
    test('passes an undecodable body through and does not cache it', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.mode = _UpstreamMode.brokenGzip;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
          autoUncompress: false,
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.contentEncoding, equals('gzip'));
        expect(utf8.decode(response.bodyBytes), equals(_responseBody));
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
      });
    });

    /// proxy が求めない方式（br）は、従来どおりそのまま返して保存すること
    test('passes a coding it did not ask for through', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.mode = _UpstreamMode.brotli;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );
        await proxy.cacheReady;

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
          autoUncompress: false,
        );

        expect(response.contentEncoding, equals('br'));
        expect(utf8.decode(response.bodyBytes), equals(_responseBody));
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
      });
    });

    /// 別 origin の中継でも gzip を求め、解凍して返すこと
    test('asks for gzip when relaying to a mirrored origin', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final cdn = await _startMockUpstream();
        try {
          final cdnPort = Uri.parse(cdn.origin).port;
          final port = await proxy.start(
            config: ProxyConfig(
              origin: upstream!.origin,
              mirroredOrigins: [cdn.origin],
            ),
          );

          final response = await _performGet(
            Uri.parse('http://127.0.0.1:$port'
                '/__offline_web_proxy/ext/http/127.0.0.1:$cdnPort/lib/app.js'),
            autoUncompress: false,
          );

          expect(cdn.receivedAcceptEncodings['/lib/app.js'], equals('gzip'));
          expect(response.contentEncoding, isNull);
          expect(utf8.decode(response.bodyBytes), equals(_responseBody));
        } finally {
          await cdn.close();
        }
      });
    });

    /// x-gzip と、identity を含む宣言も解凍すること
    test('decompresses x-gzip and gzip listed with identity', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        final uri = Uri.parse('http://127.0.0.1:$port/app/index.html');

        for (final mode in [
          _UpstreamMode.xGzip,
          _UpstreamMode.gzipWithIdentity,
        ]) {
          upstream!.mode = mode;
          final response = await _performGet(uri, autoUncompress: false);

          expect(response.contentEncoding, isNull, reason: mode.name);
          expect(
            utf8.decode(response.bodyBytes),
            equals(_responseBody),
            reason: mode.name,
          );
        }
      });
    });

    /// 本文を持たない 204 と 304 からも Content-Encoding を外すこと
    test('removes content-encoding from 204 and 304 responses', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCodes['/app/empty'] = HttpStatus.noContent;
        upstream!.statusCodes['/app/same'] = HttpStatus.notModified;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        for (final path in ['/app/empty', '/app/same']) {
          final response = await _performGet(
            Uri.parse('http://127.0.0.1:$port$path'),
            autoUncompress: false,
          );

          expect(response.statusCode, equals(upstream!.statusCodes[path]));
          expect(response.contentEncoding, isNull, reason: path);
        }
      });
    });

    /// 範囲の要求には identity を送り、範囲の応答は解凍しないこと
    test('sends identity for a range request and leaves 206 alone', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        final uri = Uri.parse('http://127.0.0.1:$port/app/video.mp4');

        Future<({int statusCode, String? contentEncoding, List<int> body})>
            getRange() async {
          final client = HttpClient()..autoUncompress = false;
          try {
            final request = await client.getUrl(uri);
            request.headers.set('range', 'bytes=0-9');
            final response = await request.close();
            final body = await response.fold<List<int>>(
              <int>[],
              (previous, chunk) => previous..addAll(chunk),
            );
            return (
              statusCode: response.statusCode,
              contentEncoding: response.headers.value('content-encoding'),
              body: body,
            );
          } finally {
            client.close(force: true);
          }
        }

        await getRange();
        expect(
          upstream!.receivedAcceptEncodings['/app/video.mp4'],
          equals('identity'),
        );

        // identity を無視して圧縮した表現の範囲を返しても、解凍しないこと
        upstream!.mode = _UpstreamMode.forceGzip;
        final response = await getRange();
        expect(response.statusCode, equals(HttpStatus.partialContent));
        expect(response.contentEncoding, equals('gzip'));
        expect(response.body, hasLength(10));
      });
    });

    /// 途中で切れた gzip は、解凍せずにそのまま返し、保存しないこと
    ///
    /// dart:io の解凍器は切れた gzip を例外なく途中まで解凍するため、
    /// このテストは末尾の ISIZE の照合で見分けていることを確かめる。
    test('passes a truncated gzip through and does not cache it', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.mode = _UpstreamMode.truncatedGzip;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
          autoUncompress: false,
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.contentEncoding, equals('gzip'));
        expect(_looksGzip(response.bodyBytes), isTrue);
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
      });
    });

    /// 解凍後に 64 MB を超える本文は、解凍せずにそのまま返し、保存しないこと
    test('passes a body too large once decompressed through', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.mode = _UpstreamMode.forceGzip;
        // 同じ文字の繰り返しは 1000 分の 1 ほどに縮むため、送る量は小さい
        upstream!.bodies['/app/huge.html'] = 'a' * (64 * 1024 * 1024 + 1);
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/huge.html'),
          autoUncompress: false,
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.contentEncoding, equals('gzip'));
        expect(response.bodyBytes.length, lessThan(1024 * 1024));
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
      });
    });

    /// 解凍できない更新系の応答は、状態コードを変えず、キューへ入れないこと
    test('keeps the status of an undecodable update response', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.mode = _UpstreamMode.brokenGzip;
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final client = HttpClient()..autoUncompress = false;
        try {
          final request = await client.postUrl(
            Uri.parse('http://127.0.0.1:$port/api/records'),
          );
          request.headers.contentType = ContentType.json;
          request.write('{"a":1}');
          final response = await request.close();
          await response.drain<void>();

          expect(response.statusCode, equals(HttpStatus.ok));
          expect(response.headers.value('content-encoding'), equals('gzip'));
          expect(response.headers.value('x-offline-queued'), isNull);
        } finally {
          client.close(force: true);
        }
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// WebStorage の引き継ぎでも、解凍できない HTML は加工せずに返すこと
    test('leaves an undecodable html alone for web storage inheritance',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.mode = _UpstreamMode.brokenGzip;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            enableWebStorageInheritance: true,
          ),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
          autoUncompress: false,
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.contentEncoding, equals('gzip'));
        expect(utf8.decode(response.bodyBytes), equals(_responseBody));
      });
    });
  });

  group('圧縮を無効にした場合（doc/specs.ja.md 【7】レスポンス圧縮）', () {
    /// 転送経路とウォームアップが identity を送ること
    test('sends identity while forwarding and warming up', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            enableUpstreamCompression: false,
          ),
        );

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));
        await proxy.warmupCache(paths: ['/app/warm.html']);

        expect(
          upstream!.receivedAcceptEncodings['/app/index.html'],
          equals('identity'),
        );
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
        upstream!.mode = _UpstreamMode.forceGzip;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
            enableUpstreamCompression: false,
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
        upstream!.mode = _UpstreamMode.forceGzip;
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
            enableUpstreamCompression: false,
          ),
        );
        await proxy.cacheReady;

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
