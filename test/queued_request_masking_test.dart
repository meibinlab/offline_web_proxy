import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// 暗号化鍵を保存する secure storage 上の名前。
const String _keyName = 'offline_web_proxy.cookie_box_encryption_key';

/// キューの暗号化 Box の名前。
const String _queueBoxName = 'proxy_queue_secure';

/// 上流へ接続しないテストで使う origin。
const String _offlineOrigin = 'https://example.com';

/// マスクしたヘッダの値。
const String _masked = '***';

/// 名前がそろえた形で一致すればマスクする名前（仕様 7）。
const Set<String> _sensitiveNames = {
  'cookie',
  'authorization',
  'proxy-authorization',
};

/// 名前に含まれていればマスクする語句（仕様 7）。
const List<String> _sensitiveFragments = [
  'auth',
  'token',
  'secret',
  'session',
  'csrf',
  'xsrf',
  'key',
  'pass',
  'credential',
  'signature',
  'jwt',
  'cookie',
];

/// テストで暗号化 Box に使う 32 バイトの鍵。
final List<int> _encryptionKey =
    List<int>.generate(32, (index) => (index * 13 + 7) & 0xff);

/// 仕様 7 の判定のために、名前を小文字にして `_` を `-` にそろえる。
///
/// [name] ヘッダ名。
///
/// Returns: 判定用の名前。
String _normalize(String name) => name.toLowerCase().replaceAll('_', '-');

/// 仕様 7 の語句のうち、名前に含まれるものを返す。
///
/// テストデータの名前が意図した語句だけを含むかを、前提として確認するために使う。
///
/// [name] ヘッダ名。
///
/// Returns: 含まれる語句の一覧。
List<String> _containedFragments(String name) {
  final normalized = _normalize(name);
  return _sensitiveFragments.where(normalized.contains).toList();
}

/// キューに保存される形のデータを作る。
///
/// 検証中に消化されないよう、再送の時刻を先へ延ばす。
///
/// [url] リクエストの URL。
/// [headers] 保存するヘッダ。
Map<String, Object> _queueData({
  required String url,
  required Map<String, String> headers,
}) {
  final now = DateTime.now();
  final queuedAt = now.subtract(const Duration(minutes: 1)).toIso8601String();
  return {
    'url': url,
    'method': 'POST',
    'headers': Map<String, String>.of(headers),
    'body': utf8.encode('{"total":1}'),
    'queuedAt': queuedAt,
    'acceptedAt': queuedAt,
    'retryCount': 0,
    'nextRetryAt': now.add(const Duration(days: 1)).toIso8601String(),
  };
}

/// メモリ上に鍵を保存する secure storage。
class _FakeKeyStorage implements EncryptionKeyStorage {
  /// 保存されている値。
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<bool?> isProtectedDataAvailable() async => null;
}

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
///
/// [HttpOverrides] の既定の実装は dart:io の HttpClient を作るため、何も上書きしない。
class _RealHttpOverrides extends HttpOverrides {}

/// 受信したリクエストのヘッダと、応答したステータスコードを記録する上流サーバのモック。
class _RecordingUpstream {
  /// [_server] で待ち受けるモックを作る。
  _RecordingUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        final headers = <String, String>{};
        request.headers.forEach((name, values) {
          headers[name] = values.join(', ');
        });
        final answered = statusCode;
        received.add((headers: headers, statusCode: answered));
        request.response
          ..statusCode = answered
          ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
          ..write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  /// 待ち受けているサーバ。
  final HttpServer _server;

  /// 受信したリクエストのヘッダ（名前は小文字）と、応答したステータスコード。
  final List<({Map<String, String> headers, int statusCode})> received = [];

  /// 応答するステータスコード。テスト中に変更できる。
  int statusCode = HttpStatus.ok;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 上流サーバのモックを起動する。
Future<_RecordingUpstream> _startRecordingUpstream() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _RecordingUpstream(server);
}

/// 実 HttpClient で、ヘッダを付けた更新系リクエストを実行する。
///
/// [uri] 送信先。
/// [body] 本文。
/// [headers] 付けるヘッダ。
Future<void> _performPost(
  Uri uri,
  String body,
  Map<String, String> headers,
) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl('POST', uri);
    for (final header in headers.entries) {
      request.headers.set(header.key, header.value);
    }
    request.write(body);
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close(force: true);
  }
}

