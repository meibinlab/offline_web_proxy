// オフライン代替ページの監視スクリプトを、ヘッドレス Chrome で動かして確かめる回帰テスト。
//
// generate_pages.dart が書き出したページを、状態通知の応答をシナリオごとに切り替える
// ローカルサーバから配信し、再読込の有無と、再読込までに読んだ状態通知の件数を検証する。
// 件数と観察時間は、ページに埋め込まれたスクリプトの設定値から計算する。
// シナリオ内の時刻は、ブラウザが最初にページを取得した時点からの経過ミリ秒で表す。
//
// 使い方: node run.mjs <ページのディレクトリ> [シナリオ名...]
// ブラウザは環境変数 CHROME_PATH を優先し、指定が無ければ標準のインストール先から探す。
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/** 状態通知のパス。generate_pages.dart の設定と合わせる。 */
const STATUS_PATH = '/__offline_web_proxy/status';

/** 監視スクリプトを含むページのパス。再読込もこのパスへの要求として数える。 */
const PAGE_PATH = '/page';

/** 応答を遅らせる遷移先のパス。 */
const SLOW_PATH = '/slow';

/** SLOW_PATH への応答を遅らせる時間（ミリ秒）。 */
const SLOW_RESPONSE_DELAY_MS = 4000;

/**
 * offline_with_link のページが、表示からリンクを押すまでの時間（ミリ秒）。
 *
 * generate_pages.dart が書き出すページの値と合わせる。
 */
const LINK_CLICK_DELAY_MS = 300;

/** 遷移の途中で、再読込を見送ったことを確かめる読み取りの回数。 */
const MINIMUM_DEFERRED_READS = 2;

/**
 * 代替ページが再読込するまでに、到達できる状態を続けて読む回数。
 *
 * 仕様（doc/specs.ja.md の「代替ページの自動復帰」）で決まっている値で、
 * スクリプトの設定値には含まれない。
 */
const REQUIRED_REACHABLE_READS = 2;

/** 取得の失敗が続く場合に、スクリプトが間隔を倍にする回数の上限。実装と合わせる。 */
const FAILURE_BACKOFF_EXPONENT_LIMIT = 10;

/** ブラウザが最初のページを取得するまで待つ上限（ミリ秒）。 */
const STARTUP_TIMEOUT_MS = 30000;

/** ブラウザの終了を待つ上限（ミリ秒）。 */
const SHUTDOWN_TIMEOUT_MS = 5000;

/** 使い方の誤りや、ページ・ブラウザが見つからない場合の終了コード。 */
const EXIT_CODE_SETUP_ERROR = 2;

/** 生成したページから、スクリプトに埋め込まれた設定値を取り出す正規表現。 */
const SCRIPT_CONFIG_PATTERN = /var cfg = (\{[^\n]*?\});/;

/** 判定の計算に使う、スクリプトの設定値の項目。 */
const REQUIRED_CONFIG_FIELDS = [
  'pollIntervalMs',
  'queueWaitTimeoutMs',
  'continuationWaitMs',
  'maxConsecutiveReloads',
  'maxFailureBackoffMs',
];

/** 遷移先として配信する、監視スクリプトを含まないページの本文。 */
const REAL_HTML =
  '<!DOCTYPE html><html><head><meta charset="utf-8"><title>real</title></head>' +
  '<body><div id="msg">real</div></body></html>';

/** ブラウザの起動引数のうち、OS に関係なく付けるもの。 */
const COMMON_BROWSER_ARGUMENTS = [
  '--headless=new',
  '--disable-gpu',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-extensions',
  // 監視の周期がずれないよう、裏での通信や更新とタイマーの間引きを止める
  '--disable-background-networking',
  '--disable-background-timer-throttling',
  '--disable-backgrounding-occluded-windows',
  '--disable-renderer-backgrounding',
  '--disable-component-update',
  '--disable-breakpad',
];

/**
 * 配信するページ。
 *
 * @typedef {Object} Page
 * @property {string} name 結果の表示に使う名前。
 * @property {number} statusCode 応答のステータスコード。
 * @property {string} html 応答の本文。
 */

/**
 * 状態通知の応答。
 *
 * @typedef {Object} StatusResponse
 * @property {number} statusCode 応答のステータスコード。
 * @property {(Object|string)} body 本文。文字列はそのまま、それ以外は JSON にして返す。
 */

/**
 * サーバが受け付けた要求の記録。
 *
 * @typedef {Object} RequestEvent
 * @property {string} type 要求の種別（page、status、slow）。
 * @property {number} index 受け付けた順番（0 始まり）。
 * @property {number} t 最初のページ取得からの経過ミリ秒。
 * @property {string=} name 配信したページの名前（type が page の場合）。
 */

