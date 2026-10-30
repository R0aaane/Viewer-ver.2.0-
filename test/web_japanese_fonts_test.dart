import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/app/app_theme.dart';
import 'package:pdf_viewer/web/web_japanese_fonts.dart';

class _FontAssets extends CachingAssetBundle {
  final requests = <String>[];
  bool fail = false;

  @override
  Future<ByteData> load(String key) async {
    requests.add(key);
    if (fail) throw StateError('font asset missing');
    return ByteData.sublistView(Uint8List.fromList([1, 2, 3]));
  }
}

class _FontRegistration extends FontLoader {
  final gates = [Completer<void>(), Completer<void>()];
  int styles = 0;

  _FontRegistration() : super(webJapaneseFontFamily);

  @override
  Future<void> loadFont(Uint8List list, String family) async {
    expect(family, webJapaneseFontFamily);
    await gates[styles++].future;
  }
}

void main() {
  test(
    'both styles must finish registering before fonts become ready',
    () async {
      final assets = _FontAssets();
      final loader = _FontRegistration();
      var ready = false;
      final future = loadWebJapaneseFonts(
        bundle: assets,
        loader: loader,
      ).then((_) => ready = true);
      await pumpEventQueue();
      expect(assets.requests, webJapaneseFontAssets);
      expect(loader.styles, 1);
      expect(ready, isFalse);
      loader.gates[0].complete();
      await pumpEventQueue();
      expect(loader.styles, 2);
      expect(ready, isFalse);
      loader.gates[1].complete();
      await future;
      expect(ready, isTrue);
    },
  );

  test(
    'missing font assets are reported so startup can use its fallback',
    () async {
      final assets = _FontAssets()..fail = true;
      await expectLater(
        loadWebJapaneseFonts(bundle: assets, loader: _FontRegistration()),
        throwsStateError,
      );
    },
  );

  test('Web Japanese family applies to body, controls and app bar', () {
    final theme = buildAppTheme(fontFamily: webJapaneseFontFamily);
    expect(theme.textTheme.bodyMedium?.fontFamily, webJapaneseFontFamily);
    expect(theme.textTheme.labelLarge?.fontFamily, webJapaneseFontFamily);
    expect(theme.appBarTheme.titleTextStyle?.fontFamily, webJapaneseFontFamily);
    expect(theme.chipTheme.labelStyle?.fontFamily, webJapaneseFontFamily);
    expect(
      theme.chipTheme.secondaryLabelStyle?.fontFamily,
      webJapaneseFontFamily,
    );
    expect(
      theme.inputDecorationTheme.labelStyle?.fontFamily,
      webJapaneseFontFamily,
    );
    expect(
      theme.inputDecorationTheme.hintStyle?.fontFamily,
      webJapaneseFontFamily,
    );
    expect(
      theme.dropdownMenuTheme.textStyle?.fontFamily,
      webJapaneseFontFamily,
    );
    expect(
      buildAppTheme().textTheme.bodyMedium?.fontFamily,
      isNot(webJapaneseFontFamily),
    );
  });
}
