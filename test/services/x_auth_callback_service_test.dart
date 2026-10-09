import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/xviewer/core/errors/app_exception.dart';
import 'package:pdf_viewer/xviewer/services/x_auth_callback_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('xviewer/auth_callback');
  const events = MethodChannel('xviewer/auth_callback/events');

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });

  test(
    'timeout cancels the native event subscription and reports AppException',
    () async {
      var cancelled = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        method,
        (_) async => null,
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(events, (
        call,
      ) async {
        if (call.method == 'cancel') cancelled = true;
        return null;
      });
      await expectLater(
        const XAuthCallbackService().waitForCallback(
          'xviewer://oauth',
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<AppException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue);
    },
  );

  test('callback credentials are returned but never logged', () async {
    const callback = 'xviewer://oauth?code=private-code&state=private-state';
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      method,
      (_) async => callback,
    );
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    try {
      expect(
        await const XAuthCallbackService().consumePendingCallback(
          'xviewer://oauth',
        ),
        Uri.parse(callback),
      );
    } finally {
      debugPrint = previous;
    }
    expect(logs.join(), isNot(contains('private-code')));
    expect(logs.join(), isNot(contains('private-state')));
  });
}
