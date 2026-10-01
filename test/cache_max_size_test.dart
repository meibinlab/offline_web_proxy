import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = <String, List<String>>{};

/// 1 件あたりの本文の大きさ（バイト）。
const int _bodySize = 100;

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// パスごとに決まった大きさの本文を返す上流サーバのモック。
///
/// 本文は `max-age` 付きで返し、通常の保存判定で保存されるようにする。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        final size = sizes[request.uri.path] ?? _bodySize;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'json')
          ..headers.set('cache-control', 'max-age=3600')
          ..add(List<int>.filled(size, 0x61));
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// パスごとの本文の大きさ。未登録のパスは [_bodySize] を返す。
  final Map<String, int> sizes = <String, int>{};

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

/// 実 HttpClient で GET を実行する。
///
/// [uri] は要求先です。戻り値はステータスと `X-Offline-Source` の値です。
Future<({int statusCode, String? offlineSource})> _get(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    await response.drain<void>();
    return (
      statusCode: response.statusCode,
      offlineSource: response.headers.value('x-offline-source'),
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
    hiveTestDirectory =
        Directory.systemTemp.createTempSync('offline_web_proxy_cache_max').path;
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

  /// 上流とキャッシュの上限を指定して proxy を起動する。
  ///
  /// [cacheMaxSize] は応答キャッシュの上限です。戻り値は proxy のポートです。
  /// 上流は起動済みのものがあれば使い回し、キャッシュのキーを揃える。
  /// 応答キャッシュを開き終わるまで待ってから返す。
  Future<int> startProxy(int cacheMaxSize) async {
    upstream ??= await _startMockUpstream();
    final port = await proxy.start(
      config: ProxyConfig(
        origin: upstream!.origin,
        cacheMaxSize: cacheMaxSize,
      ),
    );
    // 応答キャッシュは start() の後に裏で開くため、開き終わるのを待つ
    await proxy.cacheReady;
    return port;
  }

  /// 指定したパスを順に取得し、キャッシュへ保存させる。
  ///
  /// 保存した日時で順を決めるため、間を空けて取得する。
  Future<void> fetchAll(int port, List<String> paths) async {
    for (final path in paths) {
      await _get(Uri.parse('http://127.0.0.1:$port$path'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// オフラインのときにキャッシュから返せるパスを返す。
  Future<List<String>> cachedPaths(int port, List<String> paths) async {
    await _emitConnectivity(['none']);
    final cached = <String>[];
    for (final path in paths) {
      final response = await _get(Uri.parse('http://127.0.0.1:$port$path'));
      if (response.statusCode == HttpStatus.ok &&
          response.offlineSource == 'cache') {
        cached.add(path);
      }
    }
    return cached;
  }

  group('キャッシュの容量の上限（doc/specs.ja.md 【16】キャッシュ容量・TTL）', () {
    /// 上限を超えたら、保存した日時の古いものから削除すること
    test('removes the oldest entries once the total exceeds the limit',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy(_bodySize * 2 + 50);
        final events = <ProxyEvent>[];
        final subscription = proxy.events.listen(events.add);

        await fetchAll(port, ['/a', '/b', '/c']);

        final stats = await proxy.getCacheStats();
        expect(stats.totalEntries, equals(2));
        expect(stats.totalSize, equals(_bodySize * 2));
        final cleared = events
            .where((event) => event.type == ProxyEventType.cacheEvicted)
            .single;
        expect(cleared.data['reason'], equals('cacheMaxSize'));
        expect(cleared.data['evictedCount'], equals(1));
        expect(cleared.data['evictedBytes'], equals(_bodySize));
        await subscription.cancel();

        expect(await cachedPaths(port, ['/a', '/b', '/c']), ['/b', '/c']);
      });
    });

    /// 上限の 9 割まで下げ、上限に張り付いたまま毎回削除しないこと
    test('removes down to 90 percent of the limit', () async {
      await withRealHttpClient(() async {
        // 上限 500、下げる先 450。6 件目で 600 になり、2 件消して 400 になる
        final port = await startProxy(_bodySize * 5);
        final events = <ProxyEvent>[];
        final subscription = proxy.events.listen(events.add);

        await fetchAll(port, ['/a', '/b', '/c', '/d', '/e', '/f']);
        // 400 からもう 1 件足しても 500 に収まり、削除は起きない
        await fetchAll(port, ['/g']);

        final evicted = events
            .where((event) => event.type == ProxyEventType.cacheEvicted)
            .toList();
        expect(evicted, hasLength(1));
        expect(evicted.single.data['evictedCount'], equals(2));
        expect((await proxy.getCacheStats()).totalSize, equals(_bodySize * 5));
        await subscription.cancel();
      });
    });

    /// 同時に保存しても、上限を超えたまま残らず、合計がずれないこと
    test('keeps the total within the limit under concurrent saves', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(_bodySize * 5 + 50);

        await Future.wait([
          for (var i = 0; i < 12; i++)
            _get(Uri.parse('http://127.0.0.1:$port/p$i')),
        ]);

        final stats = await proxy.getCacheStats();
        expect(stats.totalSize, lessThanOrEqualTo(_bodySize * 5 + 50));
        expect(stats.totalSize, equals(stats.totalEntries * _bodySize));
        // 下げる先（495）より下へ削りすぎないこと
        expect(stats.totalEntries, greaterThanOrEqualTo(4));
      });
    });

    /// 同じ URL を保存し直しても、合計を二重に数えないこと
    test('does not count a replaced entry twice', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(_bodySize * 2 + 50);

        await fetchAll(port, ['/a', '/b', '/a', '/a']);

        final stats = await proxy.getCacheStats();
        expect(stats.totalEntries, equals(2));
        expect(stats.totalSize, equals(_bodySize * 2));
      });
    });

    /// URL を指定して消した分を、合計から外すこと
    test('recounts the total after an entry is cleared', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(_bodySize * 2 + 50);

        await fetchAll(port, ['/a', '/b']);
        await proxy.clearCacheForUrl('${upstream!.origin}/a');
        await fetchAll(port, ['/c']);

        // 消した /a を数えたままなら、/b まで削除される
        expect((await proxy.getCacheStats()).totalEntries, equals(2));
        expect(await cachedPaths(port, ['/b', '/c']), ['/b', '/c']);
      });
    });

    /// 本文だけで上限を超える応答は保存せず、他の記録も残すこと
    test('skips a response larger than the limit on its own', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(_bodySize * 2 + 50);
        upstream!.sizes['/huge'] = _bodySize * 3;
        final events = <ProxyEvent>[];
        final subscription = proxy.events.listen(events.add);

        await fetchAll(port, ['/a', '/huge']);

        final stats = await proxy.getCacheStats();
        expect(stats.totalEntries, equals(1));
        expect(stats.totalSize, equals(_bodySize));
        final skipped = events
            .where((event) => event.type == ProxyEventType.cacheSkipped)
            .single;
        expect(skipped.data['reason'], equals('cacheMaxSize'));
        expect(skipped.url, contains('huge'));
        expect(
          events.where((event) => event.type == ProxyEventType.cacheEvicted),
          isEmpty,
        );
        await subscription.cancel();
      });
    });

    /// 0 は上限なしとして扱うこと
    test('keeps everything when the limit is zero', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(0);

        await fetchAll(port, ['/a', '/b', '/c', '/d']);

        expect((await proxy.getCacheStats()).totalEntries, equals(4));
      });
    });

    /// 負の値は起動時に拒否すること
    test('rejects a negative limit', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();

        await expectLater(
          proxy.start(
            config: ProxyConfig(origin: upstream!.origin, cacheMaxSize: -1),
          ),
          throwsA(isA<ProxyStartException>()),
        );
      });
    });

    /// 起動前から上限を超えていた分も、次の保存で削除すること
    test('applies the limit to entries kept from a previous run', () async {
      await withRealHttpClient(() async {
        var port = await startProxy(0);
        await fetchAll(port, ['/a', '/b', '/c']);
        await proxy.stop();

        port = await startProxy(_bodySize * 2 + 50);
        await fetchAll(port, ['/d']);

        final stats = await proxy.getCacheStats();
        expect(stats.totalEntries, equals(2));
        expect(await cachedPaths(port, ['/a', '/b', '/c', '/d']), ['/c', '/d']);
      });
    });
  });
}
