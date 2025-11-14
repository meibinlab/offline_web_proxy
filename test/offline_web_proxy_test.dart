import 'package:flutter_test/flutter_test.dart';
import 'package:offline_web_proxy/offline_web_proxy.dart';

void main() {
  group('OfflineWebProxy', () {
    /// プロキシインスタンスのテスト
    test('should create proxy instance', () {
      final proxy = OfflineWebProxy();
      expect(proxy, isNotNull);
      expect(proxy.isRunning, isFalse);
    });

    /// イベントストリームのテスト
    test('should provide event stream', () {
      final proxy = OfflineWebProxy();
      expect(proxy.events, isA<Stream<ProxyEvent>>());
    });

    /// 設定の初期化テスト
    test('should initialize with default config', () async {
      final proxy = OfflineWebProxy();
      
      // 基本的な初期化テスト（実際のサーバー起動は行わない）
      expect(proxy.isRunning, isFalse);
    });
  });
}