/// [check] が真を返すまで待つ。
///
/// [check] 待ち終える条件。
/// [timeout] 待つ上限。
///
/// Returns: 上限までに条件を満たした場合は `true`。
Future<bool> _waitUntil(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
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

  late _FakeKeyStorage keyStorage;
  late OfflineWebProxy proxy;
  _RecordingUpstream? upstream;

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_queued_request_masking')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    keyStorage = _FakeKeyStorage();
    proxy = OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks(
      keyStorage: keyStorage,
      keyRereadInterval: Duration.zero,
    ));
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream?.close();
    upstream = null;
    await Hive.close();
  });

  /// ヘッダ [headers] を持つキューの項目を 1 件だけ暗号化 Box に直接書き、[config] で
  /// 起動してから、一覧で返る 1 件を取得する。
  ///
  /// [headers] 保存するヘッダ。
  /// [url] 保存する URL。
  /// [config] 起動に使う設定。
  ///
  /// Returns: [OfflineWebProxy.getQueuedRequests] が返した 1 件。
  Future<QueuedRequest> listSingleQueued(
    Map<String, String> headers, {
    String url = '$_offlineOrigin/api/sales',
    ProxyConfig config = const ProxyConfig(origin: _offlineOrigin),
  }) async {
    keyStorage.values[_keyName] = base64Encode(_encryptionKey);
    await Hive.initFlutter();
    final box = await Hive.openBox(
      _queueBoxName,
      encryptionCipher: HiveAesCipher(_encryptionKey),
    );
    await box.put(
      '0001757000000000000-000000',
      _queueData(url: url, headers: headers),
    );
    await box.close();

    await proxy.start(config: config);
    final queued = await proxy.getQueuedRequests();
    // 前提: 書いた 1 件だけが一覧に返る
    expect(queued, hasLength(1));
    return queued.single;
  }

  /// 暗号化 Box に保存されているキューの項目 1 件のヘッダを、そのまま読む。
  Map<String, String> storedHeaders() {
    final data = Hive.box(_queueBoxName).values.single as Map;
    return Map<String, String>.from(data['headers'] as Map);
  }

  group('getQueuedRequests のヘッダのマスク（仕様 7）', () {
    /// cookie / authorization / proxy-authorization と一致する名前は、大文字小文字や `_` と `-` の違いによらず値を *** にすること
    test('masks the exact sensitive names regardless of case and separator',
        () async {
      const headers = {
        'Cookie': 'SID=cookie-value',
        'AUTHORIZATION': 'Bearer auth-value',
        'Proxy_Authorization': 'Basic proxy-value',
        'content-type': 'application/json',
      };

      final queued = await listSingleQueued(headers);

      // 値は *** に置き換え、名前はそのまま返す
      expect(queued.headers['Cookie'], _masked);
      expect(queued.headers['AUTHORIZATION'], _masked);
      expect(queued.headers['Proxy_Authorization'], _masked);
      // 対象外のヘッダは値を残す（すべてを置き換えていないことの確認）
      expect(queued.headers['content-type'], 'application/json');
      expect(queued.headers.keys.toSet(), equals(headers.keys.toSet()));
      // 保存値は置き換えない
      expect(storedHeaders(), equals(headers));
    });

    /// 名前に auth / token / secret / session / csrf / xsrf / key / pass / credential / signature / jwt / cookie のいずれかを含むヘッダは値を *** にすること
    test('masks names containing a sensitive fragment', () async {
      const namesByFragment = {
        'auth': 'X-Auth-User',
        'token': 'X_ACCESS_TOKEN',
        'secret': 'X-Client-Secret',
        'session': 'x-session-id',
        'csrf': 'X-CSRF-Guard',
        'xsrf': 'X-Xsrf-Guard',
        'key': 'X-Api-Key',
        'pass': 'X-Passcode',
        'credential': 'X-Credential-Id',
        'signature': 'X-Request-Signature',
        'jwt': 'X-JWT',
        'cookie': 'X-Cookie-Consent',
      };
      // 前提: 仕様の語句をすべて使い、各名前は対応する語句を 1 つだけ含み、
      // 完全一致の名前には当たらない
      expect(namesByFragment.keys.toList(), equals(_sensitiveFragments));
      for (final entry in namesByFragment.entries) {
        expect(_containedFragments(entry.value), equals([entry.key]),
            reason: entry.value);
        expect(_sensitiveNames.contains(_normalize(entry.value)), isFalse,
            reason: entry.value);
      }

      final queued = await listSingleQueued({
        for (final entry in namesByFragment.entries)
          entry.value: 'value-${entry.key}',
        'X-Request-Id': 'request-1',
      });

      // 語句を含む名前は、どの語句でも値を *** にする
      for (final name in namesByFragment.values) {
        expect(queued.headers[name], _masked, reason: name);
      }
      // 語句を含まない名前は値を残す
      expect(queued.headers['X-Request-Id'], 'request-1');
    });

    /// 機密情報を示す名前・語句に当たらないヘッダは、値をそのまま返すこと
    test('keeps the values of other headers', () async {
      const headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': 'Mozilla/5.0',
        'X-Request-Id': 'request-1',
        'X-Offline-Accepted-At': '2026-09-01T00:00:00.000Z',
      };
      // 前提: どの名前も仕様の名前・語句に当たらない
      for (final name in headers.keys) {
        expect(_containedFragments(name), isEmpty, reason: name);
        expect(_sensitiveNames.contains(_normalize(name)), isFalse,
            reason: name);
      }

      final queued = await listSingleQueued(headers);

      // 名前も値も保存したまま返す
      expect(queued.headers, equals(headers));
    });

    /// 既定のべき等性キーのヘッダ（Idempotency-Key）は、名前に key を含んでも、大文字小文字や `_` と `-` の違いによらずマスクしないこと
    test('keeps the default idempotency key header', () async {
      final queued = await listSingleQueued({
        'Idempotency-Key': 'idempotency-1',
        'IDEMPOTENCY_KEY': 'idempotency-2',
        'X-Api-Key': 'api-key-1',
      });

      // 前提: べき等性キーのヘッダ名は、語句 key を含む
      expect(_containedFragments('Idempotency-Key'), contains('key'));
      // 設定されたべき等性キーのヘッダは値を残す
      expect(queued.headers['Idempotency-Key'], 'idempotency-1');
      expect(queued.headers['IDEMPOTENCY_KEY'], 'idempotency-2');
      // 同じ語句を含む別のヘッダはマスクする（除外が名前に限られることの確認）
      expect(queued.headers['X-Api-Key'], _masked);
    });

    /// べき等性キーのヘッダ名を変えた場合は、設定した名前をマスクせず、既定の Idempotency-Key はマスクすること
    test('follows a changed idempotency header name', () async {
      final queued = await listSingleQueued(
        {
          'X-Request-Key': 'request-key-1',
          'x_request_key': 'request-key-2',
          'Idempotency-Key': 'idempotency-1',
        },
        config: const ProxyConfig(
          origin: _offlineOrigin,
          idempotencyHeaderName: 'X-Request-Key',
        ),
      );

      // 設定したヘッダ名は、`_` と `-` の違いによらず値を残す
      expect(queued.headers['X-Request-Key'], 'request-key-1');
      expect(queued.headers['x_request_key'], 'request-key-2');
      // 設定から外れた既定の名前は、語句 key を含むためマスクする
      expect(queued.headers['Idempotency-Key'], _masked);
    });

    /// URL のクエリに機密情報を示す名前が含まれていてもマスクしないこと
    test('does not mask the query of the URL', () async {
      const url =
          '$_offlineOrigin/api/sales?token=token-1&session=session-1&api_key=key-1';

      final queued = await listSingleQueued(
        {'Authorization': 'Bearer auth-value'},
        url: url,
      );

      // 前提: ヘッダのマスクは効いている
      expect(queued.headers['Authorization'], _masked);
      // URL は保存したまま返す
      expect(queued.url, url);
    });

    /// 一覧ではマスクしても保存値は変えず、再送では保存値（元の値）を上流へ送ること
    test('resends the stored values instead of the masked ones', () async {
      await HttpOverrides.runZoned<Future<void>>(
        () async {
          upstream = await _startRecordingUpstream();
          final port = await proxy.start(
            config: ProxyConfig(origin: upstream!.origin),
          );

          // 5xx を返してキューへ保存させる
          upstream!.statusCode = HttpStatus.internalServerError;
          await _performPost(
            Uri.parse('http://127.0.0.1:$port/api/sales'),
            '{"total":1}',
            {
              'Authorization': 'Bearer auth-original',
              'X-Api-Key': 'api-key-original',
              'X-CSRF-Token': 'csrf-original',
              'Cookie': 'SID=cookie-original',
              'Idempotency-Key': 'idempotency-original',
              'X-Trace-Id': 'trace-original',
            },
          );

          final queued = await proxy.getQueuedRequests();
          // 前提: 1 件がキューに保存されている
          expect(queued, hasLength(1));
          final listed = queued.single.headers;
          // 一覧では機密情報を含み得るヘッダの値を *** にする
          expect(listed['authorization'], _masked);
          expect(listed['x-api-key'], _masked);
          expect(listed['x-csrf-token'], _masked);
          expect(listed['cookie'], _masked);
          // べき等性キーと対象外のヘッダは値を残す
          expect(listed['idempotency-key'], 'idempotency-original');
          expect(listed['x-trace-id'], 'trace-original');

          // 保存値は元の値のまま
          final stored = storedHeaders();
          expect(stored['authorization'], 'Bearer auth-original');
          expect(stored['x-api-key'], 'api-key-original');
          expect(stored['x-csrf-token'], 'csrf-original');
          expect(stored['cookie'], 'SID=cookie-original');

          // 上流を回復させ、再送でキューが空になるのを待つ
          upstream!.statusCode = HttpStatus.ok;
          final drained = await _waitUntil(
              () async => (await proxy.getQueuedRequests()).isEmpty);
          expect(drained, isTrue, reason: 'キューが時間内に空になりませんでした');

          final resent = upstream!.received
              .where((request) => request.statusCode == HttpStatus.ok)
              .toList();
          // 前提: 2xx で受け付けた再送がある
          expect(resent, isNotEmpty);
          final headers = resent.last.headers;
          // 上流には保存した元の値が届く
          expect(headers['authorization'], 'Bearer auth-original');
          expect(headers['x-api-key'], 'api-key-original');
          expect(headers['x-csrf-token'], 'csrf-original');
          expect(headers['cookie'], contains('SID=cookie-original'));
          expect(headers['idempotency-key'], 'idempotency-original');
          // マスクした値を送っていない
          expect(
            headers.values.where((value) => value.contains(_masked)),
            isEmpty,
          );
        },
        createHttpClient: _RealHttpOverrides().createHttpClient,
      );
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
