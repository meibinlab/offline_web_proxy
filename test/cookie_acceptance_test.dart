import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';
import 'package:offline_web_proxy/src/models/cookie_date.dart';
import 'package:offline_web_proxy/src/models/cookie_record.dart';
import 'package:offline_web_proxy/src/models/cookie_rejection.dart';
import 'package:offline_web_proxy/src/models/cookie_save_failure.dart';

import 'support/access_token_http.dart';

/// `AssetManifest.json` のモック内容。静的リソース一覧の初期化を安定させるために使用する。
const Map<String, List<String>> _mockAssetManifest = {
  'assets/static/app.js': ['assets/static/app.js'],
};

/// 暗号化した Cookie Box の名前。保存領域の失敗を作るために使用する。
const String _cookieBoxName = 'proxy_cookies_secure';

/// パスごとに `Set-Cookie` を返し、受け取った `Cookie` を記録する上流のモック。
class _MockUpstream {
  _MockUpstream(this._server) {
    _server.listen((HttpRequest request) async {
      try {
        await request.drain<void>();
        receivedCookies.add(request.headers.value('cookie'));
        await beforeRespond?.call(request.uri.path);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('text', 'plain', charset: 'utf-8');
        // 応答を保存しないようにし、Cookie の確認だけに絞る
        request.response.headers.set('cache-control', 'no-store');
        for (final value in setCookies[request.uri.path] ?? const <String>[]) {
          request.response.headers.add('set-cookie', value);
        }
        request.response.write('upstream');
        await request.response.close();
      } catch (_) {
        // 既に切断されている場合は無視する
      }
    });
  }

  final HttpServer _server;

  /// パスごとに応答へ付ける `Set-Cookie` の値。
  final Map<String, List<String>> setCookies = <String, List<String>>{};

  /// 応答を返す直前に呼ぶ処理。引数は要求のパス。
  Future<void> Function(String path)? beforeRespond;

  /// 受け取った `Cookie` ヘッダの値。受信順に追加される（なければ `null`）。
  final List<String?> receivedCookies = <String?>[];

  /// 上流のポート。
  int get port => _server.port;

  /// 上流の origin。
  String get origin => 'http://127.0.0.1:${_server.port}';

  /// 上流を停止する。
  Future<void> close() => _server.close(force: true);
}

/// 上流のモックを起動する。
///
/// Returns: 起動したモック。
Future<_MockUpstream> _startMockUpstream() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _MockUpstream(server);
}

/// 実 HttpClient で GET を送り、ステータスを返す。
///
/// [uri] 要求先。
///
/// Returns: 応答のステータスコード。
Future<int> _get(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// `Expires` に使う、`-` 区切りで年を 4 桁にした日付の文字列を返す。
///
/// [at] 表す日時（UTC）。
///
/// Returns: `Wed, 21-Oct-2026 07:28:00 GMT` の形の文字列。
String _dashedCookieDate(DateTime at) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int value) => value.toString().padLeft(2, '0');
  return '${weekdays[at.weekday - 1]}, ${two(at.day)}-${months[at.month - 1]}-'
      '${at.year} ${two(at.hour)}:${two(at.minute)}:${two(at.second)} GMT';
}

/// 受け入れ規則を適用して `Set-Cookie` を解釈する。
///
/// [header] `Set-Cookie` の値。
/// [url] 受け取った要求先。
/// [fromMirroredOrigin] 中継先の応答かどうか。
/// [originHost] 設定済み origin のホスト。
///
/// Returns: 解釈した Cookie。
CookieRecord _accept(
  String header,
  String url, {
  bool fromMirroredOrigin = false,
  String? originHost,
}) {
  return CookieRecord.fromSetCookieHeader(
    setCookieHeader: header,
    requestUri: Uri.parse(url),
    applyAcceptanceRules: true,
    fromMirroredOrigin: fromMirroredOrigin,
    configuredOriginHost: originHost,
  );
}