/**
 * ページに埋め込まれたスクリプトの設定値のうち、判定に使うもの。
 *
 * @typedef {Object} ScriptConfig
 * @property {number} pollIntervalMs 状態通知を読む間隔（ミリ秒）。
 * @property {number} queueWaitTimeoutMs 再送の完了を待つ上限時間（ミリ秒）。
 * @property {number} continuationWaitMs 継続復帰で状態通知を読み始めるまでの待ち時間（ミリ秒）。
 * @property {number} maxConsecutiveReloads 自動再読込を止める連続回数。
 * @property {number} maxFailureBackoffMs 取得の失敗が続く場合に延ばす間隔の上限（ミリ秒）。
 */

/**
 * 検証するシナリオ。
 *
 * @typedef {Object} Scenario
 * @property {string} name シナリオ名。
 * @property {!Array<!Page>} pages PAGE_PATH への要求に順に返すページ。尽きたら最後のページを返し続ける。
 * @property {function(number): !StatusResponse} status 経過ミリ秒から状態通知の応答を決める関数。
 * @property {number} durationMs 最初のページ取得から観察を続ける時間（ミリ秒）。
 * @property {function(!Array<!RequestEvent>, !Array<!RequestEvent>, !Array<!RequestEvent>): (boolean|string)} check
 *     ページの要求、状態通知の要求、すべての要求を受け取り、合格なら true、不合格なら理由を返す関数。
 */

/**
 * 準備の誤りを表示し、終了コード EXIT_CODE_SETUP_ERROR で終了する。
 *
 * @param {string} message 表示する内容。
 */
function exitWithSetupError(message) {
  console.error(message);
  process.exit(EXIT_CODE_SETUP_ERROR);
}

/**
 * generate_pages.dart が書き出したページを読み込む。
 *
 * ファイルが無い場合は、シナリオの失敗と区別できるよう準備の誤りとして終了する。
 *
 * @param {string} directory generate_pages.dart の出力先。
 * @param {string} name 拡張子を除いたファイル名。
 * @param {number} statusCode ページを返すときのステータスコード。
 * @return {!Page} 配信するページ。
 */
function loadPage(directory, name, statusCode) {
  const filePath = path.join(directory, `${name}.html`);
  if (!fs.existsSync(filePath)) {
    exitWithSetupError(
      `page not found: ${filePath}. Run generate_pages.dart first.`,
    );
  }
  return { name, statusCode, html: fs.readFileSync(filePath, 'utf8') };
}

/**
 * ページに埋め込まれたスクリプトの設定値を取り出す。
 *
 * 取り出せない場合は判定の前提が崩れているため、準備の誤りとして終了する。
 *
 * @param {!Page} page 監視スクリプトを含むページ。
 * @return {!ScriptConfig} スクリプトの設定値。
 */
function readScriptConfig(page) {
  const match = SCRIPT_CONFIG_PATTERN.exec(page.html);
  if (match === null) {
    exitWithSetupError(`script config not found in ${page.name}.html`);
  }
  let parsed;
  try {
    parsed = JSON.parse(match[1]);
  } catch (error) {
    exitWithSetupError(
      `script config in ${page.name}.html is not JSON: ${error.message}`,
    );
  }
  for (const field of REQUIRED_CONFIG_FIELDS) {
    if (typeof parsed[field] !== 'number' || !(parsed[field] > 0)) {
      exitWithSetupError(
        `script config in ${page.name}.html has no positive ${field}`,
      );
    }
  }
  return parsed;
}

/**
 * 上流へ到達できる状態の応答を作る。
 *
 * @param {number=} queueLength キューに残っている件数。
 * @return {!StatusResponse} 状態通知の応答。
 */
function reachable(queueLength = 0) {
  return {
    statusCode: 200,
    body: { isOnline: true, isUpstreamReachable: true, queueLength },
  };
}

/**
 * 上流へ到達できない状態の応答を作る。
 *
 * @param {number=} queueLength キューに残っている件数。
 * @return {!StatusResponse} 状態通知の応答。
 */
function unreachable(queueLength = 0) {
  return {
    statusCode: 200,
    body: { isOnline: false, isUpstreamReachable: false, queueLength },
  };
}

/**
 * 2 つの要求の間に受け付けた状態通知の要求を取り出す。
 *
 * 同じミリ秒に受け付けた要求の前後を取り違えないよう、時刻ではなく順番で比べる。
 *
 * @param {!Array<!RequestEvent>} statuses 状態通知の要求。
 * @param {?RequestEvent} after この要求より後のものに限る。null なら最初から。
 * @param {?RequestEvent} before この要求より前のものに限る。null なら最後まで。
 * @return {!Array<!RequestEvent>} 該当する状態通知の要求。
 */
function statusesBetween(statuses, after, before) {
  return statuses.filter(
    (event) =>
      (after === null || event.index > after.index) &&
      (before === null || event.index < before.index),
  );
}

/**
 * 観察時間内に受け付けた要求を数える。
 *
 * ブラウザを止めるまでの間に受け付けた要求を、件数に含めないために使う。
 *
 * @param {!Array<!RequestEvent>} events 要求の記録。
 * @param {number} durationMs 観察時間（ミリ秒）。
 * @return {number} 観察時間内に受け付けた要求の件数。
 */
