import 'dart:convert';
import 'dart:math';

import '../models/proxy_config.dart';

/// proxy が生成する、ページ遷移向けの応答ページの種類。
enum OfflineRecoveryPageKind {
  /// オフライン時にキャッシュを返せないページ遷移へ返す代替ページ（200）。
  offlineFallback,

  /// 上流へ到達できずキャッシュも返せないページ遷移へ返すページ（504）。
  gatewayTimeout,
}

/// 監視スクリプトの動作に必要な値をまとめたクラス。
///
/// proxy の内部でだけ使用します。
class OfflineRecoveryScriptOptions {
  /// 監視スクリプトの設定を生成します。
  ///
  /// [pageKind] は埋め込み先のページの種類です。
  /// [statusPath] は状態通知エンドポイントのパスで、空文字列は無効を表します。
  /// [pollInterval] は状態通知を読む間隔です。
  /// [queueWaitTimeout] は再送の完了を待つ上限時間です。
  /// [requestTimeout] は proxy の要求の締め切りで、目印の有効時間の代替に使います。
  /// [offlinePageAutoReload] は代替ページの自動復帰の有効・無効です。
  /// [continuation] は継続復帰の有効・無効です。
  /// [gatewayTimeoutAutoReload] は 504 ページの監視中からの自動再読込の有効・無効です。
  const OfflineRecoveryScriptOptions({
    required this.pageKind,
    required this.statusPath,
    required this.pollInterval,
    required this.queueWaitTimeout,
    required this.requestTimeout,
    required this.offlinePageAutoReload,
    required this.continuation,
    required this.gatewayTimeoutAutoReload,
  });

  /// 埋め込み先のページの種類。
  final OfflineRecoveryPageKind pageKind;

  /// 状態通知エンドポイントのパス。空文字列は無効を表します。
  final String statusPath;

  /// 状態通知を読む間隔。
  final Duration pollInterval;

  /// 再送の完了を待つ上限時間。
  final Duration queueWaitTimeout;

  /// proxy の要求の締め切り。
  ///
  /// `performance.timeOrigin` を使えない WebView で、自動再読込の結果かどうかを
  /// 判定する有効時間の算出に使います。
  final Duration requestTimeout;

  /// 代替ページの自動復帰の有効・無効。
  final bool offlinePageAutoReload;

  /// 継続復帰（自動再読込の結果として表示された 504 ページの再読込）の有効・無効。
  final bool continuation;

  /// 504 ページの監視中からの自動再読込の有効・無効。
  final bool gatewayTimeoutAutoReload;
}

/// 自動再読込が連続して proxy のページに着いた場合に、再読込を止める回数。
const int _maxConsecutiveAutoReloads = 3;

/// 継続復帰で、状態通知を読み始めるまでの待ち時間。
const Duration _continuationWait = Duration(seconds: 10);

/// 遷移を始めた時刻と目印の差を、自動再読込の結果とみなす上限。
const Duration _markerWindow = Duration(seconds: 10);

/// 遷移を始めた時刻と目印の差の下限。時計の補正による小さなずれを許す。
const Duration _markerLowerBound = Duration(seconds: -1);

/// 要求の締め切りへ足す余裕。
///
/// `performance.timeOrigin` を使えない場合の目印の有効時間と、画面から始まった
/// 遷移を待つ時間の算出に使います。
const Duration _fallbackMarkerMargin = Duration(seconds: 30);

/// 状態通知の取得失敗が続く場合に延ばす間隔の上限。
const Duration _maxFailureBackoff = Duration(seconds: 30);

/// 状態通知の取得を打ち切るまでの時間の下限。
const Duration _minimumFetchTimeout = Duration(seconds: 1);

/// 監視間隔として受け付ける最小値。
///
/// これより短いと状態通知への要求が途切れなく続くため、`start()` で拒否します。
const Duration offlineRecoveryMinimumPollInterval = Duration(milliseconds: 100);

/// 監視間隔として受け付ける最大値。
///
/// ブラウザのタイマーが扱える範囲（約 24.8 日）に収めるため、`start()` で拒否します。
const Duration offlineRecoveryMaximumPollInterval = Duration(hours: 24);

/// 他の URL の記録を掃除するまでの経過時間。
const Duration _staleRecordAge = Duration(minutes: 10);

