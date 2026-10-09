import 'dart:js_interop';

@JS('Object.assign')
external JSObject _copyProperties(JSObject target, JSObject source);

extension type _PdfLibrary(JSObject _) implements JSObject {
  external JSFunction get getDocument;
  external set getDocument(JSFunction value);
  external bool? get pdfViewerEvalDisabled;
  external set pdfViewerEvalDisabled(bool value);
}

extension type _DocumentOptions(JSObject _) implements JSObject {
  external set isEvalSupported(bool value);
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
    _DocumentOptions(options).isEvalSupported = false;
    return getDocument.callAsFunction(library, options);
  }).toJS;
  facade.pdfViewerEvalDisabled = true;
  return facade;
}
