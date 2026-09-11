import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/src/storage/async_lock.dart';

void main() {
  group('AsyncLock', () {
    /// 同時に取得を試みた処理が、待ち始めた順に 1 つずつ実行されること
    test('runs actions one at a time in the order they waited', () async {
      final lock = AsyncLock();
      final events = <String>[];

      Future<void> run(String name) {
        return lock.synchronized(() async {
          events.add('$name:start');
          await Future<void>.delayed(const Duration(milliseconds: 10));
          events.add('$name:end');
        });
      }

      await Future.wait([run('a'), run('b'), run('c')]);

      expect(
        events,
        equals([
          'a:start',
          'a:end',
          'b:start',
          'b:end',
          'c:start',
          'c:end',
        ]),
      );
      expect(lock.isLocked, isFalse);
    });

    /// 処理が例外で終わってもロックを解放し、次の処理が実行されること
    test('releases the lock when an action throws', () async {
      final lock = AsyncLock();

      await expectLater(
        lock.synchronized<void>(() async => throw StateError('failed')),
        throwsA(isA<StateError>()),
      );

      expect(lock.isLocked, isFalse);
      expect(await lock.synchronized(() async => 1), equals(1));
    });

    /// 上限時間までに取得できない場合は処理を実行せず TimeoutException を送出すること
    test('throws TimeoutException without running the action on timeout',
        () async {
      final lock = AsyncLock();
      final release = Completer<void>();
      final holder = lock.synchronized(() => release.future);

      var ran = false;
      await expectLater(
        lock.synchronized(
          () async => ran = true,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(ran, isFalse);

      release.complete();
      await holder;

      // 諦めた処理が待ち行列に残らず、ロックが解放されること
      expect(lock.isLocked, isFalse);
      expect(await lock.synchronized(() async => 'next'), equals('next'));
    });
  });
}
