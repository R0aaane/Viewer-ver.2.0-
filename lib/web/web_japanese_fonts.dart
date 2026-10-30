import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const webJapaneseFontFamily = 'PdfViewerJapanese';
const webJapaneseFontAssets = [
  'assets/fonts/NotoSansJP-Regular.woff2',
  'assets/fonts/NotoSansJP-Bold.woff2',
];

/// Load both styles before showing Japanese text, rather than on each new glyph.
/// WOFF2 is used only by the Web bootstrap; desktop keeps its existing fonts.
Future<void> loadWebJapaneseFonts({
  AssetBundle? bundle,
  FontLoader? loader,
}) async {
  final assets = bundle ?? rootBundle;
  final fonts = loader ?? FontLoader(webJapaneseFontFamily);
  // Observe every download immediately, including errors while another asset
  // is still loading or being registered by FontLoader.
  final data = await Future.wait(webJapaneseFontAssets.map(assets.load));
  for (final bytes in data) {
    fonts.addFont(Future.value(bytes));
  }
  await fonts.load();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Noto Sans JP',
    ], await assets.loadString('assets/fonts/OFL.txt'));
  });
}