/// 設定値を埋め込む位置を表す、スクリプト内の目印。
const String _configToken = '__OFFLINE_WEB_PROXY_RECOVERY_CONFIG__';

/// 監視スクリプトの本体。
///
/// 古い WebView でも動くよう、`var` と関数宣言だけで書いています。
/// 状態遷移は doc/specs.ja.md のオフライン応答の節に合わせています。
const String _recoveryScriptSource = r'''
(function () {
  'use strict';
  var cfg = __OFFLINE_WEB_PROXY_RECOVERY_CONFIG__;
  if (document.readyState !== 'loading' || typeof fetch !== 'function') {
    return;
  }
  // 同じページで複数回実行されると、連続回数の記録を互いに打ち消すため
  if (window.__offlineWebProxyRecoveryStarted === true) {
    return;
  }
  window.__offlineWebProxyRecoveryStarted = true;

  var KEY_PREFIX = '__offline_web_proxy_recovery:';
  var key = KEY_PREFIX + location.pathname + location.search;
  var storage = openStorage();
  var count = 0;
  var state = null;
  var timer = null;
  var generation = 0;
  var reloaded = false;
  var reachableStreak = 0;
  var failureCount = 0;
  var queueWaitStartedAt = 0;
  var leavingAt = 0;

  var arrivedByAutoReload = processMarker();
  state = initialState(arrivedByAutoReload);
  if (state === 'continuation') {
    schedule(cfg.continuationWaitMs);
  } else if (state !== null) {
    schedule(cfg.pollIntervalMs);
  }

  window.addEventListener('pageshow', function (event) {
    if (!event.persisted) {
      return;
    }
    // bfcache から戻った場合は判定し直さず、保存済みの回数で監視をやり直す
    generation += 1;
    clearTimeout(timer);
    reloaded = false;
    leavingAt = 0;
    reachableStreak = 0;
    failureCount = 0;
    var record = readRecord();
    count = record === null ? 0 : record.count;
    state = restartState();
    if (state !== null) {
      schedule(cfg.pollIntervalMs);
    }
  });

  window.addEventListener('beforeunload', function () {
    // 画面から始まった遷移の途中で再読込すると、その遷移を打ち消すため時刻を残す
    leavingAt = Date.now();
  });

  function openStorage() {
    try {
      var candidate = window.sessionStorage;
      var probe = KEY_PREFIX + 'probe';
      candidate.setItem(probe, '1');
      candidate.removeItem(probe);
      return candidate;
    } catch (error) {
      return null;
    }
  }

  function readRecord() {
    if (storage === null) {
      return null;
    }
    try {
      var parsed = JSON.parse(storage.getItem(key));
      if (parsed === null || typeof parsed !== 'object') {
        return null;
      }
      return {
        count: typeof parsed.count === 'number' ? parsed.count : 0,
        markerAt: typeof parsed.markerAt === 'number' ? parsed.markerAt : null
      };
    } catch (error) {
      return null;
    }
  }

  function saveRecord(markerAt) {
    if (storage === null) {
      return;
    }
    var now = Date.now();
    try {
      if (count === 0 && markerAt === null) {
        storage.removeItem(key);
      } else {
        storage.setItem(key, JSON.stringify({
          count: count,
          markerAt: markerAt,
          updatedAt: now
        }));
      }
    } catch (error) {
      // 保存できなくても監視は続ける
    }
    removeStaleRecords(now);
  }

  function removeStaleRecords(now) {
    try {
      var staleKeys = [];
      for (var index = 0; index < storage.length; index++) {
        var name = storage.key(index);
        if (name === null || name === key || name.indexOf(KEY_PREFIX) !== 0) {
          continue;
        }
        var updatedAt = 0;
        try {
          var value = JSON.parse(storage.getItem(name));
          if (value !== null && typeof value.updatedAt === 'number') {
            updatedAt = value.updatedAt;
          }
        } catch (error) {
          updatedAt = 0;
        }
        if (now - updatedAt > cfg.staleRecordAgeMs) {
          staleKeys.push(name);
        }
      }
      for (var position = 0; position < staleKeys.length; position++) {
        storage.removeItem(staleKeys[position]);
      }
    } catch (error) {
      // 掃除できなくても動作には影響しない
    }
  }

  function navigationType() {
    try {
      if (typeof performance.getEntriesByType === 'function') {
        var entries = performance.getEntriesByType('navigation');
        if (entries.length > 0 && typeof entries[0].type === 'string') {
          return entries[0].type;
        }
      }
      if (performance.navigation) {
        return performance.navigation.type === 1 ? 'reload' : 'navigate';
      }
    } catch (error) {
      return null;
    }
    return null;
  }

  function processMarker() {
    if (storage === null) {
      return false;
    }
    var record = readRecord();
    var byAutoReload = false;
    if (record !== null && record.markerAt !== null &&
        navigationType() === 'reload') {
      var elapsed;
      var limit;
      if (typeof performance !== 'undefined' &&
          typeof performance.timeOrigin === 'number') {
        // 応答待ちの長さに左右されないよう、遷移を始めた時刻で比べる
        elapsed = performance.timeOrigin - record.markerAt;
        limit = cfg.markerWindowMs;
      } else {
        elapsed = Date.now() - record.markerAt;
        limit = cfg.fallbackMarkerWindowMs;
      }
      byAutoReload = elapsed >= cfg.markerLowerBoundMs && elapsed <= limit;
    }
    count = byAutoReload ? record.count + 1 : 0;
    // 目印は必ず消す。再試行ボタンによる再読込を自動再読込として数えないため
    saveRecord(null);
    return byAutoReload;
  }

  function initialState(byAutoReload) {
    if (cfg.pageKind === 'offlineFallback') {
      return cfg.offlinePageAutoReload ? 'awaitingRecovery' : null;
    }
    if (byAutoReload && cfg.continuation) {
      return 'continuation';
    }
    return cfg.gatewayTimeoutAutoReload ? 'monitoring' : null;
  }

  function restartState() {
    if (cfg.pageKind === 'offlineFallback') {
      return cfg.offlinePageAutoReload ? 'awaitingRecovery' : null;
    }
    return cfg.gatewayTimeoutAutoReload ? 'monitoring' : null;
  }

  function schedule(delay) {
    clearTimeout(timer);
    timer = setTimeout(poll, delay);
  }

  function poll() {
    if (reloaded || state === null) {
      return;
    }
    var pollGeneration = generation;
    readStatus(function (status) {
      if (pollGeneration !== generation || reloaded || state === null) {
        return;
      }
      if (status === null) {
        handleFailure();
        return;
      }
      failureCount = 0;
      handleStatus(status);
    });
  }

  function handleStatus(status) {
    var reachable = status.isUpstreamReachable === true;
    if (state === 'monitoring') {
      if (!reachable) {
        state = 'awaitingRecovery';
        reachableStreak = 0;
      }
    } else if (state === 'awaitingRecovery') {
      if (reachable) {
        reachableStreak += 1;
        if (reachableStreak >= 2) {
          state = 'awaitingQueue';
          queueWaitStartedAt = Date.now();
        }
      } else {
        reachableStreak = 0;
      }
    } else if (state === 'continuation') {
      if (reachable) {
        state = 'awaitingQueue';
        queueWaitStartedAt = Date.now();
      } else {
        state = 'awaitingRecovery';
        reachableStreak = 0;
      }
    } else if (state === 'awaitingQueue' && !reachable) {
      state = 'awaitingRecovery';
      reachableStreak = 0;
    }

    if (state === 'awaitingQueue') {
      var queueLength =
          typeof status.queueLength === 'number' ? status.queueLength : 0;
      if (queueLength === 0 ||
          Date.now() - queueWaitStartedAt >= cfg.queueWaitTimeoutMs) {
        reloadPage();
        return;
      }
    }
    schedule(cfg.pollIntervalMs);
  }

  function handleFailure() {
    failureCount += 1;
    if (state === 'awaitingQueue') {
      state = 'awaitingRecovery';
      reachableStreak = 0;
    } else if (state === 'awaitingRecovery') {
      reachableStreak = 0;
    }
    var delay = cfg.pollIntervalMs * Math.pow(2, Math.min(failureCount, 10));
    schedule(Math.min(
        delay, Math.max(cfg.maxFailureBackoffMs, cfg.pollIntervalMs)));
  }

  function reloadPage() {
    if (leavingAt !== 0 && Date.now() - leavingAt < cfg.navigationGraceMs) {
      // 遷移が終わるまで見送り、次の周期で判定し直す
      schedule(cfg.pollIntervalMs);
      return;
    }
    if (storage !== null) {
      if (count >= cfg.maxConsecutiveReloads) {
        // 上限に達したら止め、再試行ボタンだけを残す
        state = null;
        clearTimeout(timer);
        return;
      }
      saveRecord(Date.now());
    }
    reloaded = true;
    state = null;
    clearTimeout(timer);
    location.reload();
  }

  function readStatus(callback) {
    var settled = false;
    var controller =
        typeof AbortController === 'function' ? new AbortController() : null;
    var deadline = setTimeout(function () {
      if (controller !== null) {
        try {
          controller.abort();
        } catch (error) {
          // 中断に失敗しても結果は捨てる
        }
      }
      finish(null);
    }, cfg.fetchTimeoutMs);
    var options = { cache: 'no-store', credentials: 'same-origin' };
    if (controller !== null) {
      options.signal = controller.signal;
    }

    function finish(value) {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(deadline);
      callback(value);
    }

    try {
      fetch(cfg.statusPath, options).then(function (response) {
        if (!response.ok) {
          throw new Error('unexpected status');
        }
        return response.json();
      }).then(function (body) {
        var valid = body !== null && typeof body === 'object' &&
            typeof body.isUpstreamReachable === 'boolean';
        finish(valid ? body : null);
      }, function () {
        finish(null);
      });
    } catch (error) {
      finish(null);
    }
  }
})();
''';

