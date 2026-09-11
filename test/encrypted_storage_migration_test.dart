import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/models/cookie_record.dart';
import 'package:offline_web_proxy/src/storage/encryption_key_storage.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// 暗号化鍵を保存する secure storage 上の名前（Cookie と業務データで共有する）。
const String _keyName = 'offline_web_proxy.cookie_box_encryption_key';

/// キューの暗号化 Box の名前。
const String _encryptedQueueBoxName = 'proxy_queue_secure';

/// 隔離の暗号化 Box の名前。
const String _encryptedQuarantineBoxName = 'proxy_quarantined_requests_secure';

/// ドロップ履歴の暗号化 Box の名前。
const String _encryptedDroppedBoxName = 'proxy_dropped_requests_secure';

/// Cookie の暗号化 Box の名前。
const String _encryptedCookieBoxName = 'proxy_cookies_secure';

/// キューの旧平文 Box の名前。
const String _legacyQueueBoxName = 'proxy_queue';

/// 隔離の旧平文 Box の名前。
const String _legacyQuarantineBoxName = 'proxy_quarantined_requests';

/// ドロップ履歴の旧平文 Box の名前。
const String _legacyDroppedBoxName = 'proxy_dropped_requests';

/// Cookie の旧平文 Box の名前。
const String _legacyCookieBoxName = 'proxy_cookies';

/// 上流へ送らないテストで使う origin。これを使うテストでは上流へ接続しない。
const String _offlineOrigin = 'https://example.com';

/// テストの間に遅らせた移行が始まらないよう、十分長くした待ち時間。
const Duration _longMigrationDelay = Duration(minutes: 10);

/// 保存領域のキー（19 桁のマイクロ秒と 6 桁の連番）。辞書順は A < B < C。
const String _keyA = '0001757000000000000-000000';

/// 保存領域のキー（19 桁のマイクロ秒と 6 桁の連番）。辞書順は A < B < C。
const String _keyB = '0001757000000000001-000000';

/// 保存領域のキー（19 桁のマイクロ秒と 6 桁の連番）。辞書順は A < B < C。
const String _keyC = '0001757000000000002-000000';

/// 旧形式（13 桁のミリ秒）のキー。
const String _millisecondKey = '1757000000003';

/// 旧形式（16 桁のマイクロ秒）のキー。
const String _microsecondKey = '1757000000000004';

/// 再送させたくない項目の nextRetryAt に使う、十分未来の日時。
final DateTime _farFuture = DateTime(2099, 1, 1);

/// Box の種類ごとの、暗号化 Box と旧平文 Box の名前。
const Map<ProxyStorageBox, ({String encrypted, String legacy})> _boxNames = {
  ProxyStorageBox.queue: (
    encrypted: _encryptedQueueBoxName,
    legacy: _legacyQueueBoxName,
  ),
  ProxyStorageBox.quarantine: (
    encrypted: _encryptedQuarantineBoxName,
    legacy: _legacyQuarantineBoxName,
  ),
  ProxyStorageBox.droppedRequests: (
    encrypted: _encryptedDroppedBoxName,
    legacy: _legacyDroppedBoxName,
  ),
};

/// テスト用の 32 バイトの暗号化鍵を作る。
///
/// Returns: 32 バイトの鍵。
List<int> _testKey() =>
    List<int>.generate(32, (index) => (index * 7 + 3) & 0xff);

/// 保持期間の判定に掛からない、少し前の日時を返す。
///
/// 隔離とドロップ履歴は起動時に保持期間（既定 30 日）で整理されるため、
/// 固定の日付ではなく現在時刻から求める。
///
/// Returns: 現在から 1 時間前の日時。
DateTime _recentBase() => DateTime.now().subtract(const Duration(hours: 1));

/// キューに保存される形のデータを作る。
///
/// [url] 上流の絶対 URL。
/// [body] 本文（UTF-8 のバイト列として保存する）。
/// [queuedAt] 保存時刻。
/// [nextRetryAt] 次に再送する時刻。省略時は [queuedAt]（再送の時刻を過ぎている）。
/// [headers] 保存するヘッダ。
///
/// Returns: キューの項目。
Map<String, Object> _queueEntry({
  required String url,
  required String body,
  required DateTime queuedAt,
  DateTime? nextRetryAt,
  Map<String, String> headers = const {},
}) {
  return {
    'url': url,
    'method': 'POST',
    'headers': Map<String, String>.from(headers),
    // Uint8List のため、平文の Box ではファイルにそのままのバイト列で残る
    'body': utf8.encode(body),
    'queuedAt': queuedAt.toIso8601String(),
    'acceptedAt': queuedAt.toIso8601String(),
    'retryCount': 0,
    'nextRetryAt': (nextRetryAt ?? queuedAt).toIso8601String(),
  };
}

/// 隔離に保存される形のデータを作る。
///
/// [url] 上流の絶対 URL。
/// [body] 本文。
/// [quarantinedAt] 隔離した時刻（保存時刻）。
/// [headers] 保存するヘッダ。
///
/// Returns: 隔離の項目。
Map<String, Object> _quarantineEntry({
  required String url,
  required String body,
  required DateTime quarantinedAt,
  Map<String, String> headers = const {},
}) {
  return {
    ..._queueEntry(
      url: url,
      body: body,
      queuedAt: quarantinedAt.subtract(const Duration(minutes: 30)),
      headers: headers,
    ),
    'quarantinedAt': quarantinedAt.toIso8601String(),
    'statusCode': HttpStatus.badRequest,
    'reason': '4xx_error',
    'errorMessage': 'HTTP 400',
  };
}

/// ドロップ履歴に保存される形のデータを作る。
///
/// [url] 上流の絶対 URL。
/// [droppedAt] 記録した時刻（保存時刻）。
/// [acknowledged] 確認済みかどうか。
///
/// Returns: ドロップ履歴の項目。
Map<String, Object> _droppedEntry({
  required String url,
  required DateTime droppedAt,
  bool acknowledged = false,
}) {
  return {
    'url': url,
    'method': 'POST',
    'droppedAt': droppedAt.toIso8601String(),
    'dropReason': '4xx_error',
    'statusCode': HttpStatus.badRequest,
    'errorMessage': 'HTTP 400',
    'acknowledged': acknowledged,
  };
}

/// [haystack] の中に [needle] と同じ並びのバイト列があるかを返す。
///
/// [haystack] 探す対象のバイト列。
/// [needle] 探すバイト列。
///
/// Returns: 含まれる場合は `true`。
bool _containsBytes(List<int> haystack, List<int> needle) {
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var matched = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return true;
    }
  }
  return false;
}

/// 値を保持するだけの secure storage の偽物。鍵の有無をテストから操作する。
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
class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

/// 受信した本文を記録し、特定の本文への応答を止められる上流サーバのモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        receivedBodies.add(body);
        // 送信中の状態を作るため、登録された本文には解放されるまで応答しない
        final gate = heldBodies[body];
        if (gate != null) {
          await gate.future;
        }
        request.response
          ..statusCode = statusCode
          ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
          ..write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// 上流が受信したリクエスト本文の一覧。受信順に追加される。
  final List<String> receivedBodies = <String>[];

  /// 応答を止める本文と、応答を再開させる Completer。
  final Map<String, Completer<void>> heldBodies = {};

  /// 応答するステータスコード。テスト中に変更できる。
  int statusCode = HttpStatus.ok;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// 上流サーバのモックを起動する。
///
/// Returns: 起動したモック。
Future<_MockUpstream> _startMockUpstream() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _MockUpstream(server);
}

/// connectivity_plus の状態変化イベントを擬似送信する。
///
/// オフライン → オンラインの変化で proxy はキュー消化をすぐに始めるため、
/// 5 秒ごとの定期処理を待たずに再送を起こすために使う。
///
/// [statuses] `['none']` や `['wifi']` のような接続状態の一覧。
Future<void> _emitConnectivity(List<String> statuses) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'dev.fluttercommunity.plus/connectivity_status',
    const StandardMethodCodec().encodeSuccessEnvelope(statuses),
    (ByteData? _) {},
  );
}

/// オフライン → オンラインを通知し、キュー消化をすぐに始めさせる。
Future<void> _triggerQueueDrain() async {
  await _emitConnectivity(['none']);
  await _emitConnectivity(['wifi']);
}

/// 実 HttpClient で proxy へ要求を実行する。
///
/// [uri] 要求先。
/// [method] HTTP メソッド。
///
/// Returns: ステータスコードと本文。
Future<({int statusCode, String body})> _performRequest(
  Uri uri, {
  String method = 'GET',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return (statusCode: response.statusCode, body: responseBody);
  } finally {
    client.close(force: true);
  }
}

