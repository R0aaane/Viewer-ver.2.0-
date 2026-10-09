@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/web/pdfjs_safety.dart';
import 'package:pdf_viewer/web/web_remote_api_client.dart';

extension type _TestLibrary._(JSObject _) implements JSObject {
  external factory _TestLibrary({JSFunction getDocument, String version});
  external JSFunction get getDocument;
  external String get version;
}

extension type _TestOptions._(JSObject _) implements JSObject {
  external factory _TestOptions({bool isEvalSupported, String url});
  external bool get isEvalSupported;
  external String get url;
}

void main() {
  test('PDF.js receives eval disabled and retains its other exports', () {
    var calls = 0;
    final source = _TestLibrary(
      version: '3.11.174',
      getDocument: ((JSObject raw) {
        final options = _TestOptions._(raw);
        expect(options.isEvalSupported, isFalse);
        expect(options.url, 'sample.pdf');
        calls++;
        return 7.toJS;
      }).toJS,
    );
    final safe = _TestLibrary._(securePdfJsLibrary(source));
    expect(safe.version, source.version);
    expect(securePdfJsLibrary(safe), same(safe));
    final result = safe.getDocument.callAsFunction(
      safe,
      _TestOptions(isEvalSupported: true, url: 'sample.pdf'),
    );
    expect((result as JSNumber).toDartInt, 7);
    expect(calls, 1);
  });

  test(
    'failed folder requests can retry without secondary async errors',
    () async {
      final client = WebRemoteApiClient(
        baseUrl: '${Uri.base.origin}/missing-api',
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          client.listFolders(),
          throwsA(isA<WebRemoteException>()),
        );
        await Future<void>.delayed(Duration.zero);
      }
    },
  );

  test('failed memoized requests evict the failed future safely', () async {
    final client = WebRemoteApiClient(
      baseUrl: '${Uri.base.origin}/missing-api',
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        client.listFolderChildren('missing-folder'),
        throwsA(isA<WebRemoteException>()),
      );
      await Future<void>.delayed(Duration.zero);
    }
  });
}
