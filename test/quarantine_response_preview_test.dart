import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// 最初の転送を 500 で断ってキューへ入れ、キューからの送信を指定の応答で
/// 断る上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        final isReplay = request.headers.value('x-offline-replay') == '1';
        if (isReplay) {
          replayRemotePorts.add(request.connectionInfo!.remotePort);
        }
        if (!isReplay) {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
          return;
        }
        request.response.statusCode = replayStatusCode;
        if (replayContentType == null) {
          // dart:io が既定で付ける text/plain を外す
          request.response.headers.removeAll('content-type');
        } else {
          request.response.headers.set('content-type', replayContentType!);
        }
        if (replayContentEncoding != null) {
          request.response.headers
              .set('content-encoding', replayContentEncoding!);
        }
        final delay = replayBodyDelay;
        if (delay != null && replayBody.isNotEmpty) {
          // 先頭だけ送ってから止め、本文の受信中に締め切りを過ぎさせる
          request.response.add(replayBody.sublist(0, 1));
          await request.response.flush();
          await Future<void>.delayed(delay);
          request.response.add(replayBody.sublist(1));
        } else {
          request.response.add(replayBody);
        }
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// キューからの送信に返すステータスコード。
  int replayStatusCode = HttpStatus.badRequest;

  /// キューからの送信に返す `Content-Type`。
  String? replayContentType = 'application/json';

  /// キューからの送信に返す `Content-Encoding`。
  String? replayContentEncoding;

  /// キューからの送信に返す本文。
  List<int> replayBody = utf8.encode('{"error":"not assigned"}');

  /// キューからの送信を受けた接続の、proxy 側のポート番号。受信順に追加される。
  final List<int> replayRemotePorts = <int>[];

  /// 指定した場合、本文の 2 バイト目以降を送るまで待たせる。
  Duration? replayBodyDelay;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// [check] が真を返すまで待機する。
