import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

import 'support/access_token_http.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// ログインのパス。
const String _loginPath = '/api/login.json';

/// 既定（暗号化）の応答キャッシュの、メタデータの Box 名。
const String _encryptedIndexBoxName = 'proxy_cache_index_secure';

/// 平文の応答キャッシュの、メタデータの Box 名。
const String _plainIndexBoxName = 'proxy_cache_index';

/// 平文の応答キャッシュの、本文の Box 名。
const String _plainBodyBoxName = 'proxy_cache_body';

/// 利用者ごとにセッションを返し、受け取った Cookie を本文へ書く上流サーバの
/// モック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        if (request.uri.path == _loginPath) {
          if (!loginReceived.isCompleted) {
            loginReceived.complete();
          }
          final gate = loginGate;
          if (gate != null) {
            await gate.future;
          }
          final account =
              (jsonDecode(body) as Map<String, dynamic>)['account'] as String;
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..headers.add('set-cookie', 'session=$account; Path=/')
            ..write(jsonEncode({'ok': true}));
          await request.response.close();
          return;
        }

        if (request.uri.path == '/page' || request.uri.path == '/app/page') {
          final gate = pageGate;
          if (gate != null) {
            if (!pageReceived.isCompleted) {
              pageReceived.complete();
            }
            await gate.future;
          }
          if (dropPage) {
            // 応答を返さずに切断し、上流へ到達できなかった場合にする
            final socket =
                await request.response.detachSocket(writeHeaders: false);
            socket.destroy();
            return;
          }
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType =
              ContentType('text', 'plain', charset: 'utf-8');
          pageHeaders.forEach((name, values) {
            for (final value in values) {
              request.response.headers.add(name, value);
            }
          });
          request.response.write(
            'page:${request.headers.value('cookie') ?? 'none'}',
          );
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// `/page` と `/app/page` の応答に付けるヘッダ。テスト中に差し替える。
  Map<String, List<String>> pageHeaders = <String, List<String>>{
    'cache-control': ['max-age=3600'],
  };

  /// `true` の場合、`/page` と `/app/page` へ応答せずに切断する。
  bool dropPage = false;

  /// 指定した場合、`/page` と `/app/page` への応答を完了するまで待たせる。
  Completer<void>? pageGate;

  /// [pageGate] で待たせる要求を受け取ったときに完了する。
  Completer<void> pageReceived = Completer<void>();

  /// 指定した場合、ログインへの応答を完了するまで待たせる。
  Completer<void>? loginGate;

  /// ログインを受け取ったときに完了する。
  Completer<void> loginReceived = Completer<void>();

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 実 HttpClient で読み取り要求を実行した結果。
typedef _GetResult = ({
  int statusCode,
  String body,
  String? offlineSource,
  List<String> setCookies,
  String? setCookie2,
});

/// 実 HttpClient で `GET` を実行する。
///
/// [uri] 要求先。
/// [headers] 付与する要求ヘッダ。
///
/// Returns: ステータス、本文、`X-Offline-Source`、`Set-Cookie` の一覧、
///   `Set-Cookie2`。
Future<_GetResult> _get(
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
      setCookies: response.headers['set-cookie'] ?? const <String>[],
      setCookie2: response.headers.value('set-cookie2'),
    );
  } finally {
    client.close(force: true);
  }
}

/// 実 HttpClient で `POST` を実行する。
///
/// [uri] 要求先。
/// [body] JSON の本文。
///
/// Returns: 応答のステータスコード。
Future<int> _post(Uri uri, String body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// connectivity_plus の状態変化イベントを擬似送信する。
///
/// [statuses] `['none']` や `['wifi']` のような接続状態一覧。
Future<void> _emitConnectivity(List<String> statuses) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'dev.fluttercommunity.plus/connectivity_status',
    const StandardMethodCodec().encodeSuccessEnvelope(statuses),
    (ByteData? _) {},
  );
}

/// ログインの要求本文の `account` を返す。
String? _resolveAccount(QueueOwnerContext context) {
  return switch (context.requestJson) {
    {'account': final String account} => account,
    _ => null,
  };
}

