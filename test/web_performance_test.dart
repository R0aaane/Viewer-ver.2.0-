import 'package:flutter_test/flutter_test.dart';

import 'package:pdf_viewer/web/web_gamepad_poller.dart';
import 'package:pdf_viewer/web/web_performance_policy.dart';

void main() {
  test('WebKit policy covers Safari desktop, iPhone, iPad and iOS Chrome', () {
    for (final agent in [
      'Macintosh AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15',
      'iPhone AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1',
      'iPad AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15',
      'iPhone AppleWebKit/605.1.15 CriOS/130.0 Mobile/15E148 Safari/604.1',
    ]) {
      expect(WebPerformancePolicy.fromUserAgent(agent).reduceEffects, isTrue);
    }
    for (final agent in [
      'Macintosh AppleWebKit/537.36 Chrome/130.0 Safari/537.36',
      'Windows AppleWebKit/537.36 Chrome/130.0 Edg/130.0',
      'Android AppleWebKit/537.36 Chrome/130.0 Safari/537.36',
      'Macintosh Gecko/20100101 Firefox/130.0',
    ]) {
      expect(WebPerformancePolicy.fromUserAgent(agent).reduceEffects, isFalse);
    }
  });

  test(
    'large thumbnails are bounded without lowering small thumbnail detail',
    () {
      const webKit = WebPerformancePolicy(reduceEffects: true);
      const standard = WebPerformancePolicy(reduceEffects: false);
      expect(webKit.thumbnailDimension(1500), 1024);
      expect(standard.thumbnailDimension(1500), 2700);
      expect(webKit.thumbnailDimension(120), standard.thumbnailDimension(120));
    },
  );

  testWidgets(
    'polling stays idle without a controller and accelerates on connect',
    (tester) async {
      var calls = 0;
      var connected = false;
      final poller = WebGamepadPoller(
        isActive: () => true,
        poll: () {
          calls++;
          return connected;
        },
      );
      await tester.pump(const Duration(seconds: 2));
      expect(calls, 4);
      connected = true;
      await tester.pump(const Duration(milliseconds: 500));
      final before = calls;
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls - before, 5);
      connected = false;
      await tester.pump(const Duration(milliseconds: 80));
      final idle = calls;
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, idle);
      poller.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, idle);
    },
  );

  testWidgets(
    'hidden routes do not query controllers and recover when visible',
    (tester) async {
      var visible = false;
      var calls = 0;
      final poller = WebGamepadPoller(
        isActive: () => visible,
        poll: () {
          calls++;
          return true;
        },
      );
      await tester.pump(const Duration(seconds: 2));
      expect(calls, 0);
      visible = true;
      await tester.pump(const Duration(milliseconds: 500));
      expect(calls, 1);
      poller.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 1);
    },
  );
}