///
/// [timeout] を超えた場合は待機を打ち切り、呼び出し側のアサーションに委ねます。
Future<void> _waitUntil(
  FutureOr<bool> Function() check, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
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
  late _MockUpstream upstream;

  setUp(() async {
    hiveTestDirectory =
        Directory.systemTemp.createTempSync('offline_web_proxy_preview').path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    proxy = OfflineWebProxy();
    upstream = _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream.close();
  });

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: _RealHttpOverrides().createHttpClient,
    );
  }

  /// proxy を起動して 1 件をキューへ入れ、上流に断られて隔離されるまで待つ。
  ///
  /// [maxBytes] 残す応答本文の上限。
  /// [enableAdminApi] 管理 API を有効にするかどうか。
  ///
  /// Returns: 隔離された要求と、proxy のポート番号。
  Future<({QuarantinedRequest request, int port})> quarantineOne({
    int maxBytes = 1024,
    bool enableAdminApi = false,
  }) async {
    final port = await proxy.start(
      config: ProxyConfig(
        origin: upstream.origin,
        quarantineResponseBodyMaxBytes: maxBytes,
        enableAdminApi: enableAdminApi,
      ),
    );
    final client = HttpClient();
    try {
      final request =
          await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/photos'));
      request.write('{"photo":1}');
      final response = await request.close();
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }

    await _waitUntil(
        () async => (await proxy.getQuarantinedRequests()).isNotEmpty);
    final quarantined = await proxy.getQuarantinedRequests();
    expect(quarantined, hasLength(1));
    return (request: quarantined.single, port: port);
  }

  /// 上流の 5xx で、更新系を [count] 件キューへ入れる。
  Future<void> postRecords(int port, int count) async {
    for (var i = 0; i < count; i++) {
      final client = HttpClient();
      try {
        final request = await client
            .postUrl(Uri.parse('http://127.0.0.1:$port/api/photos'));
        request.write('{"photo":$i}');
        final response = await request.close();
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    }
  }

  group('隔離に残す応答本文（doc/specs.ja.md 【5】隔離に残す応答本文）', () {
    /// 既定では本文を残さないこと
    test('keeps no body by default', () async {
      await withRealHttpClient(() async {
        final result = await quarantineOne(maxBytes: 0);
        expect(result.request.statusCode, equals(HttpStatus.badRequest));
        expect(result.request.errorMessage, equals('HTTP 400'));
        expect(result.request.responseBodyPreview, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// JSON の本文を残し、起動し直しても読めること
    test('keeps a JSON body and restores it after a restart', () async {
      await withRealHttpClient(() async {
        final result = await quarantineOne();
        expect(result.request.responseBodyPreview,
            equals('{"error":"not assigned"}'));
        expect(result.request.errorMessage, equals('HTTP 400'));

        await proxy.stop();
        await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            quarantineResponseBodyMaxBytes: 1024,
          ),
        );
        final restored = await proxy.getQuarantinedRequests();
        expect(restored.single.responseBodyPreview,
            equals('{"error":"not assigned"}'));
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// +json と text/* を残し、それ以外の種類は残さないこと
    test('keeps only textual content types in UTF-8', () async {
      final cases = <String?, bool>{
        'application/problem+json': true,
        'text/plain; charset=utf-8': true,
        'text/html': true,
        'text/plain; charset=us-ascii': true,
        'text/plain; charset=Shift_JIS': false,
        'application/octet-stream': false,
        'image/png': false,
        null: false,
      };
      await withRealHttpClient(() async {
        for (final entry in cases.entries) {
          upstream.replayContentType = entry.key;
          final result = await quarantineOne();
          expect(result.request.responseBodyPreview,
              entry.value ? equals('{"error":"not assigned"}') : isNull,
              reason: 'Content-Type: ${entry.key}');
          await proxy.clearQuarantinedRequests();
          await proxy.stop();
        }
      });
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// 上限で切り、UTF-8 の文字の途中では切らないこと
    test('cuts at the limit on a character boundary', () async {
      await withRealHttpClient(() async {
        // 「あ」は 3 バイト。4 バイト目で切ると 2 文字目の途中になる
        upstream.replayContentType = 'text/plain';
        upstream.replayBody = utf8.encode('あいうえお');
        final result = await quarantineOne(maxBytes: 4);
        expect(result.request.responseBodyPreview, equals('あ'));
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// gzip で圧縮した本文は解凍してから先頭を残すこと
    test('decompresses a gzip body before keeping it', () async {
      await withRealHttpClient(() async {
        upstream.replayContentEncoding = 'gzip';
        upstream.replayBody = gzip.encode(utf8.encode('{"error":"gzip"}'));
        final result = await quarantineOne(maxBytes: 8);
        expect(result.request.responseBodyPreview, equals('{"error"'));
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// proxy が求めない圧縮方式の本文は残さないこと
    test('keeps no body in another encoding', () async {
      await withRealHttpClient(() async {
        upstream.replayContentEncoding = 'br';
        upstream.replayBody = [1, 2, 3];
        final result = await quarantineOne();
        expect(result.request.responseBodyPreview, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// 管理 API の一覧には本文の先頭を含めないこと
    test('is not returned by the admin API', () async {
      await withRealHttpClient(() async {
        final result = await quarantineOne(enableAdminApi: true);
        expect(result.request.responseBodyPreview, isNotNull);

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(
              'http://127.0.0.1:${result.port}/__offline_web_proxy/admin/quarantine'));
          final response = await request.close();
          final body = await utf8.decoder.bind(response).join();
          expect(response.statusCode, equals(HttpStatus.ok));
          expect(body, isNot(contains('not assigned')));
          expect(body, isNot(contains('responseBodyPreview')));
        } finally {
          client.close(force: true);
        }
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// 本文の先頭を含めると 1 件で上限を超える場合は、先頭を外して隔離すること
    test('drops the text rather than the request when it does not fit',
        () async {
      await withRealHttpClient(() async {
        upstream.replayContentType = 'text/plain';
        upstream.replayBody = utf8.encode('x' * 1000);
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            quarantineResponseBodyMaxBytes: 1000,
            quarantineMaxBytes: 500,
          ),
        );
        await postRecords(port, 1);

        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined.single.responseBodyPreview, isNull);
        expect(await proxy.getDroppedRequests(), isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// 本文の先頭も隔離の合計バイト数に数えること
    test('counts the body toward quarantineMaxBytes', () async {
      await withRealHttpClient(() async {
        upstream.replayContentType = 'text/plain';
        upstream.replayBody = utf8.encode('x' * 1000);
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            quarantineResponseBodyMaxBytes: 1000,
            // 先頭が無ければ 2 件とも収まり、先頭を含めると 1 件だけ収まる上限
            quarantineMaxBytes: 1500,
          ),
        );
        await postRecords(port, 2);

        // 追い出しはドロップ履歴へ記録してから隔離から消すため、両方を待つ
        await _waitUntil(() async =>
            (await proxy.getDroppedRequests()).isNotEmpty &&
            (await proxy.getQuarantinedRequests()).length == 1);
        expect(await proxy.getQuarantinedRequests(), hasLength(1));
        expect((await proxy.getDroppedRequests()).single.dropReason,
            equals('quarantine_limit'));
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// 大きな本文の先頭を読んだ後も接続を解放し、後続の再送が止まらないこと
    test('keeps resending after reading the start of large bodies', () async {
      await withRealHttpClient(() async {
        upstream.replayContentType = 'text/plain';
        upstream.replayBody = utf8.encode('y' * (512 * 1024));
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            quarantineResponseBodyMaxBytes: 10,
          ),
        );
        await postRecords(port, 3);

        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).length == 3);
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined, hasLength(3));
        expect(quarantined.every((r) => r.responseBodyPreview == 'y' * 10),
            isTrue);
        expect(await proxy.getQueuedRequests(), isEmpty);
        // 本文を最後まで受信して接続を解放し、同じ接続で後続を送ること。
        // キューへ入れている間に定期処理が重なると接続が 2 本になり得るため、
        // 接続の数が再送の件数より少ないこと（再利用したこと）を確かめる
        expect(upstream.replayRemotePorts, hasLength(3));
        expect(upstream.replayRemotePorts.toSet().length, lessThan(3));
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// 本文の受信中に締め切りを過ぎた場合は、先頭なしで隔離すること
    test('quarantines without text when the body times out', () async {
      await withRealHttpClient(() async {
        upstream.replayBodyDelay = const Duration(seconds: 3);
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream.origin,
            quarantineResponseBodyMaxBytes: 1024,
            requestTimeout: const Duration(seconds: 1),
          ),
        );
        await postRecords(port, 1);

        await _waitUntil(
            () async => (await proxy.getQuarantinedRequests()).isNotEmpty);
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined.single.statusCode, equals(HttpStatus.badRequest));
        expect(quarantined.single.responseBodyPreview, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// 256 KB を超える gzip の本文は残さないこと
    test('keeps no text for a gzip body over 256 KB', () async {
      await withRealHttpClient(() async {
        final random = Random(1);
        final noise =
            List<int>.generate(300 * 1024, (_) => random.nextInt(256));
        upstream.replayContentType = 'text/plain';
        upstream.replayContentEncoding = 'gzip';
        upstream.replayBody = gzip.encode(noise);
        expect(upstream.replayBody.length, greaterThan(256 * 1024));

        final result = await quarantineOne();
        expect(result.request.responseBodyPreview, isNull);
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// 隔離から送り直すときは本文の先頭を消し、再び断られたら新しい本文を残すこと
    test('replaces the body when a retried request is refused again', () async {
      await withRealHttpClient(() async {
        final first = await quarantineOne();
        upstream.replayBody = utf8.encode('{"error":"second"}');

        expect(await proxy.retryQuarantinedRequest(first.request.id), isTrue);
        await _waitUntil(() async {
          final quarantined = await proxy.getQuarantinedRequests();
          return quarantined.length == 1 &&
              quarantined.single.id != first.request.id;
        });
        expect(
            (await proxy.getQuarantinedRequests()).single.responseBodyPreview,
            equals('{"error":"second"}'));
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// 範囲外の上限は起動時に拒否すること
    test('rejects limits outside 0-65536', () async {
      for (final value in [-1, 65537]) {
        await expectLater(
          proxy.start(
            config: ProxyConfig(
              origin: upstream.origin,
              quarantineResponseBodyMaxBytes: value,
            ),
          ),
          throwsA(isA<ProxyStartException>().having((error) => error.message,
              'message', contains('quarantineResponseBodyMaxBytes'))),
        );
      }
      await proxy.start(
        config: ProxyConfig(
          origin: upstream.origin,
          quarantineResponseBodyMaxBytes: 65536,
        ),
      );
      expect(proxy.isRunning, isTrue);
    });
  });
}
