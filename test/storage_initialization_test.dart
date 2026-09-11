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

/// Cookie と業務データの暗号化鍵を保存する secure storage のキー。
const String _encryptionKeyStorageKey =
    'offline_web_proxy.cookie_box_encryption_key';

/// 起動に使う上流 origin。これらのテストでは上流へ接続しない。
const String _origin = 'https://example.com';

/// 暗号化 Cookie Box の名前。
const String _encryptedCookieBoxName = 'proxy_cookies_secure';

/// 旧平文 Cookie Box の名前。
const String _legacyCookieBoxName = 'proxy_cookies';

/// 鍵の読み取りを遅らせ、書き込み回数を数える secure storage。
///
/// 読み取りの間に別の初期化が割り込めるようにし、直列化が外れた場合に
/// 鍵の書き込みが 2 回になることを確実に検出するために使う。
class _CountingKeyStorage implements EncryptionKeyStorage {
  /// 保存されている値。
  final Map<String, String> values = {};

  /// 鍵を書き込んだ回数。
  int writeCount = 0;

  @override
  Future<String?> read(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<bool?> isProtectedDataAvailable() async => null;
}

/// 復元する Cookie を作る。
///
/// [name] Cookie 名。
///
/// Returns: `example.com` のホスト限定 Cookie。
CookieRestoreEntry _cookie(String name) {
  return CookieRestoreEntry(
    name: name,
    value: 'value-$name',
    domain: 'example.com',
    hostOnly: true,
  );
}

/// 端末のロック状態を切り替えられる secure storage。
class _LockableKeyStorage extends SecureEncryptionKeyStorage {
  /// 端末がロックされていて、鍵を読めない状態かどうか。
  bool locked = true;

