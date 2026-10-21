import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/src/matching/request_target_check.dart';

void main() {
  group('findRequestPathRejection（doc/specs.ja.md 【2】パス検証）', () {
    /// 符号化した区切りや `\` で隠した `.` と `..` を拒否すること
    test('rejects dot segments hidden behind encoding', () {
      for (final path in [
        '/a/..%2Fb',
        '/a/..%2fb',
        '/a/%2E%2E/b',
        '/%2e%2e/x',
        '/a/%5C..',
        '/x/%2E%2E%5Cy',
        '/a/.%2Fb',
        '/a/b%2F..',
        r'/a/..\b',
        // Tomcat などは `;` 以降を落としてから `..` を解決する
        '/a/..;jsessionid=1/b',
        '/a/..%3B/b',
        '/a/../b',
        '/./a',
      ]) {
        expect(findRequestPathRejection(path), RequestPathRejection.dotSegment,
            reason: path);
      }
    });

    /// `%` の後に 16 進数 2 桁が続かないパスを拒否すること
    test('rejects malformed percent encoding', () {
      for (final path in ['/a/%zz', '/a/%2', '/a/%', '/a%G0/b']) {
        expect(
          findRequestPathRejection(path),
          RequestPathRejection.malformedPercentEncoding,
          reason: path,
        );
      }
    });

    /// `.` と `..` を伴わない符号化は受け付けること
    test('accepts encoded separators without dot segments', () {
      for (final path in [
        '/',
        '/a%2Fb',
        '/a/%5Cb',
        '/a/...',
        '/a/..b',
        '/a/b..',
        '/a/.well-known/x',
        '/files/%82%A0.txt',
        '/a;v=1/b',
        '/a/%25zz',
      ]) {
        expect(findRequestPathRejection(path), isNull, reason: path);
      }
    });
  });

  group('parseHostHeader（doc/specs.ja.md 【2】Host 照合）', () {
    /// ホスト名を小文字にし、ポートを分けること
    test('splits a host name and a port', () {
      expect(
          parseHostHeader('127.0.0.1:8080'), (name: '127.0.0.1', port: 8080));
      expect(parseHostHeader('LocalHost:80'), (name: 'localhost', port: 80));
      expect(parseHostHeader(' localhost '), (name: 'localhost', port: null));
      expect(parseHostHeader('[::1]:8080'), (name: '[::1]', port: 8080));
      expect(parseHostHeader('[::1]'), (name: '[::1]', port: null));
      // 末尾のドットは取り除かない
      expect(
          parseHostHeader('localhost.:8080'), (name: 'localhost.', port: 8080));
    });

    /// 形式に合わない値は解釈しないこと
    test('returns null for malformed values', () {
      for (final value in [
        '',
        '  ',
        'localhost:',
        'localhost:abc',
        'localhost:+80',
        'localhost:0',
        'localhost:65536',
        'localhost:123456',
        '::1',
        '[::1',
        '[::1]x',
        '[]:80',
        ':80',
      ]) {
        expect(parseHostHeader(value), isNull, reason: value);
      }
    });
  });
}