function countWithin(events, durationMs) {
  return events.filter((event) => event.t < durationMs).length;
}

/**
 * 状態通知の取得に失敗し続けた場合に、観察時間内に読む回数を計算する。
 *
 * スクリプトは失敗のたびに間隔を倍にし、maxFailureBackoffMs で打ち止めにする。
 *
 * @param {!ScriptConfig} scriptConfig スクリプトの設定値。
 * @param {number} durationMs 観察時間（ミリ秒）。
 * @return {number} 応答の遅れが無い場合に読む回数。
 */
function countFailureReads(scriptConfig, durationMs) {
  const pollMs = scriptConfig.pollIntervalMs;
  let readAt = pollMs;
  let failures = 0;
  let reads = 0;
  while (readAt < durationMs) {
    reads += 1;
    failures += 1;
    const delay =
      pollMs * Math.pow(2, Math.min(failures, FAILURE_BACKOFF_EXPONENT_LIMIT));
    readAt += Math.min(delay, Math.max(scriptConfig.maxFailureBackoffMs, pollMs));
  }
  return reads;
}

/**
 * 不合格の理由として、ページと状態通知の要求の時刻を文字列にする。
 *
 * @param {!Array<!RequestEvent>} pages ページの要求。
 * @param {!Array<!RequestEvent>} statuses 状態通知の要求。
 * @return {string} 要求の一覧。
 */
function describeEvents(pages, statuses) {
  const pageList = pages.map((event) => `${event.name}@${event.t}`).join(',');
  const statusList = statuses.map((event) => event.t).join(',');
  return `pages=[${pageList}] statuses=[${statusList}]`;
}

/**
 * 判定の結果を返す。
 *
 * @param {boolean} passed 合格かどうか。
 * @param {!Array<!RequestEvent>} pages ページの要求。
 * @param {!Array<!RequestEvent>} statuses 状態通知の要求。
 * @return {(boolean|string)} 合格なら true、不合格なら要求の一覧。
 */
function judge(passed, pages, statuses) {
  return passed ? true : describeEvents(pages, statuses);
}

/**
 * スクリプトの設定値から、各シナリオの応答、観察時間、判定を組み立てる。
 *
 * @param {string} directory generate_pages.dart の出力先。
 * @param {!ScriptConfig} scriptConfig スクリプトの設定値。
 * @return {!Array<!Scenario>} 実行する順に並べたシナリオ。
 */