/// [check] が真を返すまでポーリングで待機する。
///
/// [timeout] を超えた場合は待機を打ち切り、呼び出し側のアサーションに委ねる。
///
/// [check] 待つ条件。
/// [timeout] 待つ上限時間。
Future<void> _waitUntil(
  FutureOr<bool> Function() check, {
  Duration timeout = const Duration(seconds: 10),
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

  late _FakeKeyStorage keyStorage;
  late OfflineWebProxy proxy;
  _MockUpstream? upstream;

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_encrypted_migration')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    keyStorage = _FakeKeyStorage();
    proxy = OfflineWebProxy.withStorageTestHooks(
      ProxyStorageTestHooks(keyStorage: keyStorage),
    );
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream?.close();
    upstream = null;
    await Hive.close();
  });

  /// テスト用の差し替えを入れた proxy を作る。
  ///
  /// [deferredMigrationDelay] 鍵を生成したインスタンスで移行を遅らせる時間。
  /// [beforeLegacyBoxCleared] 旧 Box を空にする直前に呼ぶ処理。
  ///
  /// Returns: 作成した proxy。
  OfflineWebProxy createProxy({
    Duration deferredMigrationDelay = _longMigrationDelay,
    Future<void> Function(ProxyStorageBox kind)? beforeLegacyBoxCleared,
  }) {
    return OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks(
      keyStorage: keyStorage,
      keyRereadInterval: Duration.zero,
      deferredMigrationDelay: deferredMigrationDelay,
      beforeLegacyBoxCleared: beforeLegacyBoxCleared,
    ));
  }

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  ///
  /// proxy のタイマーもこのゾーンで作られるため、start() もこの中で呼ぶ。
  ///
  /// [body] テスト本体。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: _RealHttpOverrides().createHttpClient,
    );
  }

  /// 鍵が secure storage に既にある状態（このインスタンスで生成しない状態）を作る。
  ///
  /// Returns: 保存した鍵。
  List<int> storeExistingKey() {
    final key = _testKey();
    keyStorage.values[_keyName] = base64Encode(key);
    return key;
  }

  /// Box のファイルを返す。
  ///
  /// [name] Box の名前。
  File boxFile(String name) =>
      File('$hiveTestDirectory${Platform.pathSeparator}$name.hive');

  /// Box のファイル（.hive / .hivec / .lock）のいずれかが残っているかを返す。
  ///
  /// Hive はこのいずれかがあれば Box が存在するとみなすため、すべてを確認する。
  ///
  /// [name] Box の名前。
  bool boxFilesExist(String name) {
    return ['hive', 'hivec', 'lock'].any((extension) =>
        File('$hiveTestDirectory${Platform.pathSeparator}$name.$extension')
            .existsSync());
  }

  /// 旧平文 Box を平文のまま書き、閉じる。
  ///
  /// [name] Box の名前。
  /// [entries] 書き込む内容。
  Future<void> writeLegacyBox(String name, Map<String, Object> entries) async {
    await Hive.initFlutter();
    final box = await Hive.openBox(name);
    await box.putAll(entries);
    await box.close();
  }

  /// 暗号化 Box を直接書き、閉じる。
  ///
  /// [name] Box の名前。
  /// [key] 暗号化に使う鍵。
  /// [entries] 書き込む内容。
  Future<void> writeEncryptedBox(
    String name,
    List<int> key,
    Map<String, Object> entries,
  ) async {
    await Hive.initFlutter();
    final box = await Hive.openBox(name, encryptionCipher: HiveAesCipher(key));
    await box.putAll(entries);
    await box.close();
  }

  /// [target] が出す errorOccurred イベントを集める。
  ///
  /// [target] 対象の proxy。start() の前に呼ぶ。
  ///
  /// Returns: 受け取ったイベントの一覧（受信順に追加される）。
  List<ProxyEvent> captureErrorEvents(OfflineWebProxy target) {
    final events = <ProxyEvent>[];
    final subscription = target.events
        .where((event) => event.type == ProxyEventType.errorOccurred)
        .listen(events.add);
    addTearDown(subscription.cancel);
    return events;
  }

  group('段階 2 での即時移行（鍵が既にある場合）', () {
    /// 鍵が段階 1 の時点で既にある場合は、start の中（稼働開始前）で書き写してから旧 Box を空にして消し、キーを変えないこと
    test('migrates legacy boxes inside start keeping their keys', () async {
      storeExistingKey();
      final base = _recentBase();
      final queueEntries = <String, Object>{
        _millisecondKey: _queueEntry(
          url: '$_offlineOrigin/api/millisecond',
          body: 'millisecond',
          queuedAt: base,
          nextRetryAt: _farFuture,
        ),
        _microsecondKey: _queueEntry(
          url: '$_offlineOrigin/api/microsecond',
          body: 'microsecond',
          queuedAt: base.add(const Duration(minutes: 1)),
          nextRetryAt: _farFuture,
        ),
        _keyA: _queueEntry(
          url: '$_offlineOrigin/api/sequenced',
          body: 'sequenced',
          queuedAt: base.add(const Duration(minutes: 2)),
          nextRetryAt: _farFuture,
          headers: {'x-note': 'note'},
        ),
      };
      await writeLegacyBox(_legacyQueueBoxName, queueEntries);
      await writeLegacyBox(_legacyQuarantineBoxName, {
        _keyB: _quarantineEntry(
          url: '$_offlineOrigin/api/quarantined',
          body: 'quarantined',
          quarantinedAt: base,
        ),
      });
      await writeLegacyBox(_legacyDroppedBoxName, {
        _keyC:
            _droppedEntry(url: '$_offlineOrigin/api/dropped', droppedAt: base),
      });
      await Hive.close();

      final hookCalls = <({
        ProxyStorageBox kind,
        bool running,
        bool copied,
        bool legacyHasEntries,
      })>[];
      proxy = createProxy(beforeLegacyBoxCleared: (kind) async {
        final names = _boxNames[kind]!;
        final encryptedBox = Hive.box(names.encrypted);
        final legacyBox = Hive.box(names.legacy);
        hookCalls.add((
          kind: kind,
          running: proxy.isRunning,
          copied: encryptedBox.keys.toSet().containsAll(legacyBox.keys),
          legacyHasEntries: legacyBox.isNotEmpty,
        ));
      });

      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // 3 種類とも、start の中（稼働開始前）で移行したこと
      expect(hookCalls.map((call) => call.kind), [
        ProxyStorageBox.queue,
        ProxyStorageBox.quarantine,
        ProxyStorageBox.droppedRequests,
      ]);
      for (final call in hookCalls) {
        expect(call.running, isFalse, reason: '${call.kind} は稼働開始前に移行する');
        // 暗号化 Box へ書き写した後、旧 Box を空にする前に呼ばれたこと
        expect(call.copied, isTrue, reason: '${call.kind} は書き写し済み');
        expect(call.legacyHasEntries, isTrue, reason: '${call.kind} は空にする前');
      }

      // 旧 Box のファイルが消えていること
      expect(boxFilesExist(_legacyQueueBoxName), isFalse);
      expect(boxFilesExist(_legacyQuarantineBoxName), isFalse);
      expect(boxFilesExist(_legacyDroppedBoxName), isFalse);

      // キュー ID（旧形式の 13 桁・16 桁を含むキー）が変わらないこと
      final queueBox = Hive.box(_encryptedQueueBoxName);
      expect(queueBox.keys.toSet(), queueEntries.keys.toSet());
      // 値がそのまま書き写されていること
      final migrated = queueBox.get(_keyA) as Map;
      expect(migrated['url'], '$_offlineOrigin/api/sequenced');
      expect(migrated['method'], 'POST');
      expect(migrated['body'], utf8.encode('sequenced'));
      expect(Map<String, String>.from(migrated['headers'] as Map),
          {'x-note': 'note'});
      expect(migrated['queuedAt'],
          base.add(const Duration(minutes: 2)).toIso8601String());

      // 一覧では移行済み（pendingMigration が false）として返ること
      final queued = await proxy.getQueuedRequests();
      expect(queued, hasLength(3));
      expect(queued.map((request) => request.pendingMigration),
          everyElement(isFalse));

      // 隔離 ID（キー）が変わらないこと
      final quarantined = await proxy.getQuarantinedRequests();
      expect(quarantined, hasLength(1));
      expect(quarantined.single.id, _keyB);
      expect(quarantined.single.pendingMigration, isFalse);

      // ドロップ履歴もキーを保って移行したこと
      expect(Hive.box(_encryptedDroppedBoxName).keys.toList(), [_keyC]);
      final dropped = await proxy.getDroppedRequests();
      expect(dropped, hasLength(1));
      expect(dropped.single.pendingMigration, isFalse);

      // 件数が二重にならないこと
      final stats = await proxy.getStats();
      expect(stats.queueLength, 3);
      expect(stats.quarantinedCount, 1);
      expect(stats.droppedRequestsCount, 1);
    });
  });

  group('移行の遅延（このインスタンスで鍵を生成した場合）', () {
    /// 鍵を生成した場合は移行を遅らせ、旧 Box の項目を pendingMigration: true で一覧と件数に含め、保存時刻の順に混ぜて並べてから limit を適用すること
    test('lists and counts pending legacy entries merged by stored time',
        () async {
      await withRealHttpClient(() async {
        final base = _recentBase();
        final early = base;
        final middle = base.add(const Duration(minutes: 1));
        final late = base.add(const Duration(minutes: 2));
        // 保存時刻の順（C → A → B）を、キーの辞書順（A → B → C）や Box の順（暗号化 → 旧）とずらす
        await writeLegacyBox(_legacyQueueBoxName, {
          _keyB: _queueEntry(
            url: '$_offlineOrigin/api/legacy-late',
            body: 'legacy-late',
            queuedAt: late,
            nextRetryAt: _farFuture,
          ),
          _keyC: _queueEntry(
            url: '$_offlineOrigin/api/legacy-early',
            body: 'legacy-early',
            queuedAt: early,
            nextRetryAt: _farFuture,
          ),
        });
        await writeLegacyBox(_legacyQuarantineBoxName, {
          _keyB: _quarantineEntry(
            url: '$_offlineOrigin/api/legacy-late',
            body: 'legacy-late',
            quarantinedAt: late,
          ),
          _keyC: _quarantineEntry(
            url: '$_offlineOrigin/api/legacy-early',
            body: 'legacy-early',
            quarantinedAt: early,
          ),
        });
        await writeLegacyBox(_legacyDroppedBoxName, {
          _keyB: _droppedEntry(
            url: '$_offlineOrigin/api/legacy-late',
            droppedAt: late,
          ),
          _keyC: _droppedEntry(
            url: '$_offlineOrigin/api/legacy-early',
            droppedAt: early,
          ),
        });
        await Hive.close();

        proxy = createProxy();
        final port = await proxy.start(
          config: const ProxyConfig(origin: _offlineOrigin),
        );

        // 暗号化 Box にも、保存時刻が中間の項目を置く
        await Hive.box(_encryptedQueueBoxName).put(
          _keyA,
          _queueEntry(
            url: '$_offlineOrigin/api/encrypted-middle',
            body: 'encrypted-middle',
            queuedAt: middle,
            nextRetryAt: _farFuture,
          ),
        );
        await Hive.box(_encryptedQuarantineBoxName).put(
          _keyA,
          _quarantineEntry(
            url: '$_offlineOrigin/api/encrypted-middle',
            body: 'encrypted-middle',
            quarantinedAt: middle,
          ),
        );
        // 確認済みにし、未確認件数は旧 Box の 2 件だけになるようにする
        await Hive.box(_encryptedDroppedBoxName).put(
          _keyA,
          _droppedEntry(
            url: '$_offlineOrigin/api/encrypted-middle',
            droppedAt: middle,
            acknowledged: true,
          ),
        );

        // 前提: 移行を待っていること（旧 Box のファイルが残っている）
        expect(boxFilesExist(_legacyQueueBoxName), isTrue);
        expect(boxFilesExist(_legacyQuarantineBoxName), isTrue);
        expect(boxFilesExist(_legacyDroppedBoxName), isTrue);

        const expectedUrls = [
          '$_offlineOrigin/api/legacy-early',
          '$_offlineOrigin/api/encrypted-middle',
          '$_offlineOrigin/api/legacy-late',
        ];

        // キューの一覧が保存時刻の順に混ざり、旧 Box の項目だけ pendingMigration が true であること
        final queued = await proxy.getQueuedRequests();
        expect(queued.map((request) => request.url), expectedUrls);
        expect(queued.map((request) => request.pendingMigration),
            [true, false, true]);

        // 隔離の一覧も同様で、limit は並べた後の先頭から効くこと
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined.map((request) => request.id), [_keyC, _keyA, _keyB]);
        expect(quarantined.map((request) => request.pendingMigration),
            [true, false, true]);
        final limitedQuarantined = await proxy.getQuarantinedRequests(limit: 2);
        expect(limitedQuarantined.map((request) => request.id), [_keyC, _keyA]);

        // ドロップ履歴の一覧も同様で、limit は並べた後の先頭から効くこと
        final dropped = await proxy.getDroppedRequests();
        expect(dropped.map((request) => request.url), expectedUrls);
        expect(dropped.map((request) => request.pendingMigration),
            [true, false, true]);
        final limitedDropped = await proxy.getDroppedRequests(limit: 2);
        expect(
            limitedDropped.map((request) => request.url), expectedUrls.take(2));

        // 統計の件数に、移行を待っている項目を含むこと
        final stats = await proxy.getStats();
        expect(stats.queueLength, 3);
        expect(stats.quarantinedCount, 3);
        expect(stats.droppedRequestsCount, 3);
        expect(stats.unacknowledgedDroppedCount, 2);

        // 状態通知の JSON の件数にも含むこと
        final response = await _performRequest(
          Uri.parse('http://127.0.0.1:$port/__offline_web_proxy/status'),
        );
        expect(response.statusCode, HttpStatus.ok);
        final status = jsonDecode(response.body) as Map<String, dynamic>;
        expect(status['queueLength'], 3);
        expect(status['quarantinedCount'], 3);
        expect(status['unacknowledgedDroppedCount'], 2);
      });
    });

    /// 移行を待つ間も 5 秒ごとのキュー消化で暗号化キューを再送し、旧キューの項目は移行するまで送らないこと
    test('keeps resending the encrypted queue while legacy items wait',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final origin = upstream!.origin;
        final base = _recentBase();
        // 旧キューの項目は暗号化キューの項目より古く、再送の時刻も過ぎている。
        // 誤って送る場合は、暗号化キューの項目より先に届く
        await writeLegacyBox(_legacyQueueBoxName, {
          _keyB: _queueEntry(
            url: '$origin/api/legacy',
            body: 'legacy',
            queuedAt: base,
          ),
        });
        await Hive.close();

        proxy = createProxy();
        await proxy.start(config: ProxyConfig(origin: origin));
        await Hive.box(_encryptedQueueBoxName).put(
          _keyA,
          _queueEntry(
            url: '$origin/api/encrypted',
            body: 'encrypted',
            queuedAt: base.add(const Duration(minutes: 1)),
          ),
        );

        // 前提: 旧キューの項目が移行を待っていること
        final before = await proxy.getQueuedRequests();
        expect(
            before.map((request) => request.pendingMigration), [true, false]);
        expect(boxFilesExist(_legacyQueueBoxName), isTrue);

        // 接続状態の通知では起こさず、5 秒ごとの定期処理による再送を待つ
        await _waitUntil(
          () => upstream!.receivedBodies.isNotEmpty,
          timeout: const Duration(seconds: 15),
        );

        // 暗号化キューの項目だけが送られたこと
        expect(upstream!.receivedBodies, ['encrypted']);

        await _waitUntil(() async => (await proxy.getStats()).queueLength == 1);
        // 送った項目は消え、旧キューの項目は移行待ちのまま残ること
        final after = await proxy.getQueuedRequests();
        expect(after, hasLength(1));
        expect(after.single.url, '$origin/api/legacy');
        expect(after.single.pendingMigration, isTrue);
        expect(boxFilesExist(_legacyQueueBoxName), isTrue);
        // 旧キューの項目は送られていないこと
        expect(upstream!.receivedBodies, ['encrypted']);
      });
    });

    /// 移行した後は、旧キューから移した項目と暗号化キューの項目を保存時刻の順に送ること
    test('sends migrated and encrypted items in stored-time order', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final origin = upstream!.origin;
        final base = _recentBase();
        // キーの辞書順（A: second → B: third → C: first）と保存時刻の順をずらす
        await writeLegacyBox(_legacyQueueBoxName, {
          _keyB: _queueEntry(
            url: '$origin/api/third',
            body: 'third',
            queuedAt: base.add(const Duration(minutes: 2)),
          ),
          _keyC: _queueEntry(
            url: '$origin/api/first',
            body: 'first',
            queuedAt: base,
          ),
        });
        await Hive.close();

        proxy = createProxy(deferredMigrationDelay: const Duration(seconds: 2));
        await proxy.start(config: ProxyConfig(origin: origin));
        // 移行が終わるまで送らないよう、オフラインにしておく
        await _emitConnectivity(['none']);
        await Hive.box(_encryptedQueueBoxName).put(
          _keyA,
          _queueEntry(
            url: '$origin/api/second',
            body: 'second',
            queuedAt: base.add(const Duration(minutes: 1)),
          ),
        );

        // 前提: 旧キューの 2 件が移行を待っていること
        final before = await proxy.getQueuedRequests();
        expect(
            before.where((request) => request.pendingMigration), hasLength(2));

        await _waitUntil(
          () async {
            final queued = await proxy.getQueuedRequests();
            return queued.length == 3 &&
                queued.every((request) => !request.pendingMigration);
          },
          timeout: const Duration(seconds: 15),
        );
        // 前提: 移行を終え、オフラインの間は何も送っていないこと
        final migrated = await proxy.getQueuedRequests();
        expect(migrated, hasLength(3));
        expect(migrated.map((request) => request.pendingMigration),
            everyElement(isFalse));
        expect(upstream!.receivedBodies, isEmpty);

        await _emitConnectivity(['wifi']);
        await _waitUntil(() => upstream!.receivedBodies.length >= 3);

        // 保存時刻の順に送られること
        expect(upstream!.receivedBodies, ['first', 'second', 'third']);
      });
    });
  });

  group('遅らせた移行の途中失敗と再試行', () {
    /// 旧 Box を空にする前に失敗したら書き写したキーを暗号化 Box から消し、次の定期処理で移行し直して、同じ項目を 1 回だけ送ること
    test('removes copied queue keys on failure and sends the item once',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final origin = upstream!.origin;
        await writeLegacyBox(_legacyQueueBoxName, {
          _keyA: _queueEntry(
            url: '$origin/api/legacy',
            body: 'legacy',
            queuedAt: _recentBase(),
          ),
        });
        await Hive.close();

        var hookCalls = 0;
        bool? copiedBeforeFailure;
        proxy = createProxy(
          deferredMigrationDelay: const Duration(milliseconds: 500),
          beforeLegacyBoxCleared: (kind) async {
            if (kind != ProxyStorageBox.queue) {
              return;
            }
            hookCalls++;
            if (hookCalls == 1) {
              copiedBeforeFailure =
                  Hive.box(_encryptedQueueBoxName).containsKey(_keyA);
              throw Exception('injected failure before clearing legacy box');
            }
          },
        );
        final errors = captureErrorEvents(proxy);
        await proxy.start(config: ProxyConfig(origin: origin));

        await _waitUntil(() => errors.any(
            (event) => event.data['operation'] == 'legacyStorageMigration'));

        // 前提: 書き写した後、旧 Box を空にする前に 1 回だけ失敗したこと
        expect(hookCalls, 1);
        expect(copiedBeforeFailure, isTrue);
        expect(
          errors.where(
              (event) => event.data['operation'] == 'legacyStorageMigration'),
          hasLength(1),
        );
        // 書き写したキーが暗号化 Box から消えていること
        expect(Hive.box(_encryptedQueueBoxName).containsKey(_keyA), isFalse);
        // 旧 Box は残り、項目は移行待ちの 1 件として扱われること
        expect(boxFilesExist(_legacyQueueBoxName), isTrue);
        final pending = await proxy.getQueuedRequests();
        expect(pending, hasLength(1));
        expect(pending.single.pendingMigration, isTrue);
        expect((await proxy.getStats()).queueLength, 1);
        expect(upstream!.receivedBodies, isEmpty);

        // 次の定期処理（5 秒ごと）で移行し直すこと
        await _waitUntil(
          () => hookCalls >= 2 && !boxFilesExist(_legacyQueueBoxName),
          timeout: const Duration(seconds: 15),
        );
        expect(hookCalls, 2);
        expect(boxFilesExist(_legacyQueueBoxName), isFalse);
        // 定期処理は移行を待ってからキュー消化を始めるため、移行した項目が同じ回の
        // うちに送られていることがある。移行待ちの項目が残っていないことだけを確かめる
        expect(
          (await proxy.getQueuedRequests())
              .where((request) => request.pendingMigration),
          isEmpty,
        );

        await _triggerQueueDrain();
        await _waitUntil(() async => (await proxy.getStats()).queueLength == 0);

        // 同じ項目は 1 回だけ送られ、送り直す記録も残らないこと
        expect(upstream!.receivedBodies, ['legacy']);
        expect(await proxy.getQueuedRequests(), isEmpty);
      });
    });

    /// 隔離の移行が旧 Box を空にする前に失敗しても、移行し直した後の隔離は 1 件のままで ID も変わらないこと
    test('keeps a single quarantined request when its migration is retried',
        () async {
      await writeLegacyBox(_legacyQuarantineBoxName, {
        _keyA: _quarantineEntry(
          url: '$_offlineOrigin/api/quarantined',
          body: 'quarantined',
          quarantinedAt: _recentBase(),
        ),
      });
      await Hive.close();

      var hookCalls = 0;
      bool? copiedBeforeFailure;
      proxy = createProxy(
        deferredMigrationDelay: const Duration(milliseconds: 500),
        beforeLegacyBoxCleared: (kind) async {
          if (kind != ProxyStorageBox.quarantine) {
            return;
          }
          hookCalls++;
          if (hookCalls == 1) {
            copiedBeforeFailure =
                Hive.box(_encryptedQuarantineBoxName).containsKey(_keyA);
            throw Exception('injected failure before clearing legacy box');
          }
        },
      );
      final errors = captureErrorEvents(proxy);
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      await _waitUntil(() => errors
          .any((event) => event.data['operation'] == 'legacyStorageMigration'));

      // 前提: 書き写した後に 1 回だけ失敗したこと
      expect(hookCalls, 1);
      expect(copiedBeforeFailure, isTrue);
      // 書き写したキーが暗号化 Box から消え、隔離は移行待ちの 1 件のままであること
      expect(Hive.box(_encryptedQuarantineBoxName).containsKey(_keyA), isFalse);
      final pending = await proxy.getQuarantinedRequests();
      expect(pending, hasLength(1));
      expect(pending.single.pendingMigration, isTrue);
      expect((await proxy.getStats()).quarantinedCount, 1);

      // 次の定期処理（5 秒ごと）で移行し直すこと
      await _waitUntil(
        () => hookCalls >= 2 && !boxFilesExist(_legacyQuarantineBoxName),
        timeout: const Duration(seconds: 15),
      );
      expect(hookCalls, 2);

      // 隔離は 1 件のまま、ID も変わらないこと
      final migrated = await proxy.getQuarantinedRequests();
      expect(migrated, hasLength(1));
      expect(migrated.single.id, _keyA);
      expect(migrated.single.pendingMigration, isFalse);
      expect((await proxy.getStats()).quarantinedCount, 1);
      expect(Hive.box(_encryptedQuarantineBoxName).keys.toList(), [_keyA]);
    });
  });

  group('移行を待つ間の、暗号化 Box にある同じキーの残骸', () {
    /// 書き写したキーを消せなかった場合に備え、旧 Box が空になるまで暗号化 Box にある同じキーを一覧・件数・再送・隔離の変更・履歴の削除から外すこと
    test('ignores leftovers with the same keys while migration waits',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final origin = upstream!.origin;
        final base = _recentBase();
        final legacyQueueItem = _queueEntry(
          url: '$origin/api/legacy',
          body: 'legacy',
          queuedAt: base,
        );
        final legacyQuarantineItem = _quarantineEntry(
          url: '$origin/api/quarantined',
          body: 'quarantined',
          quarantinedAt: base,
        );
        // 保持期間（既定 30 日）を過ぎた履歴。暗号化 Box の側で数えると、保持上限の処理で消される
        final legacyDroppedItem = _droppedEntry(
          url: '$origin/api/dropped',
          droppedAt: DateTime.now().subtract(const Duration(days: 365)),
        );
        await writeLegacyBox(_legacyQueueBoxName, {_keyA: legacyQueueItem});
        await writeLegacyBox(
            _legacyQuarantineBoxName, {_keyA: legacyQuarantineItem});
        await writeLegacyBox(_legacyDroppedBoxName, {_keyA: legacyDroppedItem});
        await Hive.close();

        proxy = createProxy();
        await proxy.start(
          config: ProxyConfig(origin: origin, dropPolicy: DropPolicy.drop),
        );

        // 書き写した後にキーを消せなかった残骸を再現する
        await Hive.box(_encryptedQueueBoxName).put(_keyA, legacyQueueItem);
        await Hive.box(_encryptedQuarantineBoxName)
            .put(_keyA, legacyQuarantineItem);
        await Hive.box(_encryptedDroppedBoxName).put(_keyA, legacyDroppedItem);
        // 残骸とは別の、暗号化キューの通常の項目（旧キューの項目より新しい）
        await Hive.box(_encryptedQueueBoxName).put(
          _keyB,
          _queueEntry(
            url: '$origin/api/encrypted',
            body: 'encrypted',
            queuedAt: base.add(const Duration(minutes: 1)),
          ),
        );

        // 前提: 3 種類とも移行を待っていること
        expect(boxFilesExist(_legacyQueueBoxName), isTrue);
        expect(boxFilesExist(_legacyQuarantineBoxName), isTrue);
        expect(boxFilesExist(_legacyDroppedBoxName), isTrue);

        // 一覧に残骸が二重に現れないこと
        final queued = await proxy.getQueuedRequests();
        expect(queued.map((request) => request.url),
            ['$origin/api/legacy', '$origin/api/encrypted']);
        expect(
            queued.map((request) => request.pendingMigration), [true, false]);
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined, hasLength(1));
        expect(quarantined.single.pendingMigration, isTrue);
        final dropped = await proxy.getDroppedRequests();
        expect(dropped, hasLength(1));
        expect(dropped.single.pendingMigration, isTrue);

        // 件数に残骸を数えないこと
        final stats = await proxy.getStats();
        expect(stats.queueLength, 2);
        expect(stats.quarantinedCount, 1);
        expect(stats.droppedRequestsCount, 1);
        expect(stats.unacknowledgedDroppedCount, 1);

        // 隔離の変更（再送・破棄）の対象にせず、残骸も消さないこと
        expect(await proxy.retryQuarantinedRequest(_keyA), isFalse);
        expect(await proxy.discardQuarantinedRequest(_keyA), isFalse);
        expect(
            Hive.box(_encryptedQuarantineBoxName).containsKey(_keyA), isTrue);
        expect((await proxy.getStats()).queueLength, 2);

        // 再送を起こす。通常の項目は 400 で履歴へ移り、そのとき保持上限の処理が走る
        await _triggerQueueDrain();
        await _waitUntil(
            () async => (await proxy.getDroppedRequests()).length >= 2);

        // 残骸は再送の対象にならず、通常の項目だけが送られたこと
        expect(upstream!.receivedBodies, ['encrypted']);
        expect(Hive.box(_encryptedQueueBoxName).containsKey(_keyA), isTrue);
        final remaining = await proxy.getQueuedRequests();
        expect(remaining, hasLength(1));
        expect(remaining.single.pendingMigration, isTrue);

        // 前提: 通常の項目の履歴が追加されたこと（旧 Box の履歴と合わせて 2 件）
        expect(await proxy.getDroppedRequests(), hasLength(2));
        // 保持期間を過ぎた残骸を、履歴の削除の対象にしないこと
        expect(Hive.box(_encryptedDroppedBoxName).containsKey(_keyA), isTrue);
        // 確認済みへの変更でも残骸を数えないこと（旧 Box の履歴と追加された履歴の 2 件）
        expect(await proxy.acknowledgeDroppedRequests(), 2);
        expect((await proxy.getStats()).unacknowledgedDroppedCount, 0);
      });
    });
  });

  group('移行を待つ間の隔離とドロップ履歴の操作', () {
    /// 移行を待っている隔離は retryQuarantinedRequest / discardQuarantinedRequest が false、管理 API の retry / discard が 409 を返し、項目を変えないこと
    test('refuses to retry or discard pending legacy quarantine', () async {
      await withRealHttpClient(() async {
        await writeLegacyBox(_legacyQuarantineBoxName, {
          _keyA: _quarantineEntry(
            url: '$_offlineOrigin/api/quarantined',
            body: 'quarantined',
            quarantinedAt: _recentBase(),
          ),
        });
        await Hive.close();

        proxy = createProxy();
        final port = await proxy.start(
          config: const ProxyConfig(
            origin: _offlineOrigin,
            enableAdminApi: true,
          ),
        );

        // 前提: 隔離が移行を待っていること
        final before = await proxy.getQuarantinedRequests();
        expect(before, hasLength(1));
        expect(before.single.id, _keyA);
        expect(before.single.pendingMigration, isTrue);

        // Dart API は false を返すこと
        expect(await proxy.retryQuarantinedRequest(_keyA), isFalse);
        expect(await proxy.discardQuarantinedRequest(_keyA), isFalse);

        // 管理 API は 409 を返すこと
        final retryResponse = await _performRequest(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/admin/quarantine/$_keyA/retry'),
          method: 'POST',
        );
        expect(retryResponse.statusCode, HttpStatus.conflict);
        expect(jsonDecode(retryResponse.body)['retried'], isFalse);
        final discardResponse = await _performRequest(
          Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/admin/quarantine/$_keyA'),
          method: 'DELETE',
        );
        expect(discardResponse.statusCode, HttpStatus.conflict);
        expect(jsonDecode(discardResponse.body)['discarded'], isFalse);

        // 隔離は移行待ちのまま残り、キューへも戻っていないこと
        final after = await proxy.getQuarantinedRequests();
        expect(after, hasLength(1));
        expect(after.single.id, _keyA);
        expect(after.single.pendingMigration, isTrue);
        expect((await proxy.getStats()).queueLength, 0);
        expect(boxFilesExist(_legacyQuarantineBoxName), isTrue);
      });
    });

    /// acknowledgeDroppedRequests() は移行を待っている履歴も確認済みにし、移行後と再起動後も未確認に戻らないこと
    test('keeps pending dropped history acknowledged after migration',
        () async {
      final base = _recentBase();
      await writeLegacyBox(_legacyDroppedBoxName, {
        _keyA: _droppedEntry(url: '$_offlineOrigin/api/1', droppedAt: base),
        _keyB: _droppedEntry(
          url: '$_offlineOrigin/api/2',
          droppedAt: base.add(const Duration(minutes: 1)),
        ),
      });
      await Hive.close();

      proxy = createProxy(deferredMigrationDelay: const Duration(seconds: 3));
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // 前提: 移行を待っており、未確認として数えられていること
      final before = await proxy.getDroppedRequests();
      expect(before.map((request) => request.pendingMigration), [true, true]);
      expect(before.map((request) => request.acknowledged), [false, false]);
      expect((await proxy.getStats()).unacknowledgedDroppedCount, 2);

      // 旧 Box の履歴も確認済みにすること
      expect(await proxy.acknowledgeDroppedRequests(), 2);
      final acknowledged = await proxy.getDroppedRequests();
      expect(acknowledged.map((request) => request.pendingMigration),
          [true, true]);
      expect(acknowledged.map((request) => request.acknowledged), [true, true]);
      expect((await proxy.getStats()).unacknowledgedDroppedCount, 0);

      await _waitUntil(
        () => !boxFilesExist(_legacyDroppedBoxName),
        timeout: const Duration(seconds: 15),
      );

      // 移行後も確認済みのままであること
      final migrated = await proxy.getDroppedRequests();
      expect(
          migrated.map((request) => request.pendingMigration), [false, false]);
      expect(migrated.map((request) => request.acknowledged), [true, true]);
      expect((await proxy.getStats()).unacknowledgedDroppedCount, 0);

      // 再起動後も確認済みのままであること
      await proxy.stop();
      proxy = createProxy();
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));
      final restarted = await proxy.getDroppedRequests();
      expect(restarted.map((request) => request.acknowledged), [true, true]);
      expect((await proxy.getStats()).unacknowledgedDroppedCount, 0);
    });

    /// clearQuarantinedRequests() / clearDroppedRequests() は移行を待っている旧 Box も消し、旧 Box のファイルも消えて、移行の時刻の後や再起動後に復活しないこと
    test('clears pending legacy quarantine and history for good', () async {
      final base = _recentBase();
      await writeLegacyBox(_legacyQuarantineBoxName, {
        _keyA: _quarantineEntry(
          url: '$_offlineOrigin/api/quarantined',
          body: 'quarantined',
          quarantinedAt: base,
        ),
      });
      await writeLegacyBox(_legacyDroppedBoxName, {
        _keyA:
            _droppedEntry(url: '$_offlineOrigin/api/dropped', droppedAt: base),
      });
      await Hive.close();

      const delay = Duration(seconds: 2);
      proxy = createProxy(deferredMigrationDelay: delay);
      final startedAt = DateTime.now();
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // 前提: 移行を待っていること
      expect((await proxy.getQuarantinedRequests()).single.pendingMigration,
          isTrue);
      expect(
          (await proxy.getDroppedRequests()).single.pendingMigration, isTrue);
      expect(boxFilesExist(_legacyQuarantineBoxName), isTrue);
      expect(boxFilesExist(_legacyDroppedBoxName), isTrue);

      await proxy.clearQuarantinedRequests();
      await proxy.clearDroppedRequests();

      // 旧 Box の分も消え、件数も 0 になること
      expect(await proxy.getQuarantinedRequests(), isEmpty);
      expect(await proxy.getDroppedRequests(), isEmpty);
      final stats = await proxy.getStats();
      expect(stats.quarantinedCount, 0);
      expect(stats.droppedRequestsCount, 0);
      expect(stats.unacknowledgedDroppedCount, 0);
      // 旧 Box のファイルも消えること
      expect(boxFilesExist(_legacyQuarantineBoxName), isFalse);
      expect(boxFilesExist(_legacyDroppedBoxName), isFalse);

      // 移行を始める時刻を過ぎても復活しないこと
      await _waitUntil(
        () => DateTime.now()
            .isAfter(startedAt.add(delay + const Duration(seconds: 1))),
      );
      expect(await proxy.getQuarantinedRequests(), isEmpty);
      expect(await proxy.getDroppedRequests(), isEmpty);

      // 再起動しても復活しないこと
      await proxy.stop();
      proxy = createProxy();
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));
      expect(await proxy.getQuarantinedRequests(), isEmpty);
      expect(await proxy.getDroppedRequests(), isEmpty);
    });
  });

  group('停止と再起動', () {
    /// stop() を呼んだ後は、送信中の 1 件の次へ進まず、残りの項目はキューに残ること
    test('does not move on to the next queued item after stop() is called',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final origin = upstream!.origin;
        final key = storeExistingKey();
        final base = _recentBase();
        await writeEncryptedBox(_encryptedQueueBoxName, key, {
          _keyA: _queueEntry(
            url: '$origin/api/first',
            body: 'first',
            queuedAt: base,
          ),
          _keyB: _queueEntry(
            url: '$origin/api/second',
            body: 'second',
            queuedAt: base.add(const Duration(minutes: 1)),
          ),
        });
        await Hive.close();
        final firstResponseGate = Completer<void>();
        upstream!.heldBodies['first'] = firstResponseGate;

        proxy = createProxy();
        await proxy.start(config: ProxyConfig(origin: origin));
        // 前提: 2 件がキューにあること
        expect((await proxy.getStats()).queueLength, 2);

        await _triggerQueueDrain();
        await _waitUntil(() => upstream!.receivedBodies.isNotEmpty);
        // 前提: 1 件目の応答を待っている（送信中である）こと
        expect(upstream!.receivedBodies, ['first']);

        // 停止を始めてから 1 件目の応答を返す
        final stopping = proxy.stop();
        firstResponseGate.complete();
        await stopping;
        // 誤って次の 1 件を送った場合に、上流へ届くだけの時間を置く
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // 2 件目は送られていないこと
        expect(upstream!.receivedBodies, ['first']);

        // 2 件目がキューに残っていること（再起動して確かめる）
        proxy = createProxy();
        await proxy.start(config: ProxyConfig(origin: origin));
        final remaining = await proxy.getQueuedRequests();
        expect(remaining.map((request) => request.url),
            contains('$origin/api/second'));
      });
    });

    /// 移行を待つ間に stop() しても旧 Box は残り、停止中は移行せず、stop → start の後に改めて移行されること
    test('reschedules the deferred migration after stop and start', () async {
      await writeLegacyBox(_legacyQueueBoxName, {
        _keyA: _queueEntry(
          url: '$_offlineOrigin/api/legacy',
          body: 'legacy',
          queuedAt: _recentBase(),
          nextRetryAt: _farFuture,
        ),
      });
      await Hive.close();

      const delay = Duration(seconds: 2);
      proxy = createProxy(deferredMigrationDelay: delay);
      final startedAt = DateTime.now();
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // 前提: 移行を待っていること
      expect((await proxy.getQueuedRequests()).single.pendingMigration, isTrue);

      await proxy.stop();
      // 移行を始める時刻を過ぎても、停止中は移行しないこと
      await _waitUntil(
        () => DateTime.now()
            .isAfter(startedAt.add(delay + const Duration(seconds: 1))),
      );
      expect(boxFilesExist(_legacyQueueBoxName), isTrue);

      // 再起動の後に移行されること
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));
      await _waitUntil(
        () => !boxFilesExist(_legacyQueueBoxName),
        timeout: const Duration(seconds: 15),
      );
      expect(boxFilesExist(_legacyQueueBoxName), isFalse);
      final migrated = await proxy.getQueuedRequests();
      expect(migrated, hasLength(1));
      expect(migrated.single.pendingMigration, isFalse);
      expect(Hive.box(_encryptedQueueBoxName).keys.toList(), [_keyA]);
    });
  });

  group('書き写し後・旧 Box を空にする前に中断した状態からの起動', () {
    /// 旧 Box と暗号化 Box の両方に同じキーがある状態から起動すると、段階 2 で書き写し直し、項目は 1 件で 1 回だけ送られること
    test('recopies an interrupted migration and sends the item once', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final origin = upstream!.origin;
        final key = storeExistingKey();
        final base = _recentBase();
        final queueItem = _queueEntry(
          url: '$origin/api/interrupted',
          body: 'interrupted',
          queuedAt: base,
        );
        final quarantineItem = _quarantineEntry(
          url: '$origin/api/quarantined',
          body: 'quarantined',
          quarantinedAt: base,
        );
        await writeEncryptedBox(
            _encryptedQueueBoxName, key, {_keyA: queueItem});
        await writeEncryptedBox(
            _encryptedQuarantineBoxName, key, {_keyB: quarantineItem});
        await writeLegacyBox(_legacyQueueBoxName, {_keyA: queueItem});
        await writeLegacyBox(_legacyQuarantineBoxName, {_keyB: quarantineItem});
        await Hive.close();

        final copiedDuringStart = <ProxyStorageBox>[];
        proxy = createProxy(beforeLegacyBoxCleared: (kind) async {
          if (!proxy.isRunning) {
            copiedDuringStart.add(kind);
          }
        });
        await proxy.start(config: ProxyConfig(origin: origin));

        // 段階 2（start の中）で書き写し直し、旧 Box を消したこと
        expect(copiedDuringStart,
            [ProxyStorageBox.queue, ProxyStorageBox.quarantine]);
        expect(boxFilesExist(_legacyQueueBoxName), isFalse);
        expect(boxFilesExist(_legacyQuarantineBoxName), isFalse);

        // 項目は 1 件のまま、キーも変わらないこと
        expect(Hive.box(_encryptedQueueBoxName).keys.toList(), [_keyA]);
        final queued = await proxy.getQueuedRequests();
        expect(queued, hasLength(1));
        expect(queued.single.pendingMigration, isFalse);
        final quarantined = await proxy.getQuarantinedRequests();
        expect(quarantined, hasLength(1));
        expect(quarantined.single.id, _keyB);
        final stats = await proxy.getStats();
        expect(stats.queueLength, 1);
        expect(stats.quarantinedCount, 1);

        await _triggerQueueDrain();
        await _waitUntil(() async => (await proxy.getStats()).queueLength == 0);

        // 1 回だけ送られること
        expect(upstream!.receivedBodies, ['interrupted']);

        // 再起動しても、送り直す項目が残っていないこと
        await proxy.stop();
        proxy = createProxy();
        await proxy.start(config: ProxyConfig(origin: origin));
        expect(await proxy.getQueuedRequests(), isEmpty);
        expect(await proxy.getQuarantinedRequests(), hasLength(1));
        expect(boxFilesExist(_legacyQueueBoxName), isFalse);
      });
    });
  });

  group('Cookie の旧平文 Box の移行', () {
    /// 旧平文 Cookie Box の移行は、暗号化 Box に同じ storageKey の Cookie があれば上書きせず、無い Cookie だけを移すこと
    test('does not overwrite an encrypted cookie with the same storage key',
        () async {
      final key = storeExistingKey();
      final createdAt = DateTime.now();

      /// テスト用の Cookie レコードを作る。
      CookieRecord cookie(String name, String value) => CookieRecord(
            name: name,
            value: value,
            domain: 'example.com',
            path: '/',
            expires: null,
            secure: false,
            httpOnly: false,
            sameSite: null,
            hostOnly: true,
            createdAt: createdAt,
          );
      final newSession = cookie('SESSION', 'new-token');
      final oldSession = cookie('SESSION', 'old-token');
      final other = cookie('OTHER', 'other-token');
      // 前提: 新旧の SESSION が同じ storageKey を持つこと
      expect(oldSession.storageKey, newSession.storageKey);

      await writeEncryptedBox(_encryptedCookieBoxName, key, {
        newSession.storageKey: newSession.toMap(),
      });
      await writeLegacyBox(_legacyCookieBoxName, {
        oldSession.storageKey: oldSession.toMap(),
        other.storageKey: other.toMap(),
      });
      await Hive.close();

      proxy = createProxy();
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      final cookieBox = Hive.box(_encryptedCookieBoxName);
      // 同じ storageKey の Cookie は、暗号化 Box の新しい値のままであること
      expect(
          (cookieBox.get(newSession.storageKey) as Map)['value'], 'new-token');
      // 暗号化 Box に無い Cookie は移されること
      expect((cookieBox.get(other.storageKey) as Map)['value'], 'other-token');
      // 旧平文 Box は消えること
      expect(boxFilesExist(_legacyCookieBoxName), isFalse);
      final names = (await proxy.getCookies())
          .map((cookieInfo) => cookieInfo.name)
          .toList()
        ..sort();
      expect(names, ['OTHER', 'SESSION']);
    });
  });

  group('暗号化 Box のファイルの内容', () {
    /// 移行後の暗号化 Box のファイルに、キューと隔離の本文やヘッダ値の平文が含まれないこと
    test('does not leave plaintext bodies or header values in box files',
        () async {
      storeExistingKey();
      final base = _recentBase();
      const queueBody = 'plaintext-queue-body-7f3a';
      const queueHeader = 'plaintext-queue-header-9c2e';
      const quarantineBody = 'plaintext-quarantine-body-1d4b';
      const quarantineHeader = 'plaintext-quarantine-header-5e8f';
      await writeLegacyBox(_legacyQueueBoxName, {
        _keyA: _queueEntry(
          url: '$_offlineOrigin/api/queued',
          body: queueBody,
          queuedAt: base,
          nextRetryAt: _farFuture,
          headers: {'x-note': queueHeader},
        ),
      });
      await writeLegacyBox(_legacyQuarantineBoxName, {
        _keyB: _quarantineEntry(
          url: '$_offlineOrigin/api/quarantined',
          body: quarantineBody,
          quarantinedAt: base,
          headers: {'x-note': quarantineHeader},
        ),
      });
      await Hive.close();

      // 前提: 旧平文 Box のファイルには平文で残っていること（探し方が正しいこと）
      final legacyQueueBytes = boxFile(_legacyQueueBoxName).readAsBytesSync();
      expect(_containsBytes(legacyQueueBytes, utf8.encode(queueBody)), isTrue);
      expect(
          _containsBytes(legacyQueueBytes, utf8.encode(queueHeader)), isTrue);
      final legacyQuarantineBytes =
          boxFile(_legacyQuarantineBoxName).readAsBytesSync();
      expect(_containsBytes(legacyQuarantineBytes, utf8.encode(quarantineBody)),
          isTrue);
      expect(
          _containsBytes(legacyQuarantineBytes, utf8.encode(quarantineHeader)),
          isTrue);

      proxy = createProxy();
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // 前提: 書き写した内容を読めること
      final migratedQueue = Hive.box(_encryptedQueueBoxName).get(_keyA) as Map;
      expect(migratedQueue['body'], utf8.encode(queueBody));
      expect((migratedQueue['headers'] as Map)['x-note'], queueHeader);
      final migratedQuarantine =
          Hive.box(_encryptedQuarantineBoxName).get(_keyB) as Map;
      expect(migratedQuarantine['body'], utf8.encode(quarantineBody));
      expect(
          (migratedQuarantine['headers'] as Map)['x-note'], quarantineHeader);
      // ファイルを閉じてから読む
      await proxy.stop();

      final queueBytes = boxFile(_encryptedQueueBoxName).readAsBytesSync();
      // 前提: 記録がこのファイルにあること（Hive はキーを暗号化しない）
      expect(_containsBytes(queueBytes, utf8.encode(_keyA)), isTrue);
      // 本文とヘッダ値の平文が含まれないこと
      expect(_containsBytes(queueBytes, utf8.encode(queueBody)), isFalse);
      expect(_containsBytes(queueBytes, utf8.encode(queueHeader)), isFalse);

      final quarantineBytes =
          boxFile(_encryptedQuarantineBoxName).readAsBytesSync();
      // 前提: 記録がこのファイルにあること
      expect(_containsBytes(quarantineBytes, utf8.encode(_keyB)), isTrue);
      // 本文とヘッダ値の平文が含まれないこと
      expect(_containsBytes(quarantineBytes, utf8.encode(quarantineBody)),
          isFalse);
      expect(_containsBytes(quarantineBytes, utf8.encode(quarantineHeader)),
          isFalse);
    });
  });

  group('旧 Box のファイルを消せない場合', () {
    /// 旧 Box を空にした後にファイルを消せなかった場合も処理を続け、errorOccurred（operation: legacyStorageDelete）を出すこと
    test('continues and reports when the legacy box file cannot be deleted',
        () async {
      storeExistingKey();
      await writeLegacyBox(_legacyQueueBoxName, {
        _keyA: _queueEntry(
          url: '$_offlineOrigin/api/legacy',
          body: 'legacy',
          queuedAt: _recentBase(),
          nextRetryAt: _farFuture,
        ),
      });
      await Hive.close();

      // Windows では、別に開いているファイルを削除できないことを使って削除を失敗させる
      final handle = boxFile(_legacyQueueBoxName).openSync();
      var handleClosed = false;
      addTearDown(() {
        if (!handleClosed) {
          handle.closeSync();
        }
      });

      proxy = createProxy();
      final errors = captureErrorEvents(proxy);
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));
      await _waitUntil(() => errors
          .any((event) => event.data['operation'] == 'legacyStorageDelete'));

      // 起動を続けたこと
      expect(proxy.isRunning, isTrue);
      // 削除の失敗をイベントで知らせたこと
      final deleteErrors = errors
          .where((event) => event.data['operation'] == 'legacyStorageDelete')
          .toList();
      expect(deleteErrors, hasLength(1));
      expect(deleteErrors.single.data['box'], _legacyQueueBoxName);
      // 前提: 旧 Box のファイルが消えずに残っていること
      expect(boxFile(_legacyQueueBoxName).existsSync(), isTrue);
      // 項目は移行済みであること
      final queued = await proxy.getQueuedRequests();
      expect(queued, hasLength(1));
      expect(queued.single.pendingMigration, isFalse);
      expect(Hive.box(_encryptedQueueBoxName).keys.toList(), [_keyA]);

      // ファイルを消せるようになった後の起動で、空の旧 Box が片付き、項目は二重にならないこと
      await proxy.stop();
      handle.closeSync();
      handleClosed = true;
      proxy = createProxy();
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));
      expect(boxFilesExist(_legacyQueueBoxName), isFalse);
      expect(await proxy.getQueuedRequests(), hasLength(1));
    },
        skip: Platform.isWindows
            ? false
            : 'Windows 以外では開いているファイルも削除できるため、削除の失敗を再現できない');
  });

  group('遅らせた移行が失敗し続ける場合の再送', () {
    /// 遅らせた移行が旧 Box を空にする前に毎回失敗しても、5 秒ごとの定期処理のたびに移行を
    /// 試み直し（hook が繰り返し呼ばれ）、続けて暗号化キューの項目を送り続けること。
    /// 旧キューの項目は移行するまで送らないこと
    test(
        'keeps resending the encrypted queue while the migration keeps failing',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        final origin = upstream!.origin;
        final base = _recentBase();
        // 誤って送った場合に検出できるよう、旧キューの項目は再送の時刻を過ぎている
        await writeLegacyBox(_legacyQueueBoxName, {
          _keyA: _queueEntry(
            url: '$origin/api/legacy',
            body: 'legacy',
            queuedAt: base,
          ),
        });
        await Hive.close();

        var hookCalls = 0;
        proxy = createProxy(
          deferredMigrationDelay: const Duration(milliseconds: 500),
          beforeLegacyBoxCleared: (kind) async {
            if (kind != ProxyStorageBox.queue) {
              return;
            }
            hookCalls++;
            throw Exception('injected failure before clearing legacy box');
          },
        );
        final errors = captureErrorEvents(proxy);
        await proxy.start(config: ProxyConfig(origin: origin));
        await _waitUntil(() => errors.any(
            (event) => event.data['operation'] == 'legacyStorageMigration'));

        // 前提: 旧 Box を空にする前に移行が失敗し、旧 Box が残っていること
        expect(hookCalls, greaterThanOrEqualTo(1));
        expect(boxFilesExist(_legacyQueueBoxName), isTrue);

        final encryptedQueue = Hive.box(_encryptedQueueBoxName);
        final callsBeforeFirstItem = hookCalls;
        await encryptedQueue.put(
          _keyB,
          _queueEntry(
            url: '$origin/api/encrypted-1',
            body: 'encrypted-1',
            queuedAt: base.add(const Duration(minutes: 1)),
          ),
        );
        // 接続状態の通知では起こさず、5 秒ごとの定期処理による再送を待つ
        await _waitUntil(
          () => upstream!.receivedBodies.contains('encrypted-1'),
          timeout: const Duration(seconds: 15),
        );
        final callsAtFirstSend = hookCalls;

        await encryptedQueue.put(
          _keyC,
          _queueEntry(
            url: '$origin/api/encrypted-2',
            body: 'encrypted-2',
            queuedAt: base.add(const Duration(minutes: 2)),
          ),
        );
        await _waitUntil(
          () => upstream!.receivedBodies.contains('encrypted-2'),
          timeout: const Duration(seconds: 15),
        );
        final callsAtSecondSend = hookCalls;

        // 移行が失敗し続けても、暗号化キューの項目を定期処理で送り続けたこと
        expect(upstream!.receivedBodies, ['encrypted-1', 'encrypted-2']);
        // それぞれの再送の前に、定期処理が移行を試み直していたこと
        expect(callsAtFirstSend, greaterThan(callsBeforeFirstItem));
        expect(callsAtSecondSend, greaterThan(callsAtFirstSend));
        // 試み直した移行の失敗も、そのたびにイベントで知らせること
        expect(
          errors.where(
              (event) => event.data['operation'] == 'legacyStorageMigration'),
          hasLength(greaterThanOrEqualTo(callsAtFirstSend)),
        );

        // 旧キューの項目は送らず、移行待ちのまま残すこと
        await _waitUntil(() async => (await proxy.getStats()).queueLength == 1);
        final remaining = await proxy.getQueuedRequests();
        expect(remaining, hasLength(1));
        expect(remaining.single.url, '$origin/api/legacy');
        expect(remaining.single.pendingMigration, isTrue);
        expect(boxFilesExist(_legacyQueueBoxName), isTrue);
        expect(upstream!.receivedBodies, isNot(contains('legacy')));
      });
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('移行が終わる瞬間の一覧', () {
    /// 遅らせた移行を完了させている間に getQueuedRequests() を繰り返し呼んでも、どの時点の一覧でも
    /// 項目が抜けたり二重になったりせず、移行待ちの目印は一覧のすべてに付くかすべてから外れるかの
    /// どちらかであること
    test('never loses items in lists taken while the migration completes',
        () async {
      // 一覧を読み解く間に処理を譲る間隔（50 件）を 1 回だけ超える件数。譲る箇所を増やしすぎると、
      // 移行の完了が一覧の途中に重なる確率が下がるため、多くしない
      const itemCount = 60;
      // 一覧を取り続ける処理の数。移行の完了が、いずれかの一覧の途中に重なりやすくする
      const listerCount = 12;
      final base = _recentBase();

      /// 番号から、保存領域のキー（19 桁のマイクロ秒と 6 桁の連番）を作る。
      String storageKey(int index) =>
          '${(1757000000000000 + index).toString().padLeft(19, '0')}-000000';

      await writeLegacyBox(_legacyQueueBoxName, {
        for (var index = 0; index < itemCount; index++)
          storageKey(index): _queueEntry(
            url: '$_offlineOrigin/api/item-$index',
            body: 'item-$index',
            queuedAt: base.add(Duration(seconds: index)),
            nextRetryAt: _farFuture,
          ),
      });
      await Hive.close();

      final hookEntered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) {
          release.complete();
        }
      });
      proxy = createProxy(
        deferredMigrationDelay: const Duration(milliseconds: 300),
        beforeLegacyBoxCleared: (kind) async {
          if (kind != ProxyStorageBox.queue) {
            return;
          }
          if (!hookEntered.isCompleted) {
            hookEntered.complete();
          }
          await release.future;
        },
      );
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // 一覧ごとの件数と、移行待ちの目印が付いた件数
      final snapshots = <({int count, int pending})>[];
      var listing = true;

      /// 止めるまで一覧を取り続け、件数と目印の数を記録する。
      ///
      /// 一覧の取得が処理を譲らない場合でも移行やタイマーを止めないよう、取得ごとに処理を譲る。
      Future<void> listRepeatedly() async {
        while (listing) {
          final queued = await proxy.getQueuedRequests();
          snapshots.add((
            count: queued.length,
            pending: queued.where((request) => request.pendingMigration).length,
          ));
          await Future<void>.delayed(Duration.zero);
        }
      }

      final listers = [
        for (var i = 0; i < listerCount; i++) listRepeatedly(),
      ];
      // 書き写しを終えて旧 Box を空にする直前で止まり、その間にも一覧を取れるまで待つ
      await hookEntered.future.timeout(const Duration(seconds: 15));
      await _waitUntil(() => snapshots.length >= 5);
      final snapshotsBeforeRelease = snapshots.length;
      release.complete();
      // 移行が終わった後も、しばらく一覧を取り続ける
      await _waitUntil(
        () => !boxFilesExist(_legacyQueueBoxName),
        timeout: const Duration(seconds: 15),
      );
      final snapshotsAtCompletion = snapshots.length;
      await _waitUntil(() => snapshots.length >= snapshotsAtCompletion + 20);
      listing = false;
      await Future.wait(listers);

      // 前提: 移行を待つ間と、移行を終えた後の両方で一覧を取れたこと
      expect(snapshotsBeforeRelease, greaterThanOrEqualTo(5));
      expect(snapshots.first.pending, itemCount);
      expect(snapshots.last.pending, 0);
      expect(boxFilesExist(_legacyQueueBoxName), isFalse);
      // どの時点の一覧でも、項目が抜けたり二重になったりしていないこと
      expect(
        snapshots.map((snapshot) => snapshot.count).toSet(),
        {itemCount},
      );
      // 移行待ちの目印は、一覧のすべてに付くかすべてから外れるかのどちらかであること
      expect(
        snapshots.map((snapshot) => snapshot.pending).toSet(),
        everyElement(isIn([0, itemCount])),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('隔離と停止・再起動の競合', () {
    /// 上流が 400 を返してキュー消化が隔離する前後で stop() し、同じインスタンスで start() しても、
    /// 同じ要求を二重に隔離しないこと。再起動の直後は「隔離に 1 件でキューに無い」か
    /// 「キューに 1 件で隔離に無い」のどちらか一方で、その後のキュー消化の後も隔離は 1 件であること。
    /// 停止の時機はテストから制御できないため、応答を返してから停止するまでの時間をずらして繰り返す
    test('does not quarantine a request twice when stopped around quarantining',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final origin = upstream!.origin;
        final key = storeExistingKey();
        // 隔離の書き込みに時間がかかり、停止と重なりやすいよう本文を大きくする
        final padding = 'x' * (256 * 1024);
        // 上流の応答を返してから stop() を呼ぶまでの時間。null は stop() を呼んでから応答を返す
        const stopDelays = <Duration?>[
          null,
          Duration.zero,
          Duration(milliseconds: 1),
          Duration(milliseconds: 2),
          Duration(milliseconds: 4),
          Duration(milliseconds: 8),
          Duration(milliseconds: 16),
          Duration(milliseconds: 32),
        ];
        final outcomes = <String>[];

        for (var round = 0; round < stopDelays.length; round++) {
          final url = '$origin/api/round-$round';
          final body = 'round-$round-$padding';
          await writeEncryptedBox(_encryptedQueueBoxName, key, {
            '${(1757000000000000 + round).toString().padLeft(19, '0')}-000000':
                _queueEntry(url: url, body: body, queuedAt: _recentBase()),
          });
          final responseGate = Completer<void>();
          upstream!.heldBodies[body] = responseGate;

          await proxy.start(config: ProxyConfig(origin: origin));
          await _triggerQueueDrain();
          await _waitUntil(() => upstream!.receivedBodies.contains(body));
          // 前提: 要求が上流へ届き、応答を待っていること
          expect(upstream!.receivedBodies, contains(body),
              reason: 'round $round');

          final delay = stopDelays[round];
          if (delay == null) {
            final stopping = proxy.stop();
            responseGate.complete();
            await stopping;
          } else {
            responseGate.complete();
            await Future<void>.delayed(delay);
            await proxy.stop();
          }

          // 同じインスタンスですぐに start() し、停止をまたいだ処理が終わるまで待つ
          await proxy.start(config: ProxyConfig(origin: origin));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final quarantinedCount = (await proxy.getQuarantinedRequests())
              .where((request) => request.url == url)
              .length;
          final queuedCount = (await proxy.getQueuedRequests())
              .where((request) => request.url == url)
              .length;
          outcomes.add('round $round '
              '(${delay == null ? 'stop first' : '${delay.inMilliseconds} ms'}): '
              'quarantined $quarantinedCount, queued $queuedCount');

          // 隔離に 1 件でキューに無いか、キューに 1 件で隔離に無いかのどちらか一方であること
          expect(
            (quarantined: quarantinedCount, queued: queuedCount),
            isIn([(quarantined: 1, queued: 0), (quarantined: 0, queued: 1)]),
            reason: 'round $round',
          );

          // キューに残った場合も、次のキュー消化で 1 件だけ隔離されること
          await _triggerQueueDrain();
          await _waitUntil(() async => (await proxy.getQueuedRequests())
              .every((request) => request.url != url));
          expect(
            (await proxy.getQueuedRequests())
                .where((request) => request.url == url),
            isEmpty,
            reason: 'round $round',
          );
          expect(
            (await proxy.getQuarantinedRequests())
                .where((request) => request.url == url),
            hasLength(1),
            reason: 'round $round',
          );

          await proxy.stop();
        }

        // ignore: avoid_print
        print('隔離と停止の競合の結果:\n${outcomes.join('\n')}');
      });
    }, timeout: const Timeout(Duration(minutes: 3)));

    /// 上流の 400 を受けて隔離を保存している途中（追い出す既存の隔離を履歴へ書くために履歴のロックを
    /// 待っている間）に stop() を呼ぶと、保存が終わるまで待ってから Box を閉じること。新しいインスタンスで
    /// 起動すると、隔離は受けた要求の 1 件だけ・キューは 0 件で、上流への送信も増えないこと。
    /// 隔離のロック自体はテストから保持させられないため、保存の後半（追い出し）に stop() を重ねる
    test('waits for quarantining to finish before closing boxes on stop()',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        upstream!.statusCode = HttpStatus.badRequest;
        final origin = upstream!.origin;
        final key = storeExistingKey();
        final base = _recentBase();
        // 確認済みへの変更が履歴のロックを長く持つよう、未確認の履歴を多く置く
        const historyCount = 20000;
        await writeEncryptedBox(_encryptedDroppedBoxName, key, {
          for (var index = 0; index < historyCount; index++)
            '${(1756000000000000 + index).toString().padLeft(19, '0')}-000000':
                _droppedEntry(
                    url: '$origin/api/history-$index', droppedAt: base),
        });
        // 件数の上限 1 件のため、新しく隔離すると追い出される既存の隔離
        await writeEncryptedBox(_encryptedQuarantineBoxName, key, {
          _keyA: _quarantineEntry(
            url: '$origin/api/existing',
            body: 'existing',
            quarantinedAt: base,
          ),
        });
        await writeEncryptedBox(_encryptedQueueBoxName, key, {
          _keyB: _queueEntry(
            url: '$origin/api/rejected',
            body: 'rejected',
            queuedAt: base,
          ),
        });
        await Hive.close();
        final responseGate = Completer<void>();
        upstream!.heldBodies['rejected'] = responseGate;

        proxy = createProxy();
        await proxy.start(
          config: ProxyConfig(origin: origin, quarantineMaxCount: 1),
        );
        await _triggerQueueDrain();
        await _waitUntil(() => upstream!.receivedBodies.contains('rejected'));
        // 前提: 要求が上流へ届き、応答を待っていること
        expect(upstream!.receivedBodies, ['rejected']);

        // 確認済みへの変更に履歴のロックを持たせたまま、上流の 400 を返す
        var acknowledging = true;
        final acknowledged = proxy
            .acknowledgeDroppedRequests()
            .whenComplete(() => acknowledging = false);
        responseGate.complete();
        // 受けた要求を隔離してキューから取り除き、既存の隔離を追い出すために履歴のロックを待つまで進める
        final quarantineBox = Hive.box(_encryptedQuarantineBoxName);
        final queueBox = Hive.box(_encryptedQueueBoxName);
        await _waitUntil(() => quarantineBox.length == 2 && queueBox.isEmpty);

        // 前提: 隔離の保存の途中で、確認済みへの変更がまだ履歴のロックを持っていること
        expect(quarantineBox.length, 2);
        expect(queueBox.isEmpty, isTrue);
        expect(acknowledging, isTrue);

        await proxy.stop();

        // stop() は隔離の保存が終わるまで待ったため、履歴のロックを持っていた処理も最後まで終わっていること
        expect(acknowledging, isFalse);
        expect(await acknowledged, historyCount);

        // 新しいインスタンスで起動すると、隔離は受けた要求の 1 件だけで、キューは空であること
        proxy = createProxy();
        await proxy.start(config: ProxyConfig(origin: origin));
        final quarantined = await proxy.getQuarantinedRequests();
        expect(
          quarantined.map((request) => request.url),
          ['$origin/api/rejected'],
        );
        expect(await proxy.getQueuedRequests(), isEmpty);
        // 追い出した既存の隔離は、件数の上限による追い出しとして履歴に記録されていること
        final dropped = await proxy.getDroppedRequests();
        expect(
          dropped
              .where((request) => request.url == '$origin/api/existing')
              .map((request) => request.dropReason),
          ['quarantine_limit'],
        );

        // キュー消化を起こしても、上流への送信は増えないこと
        await _triggerQueueDrain();
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(upstream!.receivedBodies, ['rejected']);
      });
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
