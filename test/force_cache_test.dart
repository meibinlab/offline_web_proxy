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

/// 応答キャッシュの保存領域名。保存に失敗する状況を作るために使用する。
const String _cacheBoxName = 'proxy_cache';

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// 応答ヘッダを差し替えられる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        receivedPaths.add(request.uri.path);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        responseHeaders.forEach(request.response.headers.set);
        multiValueResponseHeaders.forEach((name, values) {
          for (final value in values) {
            request.response.headers.add(name, value);
          }
        });
        request.response.write(body);
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 上流が受信したパスの一覧。受信順に追加される。
  final List<String> receivedPaths = <String>[];

  /// 応答に付与するヘッダ。テスト中に差し替える。
  Map<String, String> responseHeaders = <String, String>{
    'Cache-Control': 'no-store',
  };

  /// 応答に複数行で付与するヘッダ。`Vary` のように行が分かれる場合に使う。
  Map<String, List<String>> multiValueResponseHeaders =
      <String, List<String>>{};

  /// 応答本文。
  String body = '<html><body>screen</body></html>';

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
/// [uri] は要求先です。[headers] は付与するリクエストヘッダです。
/// 戻り値はステータス、本文、および判定に使う応答ヘッダです。
Future<
    ({
      int statusCode,
      String body,
      String? offlineSource,
      String? cacheStatus,
    })> _performGet(
  Uri uri, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      body: body,
      offlineSource: response.headers.value('x-offline-source'),
      cacheStatus: response.headers.value('x-cache-status'),
    );
  } finally {
    client.close(force: true);
  }
}

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
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_force_cache')
        .path;
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

  group('forceCachePaths（doc/specs.ja.md 【8】キャッシュ整合性）', () {
    /// 既定では no-store の応答を保存しないこと
    test('does not store a no-store response when no path is listed', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
      });
    });

    /// 指定したパスの no-store 応答は保存され、オフラインで返せること
    test('stores a listed no-store response and serves it offline', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));
        expect((await proxy.getCacheStats()).totalEntries, equals(1));

        await _emitConnectivity(['none']);
        final offlineResponse = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
        );

        expect(offlineResponse.statusCode, equals(HttpStatus.ok));
        expect(
            offlineResponse.body, equals('<html><body>screen</body></html>'));
        expect(offlineResponse.offlineSource, equals('cache'));
      });
    });

    /// 一致しないパスの no-store 応答は保存しないこと
    test('does not store a no-store response outside the listed paths',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/other/index.html'));

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        // 対象外のパスは判定自体を行わないため通知もしないこと
        expect(skippedReasons, isEmpty);
      });
    });

    /// Set-Cookie を伴う応答は指定に一致しても保存しないこと
    test('skips a listed response that carries set-cookie', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-store',
          'Set-Cookie': 'session=abc; Path=/',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(skippedReasons, equals(['set-cookie']));
      });
    });

    /// Vary を伴う応答は指定に一致しても保存しないこと
    test('skips a listed response that carries vary', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-store',
          'Vary': 'Accept-Language',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(skippedReasons, equals(['vary']));
      });
    });

    /// Vary が Accept-Encoding だけの応答は指定に一致すれば保存すること
    test('stores a listed response whose vary is accept-encoding only',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-store',
          'Vary': 'Accept-Encoding',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        // proxy が accept-encoding を固定するため応答は 1 種類に定まる
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        expect(skippedReasons, isEmpty);

        await _emitConnectivity(['none']);
        final offlineResponse = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
        );

        expect(offlineResponse.statusCode, equals(HttpStatus.ok));
        expect(offlineResponse.offlineSource, equals('cache'));
      });
    });

    /// Vary の大文字小文字と余分な空白を吸収して判定すること
    test('normalises the vary value before judging it', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-store',
          'Vary': '  ACCEPT-ENCODING ,  ',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        expect(skippedReasons, isEmpty);
      });
    });

    /// Accept-Encoding 以外も併記する Vary は従来どおり除外すること
    test('skips a listed response whose vary lists another header too',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-store',
          'Vary': 'Accept-Encoding, Cookie',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        // Cookie は利用者ごとに応答が変わるため保存しない
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(skippedReasons, equals(['vary']));
      });
    });

    /// Vary: * は従来どおり除外すること
    test('skips a listed response that carries vary asterisk', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-store',
          'Vary': '*',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(skippedReasons, equals(['vary']));
      });
    });

    /// 複数行に分かれた Vary も 1 つの値として判定すること
    test('judges a vary split across several header lines as one value',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.multiValueResponseHeaders = <String, List<String>>{
          'Vary': <String>['Accept-Encoding', 'Cookie'],
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        // 行が分かれていても Cookie を見落とさないこと
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(skippedReasons, equals(['vary']));
      });
    });

    /// ヘッダ名を 1 つも挙げない Vary は保存を妨げないこと
    test('stores a listed response whose vary names no header', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-store',
          'Vary': ' , ',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        // 差の生じる要求ヘッダを 1 つも示していないため保存を妨げないこと
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        expect(skippedReasons, isEmpty);
      });
    });

    /// Set-Cookie と Vary: Accept-Encoding が併存する場合は Set-Cookie を優先すること
    test('reports set-cookie when it accompanies an accept-encoding vary',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-store',
          'Set-Cookie': 'session=abc; Path=/',
          'Vary': 'Accept-Encoding',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        // Vary を緩和しても Set-Cookie による除外は変わらないこと
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(skippedReasons, equals(['set-cookie']));
      });
    });

    /// Authorization を伴う要求の応答は指定に一致しても保存しないこと
    test('skips a listed response requested with authorization', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
          headers: const {'Authorization': 'Bearer token'},
        );

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(skippedReasons, equals(['authorization']));
      });
    });

    /// no-store が無い応答は従来どおり保存し、通知もしないこと
    test('keeps storing a response without no-store and stays silent',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Set-Cookie': 'session=abc; Path=/',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        final skippedReasons = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .listen((event) => skippedReasons.add('${event.data['reason']}'));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        expect(skippedReasons, isEmpty);
      });
    });

    /// `*` は下位セグメントに一致しないこと
    test('does not match a nested path with a single segment wildcard',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/*'],
          ),
        );

        await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/nested/index.html'),
        );
        expect((await proxy.getCacheStats()).totalEntries, equals(0));

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
      });
    });

    /// max-age=0 を伴う no-store でも設定の TTL で保存されること
    test('applies the configured ttl when the response also sends max-age=0',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        // Spring Security の既定に近い、no-store と max-age=0 の併記
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-cache, no-store, max-age=0, must-revalidate',
        };
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));
        expect((await proxy.getCacheStats()).freshEntries, equals(1));

        await _emitConnectivity(['none']);
        final offlineResponse = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
        );

        // max-age=0 をそのまま採用すると即座に stale になる
        expect(offlineResponse.cacheStatus, equals('hit'));
      });
    });

    /// 再起動で設定を変えた場合、前回のパターンが残らないこと
    test('drops the compiled patterns when the proxy restarts without them',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final firstPort = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/**'],
          ),
        );

        await _performGet(
          Uri.parse('http://127.0.0.1:$firstPort/app/index.html'),
        );
        expect((await proxy.getCacheStats()).totalEntries, equals(1));

        await proxy.stop();

        final secondPort = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );
        // 前回の保存内容と区別するため、判定前に空にする
        await proxy.clearCache();
        expect((await proxy.getCacheStats()).totalEntries, equals(0));

        await _performGet(
          Uri.parse('http://127.0.0.1:$secondPort/app/index.html'),
        );

        expect((await proxy.getCacheStats()).totalEntries, equals(0));
      });
    });

    /// クエリ付きの URL でもパス部分で照合すること
    test('matches on the path even when the url carries a query', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            forceCachePaths: const ['/app/index.html'],
          ),
        );

        await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html?v=20260909'),
        );

        expect((await proxy.getCacheStats()).totalEntries, equals(1));
      });
    });
  });

  group('キャッシュ有効期限の算出（doc/specs.ja.md 【8】キャッシュ整合性）', () {
    /// 解釈できない Expires を伴う応答でも上流の 200 をそのまま返すこと
    test('returns the upstream response even when expires cannot be parsed',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        // 旧来の Web システムでよく使われる `Expires: 0`。日時として解析できず、
        // 例外が保存処理から伝播すると転送失敗として扱われてしまう。
        upstream!.responseHeaders = <String, String>{
          'Cache-Control': 'no-cache',
          'Expires': '0',
        };
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.body, equals('<html><body>screen</body></html>'));
        // 既定 TTL で保存され、オフラインでも使えること
        expect((await proxy.getCacheStats()).freshEntries, equals(1));
      });
    });

    /// 解析できる Expires は従来どおり有効期限へ反映すること
    test('still honours a parsable expires header', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{
          'Expires': HttpDate.format(
            DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          ),
        };
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        await _performGet(Uri.parse('http://127.0.0.1:$port/app/index.html'));

        // 過去日時の Expires は即座に stale となること
        expect((await proxy.getCacheStats()).freshEntries, equals(0));
        expect((await proxy.getCacheStats()).staleEntries, equals(1));
      });
    });
  });

  group('キャッシュ保存の失敗（doc/specs.ja.md 【8】キャッシュ整合性）', () {
    /// 保存に失敗しても上流から受け取れた応答をそのまま返すこと
    test('returns the upstream response even when the cache write fails',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.responseHeaders = <String, String>{};
        final port = await proxy.start(
          config: ProxyConfig(origin: upstream!.origin),
        );

        final errorPhases = <String>[];
        proxy.events
            .where((event) => event.type == ProxyEventType.errorOccurred)
            .listen((event) => errorPhases.add('${event.data['phase']}'));

        // 保存領域が使えない状況を作る（容量不足や停止処理との競合に相当）
        await Hive.box(_cacheBoxName).close();

        final response = await _performGet(
          Uri.parse('http://127.0.0.1:$port/app/index.html'),
        );

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.body, equals('<html><body>screen</body></html>'));
        expect(errorPhases, equals(['cacheResponse']));
      });
    });
  });
}