function buildScenarios(directory, scriptConfig) {
  const pollMs = scriptConfig.pollIntervalMs;
  const queueWaitMs = scriptConfig.queueWaitTimeoutMs;
  const continuationWaitMs = scriptConfig.continuationWaitMs;
  const maxReloads = scriptConfig.maxConsecutiveReloads;

  // 遷移のシナリオは、リンクを押した後に再読込の条件を満たし、遷移が終わる前に
  // 見送りを MINIMUM_DEFERRED_READS 回確かめられることを前提にする
  if (
    pollMs * REQUIRED_REACHABLE_READS <= LINK_CLICK_DELAY_MS ||
    pollMs * (REQUIRED_REACHABLE_READS + MINIMUM_DEFERRED_READS + 1) >=
      LINK_CLICK_DELAY_MS + SLOW_RESPONSE_DELAY_MS
  ) {
    exitWithSetupError(
      `pollIntervalMs ${pollMs} does not fit navigation_in_progress_is_not_cancelled`,
    );
  }

  const offline = loadPage(directory, 'offline', 200);
  const gateway = loadPage(directory, 'gateway', 504);
  const gatewayMonitor = loadPage(directory, 'gateway_monitor', 504);
  const gatewayNoContinuation = loadPage(
    directory,
    'gateway_no_continuation',
    504,
  );
  const offlineDouble = loadPage(directory, 'offline_double', 200);
  const gatewayDouble = loadPage(directory, 'gateway_double', 504);
  const offlineWithLink = loadPage(directory, 'offline_with_link', 200);
  const insertedAfterLoad = loadPage(directory, 'inserted_after_load', 200);
  const inlineExtractedSource = loadPage(
    directory,
    'inline_extracted_source',
    200,
  );
  const real = { name: 'real', statusCode: 200, html: REAL_HTML };

  // 状態通知が、到達できない状態から到達できる状態へ切り替わる時刻（ミリ秒）
  const offlineRecoveryAt = pollMs * 6;
  const queueRecoveryAt = pollMs * 3;
  const continuationRecoveryAt = pollMs * 2;
  // 監視を有効にした 504 ページへ、到達できない状態を返す期間（ミリ秒）
  const monitorOutageStartAt = pollMs * 5;
  const monitorOutageEndAt = pollMs * 9;
  // 到達できる状態に戻ってから、再送待ちの上限を過ぎて再読込するまでに読む回数の上限
  // （応答が遅れて読み取りの間隔が延びると、これより少なくなる）
  const queueWaitReads =
    REQUIRED_REACHABLE_READS + Math.ceil(queueWaitMs / pollMs);
  // 上限までの自動再読込をすべて観察し、上限を越えた再読込も捉えられる時間（ミリ秒）
  const reloadLimitDurationMs =
    pollMs * REQUIRED_REACHABLE_READS +
    (continuationWaitMs + pollMs) * maxReloads +
    continuationWaitMs / 2;
  const failureDurationMs = pollMs * 16;
  const malformedDurationMs = pollMs * 10;
  const pollingDurationMs = pollMs * 10;
  const steadyDurationMs = pollMs * 12;

  /**
   * 取得の失敗として扱われ、再読込せずに間隔を広げながら読み続けたかを判定する。
   *
   * @param {!Array<!RequestEvent>} pages ページの要求。
   * @param {!Array<!RequestEvent>} statuses 状態通知の要求。
   * @param {number} durationMs 観察時間（ミリ秒）。
   * @return {(boolean|string)} 合格なら true、不合格なら要求の一覧。
   */
  function checkFailureBackoff(pages, statuses, durationMs) {
    const expectedReads = countFailureReads(scriptConfig, durationMs);
    const reads = countWithin(statuses, durationMs);
    // 応答の遅れで、観察時間の終わりの読み取りが 1 回ずれ込み得る
    return judge(
      pages.length === 1 &&
        reads >= expectedReads - 1 &&
        reads <= expectedReads,
      pages,
      statuses,
    );
  }

  /**
   * 自動再読込が、連続回数の上限で止まったかを判定する。
   *
   * 代替ページは到達できる状態を REQUIRED_REACHABLE_READS 回読んで再読込し、
   * 自動再読込の結果の 504 ページは継続復帰の待ちの後に 1 回読んで再読込する。
   * 上限に達したページは、1 回読んだ後に止まる。
   *
   * @param {!Array<!RequestEvent>} pages ページの要求。
   * @param {!Array<!RequestEvent>} statuses 状態通知の要求。
   * @return {(boolean|string)} 合格なら true、不合格なら要求の一覧。
   */
  function checkReloadLimit(pages, statuses) {
    if (pages.length !== maxReloads + 1) {
      return describeEvents(pages, statuses);
    }
    if (
      statusesBetween(statuses, pages[0], pages[1]).length !==
      REQUIRED_REACHABLE_READS
    ) {
      return describeEvents(pages, statuses);
    }
    for (let index = 1; index < maxReloads; index += 1) {
      if (statusesBetween(statuses, pages[index], pages[index + 1]).length !== 1) {
        return describeEvents(pages, statuses);
      }
    }
    const lastPage = pages[maxReloads];
    const lastReads = statusesBetween(statuses, lastPage, null);
    return judge(
      lastReads.length === 1 && lastReads[0].t - lastPage.t >= continuationWaitMs,
      pages,
      statuses,
    );
  }

  return [
    {
      // 到達できる状態を REQUIRED_REACHABLE_READS 回続けて読んでから再読込する
      name: 'offline_reload_after_two_reachable_reads',
      pages: [offline, real],
      status: (t) => (t < offlineRecoveryAt ? unreachable() : reachable()),
      durationMs: offlineRecoveryAt + pollMs * 12,
      check: (pages, statuses) => {
        if (pages.length !== 2) {
          return describeEvents(pages, statuses);
        }
        const readsBeforeReload = statusesBetween(statuses, pages[0], pages[1]);
        const outageReads = readsBeforeReload.filter(
          (event) => event.t < offlineRecoveryAt,
        ).length;
        return judge(
          outageReads >= 1 &&
            readsBeforeReload.length - outageReads === REQUIRED_REACHABLE_READS,
          pages,
          statuses,
        );
      },
    },
    {
      // キューが空にならなくても、再送待ちの上限を過ぎた読み取りで再読込する
      name: 'queue_wait_timeout',
      pages: [offline, real],
      status: (t) => (t < queueRecoveryAt ? unreachable(1) : reachable(1)),
      durationMs: queueRecoveryAt + queueWaitMs + pollMs * 10,
      check: (pages, statuses) => {
        if (pages.length !== 2) {
          return describeEvents(pages, statuses);
        }
        const recoveredReads = statusesBetween(
          statuses,
          pages[0],
          pages[1],
        ).filter((event) => event.t >= queueRecoveryAt);
        if (recoveredReads.length < REQUIRED_REACHABLE_READS) {
          return describeEvents(pages, statuses);
        }
        // 再送待ちは REQUIRED_REACHABLE_READS 回目の読み取りの応答を受けてから数えるため、
        // 再読込の要求は、その読み取りの要求から上限時間以上後に届く
        const queueWaitStart = recoveredReads[REQUIRED_REACHABLE_READS - 1];
        return judge(
          pages[1].t - queueWaitStart.t >= queueWaitMs &&
            recoveredReads.length <= queueWaitReads,
          pages,
          statuses,
        );
      },
    },
    {
      // 状態を取得できない間は再読込せず、取得の間隔を広げる
      name: 'status_failure_does_not_reload',
      pages: [offline, real],
      status: () => ({ statusCode: 500, body: {} }),
      durationMs: failureDurationMs,
      check: (pages, statuses) =>
        checkFailureBackoff(pages, statuses, failureDurationMs),
    },
    {
      // JSON として読めない本文は、取得の失敗として扱う
      name: 'status_body_not_json_is_failure',
      pages: [offline, real],
      status: () => ({ statusCode: 200, body: 'not json' }),
      durationMs: malformedDurationMs,
      check: (pages, statuses) =>
        checkFailureBackoff(pages, statuses, malformedDurationMs),
    },
    {
      // isUpstreamReachable が真偽値でない本文は、到達できる状態とも到達できない
      // 状態とも扱わず、取得の失敗として扱う
      name: 'status_non_boolean_reachable_is_failure',
      pages: [offline, real],
      status: () => ({
        statusCode: 200,
        body: { isOnline: true, isUpstreamReachable: 'true', queueLength: 0 },
      }),
      durationMs: malformedDurationMs,
      check: (pages, statuses) =>
        checkFailureBackoff(pages, statuses, malformedDurationMs),
    },
    {
      // 自動再読込の結果の 504 ページは、継続復帰の待ちの後に 1 回読んで再読込する
      name: 'continuation_after_gateway_timeout',
      pages: [offline, gateway, real],
      status: (t) => (t < continuationRecoveryAt ? unreachable() : reachable()),
      durationMs: continuationWaitMs + pollMs * 24,
      check: (pages, statuses) => {
        if (pages.length !== 3 || pages[1].name !== gateway.name) {
          return describeEvents(pages, statuses);
        }
        const offlineReads = statusesBetween(statuses, pages[0], pages[1]).filter(
          (event) => event.t >= continuationRecoveryAt,
        ).length;
        const gatewayReads = statusesBetween(statuses, pages[1], pages[2]);
        const waitedMs =
          gatewayReads.length === 1 ? gatewayReads[0].t - pages[1].t : -1;
        return judge(
          offlineReads === REQUIRED_REACHABLE_READS &&
            waitedMs >= continuationWaitMs &&
            waitedMs < continuationWaitMs + pollMs * 2,
          pages,
          statuses,
        );
      },
    },
    {
      // 504 ページに着いた自動再読込が上限の回数続くと止まる
      name: 'consecutive_reload_limit',
      pages: [offline, gateway],
      status: () => reachable(),
      durationMs: reloadLimitDurationMs,
      check: checkReloadLimit,
    },
    {
      // 同じスクリプトを 2 つ埋め込んでも、読み取りの回数と連続回数の上限は
      // 1 つの場合と変わらない
      name: 'double_script_keeps_consecutive_limit',
      pages: [offlineDouble, gatewayDouble],
      status: () => reachable(),
      durationMs: reloadLimitDurationMs,
      check: checkReloadLimit,
    },
    {
      // 同じスクリプトを 2 つ埋め込んでも、状態の取得は 1 周期に 1 回だけ
      name: 'double_script_polls_once_per_interval',
      pages: [offlineDouble],
      status: () => unreachable(),
      durationMs: pollingDurationMs,
      check: (pages, statuses) => {
        const maxReads = Math.floor(pollingDurationMs / pollMs);
        const reads = countWithin(statuses, pollingDurationMs);
        // 二重に動くと上限のおよそ 2 倍になる。下限は応答の遅れを見込んで半分にする
        return judge(
          pages.length === 1 &&
            reads > Math.floor(maxReads / 2) &&
            reads <= maxReads,
          pages,
          statuses,
        );
      },
    },
    {
      // 継続復帰を無効にすると、自動再読込の結果の 504 ページは状態を読まない
      name: 'continuation_disabled',
      pages: [offline, gatewayNoContinuation, real],
      status: () => reachable(),
      durationMs: pollMs * REQUIRED_REACHABLE_READS + continuationWaitMs * 1.5,
      check: (pages, statuses) =>
        judge(
          pages.length === 2 &&
            statusesBetween(statuses, pages[0], pages[1]).length ===
              REQUIRED_REACHABLE_READS &&
            statusesBetween(statuses, pages[1], null).length === 0,
          pages,
          statuses,
        ),
    },
    {
      // 既定の 504 ページは状態を読まない
      name: 'gateway_default_does_not_monitor',
      pages: [gateway, real],
      status: () => reachable(),
      durationMs: pollMs * 10,
      check: (pages, statuses) =>
        judge(pages.length === 1 && statuses.length === 0, pages, statuses),
    },
    {
      // 監視を有効にした 504 ページは、到達できない状態からの復帰で再読込する
      name: 'gateway_monitor_reloads_after_transition',
      pages: [gatewayMonitor, real],
      status: (t) =>
        t < monitorOutageStartAt || t >= monitorOutageEndAt
          ? reachable()
          : unreachable(),
      durationMs: monitorOutageEndAt + pollMs * 9,
      check: (pages, statuses) => {
        if (pages.length !== 2) {
          return describeEvents(pages, statuses);
        }
        const readsBeforeReload = statusesBetween(statuses, pages[0], pages[1]);
        const steadyReads = readsBeforeReload.filter(
          (event) => event.t < monitorOutageStartAt,
        ).length;
        const recoveredReads = readsBeforeReload.filter(
          (event) => event.t >= monitorOutageEndAt,
        ).length;
        const outageReads =
          readsBeforeReload.length - steadyReads - recoveredReads;
        return judge(
          steadyReads >= 1 &&
            outageReads >= 1 &&
            recoveredReads === REQUIRED_REACHABLE_READS,
          pages,
          statuses,
        );
      },
    },
    {
      // 監視を有効にした 504 ページは、到達できる状態が続くだけでは再読込せず、読み続ける
      name: 'gateway_monitor_ignores_steady_reachable',
      pages: [gatewayMonitor, real],
      status: () => reachable(),
      durationMs: steadyDurationMs,
      check: (pages, statuses) => {
        const maxReads = Math.floor(steadyDurationMs / pollMs);
        return judge(
          pages.length === 1 &&
            countWithin(statuses, steadyDurationMs) > Math.floor(maxReads / 2),
          pages,
          statuses,
        );
      },
    },
    {
      // 読み込みの完了後に挿入されたスクリプトは動かない
      name: 'script_inserted_after_load_stays_inactive',
      pages: [insertedAfterLoad, real],
      status: () => reachable(),
      durationMs: pollMs * 8,
      check: (pages, statuses) =>
        judge(pages.length === 1 && statuses.length === 0, pages, statuses),
    },
    {
      // 対照: 挿入に使うのと同じソースを読み込み中に実行すると、動いて再読込する
      name: 'extracted_source_runs_while_loading',
      pages: [inlineExtractedSource, real],
      status: () => reachable(),
      durationMs: pollMs * 12,
      check: (pages, statuses) =>
        judge(
          pages.length === 2 &&
            statusesBetween(statuses, pages[0], pages[1]).length ===
              REQUIRED_REACHABLE_READS,
          pages,
          statuses,
        ),
    },
    {
      // 画面から始まった遷移を再読込で打ち消さず、見送りながら次の周期で判定し直す
      name: 'navigation_in_progress_is_not_cancelled',
      pages: [offlineWithLink, real],
      status: () => reachable(),
      durationMs: LINK_CLICK_DELAY_MS + SLOW_RESPONSE_DELAY_MS + pollMs * 8,
      check: (pages, statuses, events) => {
        const slowRequests = events.filter((event) => event.type === 'slow');
        return judge(
          pages.length === 1 &&
            slowRequests.length === 1 &&
            statuses.length >= REQUIRED_REACHABLE_READS + MINIMUM_DEFERRED_READS,
          pages,
          statuses,
        );
      },
    },
  ];
}

