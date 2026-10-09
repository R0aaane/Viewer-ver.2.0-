// Run from the project root:
// dart compile js tool/pdfjs_safety_smoke.dart -o build/pdfjs_safety_smoke.js
// node -e "globalThis.self=globalThis;require('./build/pdfjs_safety_smoke.js')"
import 'dart:js_interop';

import 'package:pdf_viewer/web/pdfjs_safety.dart';

extension type TestLibrary._(JSObject _) implements JSObject {
  external factory TestLibrary({JSFunction getDocument, String version});
  external JSFunction get getDocument;
  external String get version;
}

extension type TestOptions._(JSObject _) implements JSObject {
  external factory TestOptions({bool isEvalSupported, String url});
  external bool get isEvalSupported;
  external String get url;
}

extension type TestTask._(JSObject _) implements JSObject {
  external factory TestTask({JSPromise<JSObject> promise, JSFunction destroy});
}

void main() {
  var calls = 0;
  final task = TestTask(
    promise: Future<JSObject>.value(JSObject()).toJS,
    destroy: (() => Future<JSAny?>.value(null).toJS).toJS,
  );
  final library = TestLibrary(
    version: 'test',
    getDocument: ((JSObject raw) {
      final options = TestOptions._(raw);
      if (options.isEvalSupported || options.url != 'sample.pdf') {
        throw StateError('Unsafe or changed PDF options');
      }
      calls++;
      return task;
    }).toJS,
  );
  final safe = TestLibrary._(securePdfJsLibrary(library));
  final result = safe.getDocument.callAsFunction(
    safe,
    TestOptions(isEvalSupported: true, url: 'sample.pdf'),
  );
  if (!identical(result, task) ||
      calls != 1 ||
      safe.version != 'test' ||
      !identical(securePdfJsLibrary(safe), safe)) {
    throw StateError('PDF.js facade changed the library contract');
  }
}
