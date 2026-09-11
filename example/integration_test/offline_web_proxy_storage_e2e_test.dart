import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

/// 暗号化鍵を保存する secure storage 上の名前。proxy の内部と同じ値にする。
const String _encryptionKeyName = 'offline_web_proxy.cookie_box_encryption_key';

/// キューの暗号化 Box の名前。
const String _encryptedQueueBoxName = 'proxy_queue_secure';

/// キューの旧平文 Box（0.14.0 以前）の名前。
const String _legacyQueueBoxName = 'proxy_queue';

/// テストの前に削除する Box。鍵を消すため、暗号化 Box も合わせて消す。
const List<String> _boxesToReset = [
  'proxy_cookies_secure',
  'proxy_cookies',
  _encryptedQueueBoxName,
  _legacyQueueBoxName,
  'proxy_quarantined_requests_secure',
  'proxy_quarantined_requests',
  'proxy_dropped_requests_secure',
  'proxy_dropped_requests',
];

/// 鍵を生成した起動で、旧平文 Box の移行を遅らせる時間（proxy の既定値）。
const Duration _deferredMigrationDelay = Duration(seconds: 30);

/// 上流へ届くまで待つ時間の上限。上流の再開を proxy が検知するまでの時間を含む。
const Duration _deliveryTimeout = Duration(seconds: 120);

/// キューから消えるまで待つ時間の上限。
const Duration _dequeueTimeout = Duration(seconds: 30);

/// 更新系の要求の本文をパスごとに記録し、同じポートで停止と再起動ができる上流サーバ。
class _RecordingUpstream {
  _RecordingUpstream._(this.port);

  /// 待ち受けるポート番号。再起動しても変わらない。
  final int port;

  /// 稼働中のサーバ。停止中は `null`。
  HttpServer? _server;

  /// 受信した更新系の要求の本文。キーは要求のパス。
  final Map<String, List<String>> _bodies = {};

  /// 空きポートで上流サーバを起動する。
  ///
  /// Returns: 起動した上流サーバ。
  static Future<_RecordingUpstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _RecordingUpstream._(server.port);
    upstream._listen(server);
    return upstream;
  }

  /// 上流サーバの origin。
  String get origin => 'http://127.0.0.1:$port';

  /// 同じポートで上流サーバを再起動する。
  ///
  /// Returns: 再起動の完了を表す Future。
  Future<void> restart() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _listen(server);
  }

  /// 上流サーバを停止する。
  ///
  /// Returns: 停止の完了を表す Future。
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// [path] へ届いた更新系の要求の本文を、届いた順に返す。
  ///
  /// [path] は要求のパスです。
  ///
  /// Returns: 本文の一覧。
  List<String> bodiesFor(String path) =>
      List.unmodifiable(_bodies[path] ?? const <String>[]);

  /// 受信した要求へ並行して応答する。
  ///
  /// [server] は応答に使うサーバです。
  void _listen(HttpServer server) {
    _server = server;
    unawaited(() async {
      await for (final HttpRequest request in server) {
        unawaited(_respond(request));
      }
    }());
  }

  /// 1 件の要求へ応答する。更新系の要求は本文を記録する。
  ///
  /// [request] は受信した要求です。
  ///
  /// Returns: 応答の完了を表す Future。
  Future<void> _respond(HttpRequest request) async {
    try {
      if (request.method == 'GET' || request.method == 'HEAD') {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.ok;
        if (request.method == 'GET') {
          request.response.headers.contentType =
              ContentType('text', 'plain', charset: 'utf-8');
          request.response.write('ok');
        }
      } else {
        final body = await utf8.decoder.bind(request).join();
        _bodies.putIfAbsent(request.uri.path, () => <String>[]).add(body);
        request.response.statusCode = HttpStatus.ok;
      }
      await request.response.close();
    } catch (_) {
      // 停止処理と重なった場合は無視する
    }
  }
}

