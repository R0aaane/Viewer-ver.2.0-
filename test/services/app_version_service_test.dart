import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/app_version_service.dart';

void main() {
  test('compareAppVersions compares build numbers numerically', () {
    expect(compareAppVersions('1.0.0+10', '1.0.0+2'), greaterThan(0));
    expect(compareAppVersions('1.2.0+1', '1.3.0+1'), lessThan(0));
    expect(compareAppVersions('1.0.0+1', '1.0.0+1'), 0);
  });
}
