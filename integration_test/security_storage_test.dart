import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows protected storage writes reads and removes a separate test credential',
    (tester) async {
      const storage = FlutterSecureStorage();
      final key =
          'pdf_viewer.phase6-test.${DateTime.now().microsecondsSinceEpoch}';
      addTearDown(() => storage.delete(key: key));
      await storage.write(key: key, value: 'temporary-storage-probe');
      expect(await storage.read(key: key), 'temporary-storage-probe');
      await storage.delete(key: key);
      expect(await storage.read(key: key), isNull);
    },
  );
}