/**
 * 実行している OS での、ブラウザの標準のインストール先を列挙する。
 *
 * @return {!Array<string>} 優先する順に並べた実行ファイルのパス。
 */
function listBrowserCandidates() {
  switch (process.platform) {
    case 'win32': {
      const roots = [
        process.env['ProgramFiles'],
        process.env['ProgramFiles(x86)'],
        process.env['LOCALAPPDATA'],
      ].filter(Boolean);
      return [
        ...roots.map((root) =>
          path.join(root, 'Google', 'Chrome', 'Application', 'chrome.exe'),
        ),
        ...roots.map((root) =>
          path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
        ),
      ];
    }
    case 'darwin':
      return [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      ];
    default:
      return [
        '/usr/bin/google-chrome',
        '/usr/bin/google-chrome-stable',
        '/usr/bin/chromium',
        '/usr/bin/chromium-browser',
        '/snap/bin/chromium',
        '/usr/bin/microsoft-edge',
      ];
  }
}

/**
 * 使うブラウザの実行ファイルを決める。
 *
 * @return {string|undefined} 実行ファイルのパス。見つからない場合は undefined。
 */
function findBrowser() {
  const configuredPath = process.env['CHROME_PATH'];
  if (configuredPath) {
    return fs.existsSync(configuredPath) ? configuredPath : undefined;
  }
  return listBrowserCandidates().find((candidate) => fs.existsSync(candidate));
}