/// 条件を満たすまで待つ。
///
/// [condition] は判定です。[timeout] は待つ上限です。[message] は失敗時の説明です。
///
/// Returns: 条件を満たした時点で完了する Future。
Future<void> _waitUntil(
  FutureOr<bool> Function() condition, {
  required Duration timeout,
  required String message,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(message, timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// [haystack] の中に [needle] と同じ並びのバイト列があるかを返す。
///
/// [haystack] は探す対象のバイト列です。
/// [needle] は探すバイト列です。
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

/// 保存領域のキー（19 桁のマイクロ秒と 6 桁の連番）を作る。
///
/// [time] はキーに使う時刻です。
///
/// Returns: 保存領域のキー。
String _storageKey(DateTime time) =>
    '${time.microsecondsSinceEpoch.toString().padLeft(19, '0')}-000000';

/// proxy の Box と暗号化鍵を消し、鍵の無い状態に戻す。
///
/// Returns: 削除の完了を表す Future。
Future<void> _resetProxyStorage() async {
  for (final name in _boxesToReset) {
    await Hive.deleteBoxFromDisk(name);
  }
  await const FlutterSecureStorage().delete(key: _encryptionKeyName);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('offline_web_proxy encrypted storage (emulator/device) e2e', () {
    late _RecordingUpstream upstream;
    late String hiveDirectory;

    setUpAll(() async {
      await Hive.initFlutter();
      // proxy と同じ、Hive.initFlutter の既定の保存先を求める
      final probe = await Hive.openBox('offline_web_proxy_e2e_probe');
      hiveDirectory = File(probe.path!).parent.path;
      await probe.deleteFromDisk();
      upstream = await _RecordingUpstream.start();
    });

    // 前のテストや前の実行で残った項目と鍵の影響を受けないよう、毎回消してから始める
    setUp(_resetProxyStorage);

    tearDownAll(() async {
      await upstream.stop();
    });

    testWidgets(
      'moves a plain queue of 0.14.0 and earlier into the encrypted box '
      'after the delay and sends it',
      (tester) async {
        await upstream.stop();

        final marker =
            'legacy-queue-body-${DateTime.now().microsecondsSinceEpoch}';
        final markerBytes = utf8.encode(marker);
        final queuedAt = DateTime.now().subtract(const Duration(minutes: 1));
        final queueKey = _storageKey(queuedAt);

        // 0.14.0 以前の proxy と同じ形で、旧平文のキューに 1 件保存する（べき等性キーは省く）
        final legacyBox = await Hive.openBox(_legacyQueueBoxName);
        await legacyBox.put(queueKey, <String, Object>{
          'url': '${upstream.origin}/legacy-submit',
          'method': 'POST',
          'headers': <String, String>{
            'content-type': 'text/plain; charset=utf-8',
          },
          'body': markerBytes,
          'queuedAt': queuedAt.toIso8601String(),
          'acceptedAt': queuedAt.toIso8601String(),
          'retryCount': 0,
          'nextRetryAt': queuedAt.toIso8601String(),
        });
        await legacyBox.close();

        final legacyFile = File('$hiveDirectory/$_legacyQueueBoxName.hive');
        final secureFile = File('$hiveDirectory/$_encryptedQueueBoxName.hive');
        // 平文の Box には本文がそのまま残る。暗号化 Box を同じ方法で調べる意味を確かめる
        expect(
          _containsBytes(await legacyFile.readAsBytes(), markerBytes),
          isTrue,
        );

        final proxy = OfflineWebProxy();
        final sinceStart = Stopwatch()..start();
        try {
          await proxy.start(
            config: ProxyConfig(origin: upstream.origin, port: 0),
          );

          // 鍵の無い状態から起動したため、端末の secure storage へ 32 バイトの鍵を保存する
          final storedKey =
              await const FlutterSecureStorage().read(key: _encryptionKeyName);
          expect(storedKey, isNotNull);
          expect(base64Decode(storedKey!), hasLength(32));

          // この起動で鍵を生成したため、移行を遅らせ、旧 Box の項目は移行待ちになる
          final pending = await proxy.getQueuedRequests();
          expect(pending, hasLength(1));
          expect(pending.single.pendingMigration, isTrue);
          expect(legacyFile.existsSync(), isTrue);

          // 上流が止まっている間に移行を終えさせ、暗号化 Box に項目がある状態で調べる。
          // 旧 Box のファイルは、旧 Box を空にして閉じた後に消すため、消えるまで待つ
          await _waitUntil(
            () async {
              final requests = await proxy.getQueuedRequests();
              return requests.length == 1 &&
                  !requests.single.pendingMigration &&
                  !legacyFile.existsSync();
            },
            timeout: _deferredMigrationDelay + const Duration(seconds: 60),
            message: '旧平文のキューが移行されませんでした',
          );
          expect(
            sinceStart.elapsed,
            greaterThanOrEqualTo(_deferredMigrationDelay),
          );

          // Hive はキーを平文のまま、値だけを暗号化して書く。キーがあることで、
          // 調べたファイルに移した項目の記録があることを確かめる
          final secureBytes = await secureFile.readAsBytes();
          expect(_containsBytes(secureBytes, utf8.encode(queueKey)), isTrue);
          expect(_containsBytes(secureBytes, markerBytes), isFalse);

          // 上流を再開すると、暗号化 Box から読み出した本文をそのまま送る
          await upstream.restart();
          await _waitUntil(
            () => upstream.bodiesFor('/legacy-submit').isNotEmpty,
            timeout: _deliveryTimeout,
            message: '移行した要求が上流へ届きませんでした',
          );
          await _waitUntil(
            () async => (await proxy.getQueuedRequests()).isEmpty,
            timeout: _dequeueTimeout,
            message: '送った要求がキューに残りました',
          );
          expect(upstream.bodiesFor('/legacy-submit'), [marker]);
        } finally {
          await proxy.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'keeps an encrypted queued request across stop and start, '
      'and sends it after the upstream returns',
      (tester) async {
        await upstream.stop();

        final marker =
            'offline-queue-body-${DateTime.now().microsecondsSinceEpoch}';
        final markerBytes = utf8.encode(marker);
        final secureFile = File('$hiveDirectory/$_encryptedQueueBoxName.hive');

        var proxy = OfflineWebProxy();
        try {
          final port = await proxy.start(
            config: ProxyConfig(origin: upstream.origin, port: 0),
          );

          // 上流へ到達できないため、キューに入れて 202 を返す
          final response = await http.post(
            Uri.parse('http://127.0.0.1:$port/offline-submit'),
            headers: {'content-type': 'text/plain; charset=utf-8'},
            body: marker,
          );
          expect(response.statusCode, HttpStatus.accepted);
          // キュー ID は、暗号化 Box に保存したキーと同じ値
          final queueId = response.headers['x-offline-queue-id'];
          expect(queueId, isNotNull);

          final queued = await proxy.getQueuedRequests();
          expect(queued, hasLength(1));
          expect(queued.single.url, endsWith('/offline-submit'));
          expect(queued.single.pendingMigration, isFalse);
          final secureBytes = await secureFile.readAsBytes();
          expect(_containsBytes(secureBytes, utf8.encode(queueId!)), isTrue);
          expect(_containsBytes(secureBytes, markerBytes), isFalse);

          // 同じプロセスの中で停止し、別のインスタンスで起動し直す。secure storage の
          // 鍵を読み直して開く（アプリの再起動をまたいだ鍵の保存までは確かめない）
          await proxy.stop();
          proxy = OfflineWebProxy();
          await proxy.start(
            config: ProxyConfig(origin: upstream.origin, port: 0),
          );
          final restored = await proxy.getQueuedRequests();
          expect(restored, hasLength(1));
          expect(restored.single.url, endsWith('/offline-submit'));

          await upstream.restart();
          await _waitUntil(
            () => upstream.bodiesFor('/offline-submit').isNotEmpty,
            timeout: _deliveryTimeout,
            message: 'キューの要求が上流へ届きませんでした',
          );
          await _waitUntil(
            () async => (await proxy.getQueuedRequests()).isEmpty,
            timeout: _dequeueTimeout,
            message: '送った要求がキューに残りました',
          );
          expect(upstream.bodiesFor('/offline-submit'), [marker]);
        } finally {
          await proxy.stop();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
