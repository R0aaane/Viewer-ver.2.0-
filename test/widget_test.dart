import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/metadata_settings.dart';

void main() {
  test('MetadataSettings の既定モードは standalone', () {
    const settings = MetadataSettings();
    expect(settings.appMode, AppMode.standalone);
    expect(settings.isStandaloneMode, isTrue);
    expect(settings.isRemote, isFalse);
  });
}
