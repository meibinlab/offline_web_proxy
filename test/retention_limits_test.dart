import 'dart:async';
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

/// 隔離の暗号化 Box の名前。
const String _quarantineBoxName = 'proxy_quarantined_requests_secure';

/// ドロップ履歴の暗号化 Box の名前。
const String _droppedBoxName = 'proxy_dropped_requests_secure';

/// 暗号化する前の隔離の Box の名前（遅らせた移行の移行元）。
const String _legacyQuarantineBoxName = 'proxy_quarantined_requests';

/// 暗号化する前のドロップ履歴の Box の名前（遅らせた移行の移行元）。
const String _legacyDroppedBoxName = 'proxy_dropped_requests';

/// 上流へ接続しないテストで使う origin。
const String _offlineOrigin = 'https://example.com';

/// 件数または合計バイト数の上限で、隔離から履歴へ移したときの dropReason。
const String _limitReason = 'quarantine_limit';

/// 保持期間を過ぎたため、隔離から履歴へ移したときの dropReason。
const String _expiredReason = 'quarantine_expired';

/// 1 件で合計バイト数の上限を超えたため、隔離しなかったときの dropReason。
const String _tooLargeReason = 'quarantine_too_large';

/// 隔離やキューの項目に付けるヘッダ。名前 12 文字 + 値 10 文字で 22 バイトと数える。
const Map<String, String> _plainTextHeaders = {'content-type': 'text/plain'};

/// 保存順を検証するキー（13 桁のミリ秒の形式）。
const String _key13 = '1756000000000';

/// 保存順を検証するキー（16 桁のマイクロ秒の形式）。
const String _key16 = '1756500000000000';

/// 保存順を検証するキー（19 桁と連番の形式）。辞書順では 13 / 16 桁より前に来る。
const String _key19 = '0001757000000000000-000000';

/// 保存時刻が同じ場合の順を検証するキー（16 桁）。マイクロ秒で …400。
const String _tieKey16 = '1757000000000400';

/// 保存時刻が同じ場合の順を検証するキー（19 桁）。マイクロ秒で …500。
const String _tieKey19 = '0001757000000000500-000000';

/// 保存時刻が同じ場合の順を検証するキー（13 桁）。ミリ秒 …001 はマイクロ秒で …1000。
const String _tieKey13 = '1757000000001';

/// テストで暗号化 Box に使う 32 バイトの鍵。
final List<int> _encryptionKey =
    List<int>.generate(32, (index) => (index * 11 + 5) & 0xff);

/// 19 桁のマイクロ秒と 6 桁の連番の形式でキーを作る。
///
/// [microseconds] キーに入れるマイクロ秒。
/// [sequence] 同じマイクロ秒の中の連番。
///
/// Returns: `0001757000000000000-000000` の形式のキー。
String _sequencedKey(int microseconds, [int sequence = 0]) {
  return '${microseconds.toString().padLeft(19, '0')}-'
      '${sequence.toString().padLeft(6, '0')}';
}

/// 隔離に保存される形のデータを作る。
///
/// [url] リクエストの URL。
/// [quarantinedAt] 隔離した時刻。
/// [queuedAt] キューへ保存した時刻。省略時は隔離の 1 分前。
/// [method] HTTP メソッド。
/// [bodyLength] 本文のバイト数。
/// [statusCode] 隔離時のステータスコード。
/// [errorMessage] 隔離時のエラーメッセージ。
Map<String, Object> _quarantineData({
  required String url,
  required DateTime quarantinedAt,
  DateTime? queuedAt,
  String method = 'POST',
  int bodyLength = 16,
  int statusCode = HttpStatus.badRequest,
  String errorMessage = 'HTTP 400',
}) {
  final queued = queuedAt ?? quarantinedAt.subtract(const Duration(minutes: 1));
  return {
    'url': url,
    'method': method,
    'headers': Map<String, String>.of(_plainTextHeaders),
    'body': utf8.encode('a' * bodyLength),
    'queuedAt': queued.toIso8601String(),
    'acceptedAt': queued.toIso8601String(),
    'retryCount': 1,
    'nextRetryAt': queued.toIso8601String(),
    'quarantinedAt': quarantinedAt.toIso8601String(),
    'statusCode': statusCode,
    'reason': '4xx_error',
    'errorMessage': errorMessage,
  };
}

