import 'dart:io';

import 'package:offline_web_proxy/src/pages/offline_recovery_page.dart';

/// 状態通知のパス。`run.mjs` のサーバもこのパスで状態を返す。
const String _statusPath = '/__offline_web_proxy/status';

/// 監視スクリプトの要素の開始タグ。実装が組み立てる要素と合わせる。
const String _scriptOpenTag = '<script data-offline-web-proxy="recovery">';

/// 監視スクリプトの要素の終了タグ。
const String _scriptCloseTag = '</script>';

/// 表示からリンクを押すまでの時間（ミリ秒）。
///
/// `run.mjs` の `LINK_CLICK_DELAY_MS` と合わせる。
const int _linkClickDelayMs = 300;

/// 監視スクリプトの回帰テスト（`run.mjs`）が読み込むページを書き出す。
///
/// 実装が生成する既定の代替ページと `504` ページに加え、次のページを出力する。
///
/// - 同じスクリプトを 2 つ含むページ（二重起動の防止の確認用）
/// - 表示の直後にリンクで遷移するページ（遷移を打ち消さないことの確認用）
/// - 読み込みの完了後にスクリプトを挿入するページと、同じソースを読み込み中に
///   実行する対照ページ
///
/// `run.mjs` は、ページに埋め込まれた設定値から判定の件数と観察時間を計算する。
///
/// 使い方:
/// `dart run tool/offline_recovery_harness/generate_pages.dart <出力先>`
///
/// [args] はコマンドライン引数です。出力先のディレクトリを 1 つだけ指定します。
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'usage: dart run tool/offline_recovery_harness/generate_pages.dart '
      '<output directory>',
    );
    exitCode = 64;
    return;
  }
  // 組み立ての途中で失敗したときに新旧のページが混在しないよう、
  // すべて組み立ててから書き出す
  final pages = _buildPages();
  final outputDirectory = Directory(args.single)..createSync(recursive: true);
  pages.forEach((name, html) {
    File('${outputDirectory.path}/$name.html').writeAsStringSync(html);
  });
  stdout.writeln('generated ${pages.length} pages in ${outputDirectory.path}');
}

/// 回帰テストが読み込むページをすべて組み立てる。
///
/// Returns: 拡張子を除いたファイル名と、そのページの HTML の組。
///
/// Throws: 監視スクリプトの要素の形が想定と違う場合は [StateError]。
Map<String, String> _buildPages() {
  final offline = buildDefaultOfflineRecoveryPage(
    _buildOptions(OfflineRecoveryPageKind.offlineFallback),
  );
  final offlineScript = buildOfflineRecoveryScript(
    _buildOptions(OfflineRecoveryPageKind.offlineFallback),
  );
  final gatewayScript = buildOfflineRecoveryScript(
    _buildOptions(OfflineRecoveryPageKind.gatewayTimeout),
  );
  final offlineScriptSource = _extractScriptSource(offlineScript);

  return <String, String>{
    'offline': offline,
    'gateway': buildDefaultOfflineRecoveryPage(
      _buildOptions(OfflineRecoveryPageKind.gatewayTimeout),
    ),
    'gateway_monitor': buildDefaultOfflineRecoveryPage(
      _buildOptions(
        OfflineRecoveryPageKind.gatewayTimeout,
        gatewayTimeoutAutoReload: true,
      ),
    ),
    'gateway_no_continuation': buildDefaultOfflineRecoveryPage(
      _buildOptions(OfflineRecoveryPageKind.gatewayTimeout,
          continuation: false),
    ),
    // 同じスクリプトを 2 つ含むページ（二重起動の防止の確認用）
    'offline_double':
        '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>'
            'offline$offlineScript$offlineScript</body></html>',
    'gateway_double':
        '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>'
            'gateway$gatewayScript$gatewayScript</body></html>',
    // 表示の直後にリンクで遷移するページ（遷移を打ち消さないことの確認用）
    'offline_with_link': offline.replaceFirst(
      '</body>',
      '<a id="go" href="/slow">go</a>'
          '<script>setTimeout(function () {'
          'document.getElementById("go").click();}, $_linkClickDelayMs);'
          '</script></body>',
    ),
    // 読み込みの完了後にスクリプトを挿入するページと、取り出したソースが
    // 読み込み中なら動くことを確かめる対照ページ
    'inserted_after_load':
        '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>'
            '<div id="msg">real</div><script>'
            'window.addEventListener("load", function () {'
            'var element = document.createElement("script");'
            'element.textContent = '
            '${encodeOfflineRecoveryScriptValue(offlineScriptSource)};'
            'document.body.appendChild(element);});</script></body></html>',
    'inline_extracted_source':
        '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>'
            'offline<script>$offlineScriptSource</script></body></html>',
  };
}

/// 回帰テスト用のスクリプトの設定を作る。
///
/// [pageKind] はページの種別です。
/// [continuation] は継続復帰を有効にするかどうかです。
/// [gatewayTimeoutAutoReload] は `504` ページの監視中からの自動再読込を
/// 有効にするかどうかです。
///
/// Returns: 監視間隔などを回帰テストの前提の値にしたスクリプトの設定。
OfflineRecoveryScriptOptions _buildOptions(
  OfflineRecoveryPageKind pageKind, {
  bool continuation = true,
  bool gatewayTimeoutAutoReload = false,
}) {
  return OfflineRecoveryScriptOptions(
    pageKind: pageKind,
    statusPath: _statusPath,
    pollInterval: const Duration(milliseconds: 500),
    queueWaitTimeout: const Duration(seconds: 2),
    requestTimeout: const Duration(seconds: 20),
    offlinePageAutoReload: true,
    continuation: continuation,
    gatewayTimeoutAutoReload: gatewayTimeoutAutoReload,
  );
}

/// 監視スクリプトの要素から、スクリプトのソースを取り出す。
///
/// [scriptElement] は `buildOfflineRecoveryScript` が返す要素です。
///
/// Returns: 開始タグと終了タグを除いたソース。
///
/// Throws: 要素の形が想定と違う場合は [StateError]。取り出せないままページを
/// 書き出すと、挿入したスクリプトが動かないことの確認が誤って合格するためです。
String _extractScriptSource(String scriptElement) {
  if (!scriptElement.startsWith(_scriptOpenTag) ||
      !scriptElement.endsWith(_scriptCloseTag)) {
    throw StateError(
      'unexpected recovery script element: '
      '${scriptElement.substring(0, _scriptOpenTag.length)}',
    );
  }
  return scriptElement.substring(
    _scriptOpenTag.length,
    scriptElement.length - _scriptCloseTag.length,
  );
}