/**
 * ブラウザの起動引数を作る。
 *
 * @param {string} userDataDirectory シナリオごとに作るプロファイルのディレクトリ。
 * @param {string} url 最初に開く URL。
 * @return {!Array<string>} 起動引数。
 */
function buildBrowserArguments(userDataDirectory, url) {
  const browserArguments = [
    ...COMMON_BROWSER_ARGUMENTS,
    `--user-data-dir=${userDataDirectory}`,
  ];
  if (process.platform === 'linux') {
    // CI のランナーやコンテナでは、名前空間を使うサンドボックスを作れない場合がある。
    // 開くのはこのハーネスが配信するページだけのため、サンドボックスを外す
    browserArguments.push('--no-sandbox');
  }
  browserArguments.push(url);
  return browserArguments;
}

/**
 * Promise が上限時間までに解決するかを待つ。
 *
 * @param {!Promise<*>} promise 待つ Promise。
 * @param {number} timeoutMs 待つ上限（ミリ秒）。
 * @return {!Promise<boolean>} 上限時間までに解決した場合は true。
 */
async function settlesWithin(promise, timeoutMs) {
  let timer;
  const timedOut = new Promise((resolve) => {
    timer = setTimeout(() => resolve(false), timeoutMs);
  });
  try {
    return await Promise.race([promise.then(() => true), timedOut]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 指定した時間だけ待つ。
 *
 * @param {number} durationMs 待つ時間（ミリ秒）。
 * @return {!Promise<void>} 時間が経つと解決する Promise。
 */
function sleep(durationMs) {
  return new Promise((resolve) => setTimeout(resolve, durationMs));
}

/**
 * ブラウザを子プロセスごと終了させ、終了を待つ。
 *
 * 終了させられなかった場合は、子プロセスが残った手掛かりとして警告を出す。
 *
 * @param {!import('node:child_process').ChildProcess} browser ブラウザのプロセス。
 * @param {!Promise<void>} exited ブラウザの終了で解決する Promise。
 * @return {!Promise<void>} 終了したか、待つ上限を過ぎると解決する Promise。
 */
async function stopBrowser(browser, exited) {
  if (browser.pid === undefined) {
    return;
  }
  let killFailure = null;
  if (process.platform === 'win32') {
    if (browser.exitCode === null && browser.signalCode === null) {
      const result = spawnSync(
        'taskkill',
        ['/pid', String(browser.pid), '/T', '/F'],
        { stdio: 'ignore' },
      );
      // taskkill は、ブラウザが終了した場合でも 0 以外を返すことがあるため、
      // 結果は終了を待てなかったときの警告に添える
      if (result.error || result.status !== 0) {
        killFailure = result.error
          ? result.error.message
          : `taskkill status ${result.status}`;
      }
    }
  } else {
    // 本体が先に終了していても、同じプロセスグループの子プロセスを終了させる
    try {
      process.kill(-browser.pid, 'SIGKILL');
    } catch (error) {
      if (error.code !== 'ESRCH') {
        throw error;
      }
    }
  }
  if (!(await settlesWithin(exited, SHUTDOWN_TIMEOUT_MS))) {
    console.warn(
      `warning: browser (pid ${browser.pid}) did not exit within ${SHUTDOWN_TIMEOUT_MS} ms` +
        (killFailure === null ? '' : ` (${killFailure})`),
    );
  }
}

/**
 * シナリオを 1 つ実行する。
 *
 * @param {!Scenario} scenario 実行するシナリオ。
 * @param {string} browserPath ブラウザの実行ファイルのパス。
 * @return {!Promise<{ok: boolean, detail: (boolean|string), pages: !Array<!RequestEvent>, statusCount: number}>}
 *     判定結果と、ページの要求、状態通知の要求の件数。
 */
async function runScenario(scenario, browserPath) {
  /** @type {!Array<!RequestEvent>} */
  const events = [];
  const pendingTimers = new Set();
  let firstPageAt = null;
  let notifyFirstPage = () => {};
  const firstPageRequested = new Promise((resolve) => {
    notifyFirstPage = resolve;
  });
  let pageIndex = 0;

  const server = http.createServer((request, response) => {
    const url = request.url ?? '';
    if (url.startsWith(PAGE_PATH) && firstPageAt === null) {
      firstPageAt = Date.now();
      notifyFirstPage();
    }
    const t = firstPageAt === null ? 0 : Date.now() - firstPageAt;

    if (url.startsWith(STATUS_PATH)) {
      events.push({ type: 'status', index: events.length, t });
      const result = scenario.status(t);
      response.writeHead(result.statusCode, {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
      });
      response.end(
        typeof result.body === 'string'
          ? result.body
          : JSON.stringify(result.body),
      );
      return;
    }
    if (url.startsWith(SLOW_PATH)) {
      events.push({ type: 'slow', index: events.length, t });
      const timer = setTimeout(() => {
        pendingTimers.delete(timer);
        response.writeHead(200, {
          'Content-Type': 'text/html; charset=utf-8',
          'Cache-Control': 'no-store',
        });
        response.end(REAL_HTML);
      }, SLOW_RESPONSE_DELAY_MS);
      pendingTimers.add(timer);
      return;
    }
    if (url.startsWith(PAGE_PATH)) {
      const page =
        scenario.pages[Math.min(pageIndex, scenario.pages.length - 1)];
      pageIndex += 1;
      events.push({ type: 'page', index: events.length, t, name: page.name });
      response.writeHead(page.statusCode, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
      });
      response.end(page.html);
      return;
    }
    response.writeHead(404);
    response.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  const userDataDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), 'owp-harness-'),
  );
  const browser = spawn(
    browserPath,
    buildBrowserArguments(
      userDataDirectory,
      `http://127.0.0.1:${port}${PAGE_PATH}`,
    ),
    {
      stdio: 'ignore',
      // Windows 以外では、子プロセスごと終了できるようプロセスグループを分ける
      detached: process.platform !== 'win32',
    },
  );
  let launchError = null;
  let stopping = false;
  let unexpectedExit = null;
  const exited = new Promise((resolve) => {
    browser.once('exit', (code, signal) => {
      if (!stopping) {
        unexpectedExit = `code=${code} signal=${signal}`;
      }
      resolve();
    });
    browser.once('error', (error) => {
      launchError = error;
      resolve();
    });
  });

  const started =
    (await settlesWithin(
      Promise.race([firstPageRequested, exited]),
      STARTUP_TIMEOUT_MS,
    )) && firstPageAt !== null;
  if (started) {
    await sleep(scenario.durationMs);
  }

  stopping = true;
  await stopBrowser(browser, exited);
  for (const timer of pendingTimers) {
    clearTimeout(timer);
  }
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
  try {
    fs.rmSync(userDataDirectory, {
      recursive: true,
      force: true,
      maxRetries: 3,
      retryDelay: 200,
    });
  } catch (error) {
    // 判定には影響しないため、警告だけ出して続ける
    console.warn(
      `warning: could not remove ${userDataDirectory}: ${error.message}`,
    );
  }

  const pages = events.filter((event) => event.type === 'page');
  const statuses = events.filter((event) => event.type === 'status');
  let detail;
  if (launchError !== null) {
    detail = `browser could not be started: ${launchError.message}`;
  } else if (!started) {
    detail = unexpectedExit
      ? `browser exited before requesting the page (${unexpectedExit})`
      : `browser did not request the page within ${STARTUP_TIMEOUT_MS} ms`;
  } else if (unexpectedExit !== null) {
    detail = `browser exited during the scenario (${unexpectedExit})`;
  } else {
    detail = scenario.check(pages, statuses, events);
  }
  return {
    ok: detail === true,
    detail,
    pages,
    statusCount: statuses.length,
  };
}

const [pagesDirectory, ...selectedScenarioNames] = process.argv.slice(2);
if (!pagesDirectory || !fs.existsSync(pagesDirectory)) {
  exitWithSetupError('usage: node run.mjs <pages directory> [scenario name...]');
}
const scriptConfig = readScriptConfig(loadPage(pagesDirectory, 'offline', 200));
const scenarios = buildScenarios(pagesDirectory, scriptConfig);
const unknownScenarioNames = selectedScenarioNames.filter(
  (name) => !scenarios.some((scenario) => scenario.name === name),
);
if (unknownScenarioNames.length > 0) {
  exitWithSetupError(`unknown scenario: ${unknownScenarioNames.join(', ')}`);
}
const browserPath = findBrowser();
if (!browserPath) {
  exitWithSetupError(
    process.env['CHROME_PATH']
      ? `CHROME_PATH does not exist: ${process.env['CHROME_PATH']}`
      : 'browser not found. Set CHROME_PATH to a Chrome, Chromium, or Edge executable.',
  );
}

console.log(`browser=${browserPath}`);
console.log(
  `pollIntervalMs=${scriptConfig.pollIntervalMs} ` +
    `queueWaitTimeoutMs=${scriptConfig.queueWaitTimeoutMs} ` +
    `continuationWaitMs=${scriptConfig.continuationWaitMs} ` +
    `maxConsecutiveReloads=${scriptConfig.maxConsecutiveReloads}`,
);
let passedCount = 0;
let failedCount = 0;
for (const scenario of scenarios) {
  if (
    selectedScenarioNames.length > 0 &&
    !selectedScenarioNames.includes(scenario.name)
  ) {
    continue;
  }
  const result = await runScenario(scenario, browserPath);
  if (result.ok) {
    passedCount += 1;
  } else {
    failedCount += 1;
  }
  const pageSummary = result.pages
    .map((event) => `${event.name}@${event.t}`)
    .join(',');
  console.log(
    `${result.ok ? 'PASS' : 'FAIL'} ${scenario.name} pages=${pageSummary} ` +
      `statuses=${result.statusCount}` +
      (result.ok ? '' : ` detail=${result.detail}`),
  );
}
console.log(`${passedCount} passed, ${failedCount} failed`);
process.exit(failedCount === 0 ? 0 : 1);