/// ドロップ履歴に保存される形のデータを作る。
///
/// [url] リクエストの URL。
/// [droppedAt] 履歴へ記録した時刻。
/// [acknowledged] 確認済みかどうか。
Map<String, Object> _droppedData({
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

/// キューに保存される形のデータを作る。
///
/// [url] リクエストの URL。
/// [queuedAt] キューへ保存した時刻。
/// [nextRetryAt] 次に再送する時刻。省略時は [queuedAt]（すぐに再送する）。
/// [bodyLength] 本文のバイト数。
Map<String, Object> _queueData({
  required String url,
  required DateTime queuedAt,
  DateTime? nextRetryAt,
  int bodyLength = 16,
}) {
  return {
    'url': url,
    'method': 'POST',
    'headers': Map<String, String>.of(_plainTextHeaders),
    'body': utf8.encode('a' * bodyLength),
    'queuedAt': queuedAt.toIso8601String(),
    'acceptedAt': queuedAt.toIso8601String(),
    'retryCount': 0,
    'nextRetryAt': (nextRetryAt ?? queuedAt).toIso8601String(),
  };
}

/// 仕様 4 の式（本文の長さ + ヘッダの名前と値の文字列長の合計）で大きさを求める。
///
/// テストデータの大きさが意図どおりかを、前提として確認するために使う。
///
/// [data] 隔離またはキューの形のデータ。
///
/// Returns: 仕様で定めた概算のバイト数。
int _specifiedSize(Map<String, Object> data) {
  var size = (data['body']! as List<int>).length;
  for (final header in (data['headers']! as Map<String, String>).entries) {
    size += header.key.length + header.value.length;
  }
  return size;
}

/// 一覧の URL を並びのまま取り出す。
///
/// [requests] ドロップ履歴の一覧。
///
/// Returns: URL の一覧。
List<String> _droppedUrls(List<DroppedRequest> requests) {
  return requests.map((request) => request.url).toList();
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

/// 決まったステータスコードを返す上流サーバのモック。
class _MockUpstream {
  /// [_server] で待ち受け、[statusCode] を返すモックを作る。
  _MockUpstream(this._server, this.statusCode) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        requestCount++;
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

  /// 待ち受けているサーバ。
  final HttpServer _server;

  /// 応答するステータスコード。
  final int statusCode;

  /// 受信したリクエストの件数。
  int requestCount = 0;

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流サーバを停止する。
  Future<void> close() => _server.close(force: true);
}

/// [statusCode] を返す上流サーバのモックを起動する。
Future<_MockUpstream> _startMockUpstream(int statusCode) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _MockUpstream(server, statusCode);
}

/// [check] が真を返すまで待つ。
///
/// [check] 待ち終える条件。
/// [timeout] 待つ上限。
///
/// Returns: 上限までに条件を満たした場合は `true`。
Future<bool> _waitUntil(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 20),
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

/// ドロップ履歴の一覧を繰り返し観察し、確認済みが未確認へ戻っていないかを記録する。
class _AcknowledgementTracker {
  /// 一度でも確認済みとして観察した履歴の URL。
  final Set<String> acknowledgedUrls = {};

  /// 確認済みとして観察した後に、未確認として観察した履歴の URL。
  final List<String> regressions = [];

  /// 一覧のスナップショットを 1 つ調べる。
  ///
  /// [snapshot] その時点のドロップ履歴の一覧。
  void inspect(List<DroppedRequest> snapshot) {
    for (final request in snapshot) {
      if (request.acknowledged) {
        acknowledgedUrls.add(request.url);
      } else if (acknowledgedUrls.contains(request.url)) {
        regressions.add(request.url);
      }
    }
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

  /// テスト用の差し替えを入れた proxy を作る。
  ///
  /// [storageLockTimeout] 排他を取得するまでの上限時間。
  /// [deferredMigrationDelay] 旧平文 Box の移行を遅らせる時間。
  /// [beforeLegacyBoxCleared] 旧 Box を空にする直前に呼ぶ処理。
  OfflineWebProxy createProxy({
    Duration? storageLockTimeout,
    Duration? deferredMigrationDelay,
    Future<void> Function(ProxyStorageBox kind)? beforeLegacyBoxCleared,
  }) {
    return OfflineWebProxy.withStorageTestHooks(ProxyStorageTestHooks(
      keyStorage: keyStorage,
      keyRereadInterval: Duration.zero,
      storageLockTimeout: storageLockTimeout,
      deferredMigrationDelay: deferredMigrationDelay,
      beforeLegacyBoxCleared: beforeLegacyBoxCleared,
    ));
  }

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_retention_limits')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    keyStorage = _FakeKeyStorage();
    proxy = createProxy();
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await upstream?.close();
    upstream = null;
    await Hive.close();
  });

  /// 起動前に暗号化 Box を直接書けるよう、テスト用の鍵を secure storage に置く。
  void storeEncryptionKey() {
    keyStorage.values[_keyName] = base64Encode(_encryptionKey);
  }

  /// 暗号化 Box を直接書いて閉じる。
  ///
  /// [name] Box の名前。
  /// [entries] 書き込むキーと値。
  ///
  /// Returns: 書き込んだ直後の Hive 上のキーの並び。
  Future<List<String>> writeEncryptedBox(
    String name,
    Map<String, Map<String, Object>> entries,
  ) async {
    await Hive.initFlutter();
    final box = await Hive.openBox(
      name,
      encryptionCipher: HiveAesCipher(_encryptionKey),
    );
    await box.putAll(entries);
    final keys = box.keys.map((key) => key.toString()).toList();
    await box.close();
    return keys;
  }

  /// 暗号化する前の平文 Box を直接書いて閉じる。
  ///
  /// [name] Box の名前。
  /// [entries] 書き込むキーと値。
  Future<void> writePlainBox(
    String name,
    Map<String, Map<String, Object>> entries,
  ) async {
    await Hive.initFlutter();
    final box = await Hive.openBox(name);
    await box.putAll(entries);
    await box.close();
  }

  /// [type] のイベントを発生順に集める一覧を返す。起動前に呼ぶ。
  List<ProxyEvent> collectEvents(ProxyEventType type) {
    final events = <ProxyEvent>[];
    final subscription =
        proxy.events.where((event) => event.type == type).listen(events.add);
    addTearDown(subscription.cancel);
    return events;
  }

  /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
  Future<void> withRealHttpClient(Future<void> Function() body) {
    return HttpOverrides.runZoned<Future<void>>(
      body,
      createHttpClient: _RealHttpOverrides().createHttpClient,
    );
  }

  /// キューが空になるまで待ち、時間内に空になったことを確認する。
  Future<void> waitForEmptyQueue() async {
    final emptied =
        await _waitUntil(() async => (await proxy.getQueuedRequests()).isEmpty);
    expect(emptied, isTrue, reason: 'キューが時間内に空になりませんでした');
  }

  group('保存順（仕様 1: 保存時刻の順、同じ場合はキーを時刻として読み直した値の順）', () {
    /// 19 桁のキーが Hive の辞書順で先頭に来ても、一覧と limit は保存時刻の古い順になること
    test('lists entries by saved time instead of the lexicographic key order',
        () async {
      final now = DateTime.now();
      final oldest = now.subtract(const Duration(hours: 3));
      final middle = now.subtract(const Duration(hours: 2));
      final newest = now.subtract(const Duration(hours: 1));
      final tomorrow = now.add(const Duration(days: 1));
      storeEncryptionKey();
      // 19 桁のキーを最も新しく、13 桁のキーを最も古くする
      final quarantineKeys = await writeEncryptedBox(_quarantineBoxName, {
        _key19: _quarantineData(
            url: '$_offlineOrigin/q/newest', quarantinedAt: newest),
        _key13: _quarantineData(
            url: '$_offlineOrigin/q/oldest', quarantinedAt: oldest),
        _key16: _quarantineData(
            url: '$_offlineOrigin/q/middle', quarantinedAt: middle),
      });
      final droppedKeys = await writeEncryptedBox(_droppedBoxName, {
        _key19:
            _droppedData(url: '$_offlineOrigin/d/newest', droppedAt: newest),
        _key13:
            _droppedData(url: '$_offlineOrigin/d/oldest', droppedAt: oldest),
        _key16:
            _droppedData(url: '$_offlineOrigin/d/middle', droppedAt: middle),
      });
      // キューは検証中に消化されないよう、再送の時刻を先へ延ばす
      final queueKeys = await writeEncryptedBox(_queueBoxName, {
        _key19: _queueData(
            url: '$_offlineOrigin/u/newest',
            queuedAt: newest,
            nextRetryAt: tomorrow),
        _key13: _queueData(
            url: '$_offlineOrigin/u/oldest',
            queuedAt: oldest,
            nextRetryAt: tomorrow),
        _key16: _queueData(
            url: '$_offlineOrigin/u/middle',
            queuedAt: middle,
            nextRetryAt: tomorrow),
      });

      // 前提: Hive のキーの並び（辞書順）は 19 桁 → 13 桁 → 16 桁で、保存時刻の順と異なる
      const lexicographic = [_key19, _key13, _key16];
      expect(quarantineKeys, equals(lexicographic));
      expect(droppedKeys, equals(lexicographic));
      expect(queueKeys, equals(lexicographic));

      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // 隔離の一覧は quarantinedAt の古い順に並ぶ
      expect(
        (await proxy.getQuarantinedRequests()).map((r) => r.id).toList(),
        equals([_key13, _key16, _key19]),
      );
      // limit は保存時刻の順に並べた後の先頭から数える
      expect(
        (await proxy.getQuarantinedRequests(limit: 2))
            .map((r) => r.id)
            .toList(),
        equals([_key13, _key16]),
      );
      // ドロップ履歴の一覧は droppedAt の古い順に並ぶ
      expect(
        _droppedUrls(await proxy.getDroppedRequests()),
        equals([
          '$_offlineOrigin/d/oldest',
          '$_offlineOrigin/d/middle',
          '$_offlineOrigin/d/newest',
        ]),
      );
      // ドロップ履歴の limit も並べた後の先頭から数える
      expect(
        _droppedUrls(await proxy.getDroppedRequests(limit: 1)),
        equals(['$_offlineOrigin/d/oldest']),
      );
      // キューの一覧は queuedAt の古い順に並ぶ
      expect(
        (await proxy.getQueuedRequests()).map((r) => r.url).toList(),
        equals([
          '$_offlineOrigin/u/oldest',
          '$_offlineOrigin/u/middle',
          '$_offlineOrigin/u/newest',
        ]),
      );
    });

    /// 保存時刻が同じ場合は、桁数で単位をそろえてキーを時刻として読み直した値の順に並ぶこと
    test('breaks ties by the key read as a time in a common unit', () async {
      final savedAt = DateTime.now().subtract(const Duration(hours: 1));
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      storeEncryptionKey();
      final quarantineKeys = await writeEncryptedBox(_quarantineBoxName, {
        _tieKey19: _quarantineData(
            url: '$_offlineOrigin/q/19', quarantinedAt: savedAt),
        _tieKey16: _quarantineData(
            url: '$_offlineOrigin/q/16', quarantinedAt: savedAt),
        _tieKey13: _quarantineData(
            url: '$_offlineOrigin/q/13', quarantinedAt: savedAt),
      });
      final droppedKeys = await writeEncryptedBox(_droppedBoxName, {
        _tieKey19:
            _droppedData(url: '$_offlineOrigin/d/19', droppedAt: savedAt),
        _tieKey16:
            _droppedData(url: '$_offlineOrigin/d/16', droppedAt: savedAt),
        _tieKey13:
            _droppedData(url: '$_offlineOrigin/d/13', droppedAt: savedAt),
      });
      final queueKeys = await writeEncryptedBox(_queueBoxName, {
        _tieKey19: _queueData(
            url: '$_offlineOrigin/u/19',
            queuedAt: savedAt,
            nextRetryAt: tomorrow),
        _tieKey16: _queueData(
            url: '$_offlineOrigin/u/16',
            queuedAt: savedAt,
            nextRetryAt: tomorrow),
        _tieKey13: _queueData(
            url: '$_offlineOrigin/u/13',
            queuedAt: savedAt,
            nextRetryAt: tomorrow),
      });

      // 前提: 辞書順は 19 桁 → 16 桁 → 13 桁。単位をそろえない数値の比較なら
      // 13 桁（1757000000001）が最小になり、いずれも期待する順と異なる
      const lexicographic = [_tieKey19, _tieKey16, _tieKey13];
      expect(quarantineKeys, equals(lexicographic));
      expect(droppedKeys, equals(lexicographic));
      expect(queueKeys, equals(lexicographic));

      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // マイクロ秒に直した値（…400 < …500 < …1000）の順に並ぶ
      expect(
        (await proxy.getQuarantinedRequests()).map((r) => r.id).toList(),
        equals([_tieKey16, _tieKey19, _tieKey13]),
      );
      expect(
        _droppedUrls(await proxy.getDroppedRequests()),
        equals([
          '$_offlineOrigin/d/16',
          '$_offlineOrigin/d/19',
          '$_offlineOrigin/d/13',
        ]),
      );
      expect(
        (await proxy.getQueuedRequests()).map((r) => r.url).toList(),
        equals([
          '$_offlineOrigin/u/16',
          '$_offlineOrigin/u/19',
          '$_offlineOrigin/u/13',
        ]),
      );
    });

    /// 件数の上限による「古いものから」の削除は、キーの辞書順ではなく保存時刻の順で行うこと
    test('removes the oldest by saved time when over the count limits',
        () async {
      final now = DateTime.now();
      final oldest = now.subtract(const Duration(hours: 3));
      final middle = now.subtract(const Duration(hours: 2));
      final newest = now.subtract(const Duration(hours: 1));
      storeEncryptionKey();
      final quarantineKeys = await writeEncryptedBox(_quarantineBoxName, {
        _key19: _quarantineData(
            url: '$_offlineOrigin/q/newest', quarantinedAt: newest),
        _key13: _quarantineData(
            url: '$_offlineOrigin/q/oldest', quarantinedAt: oldest),
        _key16: _quarantineData(
            url: '$_offlineOrigin/q/middle', quarantinedAt: middle),
      });
      final droppedKeys = await writeEncryptedBox(_droppedBoxName, {
        _key19: _droppedData(
            url: '$_offlineOrigin/d/newest',
            droppedAt: newest,
            acknowledged: true),
        _key13: _droppedData(
            url: '$_offlineOrigin/d/oldest',
            droppedAt: oldest,
            acknowledged: true),
        _key16: _droppedData(
            url: '$_offlineOrigin/d/middle',
            droppedAt: middle,
            acknowledged: true),
      });

      // 前提: 辞書順の先頭（19 桁）が最も新しく、隔離は上限 2 件を超えている
      expect(quarantineKeys.first, _key19);
      expect(droppedKeys.first, _key19);
      expect(quarantineKeys, hasLength(3));

      await proxy.start(
        config: const ProxyConfig(
          origin: _offlineOrigin,
          quarantineMaxCount: 2,
          droppedRequestMaxCount: 3,
        ),
      );

      // 隔離は quarantinedAt が最も古い 13 桁のキーの記録を追い出す
      expect(
        (await proxy.getQuarantinedRequests()).map((r) => r.id).toList(),
        equals([_key16, _key19]),
      );
      // 追い出しの記録で履歴が 4 件（上限 3 件）になり、droppedAt が最も古い
      // 確認済みの 1 件（13 桁のキー）を消す
      final history = await proxy.getDroppedRequests();
      expect(
        _droppedUrls(history),
        equals([
          '$_offlineOrigin/d/middle',
          '$_offlineOrigin/d/newest',
          '$_offlineOrigin/q/oldest',
        ]),
      );
      expect(history.last.dropReason, _limitReason);
    });

    /// 保存時刻が同じ記録の削除は、キーを時刻として読み直した値の小さいものから行うこと
    test('removes by the key time when saved times are equal', () async {
      final savedAt = DateTime.now().subtract(const Duration(hours: 1));
      storeEncryptionKey();
      await writeEncryptedBox(_quarantineBoxName, {
        _tieKey19: _quarantineData(
            url: '$_offlineOrigin/q/19', quarantinedAt: savedAt),
        _tieKey16: _quarantineData(
            url: '$_offlineOrigin/q/16', quarantinedAt: savedAt),
        _tieKey13: _quarantineData(
            url: '$_offlineOrigin/q/13', quarantinedAt: savedAt),
      });
      final droppedKeys = await writeEncryptedBox(_droppedBoxName, {
        _tieKey19: _droppedData(
            url: '$_offlineOrigin/d/19',
            droppedAt: savedAt,
            acknowledged: true),
        _tieKey16: _droppedData(
            url: '$_offlineOrigin/d/16',
            droppedAt: savedAt,
            acknowledged: true),
        _tieKey13: _droppedData(
            url: '$_offlineOrigin/d/13',
            droppedAt: savedAt,
            acknowledged: true),
      });

      // 前提: 辞書順の先頭は 19 桁のキーで、マイクロ秒で最小の 16 桁のキーではない
      expect(droppedKeys.first, _tieKey19);

      await proxy.start(
        config: const ProxyConfig(
          origin: _offlineOrigin,
          quarantineMaxCount: 2,
          droppedRequestMaxCount: 3,
        ),
      );

      // 隔離はマイクロ秒で最小（…400）の 16 桁のキーの記録を追い出す
      expect(
        (await proxy.getQuarantinedRequests()).map((r) => r.id).toList(),
        equals([_tieKey19, _tieKey13]),
      );
      // 履歴も、確認済みのうちマイクロ秒で最小の 16 桁のキーの記録を消す
      expect(
        _droppedUrls(await proxy.getDroppedRequests()),
        equals([
          '$_offlineOrigin/d/19',
          '$_offlineOrigin/d/13',
          '$_offlineOrigin/q/16',
        ]),
      );
    });
  });

  group('隔離の保持上限: 起動時の判定（仕様 2〜4）', () {
    /// 起動時に件数の上限を超えていれば、古いものから quarantine_limit で履歴へ移し、隔離時の statusCode と errorMessage を引き継ぐこと
    test('moves the oldest over the count limit to the history at startup',
        () async {
      final now = DateTime.now();
      final oldestAt = now.subtract(const Duration(hours: 3));
      final middleAt = now.subtract(const Duration(hours: 2));
      final newestAt = now.subtract(const Duration(hours: 1));
      final oldestKey = _sequencedKey(oldestAt.microsecondsSinceEpoch);
      final middleKey = _sequencedKey(middleAt.microsecondsSinceEpoch);
      final newestKey = _sequencedKey(newestAt.microsecondsSinceEpoch);
      storeEncryptionKey();
      final keys = await writeEncryptedBox(_quarantineBoxName, {
        oldestKey: _quarantineData(
          url: '$_offlineOrigin/api/oldest',
          quarantinedAt: oldestAt,
          method: 'PUT',
          statusCode: HttpStatus.conflict,
          errorMessage: 'HTTP 409 conflict',
        ),
        middleKey: _quarantineData(
            url: '$_offlineOrigin/api/middle', quarantinedAt: middleAt),
        newestKey: _quarantineData(
          url: '$_offlineOrigin/api/newest',
          quarantinedAt: newestAt,
          statusCode: HttpStatus.unprocessableEntity,
          errorMessage: 'HTTP 422',
        ),
      });
      final events = collectEvents(ProxyEventType.requestDropped);

      // 前提: 起動前の隔離は 3 件で、上限の 2 件を超えている
      expect(keys, hasLength(3));

      await proxy.start(
        config:
            const ProxyConfig(origin: _offlineOrigin, quarantineMaxCount: 2),
      );
      await pumpEventQueue();

      // 最も古い 1 件だけが隔離から消える
      expect(
        (await proxy.getQuarantinedRequests()).map((r) => r.id).toList(),
        equals([middleKey, newestKey]),
      );
      expect(Hive.box(_quarantineBoxName).containsKey(oldestKey), isFalse);

      final history = await proxy.getDroppedRequests();
      // 消した隔離は履歴に残り、隔離時の statusCode と errorMessage を引き継ぐ
      expect(history, hasLength(1));
      expect(history.single.url, '$_offlineOrigin/api/oldest');
      expect(history.single.method, 'PUT');
      expect(history.single.dropReason, _limitReason);
      expect(history.single.statusCode, HttpStatus.conflict);
      expect(history.single.errorMessage, 'HTTP 409 conflict');
      expect(history.single.acknowledged, isFalse);

      // requestDropped イベントに隔離の ID、理由、ステータスコードが入る
      expect(events, hasLength(1));
      expect(events.single.url, '$_offlineOrigin/api/oldest');
      expect(events.single.data['quarantineId'], oldestKey);
      expect(events.single.data['dropReason'], _limitReason);
      expect(events.single.data['statusCode'], HttpStatus.conflict);
    });

    /// 起動時に、quarantinedAt から数えて保持期間を過ぎた隔離を quarantine_expired で履歴へ移すこと（queuedAt・acceptedAt・キーの時刻は起点にしない）
    test('moves requests expired from quarantinedAt at startup', () async {
      const retention = Duration(days: 1);
      final now = DateTime.now();
      final expiredAt = now.subtract(retention + const Duration(minutes: 1));
      final keptAt = now.subtract(retention - const Duration(minutes: 1));
      final longAgo = now.subtract(const Duration(days: 365));
      // 期限切れにする記録は、キーの時刻を新しくする
      final expiredKey = _sequencedKey(now.microsecondsSinceEpoch);
      // 残す記録は、キーの時刻と queuedAt・acceptedAt を 1 年前にする
      final keptKey = _sequencedKey(longAgo.microsecondsSinceEpoch);
      storeEncryptionKey();
      await writeEncryptedBox(_quarantineBoxName, {
        expiredKey: _quarantineData(
          url: '$_offlineOrigin/api/expired',
          quarantinedAt: expiredAt,
          statusCode: HttpStatus.forbidden,
          errorMessage: 'HTTP 403 expired',
        ),
        keptKey: _quarantineData(
          url: '$_offlineOrigin/api/kept',
          quarantinedAt: keptAt,
          queuedAt: longAgo,
        ),
      });
      final events = collectEvents(ProxyEventType.requestDropped);

      await proxy.start(
        config: const ProxyConfig(
          origin: _offlineOrigin,
          quarantineRetention: retention,
        ),
      );
      await pumpEventQueue();

      // 保持期間内（quarantinedAt 基準）の記録は、queuedAt が古くても残る
      final quarantined = await proxy.getQuarantinedRequests();
      expect(quarantined.map((r) => r.id).toList(), equals([keptKey]));
      // 前提: 残した記録は queuedAt・acceptedAt が保持期間より古い
      expect(quarantined.single.queuedAt.isBefore(expiredAt), isTrue);
      expect(quarantined.single.acceptedAt.isBefore(expiredAt), isTrue);

      final history = await proxy.getDroppedRequests();
      // 期限切れの記録は quarantine_expired で、隔離時の値を引き継いで履歴に残る
      expect(history, hasLength(1));
      expect(history.single.url, '$_offlineOrigin/api/expired');
      expect(history.single.dropReason, _expiredReason);
      expect(history.single.statusCode, HttpStatus.forbidden);
      expect(history.single.errorMessage, 'HTTP 403 expired');

      // requestDropped イベントに隔離の ID、理由、ステータスコードが入る
      expect(events, hasLength(1));
      expect(events.single.data['quarantineId'], expiredKey);
      expect(events.single.data['dropReason'], _expiredReason);
      expect(events.single.data['statusCode'], HttpStatus.forbidden);
    });

    /// 合計バイト数（本文の長さ + ヘッダの名前と値の文字列長）が上限ちょうどなら追い出さないこと
    test('keeps requests whose total size equals the byte limit', () async {
      final now = DateTime.now();
      final entries = <String, Map<String, Object>>{
        for (var i = 0; i < 3; i++)
          _sequencedKey(now.microsecondsSinceEpoch - 3000000 + i):
              _quarantineData(
            url: '$_offlineOrigin/api/$i',
            quarantinedAt: now.subtract(Duration(minutes: 3 - i)),
            bodyLength: 100,
          ),
      };
      // 前提: 1 件は本文 100 + ヘッダ 22 = 122 バイトで、3 件の合計は 366 バイト
      for (final data in entries.values) {
        expect(_specifiedSize(data), 122);
      }
      storeEncryptionKey();
      await writeEncryptedBox(_quarantineBoxName, entries);

      await proxy.start(
        config:
            const ProxyConfig(origin: _offlineOrigin, quarantineMaxBytes: 366),
      );

      // 上限を超えていないため、何も追い出さない（URL などは大きさに数えない）
      expect(await proxy.getQuarantinedRequests(), hasLength(3));
      expect(await proxy.getDroppedRequests(), isEmpty);
    });

    /// 合計バイト数が上限を 1 バイトでも超えれば、古いものから quarantine_limit で履歴へ移すこと（ヘッダも大きさに数える）
    test('moves the oldest out when the total size exceeds the byte limit',
        () async {
      final now = DateTime.now();
      final keys = [
        for (var i = 0; i < 3; i++)
          _sequencedKey(now.microsecondsSinceEpoch - 3000000 + i),
      ];
      final entries = <String, Map<String, Object>>{
        for (var i = 0; i < 3; i++)
          keys[i]: _quarantineData(
            url: '$_offlineOrigin/api/$i',
            quarantinedAt: now.subtract(Duration(minutes: 3 - i)),
            bodyLength: 100,
          ),
      };
      // 前提: 合計 366 バイトで上限 365 バイトを 1 バイト超える。
      // ヘッダを数えない場合は 300 バイトで、上限を超えない
      final total = entries.values.fold<int>(
        0,
        (sum, data) => sum + _specifiedSize(data),
      );
      expect(total, 366);
      storeEncryptionKey();
      await writeEncryptedBox(_quarantineBoxName, entries);

      await proxy.start(
        config:
            const ProxyConfig(origin: _offlineOrigin, quarantineMaxBytes: 365),
      );

      // 最も古い 1 件を追い出せば 244 バイトで上限以下になるため、1 件だけ移す
      expect(
        (await proxy.getQuarantinedRequests()).map((r) => r.id).toList(),
        equals([keys[1], keys[2]]),
      );
      final history = await proxy.getDroppedRequests();
      expect(history, hasLength(1));
      expect(history.single.url, '$_offlineOrigin/api/0');
      expect(history.single.dropReason, _limitReason);
    });
  });

  group('隔離の保持上限: 大量の追い出し', () {
    /// 3000 件の隔離を件数の上限 10 件で起動し、2990 件を追い出す起動の所要時間を記録すること。
    /// 所要時間は実行環境で変わるため合否に使わず、件数の結果だけを確認する
    test('records the time to evict thousands of quarantined requests',
        () async {
      const total = 3000;
      const maxCount = 10;
      final base = DateTime.now().subtract(const Duration(hours: 1));
      storeEncryptionKey();
      await writeEncryptedBox(_quarantineBoxName, {
        for (var i = 0; i < total; i++)
          _sequencedKey(base.microsecondsSinceEpoch + i): _quarantineData(
            url: '$_offlineOrigin/q/$i',
            quarantinedAt: base.add(Duration(milliseconds: i)),
          ),
      });
      final events = collectEvents(ProxyEventType.requestDropped);

      final stopwatch = Stopwatch()..start();
      await proxy.start(
        config: const ProxyConfig(
          origin: _offlineOrigin,
          quarantineMaxCount: maxCount,
        ),
      );
      stopwatch.stop();
      // ignore: avoid_print
      print('隔離 $total 件を件数の上限 $maxCount 件で起動した所要時間: '
          '${stopwatch.elapsedMilliseconds} ms');
      await pumpEventQueue();

      // 隔離した時刻の新しい 10 件だけが残る
      final remaining = await proxy.getQuarantinedRequests();
      expect(
        remaining.map((request) => request.url).toList(),
        [for (var i = total - maxCount; i < total; i++) '$_offlineOrigin/q/$i'],
      );
      // 追い出した 2990 件は、未確認のため件数の上限（既定 1000 件）では消えずに履歴に残る
      final history = await proxy.getDroppedRequests();
      expect(history, hasLength(total - maxCount));
      expect(
        history.map((request) => request.dropReason).toSet(),
        {_limitReason},
      );
      // 追い出した件数だけ requestDropped を通知する
      expect(
        events.where((event) => event.data['dropReason'] == _limitReason),
        hasLength(total - maxCount),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('隔離の保持上限: 隔離を追加したときの判定（仕様 2・4・5）', () {
    /// 隔離を追加して件数の上限を超えれば、既存の最も古いものを履歴へ移し、追加した隔離は残すこと（履歴への記録時にも履歴の件数上限を判定すること）
    test('moves the oldest out when a new quarantine exceeds the count limit',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream(HttpStatus.badRequest);
        final origin = upstream!.origin;
        final now = DateTime.now();
        final oldestAt = now.subtract(const Duration(hours: 2));
        final newerAt = now.subtract(const Duration(hours: 1));
        final oldestKey = _sequencedKey(oldestAt.microsecondsSinceEpoch);
        final newerKey = _sequencedKey(newerAt.microsecondsSinceEpoch);
        final queuedAt = now.subtract(const Duration(minutes: 1));
        storeEncryptionKey();
        await writeEncryptedBox(_quarantineBoxName, {
          oldestKey: _quarantineData(
            url: '$origin/api/old',
            quarantinedAt: oldestAt,
            method: 'PUT',
            statusCode: HttpStatus.conflict,
            errorMessage: 'HTTP 409 old conflict',
          ),
          newerKey:
              _quarantineData(url: '$origin/api/newer', quarantinedAt: newerAt),
        });
        await writeEncryptedBox(_droppedBoxName, {
          _sequencedKey(now.microsecondsSinceEpoch - 4000000): _droppedData(
            url: '$origin/history/old',
            droppedAt: now.subtract(const Duration(hours: 4)),
            acknowledged: true,
          ),
          _sequencedKey(now.microsecondsSinceEpoch - 3000000): _droppedData(
            url: '$origin/history/new',
            droppedAt: now.subtract(const Duration(hours: 3)),
            acknowledged: true,
          ),
        });
        await writeEncryptedBox(_queueBoxName, {
          _sequencedKey(queuedAt.microsecondsSinceEpoch):
              _queueData(url: '$origin/api/new', queuedAt: queuedAt),
        });
        final droppedEvents = collectEvents(ProxyEventType.requestDropped);
        final quarantinedEvents =
            collectEvents(ProxyEventType.requestQuarantined);

        await proxy.start(
          config: ProxyConfig(
            origin: origin,
            quarantineMaxCount: 2,
            droppedRequestMaxCount: 2,
          ),
        );

        // 前提: 起動時点では隔離も履歴も上限ちょうどで、追い出しは起きていない
        expect(
          (await proxy.getQuarantinedRequests()).map((r) => r.id).toList(),
          equals([oldestKey, newerKey]),
        );
        expect(await proxy.getDroppedRequests(), hasLength(2));
        expect(await proxy.getQueuedRequests(), hasLength(1));
        expect(droppedEvents, isEmpty);

        // 上流が 4xx を返し、キューの項目が隔離に加わるのを待つ
        await waitForEmptyQueue();
        await pumpEventQueue();

        final quarantined = await proxy.getQuarantinedRequests();
        // 追加した隔離は残り、既存の最も古いものだけが隔離から消える
        expect(
          quarantined.map((r) => r.url).toList(),
          equals(['$origin/api/newer', '$origin/api/new']),
        );
        expect(quarantined.last.statusCode, HttpStatus.badRequest);
        expect(Hive.box(_quarantineBoxName).containsKey(oldestKey), isFalse);

        final history = await proxy.getDroppedRequests();
        // 追い出した隔離は quarantine_limit で、隔離時の値を引き継いで履歴に残る
        final evicted = history.singleWhere((r) => r.url == '$origin/api/old');
        expect(evicted.dropReason, _limitReason);
        expect(evicted.method, 'PUT');
        expect(evicted.statusCode, HttpStatus.conflict);
        expect(evicted.errorMessage, 'HTTP 409 old conflict');
        expect(evicted.acknowledged, isFalse);
        // 記録で履歴が 3 件（上限 2 件）になり、確認済みで最も古い履歴を消す
        expect(
          _droppedUrls(history),
          equals(['$origin/history/new', '$origin/api/old']),
        );

        // requestDropped イベントに隔離の ID、理由、隔離時のステータスコードが入る
        expect(droppedEvents, hasLength(1));
        expect(droppedEvents.single.url, '$origin/api/old');
        expect(droppedEvents.single.data['quarantineId'], oldestKey);
        expect(droppedEvents.single.data['dropReason'], _limitReason);
        expect(droppedEvents.single.data['statusCode'], HttpStatus.conflict);
        // 追加した隔離の ID は、残っている隔離のもの
        expect(quarantinedEvents, hasLength(1));
        expect(
          quarantinedEvents.single.data['quarantineId'],
          quarantined.last.id,
        );
      });
    }, timeout: const Timeout(Duration(minutes: 1)));

    /// 追加する隔離が上限ちょうどの大きさなら隔離に入れ、合計が上限以下になるまで既存の古いものから履歴へ移すこと
    test('keeps a new quarantine exactly at the byte limit', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream(HttpStatus.badRequest);
        final origin = upstream!.origin;
        final now = DateTime.now();
        final oldestKey = _sequencedKey(now.microsecondsSinceEpoch - 2000000);
        final newerKey = _sequencedKey(now.microsecondsSinceEpoch - 1000000);
        final oldest = _quarantineData(
          url: '$origin/api/old',
          quarantinedAt: now.subtract(const Duration(hours: 2)),
          bodyLength: 100,
        );
        final newer = _quarantineData(
          url: '$origin/api/newer',
          quarantinedAt: now.subtract(const Duration(hours: 1)),
          bodyLength: 100,
        );
        final queuedAt = now.subtract(const Duration(minutes: 1));
        final incoming = _queueData(
          url: '$origin/api/new',
          queuedAt: queuedAt,
          bodyLength: 378,
        );
        // 前提: 既存は 122 バイトずつ（合計 244）、追加する 1 件は上限と同じ 400 バイト
        expect(_specifiedSize(oldest), 122);
        expect(_specifiedSize(newer), 122);
        expect(_specifiedSize(incoming), 400);
        storeEncryptionKey();
        await writeEncryptedBox(
            _quarantineBoxName, {oldestKey: oldest, newerKey: newer});
        await writeEncryptedBox(_queueBoxName, {
          _sequencedKey(queuedAt.microsecondsSinceEpoch): incoming,
        });
        final droppedEvents = collectEvents(ProxyEventType.requestDropped);

        await proxy.start(
          config: ProxyConfig(origin: origin, quarantineMaxBytes: 400),
        );

        // 前提: 起動時点では合計 244 バイトで、追い出しは起きていない
        expect(await proxy.getQuarantinedRequests(), hasLength(2));
        expect(droppedEvents, isEmpty);

        await waitForEmptyQueue();
        await pumpEventQueue();

        // 上限ちょうどの 1 件は大きすぎる扱いにせず、隔離に入れる
        final quarantined = await proxy.getQuarantinedRequests();
        expect(
          quarantined.map((r) => r.url).toList(),
          equals(['$origin/api/new']),
        );
        // 合計 644 → 522 → 400 バイトになるまで、既存を古い順に履歴へ移す
        final history = await proxy.getDroppedRequests();
        expect(
          _droppedUrls(history),
          equals(['$origin/api/old', '$origin/api/newer']),
        );
        expect(
          history.map((r) => r.dropReason).toSet(),
          equals({_limitReason}),
        );
        expect(
          droppedEvents.map((e) => e.data['quarantineId']).toList(),
          equals([oldestKey, newerKey]),
        );
      });
    }, timeout: const Timeout(Duration(minutes: 1)));

    /// 1 件で合計バイト数の上限を超える場合は、既存を追い出さず隔離にも入れず、quarantine_too_large で履歴へ記録してキューから取り除くこと
    test('records a request larger than the byte limit without quarantining',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream(HttpStatus.badRequest);
        final origin = upstream!.origin;
        final now = DateTime.now();
        final oldestKey = _sequencedKey(now.microsecondsSinceEpoch - 2000000);
        final newerKey = _sequencedKey(now.microsecondsSinceEpoch - 1000000);
        final queuedAt = now.subtract(const Duration(minutes: 1));
        final incoming = _queueData(
          url: '$origin/api/too-large',
          queuedAt: queuedAt,
          bodyLength: 379,
        );
        // 前提: 追加する 1 件は 401 バイトで、それだけで上限 400 バイトを超える
        expect(_specifiedSize(incoming), 401);
        storeEncryptionKey();
        await writeEncryptedBox(_quarantineBoxName, {
          oldestKey: _quarantineData(
            url: '$origin/api/old',
            quarantinedAt: now.subtract(const Duration(hours: 2)),
            bodyLength: 100,
          ),
          newerKey: _quarantineData(
            url: '$origin/api/newer',
            quarantinedAt: now.subtract(const Duration(hours: 1)),
            bodyLength: 100,
          ),
        });
        await writeEncryptedBox(_queueBoxName, {
          _sequencedKey(queuedAt.microsecondsSinceEpoch): incoming,
        });
        final droppedEvents = collectEvents(ProxyEventType.requestDropped);
        final quarantinedEvents =
            collectEvents(ProxyEventType.requestQuarantined);

        await proxy.start(
          config: ProxyConfig(origin: origin, quarantineMaxBytes: 400),
        );

        // キューから取り除かれるのを待つ
        await waitForEmptyQueue();
        await pumpEventQueue();

        // 前提: 上流へ送り、4xx で拒否されている
        expect(upstream!.requestCount, greaterThanOrEqualTo(1));

        // 既存の隔離は追い出さず、大きすぎる 1 件も隔離に入れない
        expect(
          (await proxy.getQuarantinedRequests()).map((r) => r.id).toList(),
          equals([oldestKey, newerKey]),
        );
        expect(quarantinedEvents, isEmpty);

        // 履歴へ quarantine_too_large と上流の 4xx で記録する
        final history = await proxy.getDroppedRequests();
        expect(history, hasLength(1));
        expect(history.single.url, '$origin/api/too-large');
        expect(history.single.dropReason, _tooLargeReason);
        expect(history.single.statusCode, HttpStatus.badRequest);

        // requestDropped イベントの理由も quarantine_too_large
        expect(droppedEvents, hasLength(1));
        expect(droppedEvents.single.data['dropReason'], _tooLargeReason);
        expect(
          droppedEvents.single.data['statusCode'],
          HttpStatus.badRequest,
        );
      });
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  group('ドロップ履歴の保持上限（仕様 3・6）', () {
    /// droppedAt から数えて保持期間を過ぎた履歴は、確認済みかどうかを問わず削除すること（キーの時刻は起点にしない）
    test('removes history expired from droppedAt at startup', () async {
      const retention = Duration(days: 1);
      final now = DateTime.now();
      final longAgo = now.subtract(const Duration(days: 365));
      storeEncryptionKey();
      final keys = await writeEncryptedBox(_droppedBoxName, {
        // 期限切れの記録は、キーの時刻を新しくする
        _sequencedKey(now.microsecondsSinceEpoch): _droppedData(
          url: '$_offlineOrigin/expired/unacknowledged',
          droppedAt: now.subtract(retention + const Duration(minutes: 1)),
        ),
        _sequencedKey(now.microsecondsSinceEpoch, 1): _droppedData(
          url: '$_offlineOrigin/expired/acknowledged',
          droppedAt: now.subtract(retention + const Duration(minutes: 2)),
          acknowledged: true,
        ),
        // 残す記録は、キーの時刻を 1 年前にする
        _sequencedKey(longAgo.microsecondsSinceEpoch): _droppedData(
          url: '$_offlineOrigin/kept',
          droppedAt: now.subtract(retention - const Duration(minutes: 1)),
        ),
      });

      // 前提: 起動前の履歴は 3 件
      expect(keys, hasLength(3));

      await proxy.start(
        config: const ProxyConfig(
          origin: _offlineOrigin,
          droppedRequestRetention: retention,
        ),
      );

      // 期限切れは未確認・確認済みとも消え、保持期間内の履歴だけが残る
      expect(
        _droppedUrls(await proxy.getDroppedRequests()),
        equals(['$_offlineOrigin/kept']),
      );
    });

    /// 件数の上限を超えたら確認済みの古いものから削除し、それより古い未確認は残すこと
    test('removes the oldest acknowledged history over the count limit',
        () async {
      final now = DateTime.now();
      storeEncryptionKey();
      final keys = await writeEncryptedBox(_droppedBoxName, {
        for (final (index, url, acknowledged) in [
          (4, 'acknowledged-1', true),
          (3, 'unacknowledged-1', false),
          (2, 'acknowledged-2', true),
          (1, 'acknowledged-3', true),
        ])
          _sequencedKey(now.microsecondsSinceEpoch - index * 1000000):
              _droppedData(
            url: '$_offlineOrigin/$url',
            droppedAt: now.subtract(Duration(hours: index)),
            acknowledged: acknowledged,
          ),
      });

      // 前提: 起動前の履歴は 4 件で、上限の 2 件を超えている
      expect(keys, hasLength(4));

      await proxy.start(
        config: const ProxyConfig(
            origin: _offlineOrigin, droppedRequestMaxCount: 2),
      );

      // 超過 2 件分を、確認済みの古いもの（1 と 2）から消す。
      // 確認済みより古い未確認は残し、最も新しい確認済みも残す
      expect(
        _droppedUrls(await proxy.getDroppedRequests()),
        equals([
          '$_offlineOrigin/unacknowledged-1',
          '$_offlineOrigin/acknowledged-3',
        ]),
      );
    });

    /// 未確認の履歴は、件数の上限を超えたままでも件数では削除しないこと
    test('never removes unacknowledged history by the count limit', () async {
      final now = DateTime.now();
      storeEncryptionKey();
      await writeEncryptedBox(_droppedBoxName, {
        for (final (index, url, acknowledged) in [
          (4, 'unacknowledged-1', false),
          (3, 'unacknowledged-2', false),
          (2, 'acknowledged-1', true),
          (1, 'unacknowledged-3', false),
        ])
          _sequencedKey(now.microsecondsSinceEpoch - index * 1000000):
              _droppedData(
            url: '$_offlineOrigin/$url',
            droppedAt: now.subtract(Duration(hours: index)),
            acknowledged: acknowledged,
          ),
      });

      await proxy.start(
        config: const ProxyConfig(
            origin: _offlineOrigin, droppedRequestMaxCount: 1),
      );

      // 確認済みの 1 件だけを消し、上限 1 件を超えたままでも未確認の 3 件は残す
      final history = await proxy.getDroppedRequests();
      expect(
        _droppedUrls(history),
        equals([
          '$_offlineOrigin/unacknowledged-1',
          '$_offlineOrigin/unacknowledged-2',
          '$_offlineOrigin/unacknowledged-3',
        ]),
      );
      expect(history.every((r) => !r.acknowledged), isTrue);
    });
  });

  group('停止後の件数', () {
    /// 未確認の履歴を数えた後に stop() すると、getStats() は前回の未確認件数を返さず、
    /// キュー・隔離・履歴の件数とともに 0 を返すこと
    test('returns zero unacknowledged dropped requests after stop()', () async {
      final now = DateTime.now();
      storeEncryptionKey();
      await writeEncryptedBox(_droppedBoxName, {
        _sequencedKey(now.microsecondsSinceEpoch): _droppedData(
          url: '$_offlineOrigin/d/1',
          droppedAt: now.subtract(const Duration(minutes: 2)),
        ),
        _sequencedKey(now.microsecondsSinceEpoch + 1): _droppedData(
          url: '$_offlineOrigin/d/2',
          droppedAt: now.subtract(const Duration(minutes: 1)),
        ),
      });
      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));
      // 前提: 稼働中に未確認の 2 件を数えたこと
      expect((await proxy.getStats()).unacknowledgedDroppedCount, 2);

      await proxy.stop();
      final stats = await proxy.getStats();

      // 停止後は前回の未確認件数を返さず 0 であること
      expect(stats.unacknowledgedDroppedCount, 0);
      // キュー・隔離・履歴の件数も 0 であること
      expect(stats.droppedRequestsCount, 0);
      expect(stats.queueLength, 0);
      expect(stats.quarantinedCount, 0);
    });
  });

  group('設定値の検証（仕様 8）', () {
    final negativeConfigs = <String, ProxyConfig>{
      'quarantineMaxCount': const ProxyConfig(
        origin: _offlineOrigin,
        quarantineMaxCount: -1,
      ),
      'quarantineRetention': const ProxyConfig(
        origin: _offlineOrigin,
        quarantineRetention: Duration(microseconds: -1),
      ),
      'quarantineMaxBytes': const ProxyConfig(
        origin: _offlineOrigin,
        quarantineMaxBytes: -1,
      ),
      'droppedRequestMaxCount': const ProxyConfig(
        origin: _offlineOrigin,
        droppedRequestMaxCount: -1,
      ),
      'droppedRequestRetention': const ProxyConfig(
        origin: _offlineOrigin,
        droppedRequestRetention: Duration(microseconds: -1),
      ),
    };

    for (final entry in negativeConfigs.entries) {
      /// 負の値（-1 や -1 マイクロ秒）を指定すると、start() が ProxyStartException を送出して起動しないこと
      test('rejects a negative ${entry.key}', () async {
        await expectLater(
          proxy.start(config: entry.value),
          throwsA(isA<ProxyStartException>()),
        );
        // 起動していない
        expect(proxy.isRunning, isFalse);
      });
    }

    /// 0 は上限なしとして受け付け、既定の上限（1000 件・30 日）を超える記録も削除しないこと
    test('accepts zero as no limit', () async {
      const count = 1001;
      final ancient = DateTime.now().subtract(const Duration(days: 100));
      storeEncryptionKey();
      await writeEncryptedBox(_quarantineBoxName, {
        for (var i = 0; i < count; i++)
          _sequencedKey(ancient.microsecondsSinceEpoch + i): _quarantineData(
            url: '$_offlineOrigin/q/$i',
            quarantinedAt: ancient.add(Duration(seconds: i)),
          ),
      });
      await writeEncryptedBox(_droppedBoxName, {
        for (var i = 0; i < count; i++)
          _sequencedKey(ancient.microsecondsSinceEpoch + i): _droppedData(
            url: '$_offlineOrigin/d/$i',
            droppedAt: ancient.add(Duration(seconds: i)),
            acknowledged: true,
          ),
      });
      final events = collectEvents(ProxyEventType.requestDropped);

      await proxy.start(
        config: const ProxyConfig(
          origin: _offlineOrigin,
          quarantineMaxCount: 0,
          quarantineRetention: Duration.zero,
          quarantineMaxBytes: 0,
          droppedRequestMaxCount: 0,
          droppedRequestRetention: Duration.zero,
        ),
      );
      await pumpEventQueue();

      // 0 を受け付けて起動する
      expect(proxy.isRunning, isTrue);
      // 件数・期間・合計バイト数のどれでも隔離を追い出さない
      expect(await proxy.getQuarantinedRequests(), hasLength(count));
      expect(events, isEmpty);
      // 件数・期間のどちらでも確認済みの履歴を消さない
      expect(await proxy.getDroppedRequests(), hasLength(count));
    });
  });

  group('ロックを上限時間内に取得できない場合（仕様 9）', () {
    /// 遅らせた移行が隔離のロックを保持している間、隔離を変更する API は QueueOperationException を送出し、隔離を変えないこと
    test('quarantine APIs throw while the quarantine lock is held', () async {
      const legacyKey = '0001757000000000000-000000';
      // 鍵をこのインスタンスで生成させるため、secure storage は空のままにする
      await writePlainBox(_legacyQuarantineBoxName, {
        legacyKey: _quarantineData(
          url: '$_offlineOrigin/api/legacy',
          quarantinedAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      });
      final hookEntered = Completer<void>();
      final release = Completer<void>();
      proxy = createProxy(
        storageLockTimeout: const Duration(milliseconds: 300),
        deferredMigrationDelay: Duration.zero,
        beforeLegacyBoxCleared: (kind) async {
          if (kind != ProxyStorageBox.quarantine) {
            return;
          }
          if (!hookEntered.isCompleted) {
            hookEntered.complete();
          }
          await release.future;
        },
      );
      addTearDown(() {
        if (!release.isCompleted) {
          release.complete();
        }
      });

      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // 前提: 鍵をこのインスタンスで生成し、移行が隔離のロックを保持したまま止まっている
      expect(keyStorage.values[_keyName], isNotNull);
      await hookEntered.future.timeout(const Duration(seconds: 15));
      final pending = await proxy.getQuarantinedRequests();
      expect(pending.single.id, legacyKey);
      expect(pending.single.pendingMigration, isTrue);

      final lockTimeout = throwsA(
        isA<QueueOperationException>()
            .having((e) => e.cause, 'cause', isA<TimeoutException>()),
      );
      // 再送・破棄・全破棄はいずれもロックの待ち時間の上限で失敗する
      await expectLater(proxy.retryQuarantinedRequest(legacyKey), lockTimeout);
      await expectLater(
          proxy.discardQuarantinedRequest(legacyKey), lockTimeout);
      await expectLater(proxy.clearQuarantinedRequests(), lockTimeout);

      release.complete();
      final migrated = await _waitUntil(() async {
        final requests = await proxy.getQuarantinedRequests();
        return requests.length == 1 && !requests.single.pendingMigration;
      });
      expect(migrated, isTrue, reason: '移行が時間内に終わりませんでした');

      // 失敗した API は、隔離を消しておらず、キューへも戻していない
      expect(
        (await proxy.getQuarantinedRequests()).map((r) => r.id).toList(),
        equals([legacyKey]),
      );
      expect(await proxy.getQueuedRequests(), isEmpty);
      // ロックが空けば同じ操作は成功する（失敗の原因がロックだったことの確認）
      expect(await proxy.discardQuarantinedRequest(legacyKey), isTrue);
    });

    /// 遅らせた移行が履歴のロックを保持している間、履歴を変更する API は QueueOperationException を送出し、履歴を変えないこと
    test('dropped request APIs throw while the history lock is held', () async {
      // 鍵をこのインスタンスで生成させるため、secure storage は空のままにする
      await writePlainBox(_legacyDroppedBoxName, {
        '0001757000000000000-000000': _droppedData(
          url: '$_offlineOrigin/api/legacy',
          droppedAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      });
      final hookEntered = Completer<void>();
      final release = Completer<void>();
      proxy = createProxy(
        storageLockTimeout: const Duration(milliseconds: 300),
        deferredMigrationDelay: Duration.zero,
        beforeLegacyBoxCleared: (kind) async {
          if (kind != ProxyStorageBox.droppedRequests) {
            return;
          }
          if (!hookEntered.isCompleted) {
            hookEntered.complete();
          }
          await release.future;
        },
      );
      addTearDown(() {
        if (!release.isCompleted) {
          release.complete();
        }
      });

      await proxy.start(config: const ProxyConfig(origin: _offlineOrigin));

      // 前提: 移行が履歴のロックを保持したまま止まっている
      expect(keyStorage.values[_keyName], isNotNull);
      await hookEntered.future.timeout(const Duration(seconds: 15));
      final pending = await proxy.getDroppedRequests();
      expect(pending.single.pendingMigration, isTrue);
      expect(pending.single.acknowledged, isFalse);

      final lockTimeout = throwsA(
        isA<QueueOperationException>()
            .having((e) => e.cause, 'cause', isA<TimeoutException>()),
      );
      // 確認済みへの変更と全削除は、ロックの待ち時間の上限で失敗する
      await expectLater(proxy.acknowledgeDroppedRequests(), lockTimeout);
      await expectLater(proxy.clearDroppedRequests(), lockTimeout);

      release.complete();
      final migrated = await _waitUntil(() async {
        final requests = await proxy.getDroppedRequests();
        return requests.length == 1 && !requests.single.pendingMigration;
      });
      expect(migrated, isTrue, reason: '移行が時間内に終わりませんでした');

      // 失敗した API は、履歴を消しておらず、確認済みにもしていない
      final history = await proxy.getDroppedRequests();
      expect(history, hasLength(1));
      expect(history.single.acknowledged, isFalse);
      // ロックが空けば同じ操作は成功する（失敗の原因がロックだったことの確認）
      expect(await proxy.acknowledgeDroppedRequests(), 1);
    });
  });

  group('記録・削除と acknowledge の同時実行（仕様 10）', () {
    /// 起動時の追い出し（履歴への記録と件数上限による削除）と acknowledge を同時に実行しても、確認済みが失われず、未確認が件数で消えず、止まらないこと
    test('keeps acknowledgements while startup eviction runs', () async {
      const total = 60;
      const maxCount = 5;
      final base = DateTime.now().subtract(const Duration(hours: 1));
      storeEncryptionKey();
      await writeEncryptedBox(_quarantineBoxName, {
        for (var i = 0; i < total; i++)
          _sequencedKey(base.microsecondsSinceEpoch + i): _quarantineData(
            url: '$_offlineOrigin/q/$i',
            quarantinedAt: base.add(Duration(seconds: i)),
          ),
      });
      proxy = createProxy(storageLockTimeout: const Duration(seconds: 10));
      final events = collectEvents(ProxyEventType.requestDropped);
      final tracker = _AcknowledgementTracker();

      var started = false;
      final startFuture = proxy.start(
        config: const ProxyConfig(
          origin: _offlineOrigin,
          quarantineMaxCount: maxCount,
          droppedRequestMaxCount: 4,
        ),
      );
      unawaited(startFuture.then(
        (_) => started = true,
        onError: (Object _) => started = true,
      ));

      // 起動が終わるまで、確認済みへの変更と一覧の取得を繰り返す
      var acknowledgedTotal = 0;
      while (!started) {
        acknowledgedTotal += await proxy.acknowledgeDroppedRequests();
        tracker.inspect(await proxy.getDroppedRequests());
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await startFuture.timeout(const Duration(seconds: 30));
      await pumpEventQueue();

      final evicted =
          events.where((e) => e.data['dropReason'] == _limitReason).length;
      final history = await proxy.getDroppedRequests();
      tracker.inspect(history);
      final unacknowledged = history.where((r) => !r.acknowledged).length;

      // 前提: 上限を超えた 55 件がすべて履歴へ移っている
      expect(evicted, total - maxCount);
      expect(await proxy.getQuarantinedRequests(), hasLength(maxCount));
      // 前提: 追い出しの途中で acknowledge が効き、件数上限による削除も起きている
      expect(acknowledgedTotal, greaterThan(0));
      expect(evicted - history.length, greaterThan(0));

      // 確認済みにした履歴が、未確認へ戻っていない
      expect(tracker.regressions, isEmpty);
      // 未確認の件数は「記録した件数 - 確認済みにした件数」と一致する
      // （未確認が件数で消えていない、確認済みが失われていない）
      expect(unacknowledged, evicted - acknowledgedTotal);
      // ロックが解放されており、処理が止まっていない
      expect(
        await proxy
            .acknowledgeDroppedRequests()
            .timeout(const Duration(seconds: 5)),
        unacknowledged,
      );
    });

    /// キュー消化で隔離・履歴へ記録している最中に acknowledge を繰り返しても、確認済みが失われず、未確認が件数で消えず、止まらないこと
    test('keeps acknowledgements while quarantining from the queue', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream(HttpStatus.badRequest);
        final origin = upstream!.origin;
        const itemCount = 12;
        final base = DateTime.now().subtract(const Duration(minutes: 30));
        storeEncryptionKey();
        await writeEncryptedBox(_queueBoxName, {
          for (var i = 0; i < itemCount; i++)
            _sequencedKey(base.microsecondsSinceEpoch + i): _queueData(
              url: '$origin/api/sales/$i',
              queuedAt: base.add(Duration(seconds: i)),
            ),
        });
        proxy = createProxy(storageLockTimeout: const Duration(seconds: 10));
        final events = collectEvents(ProxyEventType.requestDropped);
        final tracker = _AcknowledgementTracker();

        await proxy.start(
          config: ProxyConfig(
            origin: origin,
            quarantineMaxCount: 1,
            droppedRequestMaxCount: 3,
          ),
        );
        // 前提: 起動時点ではすべてキューに残っている
        expect(await proxy.getQueuedRequests(), hasLength(itemCount));

        // キューが空になるまで、確認済みへの変更と一覧の取得を繰り返す
        var acknowledgedTotal = 0;
        var drained = false;
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (DateTime.now().isBefore(deadline)) {
          if ((await proxy.getQueuedRequests()).isEmpty) {
            drained = true;
            break;
          }
          acknowledgedTotal += await proxy.acknowledgeDroppedRequests();
          tracker.inspect(await proxy.getDroppedRequests());
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        await pumpEventQueue();

        // 止まらずにキューを消化し終える
        expect(drained, isTrue, reason: 'キューが時間内に空になりませんでした');

        final evicted =
            events.where((e) => e.data['dropReason'] == _limitReason).length;
        final history = await proxy.getDroppedRequests();
        tracker.inspect(history);
        final unacknowledged = history.where((r) => !r.acknowledged).length;

        // 前提: 隔離の上限 1 件により、最後の 1 件以外が履歴へ移っている
        expect(evicted, itemCount - 1);
        expect(
          (await proxy.getQuarantinedRequests()).map((r) => r.url).toList(),
          equals(['$origin/api/sales/${itemCount - 1}']),
        );
        // 前提: 記録の途中で acknowledge が効き、件数上限による削除も起きている
        expect(acknowledgedTotal, greaterThan(0));
        expect(evicted - history.length, greaterThan(0));

        // 確認済みにした履歴が、未確認へ戻っていない
        expect(tracker.regressions, isEmpty);
        // 未確認の件数は「記録した件数 - 確認済みにした件数」と一致する
        expect(unacknowledged, evicted - acknowledgedTotal);
        // ロックが解放されており、処理が止まっていない
        expect(
          await proxy
              .acknowledgeDroppedRequests()
              .timeout(const Duration(seconds: 5)),
          unacknowledged,
        );
      });
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}

/// flutter_test の既定 HttpClient はモックのため、実通信用に dart:io の実装を使う。
///
/// [HttpOverrides] の既定の実装は dart:io の HttpClient を作るため、何も上書きしない。
class _RealHttpOverrides extends HttpOverrides {}