/// 利用者の識別子から、proxy が保存する持ち主の HMAC を作り直す。
///
/// `doc/specs.ja.md`【5】の「持ち主の保存」の形式に合わせる。
///
/// [identifier] 利用者の識別子。
///
/// Returns: HMAC-SHA256 の 16 進数表記。
Future<String> _ownerDigest(String identifier) async {
  final stored = await const FlutterSecureStorage().readAll();
  expect(stored, hasLength(1));
  final key = base64Decode(stored.values.single);
  final ownerKey = Hmac(sha256, key)
      .convert(utf8.encode('offline_web_proxy.queue_owner_key'))
      .bytes;
  return Hmac(sha256, ownerKey).convert(utf8.encode(identifier)).toString();
}

/// Cookie Jar へ置く `session` Cookie。
///
/// [value] Cookie の値。
///
/// Returns: 復元する Cookie の一覧。
List<CookieRestoreEntry> _session(String value) => [
      CookieRestoreEntry(name: 'session', value: value, domain: '127.0.0.1'),
    ];

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
  late List<ProxyEvent> events;
  StreamSubscription<ProxyEvent>? subscription;

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_cache_owner')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    proxy = trackAccessToken(OfflineWebProxy());
    upstream = _MockUpstream(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    events = <ProxyEvent>[];
    subscription = proxy.events.listen(events.add);
  });

  tearDown(() async {
    for (final gate in [upstream.pageGate, upstream.loginGate]) {
      if (gate != null && !gate.isCompleted) {
        gate.complete();
      }
    }
    await subscription?.cancel();
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream.close();
  });

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: AccessTokenHttpOverrides().createHttpClient,
    );
  }

  /// proxy を起動し、応答キャッシュを開き終わるまで待つ。
  ///
  /// [resolver] 持ち主の判定関数。
  /// [cacheUserScopedResponses] 利用者ごとの応答を保存するかどうか。
  /// [encryptResponseCache] 応答キャッシュを暗号化するかどうか。
  /// [forceCachePaths] `no-store` を無視して保存するパス。
  /// [authResumePaths] ログインのパス。
  /// [upstreamFailureThreshold] 上流を遮断するまでの連続失敗回数。既定では、
  ///   上流へ到達できない応答を続けても遮断せずに同じ経路を通す。
  /// [upstreamProbePath] 遮断中に到達を確かめるパス。
  ///
  /// Returns: proxy のポート番号。
  Future<int> startProxy({
    QueueOwnerResolver? resolver = _resolveAccount,
    bool cacheUserScopedResponses = true,
    bool encryptResponseCache = true,
    List<String> forceCachePaths = const [],
    List<String> authResumePaths = const [_loginPath],
    int upstreamFailureThreshold = 100,
    String upstreamProbePath = '/',
  }) async {
    final port = await proxy.start(
      config: ProxyConfig(
        origin: upstream.origin,
        upstreamFailureThreshold: upstreamFailureThreshold,
        upstreamProbePath: upstreamProbePath,
        authResumePaths: authResumePaths,
        queueOwnerResolver: resolver,
        cacheUserScopedResponses: cacheUserScopedResponses,
        encryptResponseCache: encryptResponseCache,
        forceCachePaths: forceCachePaths,
      ),
    );
    await proxy.cacheReady;
    return port;
  }

  /// proxy を通してログインする。
  ///
  /// [port] proxy のポート番号。
  /// [account] 利用者。
  Future<void> signIn(int port, String account) async {
    final status = await _post(
      Uri.parse('http://127.0.0.1:$port$_loginPath'),
      jsonEncode({'account': account}),
    );
    expect(status, equals(HttpStatus.ok));
  }

  /// proxy を通して `path` を取得する。
  ///
  /// [port] proxy のポート番号。
  /// [path] 取得するパス。
  /// [headers] 付与する要求ヘッダ。
  ///
  /// Returns: 応答。
  Future<_GetResult> getPage(
    int port, {
    String path = '/page',
    Map<String, String> headers = const {},
  }) {
    return _get(Uri.parse('http://127.0.0.1:$port$path'), headers: headers);
  }

  /// 指定した種別のイベントの `reason` を、発生順に返す。
  ///
  /// [type] イベントの種別。
  ///
  /// Returns: `reason` の一覧。
  List<String> reasonsOf(ProxyEventType type) => [
        for (final event in events)
          if (event.type == type) '${event.data['reason']}',
      ];

  /// 応答キャッシュのメタデータを 1 件返す。
  ///
  /// [boxName] メタデータの Box 名。
  ///
  /// Returns: 唯一の記録のメタデータ。
  Map<dynamic, dynamic> singleIndexEntry({
    String boxName = _encryptedIndexBoxName,
  }) {
    final values = Hive.box(boxName).values.toList();
    expect(values, hasLength(1));
    return values.single as Map<dynamic, dynamic>;
  }

  group('Set-Cookie を保存しない（doc/specs.ja.md 【8】保存ポリシー）', () {
    /// 保存した記録に Set-Cookie と Set-Cookie2 を残さず、WebView へ返す応答は
    /// 変えないこと
    test('stores a response without its set-cookie headers', () async {
      await withRealHttpClient(() async {
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['max-age=3600'],
          'set-cookie': ['track=secret-value; Path=/'],
          'set-cookie2': ['legacy=secret-value2'],
        };
        final port = await startProxy(
          resolver: null,
          encryptResponseCache: false,
        );

        final online = await getPage(port);
        expect(online.statusCode, equals(HttpStatus.ok));
        // WebView へは従来どおり返すこと
        expect(online.setCookies, contains('track=secret-value; Path=/'));

        final index = singleIndexEntry(boxName: _plainIndexBoxName);
        expect(index.containsKey('ownerTag'), isFalse);
        final key = Hive.box(_plainIndexBoxName).keys.single;
        final stored = await Hive.lazyBox(_plainBodyBoxName).get(key) as Map;
        final storedHeaderNames = (stored['headers'] as Map)
            .keys
            .map((name) => '$name'.toLowerCase())
            .toList();
        expect(storedHeaderNames, isNot(contains('set-cookie')));
        expect(storedHeaderNames, isNot(contains('set-cookie2')));
        expect(storedHeaderNames, contains('cache-control'));

        // ファイルの生データにも Cookie の値が残らないこと
        for (final name in [_plainIndexBoxName, _plainBodyBoxName]) {
          final bytes = File('$hiveTestDirectory/$name.hive').readAsBytesSync();
          expect(latin1.decode(bytes), isNot(contains('secret-value')),
              reason: name);
        }

        await _emitConnectivity(['none']);
        final offline = await getPage(port);
        expect(offline.offlineSource, equals('cache'));
        expect(offline.body, equals('page:none'));
        expect(offline.setCookies, isEmpty);
      });
    });
  });

  group('Set-Cookie2 の旧記録（doc/specs.ja.md 【8】保存ポリシー）', () {
    /// 0.25.0 以前に Set-Cookie と Set-Cookie2 を付けて保存した記録も、
    /// キャッシュから返すときに除くこと
    test('does not serve set-cookie headers stored by an older version',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy(resolver: null);
        final key =
            sha256.convert(utf8.encode('${upstream.origin}/page')).toString();
        final now = DateTime.now();
        // 本文 → メタデータの順に、旧形式のヘッダのまま書く
        await Hive.lazyBox('proxy_cache_body_secure').put(key, {
          'headers': {
            'content-type': 'text/plain',
            'set-cookie': 'old=1; Path=/',
            'set-cookie2': 'legacy=1',
          },
          'body': Uint8List.fromList(utf8.encode('stored')),
        });
        await Hive.box(_encryptedIndexBoxName).put(key, {
          'statusCode': 200,
          'createdAt': now.toIso8601String(),
          'expiresAt': now.add(const Duration(hours: 1)).toIso8601String(),
          'contentType': 'text/plain',
          'sizeBytes': 6,
        });

        await _emitConnectivity(['none']);
        final offline = await getPage(port);
        expect(offline.offlineSource, equals('cache'));
        expect(offline.body, equals('stored'));
        expect(offline.setCookies, isEmpty);
        expect(offline.setCookie2, isNull);
      });
    });
  });

  group('利用者ごとの応答の持ち主（doc/specs.ja.md 【8】保存ポリシー）', () {
    /// 起動し直しても、同じ持ち主ならヒットすること
    test('serves the owner after a restart', () async {
      await withRealHttpClient(() async {
        var port = await startProxy();
        await signIn(port, 'alice');
        await getPage(port);
        await proxy.stop();

        port = await startProxy();
        await _emitConnectivity(['none']);
        final offline = await getPage(port);
        expect(offline.offlineSource, equals('cache'));
        expect(offline.body, equals('page:session=alice'));
        expect(reasonsOf(ProxyEventType.cacheMiss), isEmpty);
      });
    });

    /// 取得を始めた時点で他のログインが転送中なら、保存しないこと
    test('does not store a response fetched while another sign-in runs',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await signIn(port, 'alice');

        upstream.loginGate = Completer<void>();
        final pendingSignIn = signIn(port, 'bob');
        await upstream.loginReceived.future;

        final response = await getPage(port);
        expect(response.statusCode, equals(HttpStatus.ok));
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(
            reasonsOf(ProxyEventType.cacheSkipped), equals(['ownerChanged']));

        upstream.loginGate!.complete();
        await pendingSignIn;
      });
    });

    /// ログインのパスへの GET そのものは、転送中のログインに数えないこと
    test('does not count its own sign-in GET as a sign-in in progress',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          authResumePaths: const [_loginPath, '/page'],
        );
        await signIn(port, 'alice');

        // 判定関数は本文の無い GET に null を返し、持ち主は変わらない
        await getPage(port);
        expect(reasonsOf(ProxyEventType.cacheSkipped), isEmpty);
        expect(singleIndexEntry()['ownerTag'],
            equals(await _ownerDigest('alice')));
      });
    });

    /// Authorization を送った応答にも持ち主のタグを付けること
    test('tags a response fetched with authorization', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        // Cookie を持たないまま alice を持ち主にする
        await proxy.restoreCookies(const [], queueOwnerId: 'alice');

        await getPage(
          port,
          path: '/page?case=authorization',
          headers: {'authorization': 'Bearer token'},
        );
        expect(singleIndexEntry()['ownerTag'],
            equals(await _ownerDigest('alice')));

        // Authorization も Cookie も無い応答は利用者ごとではない
        await getPage(port, path: '/page?case=anonymous');
        final tags = Hive.box(_encryptedIndexBoxName)
            .values
            .map((value) => (value as Map)['ownerTag'])
            .toList();
        expect(tags, hasLength(2));
        expect(tags.where((tag) => tag == null), hasLength(1));
      });
    });

    /// 上流を遮断している間の読み取りでも、持ち主を照合すること
    test('checks the owner while the upstream circuit is open', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          upstreamFailureThreshold: 1,
          // 到達の確認も失敗させ、遮断したままにする
          upstreamProbePath: '/page',
        );
        await signIn(port, 'alice');
        await getPage(port);

        await proxy.restoreCookies(_session('bob'), queueOwnerId: 'bob');
        upstream.dropPage = true;
        // 1 回目で遮断する
        await getPage(port);
        expect((await proxy.getDiagnostics()).upstreamCircuitState,
            equals(UpstreamCircuitState.open));

        final asBob = await getPage(port);
        expect(asBob.offlineSource, isNot(equals('cache')));
        expect(asBob.body, isNot(contains('alice')));
        expect(reasonsOf(ProxyEventType.cacheMiss),
            equals(['ownerMismatch', 'ownerMismatch']));

        await proxy.restoreCookies(_session('alice'), queueOwnerId: 'alice');
        final asAlice = await getPage(port);
        expect(asAlice.offlineSource, equals('cache'));
        expect(asAlice.body, equals('page:session=alice'));
      });
    });

    /// 保存した持ち主にだけ返し、他の持ち主にはミスとすること
    test('serves a user-scoped response only to the owner who stored it',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await signIn(port, 'alice');

        final online = await getPage(port);
        expect(online.body, equals('page:session=alice'));
        // 識別子そのものではなく、持ち主の HMAC を残すこと
        expect(singleIndexEntry()['ownerTag'],
            equals(await _ownerDigest('alice')));

        await signIn(port, 'bob');
        await _emitConnectivity(['none']);

        final asBob = await getPage(port);
        expect(asBob.offlineSource, isNot(equals('cache')));
        expect(asBob.body, isNot(contains('alice')));
        expect(reasonsOf(ProxyEventType.cacheMiss), equals(['ownerMismatch']));

        // 元の持ち主に戻るとヒットすること
        await proxy.restoreCookies(_session('alice'), queueOwnerId: 'alice');
        final asAlice = await getPage(port);
        expect(asAlice.offlineSource, equals('cache'));
        expect(asAlice.body, equals('page:session=alice'));
      });
    });

    /// 上流へ到達できない場合のキャッシュも、持ち主を照合すること
    test('checks the owner when the upstream cannot be reached', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await signIn(port, 'alice');
        expect((await getPage(port)).body, equals('page:session=alice'));

        await proxy.restoreCookies(_session('bob'), queueOwnerId: 'bob');
        upstream.dropPage = true;

        final asBob = await getPage(port);
        expect(asBob.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(asBob.body, isNot(contains('alice')));
        expect(reasonsOf(ProxyEventType.cacheMiss), equals(['ownerMismatch']));

        await proxy.restoreCookies(_session('alice'), queueOwnerId: 'alice');
        final asAlice = await getPage(port);
        expect(asAlice.statusCode, equals(HttpStatus.ok));
        expect(asAlice.body, equals('page:session=alice'));
      });
    });

    /// 正体の分からない持ち主は 1 人の持ち主として扱い、その値が変わると
    /// ミスとすること
    test('treats an unresolved owner as an owner of its own', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await signIn(port, 'alice');
        await getPage(port);

        // 持ち主の分からないセッションでは、alice の応答を返さない
        await proxy.restoreCookies(_session('unknown1'));
        upstream.dropPage = true;
        final unresolvedRead = await getPage(port);
        expect(unresolvedRead.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(reasonsOf(ProxyEventType.cacheMiss), equals(['ownerMismatch']));

        // 正体の分からない持ち主の間に保存した応答は、その間だけ返す
        upstream.dropPage = false;
        expect((await getPage(port)).body, contains('session=unknown1'));
        final ownerTag = singleIndexEntry()['ownerTag'] as String;
        expect(ownerTag, startsWith('unresolved:'));

        upstream.dropPage = true;
        final sameSession = await getPage(port);
        expect(sameSession.statusCode, equals(HttpStatus.ok));
        expect(sameSession.body, contains('session=unknown1'));

        // 別の正体の分からない持ち主になると返さない
        await proxy.restoreCookies(_session('unknown2'));
        final nextSession = await getPage(port);
        expect(nextSession.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(reasonsOf(ProxyEventType.cacheMiss),
            equals(['ownerMismatch', 'ownerMismatch']));
      });
    });

    /// まだ誰もログインしていない間の応答は「持ち主なし」の印を付けて保存し、
    /// 持ち主が無い間だけ返すこと
    test('serves a response stored before sign-in only while no one owns it',
        () async {
      await withRealHttpClient(() async {
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['max-age=3600'],
          'set-cookie': ['visitor=1; Path=/'],
        };
        final port = await startProxy();
        await getPage(port);
        expect(singleIndexEntry()['ownerTag'], equals('none'));

        // 持ち主が無い間はヒットすること
        upstream.dropPage = true;
        final beforeSignIn = await getPage(port);
        expect(beforeSignIn.statusCode, equals(HttpStatus.ok));
        expect(beforeSignIn.body, equals('page:none'));
        expect(reasonsOf(ProxyEventType.cacheMiss), isEmpty);

        // A がログインした後は返さないこと
        await signIn(port, 'alice');
        final afterSignIn = await getPage(port);
        expect(afterSignIn.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(reasonsOf(ProxyEventType.cacheMiss), equals(['ownerMismatch']));

        // ログアウト（clearCookies）で正体の分からない持ち主になっても返さないこと
        await proxy.clearCookies();
        final afterSignOut = await getPage(port);
        expect(afterSignOut.statusCode, equals(HttpStatus.gatewayTimeout));
        expect(reasonsOf(ProxyEventType.cacheMiss),
            equals(['ownerMismatch', 'ownerMismatch']));
      });
    });

    /// 取得している間に持ち主が変わった応答は、保存しないこと
    test('does not store a response when the owner changes meanwhile',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await signIn(port, 'alice');

        upstream.pageGate = Completer<void>();
        final pending = getPage(port);
        await upstream.pageReceived.future;
        await proxy.restoreCookies(_session('bob'), queueOwnerId: 'bob');
        upstream.pageGate!.complete();

        final response = await pending;
        // WebView へは応答を返すこと
        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.body, equals('page:session=alice'));
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(
            reasonsOf(ProxyEventType.cacheSkipped), equals(['ownerChanged']));
      });
    });

    /// 公開 API の CacheEntry には持ち主を載せないこと
    test('does not expose the owner through getCacheList()', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await signIn(port, 'alice');
        await getPage(port);

        final entries = await proxy.getCacheList();
        expect(entries, hasLength(1));
        final digest = await _ownerDigest('alice');
        expect(entries.single.toString(), isNot(contains(digest)));
      });
    });
  });

  group('cacheUserScopedResponses: false（doc/specs.ja.md 【8】保存ポリシー）', () {
    /// Cookie を送った応答を保存しないこと
    test('does not store a response fetched with cookies', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(cacheUserScopedResponses: false);
        await signIn(port, 'alice');

        final online = await getPage(port);
        expect(online.body, equals('page:session=alice'));
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(reasonsOf(ProxyEventType.cacheSkipped), equals(['userScoped']));
      });
    });

    /// Authorization・Set-Cookie・Cache-Control: private の応答を保存せず、
    /// どれにも当てはまらない応答は保存すること
    test('judges authorization, set-cookie and private responses', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          resolver: null,
          cacheUserScopedResponses: false,
        );

        // 応答の Set-Cookie は Cookie Jar に入り、以降は Cookie を送るため先に確かめる
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['public, max-age=3600'],
        };
        await getPage(port, path: '/page?case=shared');
        expect((await proxy.getCacheStats()).totalEntries, equals(1));

        // 共有を許す指示が無い応答で確かめる
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['max-age=3600'],
        };
        await getPage(
          port,
          path: '/page?case=authorization',
          headers: {'authorization': 'Bearer token'},
        );
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['private, max-age=3600'],
        };
        await getPage(port, path: '/page?case=private');
        // Cookie Jar に入る Set-Cookie は最後に確かめる
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['max-age=3600'],
          'set-cookie': ['visitor=1; Path=/'],
        };
        await getPage(port, path: '/page?case=set-cookie');
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
        expect(reasonsOf(ProxyEventType.cacheSkipped),
            equals(['userScoped', 'userScoped', 'userScoped']));
      });
    });
  });

  group('共有を許す Cache-Control（doc/specs.ja.md 【8】利用者ごとの応答）', () {
    /// Cookie を送った応答でも、上流が public で共有を許せば利用者ごとに
    /// しないこと
    test('shares a response fetched with cookies when it says public',
        () async {
      await withRealHttpClient(() async {
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['public, max-age=3600'],
        };
        final port = await startProxy(cacheUserScopedResponses: false);
        await signIn(port, 'alice');

        await getPage(port);
        expect(reasonsOf(ProxyEventType.cacheSkipped), isEmpty);
        expect(singleIndexEntry().containsKey('ownerTag'), isFalse);
      });
    });

    for (final headers in <Map<String, List<String>>>[
      // 再検証を前提に共有を許す指示は、オフラインで再検証しないため印にしない
      {
        'cache-control': ['s-maxage=3600'],
      },
      {
        'cache-control': ['max-age=0, must-revalidate'],
      },
      // public でも、資格情報で内容が変わると示す応答は共有しない
      {
        'cache-control': ['public, max-age=3600'],
        'vary': ['Cookie'],
      },
      {
        'cache-control': ['public, max-age=3600'],
        'vary': ['Accept-Language, Authorization'],
      },
      {
        'cache-control': ['public, max-age=3600'],
        'vary': ['*'],
      },
    ]) {
      /// Cookie を送った応答は、public 以外の指示や資格情報の Vary では
      /// 利用者ごとのままであること
      test('keeps a response fetched with cookies user-scoped with $headers',
          () async {
        await withRealHttpClient(() async {
          upstream.pageHeaders = headers;
          final port = await startProxy(cacheUserScopedResponses: false);
          await signIn(port, 'alice');

          await getPage(port);
          expect((await proxy.getCacheStats()).totalEntries, equals(0));
          expect(
              reasonsOf(ProxyEventType.cacheSkipped), equals(['userScoped']));
        });
      });
    }

    /// Authorization を送った応答でも、上流が共有を許せば利用者ごとにしないこと
    test('shares a response fetched with authorization when it says public',
        () async {
      await withRealHttpClient(() async {
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['public, max-age=3600'],
        };
        final port = await startProxy(
          resolver: null,
          cacheUserScopedResponses: false,
        );

        await getPage(port, headers: {'authorization': 'Bearer token'});
        expect((await proxy.getCacheStats()).totalEntries, equals(1));
      });
    });

    /// Set-Cookie と private は、public があっても利用者ごとにすること
    test('keeps set-cookie and private responses user-scoped', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(
          resolver: null,
          cacheUserScopedResponses: false,
        );

        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['public, private="Set-Cookie", max-age=3600'],
        };
        await getPage(port, path: '/page?case=private-field');
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['public, max-age=3600'],
          'set-cookie': ['visitor=1; Path=/'],
        };
        await getPage(port, path: '/page?case=set-cookie');
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(reasonsOf(ProxyEventType.cacheSkipped),
            equals(['userScoped', 'userScoped']));
      });
    });

    /// Cookie を送り、共有を許さない応答は利用者ごとにすること
    test('keeps a response fetched with cookies user-scoped otherwise',
        () async {
      await withRealHttpClient(() async {
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['max-age=3600'],
        };
        final port = await startProxy(cacheUserScopedResponses: false);
        await signIn(port, 'alice');

        await getPage(port);
        expect(reasonsOf(ProxyEventType.cacheSkipped), equals(['userScoped']));
      });
    });
  });

  group('判定関数なし（0.25.0 互換、doc/specs.ja.md 【8】保存ポリシー）', () {
    /// 持ち主を付けずに保存し、別のセッションにも返すこと
    test('stores and serves a user-scoped response to anyone', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(resolver: null);
        await signIn(port, 'alice');
        await getPage(port);
        expect(singleIndexEntry().containsKey('ownerTag'), isFalse);

        await proxy.restoreCookies(_session('bob'));
        await _emitConnectivity(['none']);
        final offline = await getPage(port);
        expect(offline.offlineSource, equals('cache'));
        expect(offline.body, equals('page:session=alice'));
      });
    });
  });

  group('forceCachePaths（doc/specs.ja.md 【8】キャッシュ整合性）', () {
    /// 指定したパスの Set-Cookie の除外は従来どおりで、userScoped にしないこと
    test('keeps the set-cookie exclusion of a listed path', () async {
      await withRealHttpClient(() async {
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['no-store'],
          'set-cookie': ['visitor=1; Path=/'],
        };
        final port = await startProxy(
          cacheUserScopedResponses: false,
          forceCachePaths: const ['/app/**'],
        );

        await getPage(port, path: '/app/page');
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(reasonsOf(ProxyEventType.cacheSkipped), equals(['set-cookie']));
      });
    });

    /// Cookie を送って取得した指定パスの応答は、持ち主を付けて保存すること
    test('tags a listed response fetched with cookies', () async {
      await withRealHttpClient(() async {
        upstream.pageHeaders = <String, List<String>>{
          'cache-control': ['no-store'],
        };
        final port = await startProxy(forceCachePaths: const ['/app/**']);
        await signIn(port, 'alice');

        await getPage(port, path: '/app/page');
        expect(singleIndexEntry()['ownerTag'],
            equals(await _ownerDigest('alice')));
      });
    });
  });

  group('ウォームアップ（doc/specs.ja.md 【8】保存ポリシー）', () {
    /// ウォームアップで取得した応答にも持ち主を付け、他の持ち主には返さないこと
    test('tags a warmed-up response with the current owner', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        await signIn(port, 'alice');

        final result = await proxy.warmupCache(paths: const ['/page']);
        expect(result.successCount, equals(1));
        expect(singleIndexEntry()['ownerTag'],
            equals(await _ownerDigest('alice')));

        await proxy.restoreCookies(_session('bob'), queueOwnerId: 'bob');
        await _emitConnectivity(['none']);
        final asBob = await getPage(port);
        expect(asBob.offlineSource, isNot(equals('cache')));
        expect(reasonsOf(ProxyEventType.cacheMiss), equals(['ownerMismatch']));
      });
    });

    /// 無効にした場合は、Cookie を送ったウォームアップの応答を保存しないこと
    test('skips a warmed-up user-scoped response when disabled', () async {
      await withRealHttpClient(() async {
        final port = await startProxy(cacheUserScopedResponses: false);
        await signIn(port, 'alice');

        await proxy.warmupCache(paths: const ['/page']);
        expect((await proxy.getCacheStats()).totalEntries, equals(0));
        expect(reasonsOf(ProxyEventType.cacheSkipped), equals(['userScoped']));
      });
    });
  });
}