  @override
  Future<bool?> isProtectedDataAvailable() async => !locked;
}

/// secure storage に保存されている暗号化鍵を読む。
Future<String?> _readStoredKey() {
  return const FlutterSecureStorage().read(key: _encryptionKeyStorageKey);
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

  setUp(() async {
    hiveTestDirectory = Directory.systemTemp
        .createTempSync('offline_web_proxy_storage_init')
        .path;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await Hive.close();
    proxy = OfflineWebProxy();
  });

  tearDown(() async {
    if (proxy.isRunning) {
      await proxy.stop();
    }
    await Hive.close();
  });

  /// プロセスの再起動を再現し、新しい proxy で Cookie の名前一覧を読む。
  ///
  /// secure storage の内容はそのまま引き継ぐ。
  ///
  /// Returns: 再起動後に読めた Cookie 名の一覧。
  Future<List<String>> readCookieNamesAfterRestart() async {
    await Hive.close();
    proxy = OfflineWebProxy();
    final cookies = await proxy.getCookies();
    return cookies.map((cookie) => cookie.name).toList();
  }

  group('保存領域の初期化の直列化（段階 1 / 段階 2）', () {
    /// 新規インストール直後に Cookie API を同時に呼んでも鍵は 1 つに決まり、
    /// 再起動後も Cookie が残ること（鍵が 2 つ作られると、次回の起動で
    /// 暗号化 Box が切り詰められていた）
    test('generates a single key when cookie APIs run concurrently', () async {
      await Future.wait([
        proxy.getCookies(),
        proxy.restoreCookies([_cookie('SESSION')]),
        proxy.restoreCookies([_cookie('PREFERENCE')]),
      ]);
      final storedKey = await _readStoredKey();
      expect(storedKey, isNotNull);

      final names = await readCookieNamesAfterRestart();

      expect(names, containsAll(<String>['SESSION', 'PREFERENCE']));
      // 再起動で鍵を作り直していないこと
      expect(await _readStoredKey(), equals(storedKey));
    });

    /// start() と Cookie API を同時に呼んでも鍵は 1 つに決まり、
    /// 再起動後も Cookie が残ること（競合の検出は、鍵の書き込み回数を数える
    /// 別のテストで行う）
    test('generates a single key when start() and a cookie API run together',
        () async {
      await Future.wait([
        proxy.start(config: const ProxyConfig(origin: _origin)),
        proxy.restoreCookies([_cookie('SESSION')]),
      ]);
      final storedKey = await _readStoredKey();
      await proxy.stop();

      final names = await readCookieNamesAfterRestart();

      expect(names, contains('SESSION'));
      expect(await _readStoredKey(), equals(storedKey));
    });

    /// 段階 1 が失敗した後、原因を取り除けば同じインスタンスで再試行できること
    test('retries stage 1 after it failed', () async {
      final keyStorage = _LockableKeyStorage();
      proxy = OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(keyStorage: keyStorage),
      );

      // 端末のロック中は鍵を読めないため、段階 1 が失敗する
      await expectLater(
        proxy.getCookies(),
        throwsA(isA<CookieOperationException>()),
      );

      keyStorage.locked = false;

      // 失敗した結果を共有し続けず、改めて初期化すること
      await proxy.restoreCookies([_cookie('SESSION')]);
      final cookies = await proxy.getCookies();
      expect(cookies.map((cookie) => cookie.name), contains('SESSION'));
    });

    /// 段階 2 が失敗しても Cookie API は使え、原因を取り除けば start() を
    /// 再試行できること
    test('keeps cookie APIs usable after stage 2 failed and retries start()',
        () async {
      // Box のファイル名と同じディレクトリを置き、段階 2 で開けないようにする
      final blocker = Directory(
          '$hiveTestDirectory${Platform.pathSeparator}proxy_idempotency.hive')
        ..createSync();

      Object? startError;
      final uncaughtErrors = <Object>[];
      // Hive は開くのに失敗した Box の待ち合わせ用 Future を誰も待たないまま
      // 失敗させるため、未捕捉のエラーとして通知される。テストの失敗にしないよう捕捉する。
      await runZonedGuarded(() async {
        try {
          await proxy.start(config: const ProxyConfig(origin: _origin));
        } catch (error) {
          startError = error;
        }
      }, (error, stackTrace) => uncaughtErrors.add(error));

      expect(startError, isA<ProxyStartException>());
      expect(proxy.isRunning, isFalse);
      // Box を開けなかったこと以外の未捕捉エラーが紛れていないこと
      expect(uncaughtErrors, isNotEmpty);
      expect(uncaughtErrors, everyElement(isA<FileSystemException>()));

      // 段階 1 の結果（Cookie Box）はそのまま使えること
      await proxy.restoreCookies([_cookie('SESSION')]);
      expect(
        (await proxy.getCookies()).map((cookie) => cookie.name),
        contains('SESSION'),
      );

      blocker.deleteSync();

      // 失敗した段階 2 の結果を共有し続けず、改めて初期化すること
      await proxy.start(config: const ProxyConfig(origin: _origin));
      expect(proxy.isRunning, isTrue);
      expect(
        (await proxy.getCookies()).map((cookie) => cookie.name),
        contains('SESSION'),
      );
    });

    /// 鍵の読み取りが遅くても、start() と Cookie API を同時に呼んだ場合の
    /// 鍵の書き込みは 1 回だけであること
    test('writes the key once when start() and a cookie API overlap', () async {
      final keyStorage = _CountingKeyStorage();
      proxy = OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(keyStorage: keyStorage),
      );

      await Future.wait([
        proxy.start(config: const ProxyConfig(origin: _origin)),
        proxy.restoreCookies([_cookie('SESSION')]),
      ]);

      expect(keyStorage.writeCount, 1);
    });

    /// 2 つのインスタンスから同時に呼んでも、鍵の書き込みは 1 回だけであること
    test('writes the key once when two instances overlap', () async {
      final keyStorage = _CountingKeyStorage();
      proxy = OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(keyStorage: keyStorage),
      );
      final another = OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(keyStorage: keyStorage),
      );

      await Future.wait([
        proxy.restoreCookies([_cookie('SESSION')]),
        another.restoreCookies([_cookie('PREFERENCE')]),
      ]);

      expect(keyStorage.writeCount, 1);
      final names = (await another.getCookies()).map((cookie) => cookie.name);
      expect(names, containsAll(<String>['SESSION', 'PREFERENCE']));
    });

    /// 2 つのインスタンスから同時に呼んでも鍵は 1 つに決まり、再起動後も
    /// Cookie が残ること（鍵と Box は同じ isolate 内のインスタンスで共有されるため）
    test('generates a single key when two instances initialize together',
        () async {
      final another = OfflineWebProxy();
      await Future.wait([
        proxy.restoreCookies([_cookie('SESSION')]),
        another.restoreCookies([_cookie('PREFERENCE')]),
      ]);
      final storedKey = await _readStoredKey();

      final names = await readCookieNamesAfterRestart();

      expect(names, containsAll(<String>['SESSION', 'PREFERENCE']));
      expect(await _readStoredKey(), equals(storedKey));
    });

    /// 段階 1 が Cookie Box を開いた後で失敗した場合は Box を開いたまま残さず、
    /// 原因を取り除けば同じインスタンスで移行からやり直せること
    test('closes the cookie box when stage 1 fails after opening it', () async {
      await Hive.initFlutter();
      final brokenLegacyBox = await Hive.openBox(_legacyCookieBoxName);
      // 読み取れない記録を置き、旧平文 Cookie Box の移行を失敗させる
      await brokenLegacyBox.put('broken', <String, dynamic>{
        'name': 'LEGACY',
        'expires': 'not-a-date',
      });
      await brokenLegacyBox.close();

      await expectLater(
        proxy.getCookies(),
        throwsA(isA<CookieOperationException>()),
      );
      expect(Hive.isBoxOpen(_encryptedCookieBoxName), isFalse);

      final repairedLegacyBox = await Hive.openBox(_legacyCookieBoxName);
      await repairedLegacyBox.clear();
      final legacyCookie = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'LEGACY=token; Path=/',
        requestUri: Uri.parse('https://example.com/login'),
        receivedAt: DateTime.now().toUtc(),
      );
      await repairedLegacyBox.put(
        legacyCookie.storageKey,
        legacyCookie.toMap(),
      );
      await repairedLegacyBox.close();

      final cookies = await proxy.getCookies();

      expect(cookies.map((cookie) => cookie.name), contains('LEGACY'));
      expect(await Hive.boxExists(_legacyCookieBoxName), isFalse);
    });

    /// 段階 1 の後に Box が閉じられた場合は、同じインスタンスで開き直すこと
    test('reopens the cookie box on the same instance after it was closed',
        () async {
      await proxy.restoreCookies([_cookie('SESSION')]);
      final storedKey = await _readStoredKey();
      await Hive.close();

      final cookies = await proxy.getCookies();

      expect(cookies.map((cookie) => cookie.name), contains('SESSION'));
      expect(await _readStoredKey(), equals(storedKey));
    });

    /// 段階 2 の後にどれかの Box が閉じられた場合は、同じインスタンスの
    /// start() で開き直すこと
    test('reopens data boxes on the same instance after one was closed',
        () async {
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(occupied.close);

      // 保存領域の初期化の後でポートの確保に失敗させ、段階 2 の結果を残す
      await expectLater(
        proxy.start(
          config: ProxyConfig(origin: _origin, port: occupied.port),
        ),
        throwsA(isA<ProxyStartException>()),
      );
      await Hive.box('proxy_cache').close();

      await proxy.start(config: const ProxyConfig(origin: _origin));

      expect(Hive.isBoxOpen('proxy_cache'), isTrue);
    });

    /// 段階 2 の失敗時は、この呼び出しで開いた Box だけを閉じ、他の処理が
    /// 開いていた Box は閉じないこと
    test('closes only the boxes stage 2 opened when it fails', () async {
      await Hive.initFlutter();
      await Hive.openBox('proxy_cache');
      // Box のファイル名と同じディレクトリを置き、段階 2 の途中で失敗させる
      Directory(
        '$hiveTestDirectory${Platform.pathSeparator}proxy_idempotency.hive',
      ).createSync();

      Object? startError;
      final uncaughtErrors = <Object>[];
      await runZonedGuarded(() async {
        try {
          await proxy.start(config: const ProxyConfig(origin: _origin));
        } catch (error) {
          startError = error;
        }
      }, (error, stackTrace) => uncaughtErrors.add(error));

      // 段階 2 の途中（ディレクトリを置いた Box を開くところ）で失敗したこと
      expect(startError, isA<ProxyStartException>());
      final cause = (startError! as ProxyStartException).cause;
      expect(cause, isA<FileSystemException>());
      expect(
        (cause! as FileSystemException).path,
        contains('proxy_idempotency'),
      );
      expect(uncaughtErrors, everyElement(isA<FileSystemException>()));
      // 閉じたことを確かめる Box を、この呼び出しが実際に開いていたこと
      expect(
        File('$hiveTestDirectory${Platform.pathSeparator}proxy_web_storage.hive')
            .existsSync(),
        isTrue,
      );
      // 失敗より前に段階 2 が開いた Box は閉じていること
      expect(Hive.isBoxOpen('proxy_web_storage'), isFalse);
      // テストが先に開いていた Box は閉じていないこと
      expect(Hive.isBoxOpen('proxy_cache'), isTrue);
    });

    /// 共有している段階 1 の失敗が、別の error zone から待っている呼び出しにも
    /// 届き、待ったまま完了しない状態にならないこと
    test('reports a shared stage 1 failure to callers in other error zones',
        () async {
      // 端末のロック中は鍵を読めないため、段階 1 が失敗する
      final keyStorage = _LockableKeyStorage();
      proxy = OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(keyStorage: keyStorage),
      );

      final zonedOutcome = Completer<Object?>();
      runZonedGuarded(() {
        // 先に呼び、共有する段階 1 をこの zone で作らせる
        proxy.getCookies().then(
              (_) => zonedOutcome.complete(null),
              onError: (Object error) => zonedOutcome.complete(error),
            );
      }, (error, stackTrace) {
        // 届かない場合でもテストの失敗として検出できるよう、ここでは何もしない
      });

      final outsideOutcome = await proxy
          .getCookies()
          .then<Object?>((_) => null, onError: (Object error) => error)
          .timeout(const Duration(seconds: 5));
      final zonedError =
          await zonedOutcome.future.timeout(const Duration(seconds: 5));

      expect(outsideOutcome, isA<CookieOperationException>());
      expect(zonedError, isA<CookieOperationException>());
    });
  });

  group('起動処理中の start() の再呼び出し', () {
    /// start() を続けて 2 回呼ぶと、2 回目は起動処理中を理由に ProxyStartException で失敗し、
    /// 1 回目は起動できること。起動処理中の状態が残らず、その後の stop() → start() もできること
    test('rejects the second of two concurrent start() calls', () async {
      final first = proxy.start(config: const ProxyConfig(origin: _origin));
      final second = proxy.start(config: const ProxyConfig(origin: _origin));

      final secondError = await second.then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      final port = await first;

      // 2 回目は起動処理中を理由に失敗し、保存領域を使えない失敗としては扱わないこと
      expect(secondError, isA<ProxyStartException>());
      expect(secondError, isNot(isA<StorageIntegrityException>()));
      // 1 回目は起動できること
      expect(port, greaterThan(0));
      expect(proxy.isRunning, isTrue);
      expect(proxy.port, port);

      // 起動処理中の状態が残らず、停止した後に再び起動できること
      await proxy.stop();
      await proxy.start(config: const ProxyConfig(origin: _origin));
      expect(proxy.isRunning, isTrue);
    });

    /// 1 回目の start() が鍵の読み取りで止まっている間に呼んだ start() は ProxyStartException で
    /// 失敗し、1 回目の起動処理中の状態（復旧 API を拒否する状態）を崩さず、1 回目は起動できること
    test('keeps the first start() in progress when a second call is rejected',
        () async {
      final keyStorage = _GatedKeyStorage();
      proxy = OfflineWebProxy.withStorageTestHooks(
        ProxyStorageTestHooks(keyStorage: keyStorage),
      );
      addTearDown(() {
        if (!keyStorage.readGate.isCompleted) {
          keyStorage.readGate.complete();
        }
      });

      final first = proxy.start(config: const ProxyConfig(origin: _origin));
      await keyStorage.readEntered.future.timeout(const Duration(seconds: 10));

      final secondError = await proxy
          .start(config: const ProxyConfig(origin: _origin))
          .then<Object?>((_) => null, onError: (Object error) => error);

      // 2 回目は起動処理中を理由に失敗すること
      expect(secondError, isA<ProxyStartException>());
      expect(secondError, isNot(isA<StorageIntegrityException>()));
      // 1 回目はまだ起動処理中で、復旧 API は起動処理中を理由に拒否すること
      expect(proxy.isRunning, isFalse);
      final recovery = await proxy.recoverEncryptedStorage();
      expect(recovery.performed, isFalse);
      expect(recovery.rejection, StorageRecoveryRejection.proxyActive);

      keyStorage.readGate.complete();
      final port = await first;

      // 1 回目は起動できること
      expect(port, greaterThan(0));
      expect(proxy.isRunning, isTrue);
    });
  });
}

/// 鍵の読み取りを止めておける secure storage。
///
/// start() が段階 1 の鍵の読み取りで止まり、起動処理中のままになった状態を作るために使う。
class _GatedKeyStorage implements EncryptionKeyStorage {
  /// 保存されている値。
  final Map<String, String> values = {};

  /// 読み取りを止めておく待ち合わせ。完了するまで読み取りは戻らない。
  final Completer<void> readGate = Completer<void>();

  /// 読み取りが始まったことを知らせる待ち合わせ。
  final Completer<void> readEntered = Completer<void>();

  @override
  Future<String?> read(String key) async {
    if (!readEntered.isCompleted) {
      readEntered.complete();
    }
    await readGate.future;
    return values[key];
  }

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
