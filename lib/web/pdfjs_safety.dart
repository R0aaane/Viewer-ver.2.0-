import 'dart:js_interop';

import 'pdfjs_runtime_config.dart';

@JS('Object.assign')
external JSObject _copyProperties(JSObject target, JSObject source);

extension type _Promise(JSObject _) implements JSObject {
  external _Promise then(JSFunction? onValue, JSFunction? onError);
}

extension type _LoadingTask(JSObject _) implements JSObject {
  external JSPromise<JSObject> get promise;
  external JSPromise<JSAny?> destroy();
}

extension type _Document(JSObject _) implements JSObject {
  @JS('destroy')
  external JSFunction? get destroyMethod;
  @JS('destroy')
  external set destroyMethod(JSFunction value);
}

extension type _PdfLibrary(JSObject _) implements JSObject {
  external JSFunction get getDocument;
  external set getDocument(JSFunction value);
  external bool? get pdfViewerEvalDisabled;
  external set pdfViewerEvalDisabled(bool value);
}

extension type _DocumentOptions(JSObject _) implements JSObject {
  external set isEvalSupported(bool value);
  external String? get standardFontDataUrl;
  external set standardFontDataUrl(String value);
  external String? get wasmUrl;
  external set wasmUrl(String value);
}

/// pdfx forwards only selected options, so setting window.pdfRenderOptions
/// alone does not disable eval. Apply the CVE-2024-4367 workaround at the
/// getDocument boundary, keeping the original PDF.js exports available.
JSObject securePdfJsLibrary(JSObject library) {
  final original = _PdfLibrary(library);
  if (original.pdfViewerEvalDisabled == true) return library;
  final getDocument = original.getDocument;
  final facade = _PdfLibrary(_copyProperties(JSObject(), library));
  facade.getDocument = ((JSObject options) {
    final documentOptions = _DocumentOptions(options);
    documentOptions.isEvalSupported = false;
    // pdfx forwards cMaps but not the additional assets used by modern PDF.js.
    documentOptions.standardFontDataUrl ??=
        '${pdfJsDistributionUrl}standard_fonts/';
    documentOptions.wasmUrl ??= '${pdfJsDistributionUrl}wasm/';
    final task = _LoadingTask(
      getDocument.callAsFunction(library, options) as JSObject,
    );
    // Register before pdfx's promise callback without replacing PDF.js's own
    // promise or passing native JS exceptions through a Dart promise bridge.
    _Promise(task.promise)
        .then(
          ((JSObject document) {
            // PDF.js 6 moved document.destroy to loadingTask.destroy; pdfx 2.x
            // still calls it on the document. Preserve the loading task itself.
            _Document(document).destroyMethod ??= (() => task.destroy()).toJS;
            return document;
          }).toJS,
          ((JSAny? error) {
            // pdfx never receives the loading task when opening fails.
            return task.destroy();
          }).toJS,
        )
        .then(
          null,
          ((JSAny? error) {
            // The original loading promise still reports the open error to pdfx.
          }).toJS,
        );
    return task;
  }).toJS;
  facade.pdfViewerEvalDisabled = true;
  return facade;
}
