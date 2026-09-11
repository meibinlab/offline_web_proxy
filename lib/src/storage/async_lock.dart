import 'dart:async';
import 'dart:collection';

/// 非同期処理を 1 つずつ実行させるためのロックです。
///
/// 取得を待つ処理は、待ち始めた順に実行します。再入はできません。ロックを
/// 保持している処理の中から同じロックを取得しようとすると、完了しなくなります。
/// proxy の内部実装用で、ライブラリからは公開しません。
class AsyncLock {
  /// ロックの解放を待っている処理の一覧です。待ち始めた順に並びます。
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// ロックを保持している処理があるかどうかです。
  bool _locked = false;

  /// ロックを保持している処理があるかどうかを返します。
  ///
  /// Returns: 保持している処理がある場合は `true`。
  bool get isLocked => _locked;

  /// ロックを取得してから [action] を実行し、終了後に解放します。
  ///
  /// [action] ロックを保持したまま実行する処理。
  /// [timeout] ロックの取得を待つ上限時間。`null` の場合は取得できるまで
  ///   待ちます。
  ///
  /// Returns: [action] の戻り値。
  ///
  /// Throws:
  ///   * [TimeoutException] [timeout] までにロックを取得できなかった場合。
  ///     このとき [action] は実行しません。
  Future<T> synchronized<T>(
    Future<T> Function() action, {
    Duration? timeout,
  }) async {
    await _acquire(timeout);
    try {
      return await action();
    } finally {
      _release();
    }
  }

  /// ロックを取得します。
  ///
  /// [timeout] 取得を待つ上限時間。`null` の場合は取得できるまで待ちます。
  ///
  /// Throws:
  ///   * [TimeoutException] [timeout] までに取得できなかった場合。
  Future<void> _acquire(Duration? timeout) async {
    if (!_locked) {
      _locked = true;
      return;
    }

    final waiter = Completer<void>();
    _waiters.add(waiter);
    if (timeout == null) {
      await waiter.future;
      return;
    }

    try {
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      // 待ち行列に残っていれば、まだ譲られていないため取得を諦める
      if (_waiters.remove(waiter)) {
        rethrow;
      }
      // 待ち行列から外れている場合は、上限と同時にロックを譲られている。
      // ここで諦めるとロックが解放されなくなるため、保持したまま続ける。
    }
  }

  /// ロックを解放し、待っている処理があれば先頭の処理へ譲ります。
  void _release() {
    if (_waiters.isNotEmpty) {
      // 保持状態のまま譲るため、_locked は下ろさない
      _waiters.removeFirst().complete();
      return;
    }

    _locked = false;
  }
}