/// 監視スクリプトを埋め込む条件を満たすかを返します。
///
/// 504 ページは、監視しない場合も連続回数を正しく戻すために目印を処理するため、
/// 自動復帰に関する設定のいずれかが有効なら埋め込みます。
///
/// [options] は監視スクリプトの設定です。
///
/// Returns: 埋め込む場合は `true`。
bool shouldEmbedOfflineRecoveryScript(OfflineRecoveryScriptOptions options) {
  if (options.statusPath.isEmpty) {
    return false;
  }

  switch (options.pageKind) {
    case OfflineRecoveryPageKind.offlineFallback:
      return options.offlinePageAutoReload;
    case OfflineRecoveryPageKind.gatewayTimeout:
      return options.offlinePageAutoReload ||
          options.continuation ||
          options.gatewayTimeoutAutoReload;
  }
}

/// 監視スクリプトの `<script>` 要素を組み立てます。
///
/// 通常のインラインスクリプトとして組み立て、`type="module"` や `defer` は
/// 付けません。実行時の `document.readyState` で起動するかを判定するためです。
///
/// [options] は監視スクリプトの設定です。
///
/// Returns: `<script>` 要素の文字列。
String buildOfflineRecoveryScript(OfflineRecoveryScriptOptions options) {
  // 検証を通らない経路でも、間隔 0 で要求し続けないよう下限で丸める
  final pollIntervalMs = max(
    options.pollInterval.inMilliseconds,
    offlineRecoveryMinimumPollInterval.inMilliseconds,
  );
  final config = <String, Object>{
    'pageKind': options.pageKind.name,
    'statusPath': options.statusPath,
    'pollIntervalMs': pollIntervalMs,
    'fetchTimeoutMs': max(pollIntervalMs, _minimumFetchTimeout.inMilliseconds),
    'queueWaitTimeoutMs': options.queueWaitTimeout.inMilliseconds,
    'continuationWaitMs': _continuationWait.inMilliseconds,
    'maxConsecutiveReloads': _maxConsecutiveAutoReloads,
    'markerWindowMs': _markerWindow.inMilliseconds,
    'markerLowerBoundMs': _markerLowerBound.inMilliseconds,
    'fallbackMarkerWindowMs':
        (options.requestTimeout + _fallbackMarkerMargin).inMilliseconds,
    'navigationGraceMs':
        (options.requestTimeout + _fallbackMarkerMargin).inMilliseconds,
    'maxFailureBackoffMs': _maxFailureBackoff.inMilliseconds,
    'staleRecordAgeMs': _staleRecordAge.inMilliseconds,
    'offlinePageAutoReload': options.offlinePageAutoReload,
    'continuation': options.continuation,
    'gatewayTimeoutAutoReload': options.gatewayTimeoutAutoReload,
  };

  final source = _recoveryScriptSource.replaceFirst(
    _configToken,
    encodeOfflineRecoveryScriptValue(config),
  );
  return '<script data-offline-web-proxy="recovery">$source</script>';
}