/// 受け入れ規則で [reason] により拒否されることを確かめる。
///
/// [header] `Set-Cookie` の値。
/// [url] 受け取った要求先。
/// [reason] 期待する拒否理由。
/// [fromMirroredOrigin] 中継先の応答かどうか。
/// [originHost] 設定済み origin のホスト。
void _expectRejected(
  String header,
  String url,
  CookieRejectionReason reason, {
  bool fromMirroredOrigin = false,
  String? originHost,
}) {
  expect(
    () => _accept(
      header,
      url,
      fromMirroredOrigin: fromMirroredOrigin,
      originHost: originHost,
    ),
    throwsA(isA<CookieRejectedException>()
        .having((e) => e.reason, 'reason', reason)),
    reason: header,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Cookie の日付（doc/specs.ja.md 【4】Cookie 評価基準）', () {
    /// RFC 1123 と、年を 4 桁にした `-` 区切りの形式を解釈すること
    test('parses the RFC 1123 and the dashed four-digit year forms', () {
      final expected = DateTime.utc(2026, 10, 21, 7, 28);
      expect(parseCookieDate('Wed, 21 Oct 2026 07:28:00 GMT'), expected);
      expect(parseCookieDate('Wed, 21-Oct-2026 07:28:00 GMT'), expected);
    });

    /// 2 桁の年を 70～99 は 1900 年代、0～69 は 2000 年代とみなすこと
    test('maps two-digit years', () {
      expect(parseCookieDate('Wednesday, 21-Oct-26 07:28:00 GMT'),
          DateTime.utc(2026, 10, 21, 7, 28));
      expect(parseCookieDate('Thu, 21-Oct-99 07:28:00 GMT')?.year, 1999);
      expect(
          parseCookieDate('Thu, 01-Jan-70 00:00:00 GMT'), DateTime.utc(1970));
      expect(parseCookieDate('Sat, 01-Jan-69 00:00:00 GMT')?.year, 2069);
      expect(parseCookieDate('Sat, 01-Jan-00 00:00:00 GMT')?.year, 2000);
    });

    /// asctime の形式を解釈すること
    test('parses the asctime form', () {
      expect(parseCookieDate('Wed Oct 21 07:28:00 2026'),
          DateTime.utc(2026, 10, 21, 7, 28));
      expect(parseCookieDate('Wed Oct  1 07:28:00 2026'),
          DateTime.utc(2026, 10, 1, 7, 28));
    });

    /// 不正な値は解釈しないこと
    test('rejects invalid values', () {
      for (final value in <String>[
        '',
        'not a date',
        '0',
        '2026-10-21T07:28:00Z',
        'Wed, 21 Oct 2026 GMT',
        'Wed, 21 Foo 2026 07:28:00 GMT',
        'Wed, 30 Feb 2026 07:28:00 GMT',
        'Wed, 32 Oct 2026 07:28:00 GMT',
        'Wed, 00 Oct 2026 07:28:00 GMT',
        'Wed, 21 Oct 1600 07:28:00 GMT',
        'Wed, 21 Oct 2026 24:00:00 GMT',
        'Wed, 21 Oct 2026 07:60:00 GMT',
        'Wed, 21 Oct 2026 07:28:60 GMT',
      ]) {
        expect(parseCookieDate(value), isNull, reason: value);
      }
    });

    /// 字句の区切りと順序に関する RFC 6265 の手順どおりに解釈すること
    test('follows the tokenizing rules', () {
      final expected = DateTime.utc(2026, 10, 21, 7, 28);
      // 時刻の各欄は 1～2 桁
      expect(parseCookieDate('Wed, 21 Oct 2026 7:8:9 GMT'),
          DateTime.utc(2026, 10, 21, 7, 8, 9));
      // 3 桁の年は 2～4 桁の年として読み、70 未満は 2000 年代
      expect(parseCookieDate('Wed, 21 Oct 026 07:28:00 GMT'), expected);
      // 時刻の後ろに数字以外が続いてもよい
      expect(parseCookieDate('Wed, 21 Oct 2026 07:28:00GMT'), expected);
      // タブも区切り文字
      expect(parseCookieDate('Wed,\t21\tOct\t2026\t07:28:00\tGMT'), expected);
      // 月名は先頭 3 文字で判定する
      expect(
          parseCookieDate('Wednesday, 21 October 2026 07:28:00 GMT'), expected);
      // 年が先頭でもよい
      expect(parseCookieDate('2026 Oct 21 07:28:00 GMT'), expected);
      // `21Oct` は日として読まれ、月が見つからない
      expect(parseCookieDate('21Oct 2026 07:28:00 GMT'), isNull);
    });

    /// うるう年の 2 月 29 日は解釈し、平年は解釈しないこと
    test('checks that the date exists', () {
      expect(
          parseCookieDate('29 Feb 2028 00:00:00'), DateTime.utc(2028, 2, 29));
      expect(parseCookieDate('29 Feb 2027 00:00:00'), isNull);
    });

    /// 解釈できない Expires は無視し、先に解釈できた値を保つこと
    test('ignores an unparsable Expires attribute', () {
      final session = _accept(
        'a=1; Expires=2026-10-21T07:28:00Z',
        'https://app.example.com/',
      );
      expect(session.expires, isNull);

      final kept = _accept(
        'a=1; Expires=Wed, 21-Oct-2026 07:28:00 GMT; Expires=bad',
        'https://app.example.com/',
      );
      expect(kept.expires, DateTime.utc(2026, 10, 21, 7, 28));
    });
  });

  group('Max-Age と有効期限の上限（doc/specs.ja.md 【4】Cookie 評価基準）', () {
    /// 受信日時。期限の計算を固定するために使用する。
    final receivedAt = DateTime.utc(2026, 10, 21);

    /// [header] を受信日時を固定して解釈し、有効期限を返す。
    DateTime? expiresOf(String header) => CookieRecord.fromSetCookieHeader(
          setCookieHeader: header,
          requestUri: Uri.parse('https://app.example.com/'),
          receivedAt: receivedAt,
          applyAcceptanceRules: true,
        ).expires;

    /// `^-?\d+$` に合う値だけを採ること
    test('accepts only an optional minus sign and digits', () {
      expect(expiresOf('a=1; Max-Age=60'),
          receivedAt.add(const Duration(seconds: 60)));
      expect(expiresOf('a=1; Max-Age=007'),
          receivedAt.add(const Duration(seconds: 7)));
      expect(expiresOf('a=1; Max-Age=0x10'), isNull);
      expect(expiresOf('a=1; Max-Age=+5'), isNull);
      expect(expiresOf('a=1; Max-Age=5s'), isNull);
      expect(expiresOf('a=1; Max-Age='), isNull);
    });

    /// 不正な値は無視し、先に採った値を保つこと
    test('keeps the previous value after an invalid one', () {
      expect(expiresOf('a=1; Max-Age=60; Max-Age=abc'),
          receivedAt.add(const Duration(seconds: 60)));
      expect(expiresOf('a=1; Max-Age=60; Max-Age=120'),
          receivedAt.add(const Duration(seconds: 120)));
    });

    /// 0 以下は即時に失効すること
    test('expires immediately at zero or below', () {
      for (final value in ['0', '-1', '-0', '-99999999999999999999']) {
        final expires = expiresOf('a=1; Max-Age=$value')!;
        expect(expires.isAfter(receivedAt), isFalse, reason: value);
      }
    });

    /// 400 日を超える値は 400 日に丸め、桁の多い値でもあふれないこと
    test('caps the lifetime at 400 days', () {
      final cap = receivedAt.add(const Duration(days: 400));
      expect(expiresOf('a=1; Max-Age=34560000'), cap);
      expect(expiresOf('a=1; Max-Age=34560001'), cap);
      expect(expiresOf('a=1; Max-Age=99999999999999999999999999'), cap);
      expect(expiresOf('a=1; Max-Age=34559999'),
          cap.subtract(const Duration(seconds: 1)));
      // Expires にも同じ上限を掛ける
      expect(expiresOf('a=1; Expires=Wed, 21-Oct-2099 07:28:00 GMT'), cap);
      expect(expiresOf('a=1; Expires=Tue, 20-Oct-2026 00:00:00 GMT'),
          DateTime.utc(2026, 10, 20));
      // Max-Age は Expires より優先する
      expect(
          expiresOf('a=1; Expires=Wed, 21-Oct-2099 07:28:00 GMT; Max-Age=60'),
          receivedAt.add(const Duration(seconds: 60)));
    });
  });

  group('Path 属性（doc/specs.ja.md 【4】Cookie 評価基準）', () {
    /// 空か `/` で始まらない値は default-path を使うこと
    test('uses the default path for an empty or relative value', () {
      CookieRecord parse(String header, {bool rules = true}) =>
          CookieRecord.fromSetCookieHeader(
            setCookieHeader: header,
            requestUri: Uri.parse('https://app.example.com/dir/page'),
            applyAcceptanceRules: rules,
          );

      expect(parse('a=1').path, '/dir');
      expect(parse('a=1; Path=app').path, '/dir');
      expect(parse('a=1; Path=').path, '/dir');
      expect(parse('a=1; Path').path, '/dir');
      expect(parse('a=1; Path=/x').path, '/x');
      expect(parse('a=1; Path=/x; Path=y').path, '/dir');
      // アプリが渡す値の解釈でも同じ
      expect(parse('a=1; Path=app', rules: false).path, '/dir');
      expect(
        CookieRestoreEntry.fromSetCookieHeader(
          setCookieHeader: 'a=1; Path=app',
          requestUrl: 'https://app.example.com/',
        ).path,
        '/',
      );
    });
  });

  group('Secure の Cookie の保護（doc/specs.ja.md 【4】Cookie 評価基準）', () {
    /// 判定日時。
    final now = DateTime.utc(2026, 10, 21);

    /// 保存済みの Cookie を作る。
    CookieRecord stored({
      String name = 'sid',
      String domain = 'app.example.com',
      String path = '/',
      bool secure = true,
      bool hostOnly = true,
      DateTime? expires,
    }) =>
        CookieRecord(
          name: name,
          value: 'secure-value',
          domain: domain,
          path: path,
          expires: expires,
          secure: secure,
          httpOnly: false,
          sameSite: null,
          hostOnly: hostOnly,
          createdAt: now,
        );

    /// http の応答の Cookie を解釈する。
    CookieRecord incoming(String header, {String host = 'app.example.com'}) =>
        _accept(header, 'http://$host/app/page');

    /// 親ドメインの Cookie で子ドメインの Secure の Cookie を覆えないこと
    test('detects a parent-domain cookie shadowing a Secure cookie', () {
      expect(
        stored().isSecureShadowedBy(
            incoming('sid=x; Domain=example.com; Path=/'),
            at: now),
        isTrue,
      );
      // 逆向き（親ドメインの Secure の Cookie を子ホストの Cookie で覆う）
      expect(
        stored(domain: 'example.com', hostOnly: false)
            .isSecureShadowedBy(incoming('sid=x; Path=/'), at: now),
        isTrue,
      );
    });

    /// 新しい Cookie のパスが既存のパスに path-match する場合だけ当たること
    test('requires the new path to path-match the stored one', () {
      expect(stored().isSecureShadowedBy(incoming('sid=x; Path=/app'), at: now),
          isTrue);
      expect(
          stored(path: '/app')
              .isSecureShadowedBy(incoming('sid=x; Path=/'), at: now),
          isFalse);
      expect(
          stored(path: '/app').isSecureShadowedBy(
              incoming('sid=x; Path=/application'),
              at: now),
          isFalse);
    });

    /// 名前・Secure・期限・ドメインが合わなければ当たらないこと
    test('ignores cookies that do not overlap', () {
      final cookie = incoming('sid=x; Path=/');
      expect(
          stored(name: 'other').isSecureShadowedBy(cookie, at: now), isFalse);
      expect(
          stored(secure: false).isSecureShadowedBy(cookie, at: now), isFalse);
      expect(
          stored(expires: now.subtract(const Duration(seconds: 1)))
              .isSecureShadowedBy(cookie, at: now),
          isFalse);
      expect(
          stored(domain: 'other.example.com')
              .isSecureShadowedBy(cookie, at: now),
          isFalse);
    });
  });

  group('Cookie の受け入れ規則（doc/specs.ja.md 【4】Cookie 評価基準）', () {
    /// 要求先ホストに domain-match しない Domain を拒否すること
    test('domainMismatch', () {
      _expectRejected('a=1; Domain=other.com', 'https://app.example.com/',
          CookieRejectionReason.domainMismatch);
      _expectRejected('a=1; Domain=sub.app.example.com',
          'https://app.example.com/', CookieRejectionReason.domainMismatch);
      _expectRejected('a=1; Domain=ample.com', 'https://app.example.com/',
          CookieRejectionReason.domainMismatch);

      final parent =
          _accept('a=1; Domain=.Example.COM', 'https://app.example.com/');
      expect(parent.domain, 'example.com');
      expect(parent.hostOnly, isFalse);
      final self =
          _accept('a=1; Domain=app.example.com', 'https://app.example.com/');
      expect(self.domain, 'app.example.com');
      expect(self.hostOnly, isFalse);
    });

    /// IP アドレスのホストでは、ホストと等しい Domain だけをホスト限定で受け入れること
    test('ipDomain', () {
      _expectRejected('a=1; Domain=0.0.1', 'http://127.0.0.1/',
          CookieRejectionReason.ipDomain);
      _expectRejected('a=1; Domain=localhost', 'http://127.0.0.1/',
          CookieRejectionReason.ipDomain);
      _expectRejected('a=1; Domain=example.com', 'http://[::1]/',
          CookieRejectionReason.ipDomain);

      final ipv4 = _accept('a=1; Domain=127.0.0.1', 'http://127.0.0.1/');
      expect(ipv4.domain, '127.0.0.1');
      expect(ipv4.hostOnly, isTrue);
      final ipv6 = _accept('a=1; Domain=::1', 'http://[::1]/');
      expect(ipv6.domain, '::1');
      expect(ipv6.hostOnly, isTrue);
      // Domain なしの IP ホストはホスト限定で受け入れる
      expect(_accept('a=1', 'http://127.0.0.1/').hostOnly, isTrue);
    });

    /// `.` を含まない Domain は、ホストと等しい場合だけホスト限定で受け入れること
    test('singleLabelDomain', () {
      _expectRejected('a=1; Domain=com', 'https://app.example.com/',
          CookieRejectionReason.singleLabelDomain);
      _expectRejected('a=1; Domain=.com', 'https://app.example.com/',
          CookieRejectionReason.singleLabelDomain);

      final localhost = _accept('a=1; Domain=localhost', 'http://localhost/');
      expect(localhost.domain, 'localhost');
      expect(localhost.hostOnly, isTrue);
    });

    /// 中継先の応答が、設定済み origin のホストへ送られる Cookie を置けないこと
    test('mirroredOriginDomain', () {
      _expectRejected(
        'a=1; Domain=example.com',
        'https://cdn.example.com/',
        CookieRejectionReason.mirroredOriginDomain,
        fromMirroredOrigin: true,
        originHost: 'app.example.com',
      );
      // ポート違いの同じホスト（ホスト限定）も設定済み origin へ送られる
      _expectRejected(
        'a=1',
        'https://app.example.com:8443/',
        CookieRejectionReason.mirroredOriginDomain,
        fromMirroredOrigin: true,
        originHost: 'APP.example.com',
      );

      final own = _accept(
        'a=1; Domain=cdn.example.com',
        'https://cdn.example.com/',
        fromMirroredOrigin: true,
        originHost: 'app.example.com',
      );
      expect(own.domain, 'cdn.example.com');
      final hostOnly = _accept(
        'a=1',
        'https://cdn.example.com/',
        fromMirroredOrigin: true,
        originHost: 'app.example.com',
      );
      expect(hostOnly.hostOnly, isTrue);
      // 設定済み origin の応答なら親ドメインを受け入れる
      expect(
        _accept('a=1; Domain=example.com', 'https://app.example.com/',
                originHost: 'app.example.com')
            .domain,
        'example.com',
      );
    });

    /// https 以外の応答の Secure を拒否すること
    test('insecureSecure', () {
      _expectRejected('a=1; Secure', 'http://app.example.com/',
          CookieRejectionReason.insecureSecure);
      expect(_accept('a=1; Secure', 'https://app.example.com/').secure, isTrue);
      expect(_accept('a=1', 'http://app.example.com/').secure, isFalse);
    });

    /// `__Secure-` は Secure と https が必要なこと
    test('securePrefix', () {
      _expectRejected('__Secure-a=1', 'https://app.example.com/',
          CookieRejectionReason.securePrefix);
      _expectRejected('__secure-a=1', 'https://app.example.com/',
          CookieRejectionReason.securePrefix);
      _expectRejected('__Secure-a=1', 'http://app.example.com/',
          CookieRejectionReason.securePrefix);
      // http の Secure は insecureSecure として先に拒否する
      _expectRejected('__Secure-a=1; Secure', 'http://app.example.com/',
          CookieRejectionReason.insecureSecure);

      expect(
        _accept('__Secure-a=1; Secure; Domain=example.com',
                'https://app.example.com/')
            .secure,
        isTrue,
      );
    });

    /// `__Host-` は Secure、https、Domain なし、Path=/ が必要なこと
    test('hostPrefix', () {
      const url = 'https://app.example.com/app/page';
      _expectRejected(
          '__Host-a=1; Secure', url, CookieRejectionReason.hostPrefix);
      _expectRejected('__Host-a=1; Secure; Path=/app', url,
          CookieRejectionReason.hostPrefix);
      _expectRejected('__Host-a=1; Secure; Path=/; Domain=app.example.com', url,
          CookieRejectionReason.hostPrefix);
      _expectRejected(
          '__Host-a=1; Path=/', url, CookieRejectionReason.hostPrefix);
      _expectRejected(
          '__HOST-a=1; Path=/', url, CookieRejectionReason.hostPrefix);
      _expectRejected('__Host-a=1; Path=/', 'http://app.example.com/',
          CookieRejectionReason.hostPrefix);

      final accepted = _accept('__Host-a=1; Secure; Path=/', url);
      expect(accepted.hostOnly, isTrue);
      expect(accepted.path, '/');

      // Path 属性があれば、空の値もルート直下の要求では default-path の `/` になる
      final emptyPath =
          _accept('__Host-a=1; Secure; Path=', 'https://app.example.com/page');
      expect(emptyPath.path, '/');
      // Path 属性が無い場合は、解決後のパスが `/` でも受け入れない
      _expectRejected('__Host-a=1; Secure', 'https://app.example.com/page',
          CookieRejectionReason.hostPrefix);
    });

    /// 規則を適用しない既定（アプリが渡す値の解釈）では属性をそのまま取り込むこと
    test('keeps attributes as is without the acceptance rules', () {
      final record = CookieRecord.fromSetCookieHeader(
        setCookieHeader: 'a=1; Domain=other.com; Secure',
        requestUri: Uri.parse('http://app.example.com/'),
      );
      expect(record.domain, 'other.com');
      expect(record.hostOnly, isFalse);
      expect(record.secure, isTrue);
    });

    /// 例外と区分に Cookie の値を含めないこと
    test('does not carry the cookie value', () {
      try {
        _accept('sid=SECRET-VALUE; Domain=other.com', 'https://a.example.com/');
        fail('should be rejected');
      } on CookieRejectedException catch (e) {
        expect(e.toString(), isNot(contains('SECRET-VALUE')));
        expect(e.cookieName, 'sid');
        expect(cookieSaveFailureReason(e), 'domainMismatch');
      }
    });
  });

  group('上流の Set-Cookie の保存（doc/specs.ja.md 【4】Cookie 評価基準）', () {
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
    _MockUpstream? upstream;
    _MockUpstream? cdn;
    late List<ProxyEvent> events;
    StreamSubscription<ProxyEvent>? subscription;

    setUp(() async {
      hiveTestDirectory = Directory.systemTemp
          .createTempSync('offline_web_proxy_cookie_acceptance')
          .path;
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      await Hive.close();
      proxy = trackAccessToken(OfflineWebProxy());
      events = <ProxyEvent>[];
      subscription = proxy.events.listen(events.add);
    });

    tearDown(() async {
      await subscription?.cancel();
      subscription = null;
      if (proxy.isRunning) {
        await proxy.stop();
      }
      await upstream?.close();
      await cdn?.close();
      upstream = null;
      cdn = null;
    });

    /// 実通信を伴うテスト本体を、実 HttpClient が使えるゾーンで実行する。
    Future<void> withRealHttpClient(Future<void> Function() body) {
      return HttpOverrides.runZoned<Future<void>>(
        body,
        createHttpClient: AccessTokenHttpOverrides().createHttpClient,
      );
    }

    /// Cookie 保存の errorOccurred の data を返す。
    List<Map<String, dynamic>> cookieSaveEvents() => events
        .where((event) =>
            event.type == ProxyEventType.errorOccurred &&
            event.data['operation'] == 'cookieSave')
        .map((event) => event.data)
        .toList();

    /// 上流のモックを起動し、proxy を開始する。
    ///
    /// Returns: proxy のポート。
    Future<int> startProxy() async {
      upstream = await _startMockUpstream();
      return proxy.start(config: ProxyConfig(origin: upstream!.origin));
    }

    /// IP ホストの Domain を受け入れ規則で扱い、拒否は値を載せずに通知すること
    test('accepts a host-only cookie and reports a rejection without the value',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        upstream!.setCookies['/set'] = [
          'ok=1; Path=/; Domain=127.0.0.1',
          'bad=SECRET-VALUE; Path=/; Domain=localhost',
        ];

        expect(
            await _get(Uri.parse('http://127.0.0.1:$port/set')), HttpStatus.ok);
        await _get(Uri.parse('http://127.0.0.1:$port/next'));

        expect(upstream!.receivedCookies.last, 'ok=1');
        final cookies = await proxy.getCookies();
        expect(cookies.map((cookie) => cookie.name), ['ok']);

        final rejected = cookieSaveEvents();
        expect(rejected, hasLength(1));
        expect(rejected.single, {
          'operation': 'cookieSave',
          'reason': 'ipDomain',
          'cookieName': 'bad',
        });
        expect(events.map((event) => event.toString()).join(),
            isNot(contains('SECRET-VALUE')));
      });
    });

    /// http の応答の Secure を保存しないこと
    test('rejects a Secure cookie from an http response', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        upstream!.setCookies['/set'] = ['s=1; Path=/; Secure'];

        await _get(Uri.parse('http://127.0.0.1:$port/set'));

        expect(await proxy.getCookies(), isEmpty);
        expect(cookieSaveEvents().single['reason'], 'insecureSecure');
      });
    });

    /// 4 桁の年の `-` 区切りの Expires を保存し、過去の Expires で削除できること
    test('stores a dashed Expires and deletes with a past one', () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        final future = DateTime.now()
            .toUtc()
            .add(const Duration(days: 30))
            .copyWith(millisecond: 0, microsecond: 0);
        upstream!.setCookies['/set'] = [
          'sid=v1; Path=/; Expires=${_dashedCookieDate(future)}',
        ];
        upstream!.setCookies['/clear'] = [
          'sid=; Path=/; Expires=Thu, 01-Jan-70 00:00:00 GMT',
        ];

        await _get(Uri.parse('http://127.0.0.1:$port/set'));
        final stored = await proxy.getCookies();
        expect(stored.single.expires, future);

        await _get(Uri.parse('http://127.0.0.1:$port/clear'));
        expect(await proxy.getCookies(), isEmpty);

        await _get(Uri.parse('http://127.0.0.1:$port/next'));
        expect(upstream!.receivedCookies.last, isNull);
        expect(cookieSaveEvents(), isEmpty);
      });
    });

    /// http の応答が Secure の Cookie を上書きも削除もできないこと
    test('does not let an http response overwrite or delete a Secure cookie',
        () async {
      await withRealHttpClient(() async {
        final port = await startProxy();
        // アプリが渡す値は受け入れ規則の対象外（restoreCookies）
        await proxy.restoreCookies([
          CookieRestoreEntry(
            name: 'sid',
            value: 'secure-value',
            domain: '127.0.0.1',
            secure: true,
            hostOnly: true,
          ),
          CookieRestoreEntry(
            name: 'deep',
            value: 'secure-value',
            domain: '127.0.0.1',
            path: '/app',
            secure: true,
            hostOnly: true,
          ),
        ]);
        upstream!.setCookies['/overwrite'] = ['sid=EVIL-VALUE; Path=/'];
        upstream!.setCookies['/delete'] = ['sid=; Path=/; Max-Age=0'];
        // `/app` は既存の `/` に path-match するため、影で覆う Cookie も拒否する
        upstream!.setCookies['/shadow'] = ['sid=other; Path=/app'];
        // `/` は既存の `/app` に path-match しないため置ける
        upstream!.setCookies['/wider'] = ['deep=other; Path=/'];

        await _get(Uri.parse('http://127.0.0.1:$port/overwrite'));
        await _get(Uri.parse('http://127.0.0.1:$port/delete'));
        await _get(Uri.parse('http://127.0.0.1:$port/shadow'));
        await _get(Uri.parse('http://127.0.0.1:$port/wider'));

        final cookies = await proxy.getCookies();
        final sid = cookies.where((cookie) => cookie.name == 'sid').toList();
        expect(sid, hasLength(1));
        expect(sid.single.secure, isTrue);
        expect(sid.single.path, '/');
        final deep = cookies.where((cookie) => cookie.name == 'deep').toList();
        expect(deep.map((cookie) => (cookie.path, cookie.secure)),
            unorderedEquals([('/app', true), ('/', false)]));

        final rejected = cookieSaveEvents();
        expect(rejected.map((data) => data['reason']),
            ['secureOverwrite', 'secureOverwrite', 'secureOverwrite']);
        expect(
            rejected.map((data) => data['cookieName']), ['sid', 'sid', 'sid']);
        expect(events.map((event) => event.toString()).join(),
            isNot(contains('EVIL-VALUE')));
      });
    });

    /// 中継先の応答が、設定済み origin のホストへ送られる Cookie を置けないこと
    test('rejects a cookie from a mirrored origin covering the origin host',
        () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        cdn = await _startMockUpstream();
        cdn!.setCookies['/lib/app.js'] = [
          'cdn=1; Path=/',
          'cdn2=1; Path=/; Domain=127.0.0.1',
        ];
        final port = await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        expect(
          await _get(Uri.parse('http://127.0.0.1:$port'
              '/__offline_web_proxy/ext/http/127.0.0.1:${cdn!.port}'
              '/lib/app.js')),
          HttpStatus.ok,
        );
        await _get(Uri.parse('http://127.0.0.1:$port/page'));

        expect(await proxy.getCookies(), isEmpty);
        expect(upstream!.receivedCookies.last, isNull);
        expect(cookieSaveEvents().map((data) => data['reason']),
            ['mirroredOriginDomain', 'mirroredOriginDomain']);
      });
    });

    /// ウォームアップで受け取った Cookie にも受け入れ規則を適用すること
    test('applies the acceptance rules to warm-up responses', () async {
      await withRealHttpClient(() async {
        upstream = await _startMockUpstream();
        cdn = await _startMockUpstream();
        upstream!.setCookies['/warm'] = [
          'ok=1; Path=/',
          'sec=SECRET-VALUE; Path=/; Secure',
          'other=1; Path=/; Domain=localhost',
        ];
        cdn!.setCookies['/lib/app.js'] = ['cdn=1; Path=/'];
        await proxy.start(
          config: ProxyConfig(
            origin: upstream!.origin,
            mirroredOrigins: <String>[cdn!.origin],
          ),
        );

        await proxy.warmupCache(paths: [
          '/warm',
          '/__offline_web_proxy/ext/http/127.0.0.1:${cdn!.port}/lib/app.js',
        ]);

        final cookies = await proxy.getCookies();
        expect(cookies.map((cookie) => cookie.name), ['ok']);
        expect(
          cookieSaveEvents().map((data) => data['reason']),
          unorderedEquals(
              ['insecureSecure', 'ipDomain', 'mirroredOriginDomain']),
        );
        expect(events.map((event) => event.toString()).join(),
            isNot(contains('SECRET-VALUE')));
      });
    });

    /// 保存領域が使えなくても通知して要求の処理を続けること
    test('reports a storage failure and keeps serving', () async {
      await withRealHttpClient(() async {
        // Hive 2.2.3 は Box を開けなかったとき、待ち合わせ用の Future を誰も
        // 待たないまま失敗させる。proxy の外で起きる未処理の例外として集め、
        // テストの失敗にしない
        final uncaughtErrors = <Object>[];
        final port = await runZonedGuarded(
          startProxy,
          (error, _) => uncaughtErrors.add(error),
        )!;
        upstream!.setCookies['/set'] = ['sid=SECRET-VALUE; Path=/'];

        // 上流へ Cookie を送った後、応答を受け取る前に保存領域を使えなくする。
        // Cookie Box を閉じ、同じ名前のディレクトリを置いて開けなくする
        upstream!.beforeRespond = (path) async {
          await Hive.box(_cookieBoxName).close();
          final boxFile = File('$hiveTestDirectory/$_cookieBoxName.hive');
          if (boxFile.existsSync()) {
            boxFile.deleteSync();
          }
          Directory(boxFile.path).createSync();
        };

        expect(
            await _get(Uri.parse('http://127.0.0.1:$port/set')), HttpStatus.ok);

        final failures = cookieSaveEvents();
        expect(failures, hasLength(1));
        expect(failures.single['reason'], 'storageFailure');
        expect(failures.single.keys.toSet(), {'operation', 'error', 'reason'});
        // Hive の版や競合の仕方によっては未処理の例外が出ないこともあるため、
        // 空でも通す。出た場合は、Box を開けなかったことによるものに限る
        expect(uncaughtErrors, everyElement(isA<FileSystemException>()));
        expect(events.map((event) => event.toString()).join(),
            isNot(contains('SECRET-VALUE')));
      });
    });
  });
}