/// スクリプトへ埋め込む値を JSON にします。
///
/// `jsonEncode` の結果に含まれる `<` と行区切り文字を JavaScript の Unicode
/// エスケープへ置き換え、値の中の閉じタグでスクリプトが終わらないようにします。
///
/// [value] は埋め込む値です。
///
/// Returns: `<script>` 要素の中へそのまま書ける JSON 文字列。
String encodeOfflineRecoveryScriptValue(Object value) {
  // エスケープの先頭に付けるバックスラッシュ
  final backslash = String.fromCharCode(0x5C);
  return jsonEncode(value)
      .replaceAll('<', '${backslash}u003c')
      .replaceAll(String.fromCharCode(0x2028), '${backslash}u2028')
      .replaceAll(String.fromCharCode(0x2029), '${backslash}u2029');
}

/// 既定のページの HTML を組み立てます。
///
/// 再試行ボタンは、監視スクリプトの有無に関係なく置きます。
///
/// [options] は監視スクリプトの設定です。
///
/// Returns: ページ全体の HTML。
String buildDefaultOfflineRecoveryPage(OfflineRecoveryScriptOptions options) {
  final embedsScript = shouldEmbedOfflineRecoveryScript(options);
  final buffer = StringBuffer()
    ..writeln('<!DOCTYPE html>')
    ..writeln('<html lang="ja">')
    ..writeln('<head>')
    ..writeln('<meta charset="utf-8">')
    ..writeln(
      '<meta name="viewport" content="width=device-width, initial-scale=1">',
    );

  switch (options.pageKind) {
    case OfflineRecoveryPageKind.offlineFallback:
      buffer
        ..writeln('<title>オフライン</title>')
        ..writeln('</head>')
        ..writeln('<body>')
        ..writeln('<h1>オフライン中です</h1>')
        ..writeln('<p>現在オフラインのため、リクエストされたコンテンツを表示できません。</p>')
        ..writeln('<p>インターネット接続を確認してから再試行してください。</p>');
      if (embedsScript) {
        buffer.writeln('<p>接続が戻ると自動で再読み込みします。</p>');
      }
    case OfflineRecoveryPageKind.gatewayTimeout:
      buffer
        ..writeln('<title>タイムアウト</title>')
        ..writeln('</head>')
        ..writeln('<body>')
        ..writeln('<h1>上流サーバがタイムアウトしました</h1>')
        ..writeln('<p>時間をおいて再試行してください。</p>');
  }

  buffer.writeln(
    '<button type="button" onclick="location.reload()">再試行</button>',
  );
  if (embedsScript) {
    buffer.writeln(buildOfflineRecoveryScript(options));
  }
  buffer
    ..writeln('</body>')
    ..writeln('</html>');
  return buffer.toString();
}

/// 差し替え HTML の目印を監視スクリプトへ置き換えます。
///
/// 監視スクリプトは最初の目印にだけ入れ、残りの目印は空文字列へ置き換えます。
/// 同じページで複数のスクリプトが動くと、連続回数の記録を互いに打ち消すためです。
/// 埋め込む条件を満たさない場合は、すべての目印を空文字列へ置き換えます。
/// 目印が無い HTML はそのまま返します。
///
/// [html] は差し替え HTML です。
/// [options] は監視スクリプトの設定です。
///
/// Returns: 目印を置き換えた HTML。
String applyOfflineRecoveryPlaceholder(
  String html,
  OfflineRecoveryScriptOptions options,
) {
  const placeholder = ProxyConfig.recoveryScriptPlaceholder;
  final firstIndex = html.indexOf(placeholder);
  if (firstIndex < 0) {
    return html;
  }

  final replacement = shouldEmbedOfflineRecoveryScript(options)
      ? buildOfflineRecoveryScript(options)
      : '';
  final rest = html.substring(firstIndex + placeholder.length);
  return '${html.substring(0, firstIndex)}$replacement'
      '${rest.replaceAll(placeholder, '')}';
}
