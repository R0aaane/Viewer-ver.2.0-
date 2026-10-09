import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfx/pdfx.dart';
import 'package:pdfx/src/renderer/interfaces/platform.dart';

class FakePdfDocument extends Fake implements PdfDocument {
  bool closed = false;
  int closeCount = 0;
  int activePages = 0;
  int closedPages = 0;
  bool failRender = false;
  Completer<void>? renderGate;

  @override
  int get pagesCount => 10;

  @override
  Future<void> close() async {
    expect(activePages, 0, reason: 'Document closed during rendering');
    closed = true;
    closeCount++;
  }

  @override
  Future<PdfPage> getPage(
    int pageNumber, {
    bool autoCloseAndroid = false,
  }) async {
    expect(closed, isFalse, reason: 'Rendering an evicted document');
    expect(activePages, 0, reason: 'Concurrent pages on the same document');
    activePages++;
    return _FakePdfPage(this);
  }
}

class _FakePdfPage extends Fake implements PdfPage {
  _FakePdfPage(this.owner);
  final FakePdfDocument owner;

  @override
  double get width => 600;
  @override
  double get height => 800;

  @override
  Future<PdfPageImage?> render({
    required double width,
    required double height,
    PdfPageImageFormat format = PdfPageImageFormat.jpeg,
    String? backgroundColor,
    Rect? cropRect,
    int quality = 100,
    bool forPrint = false,
    bool removeTempFile = true,
  }) async {
    await owner.renderGate?.future;
    if (owner.failRender) throw StateError('Render failed');
    return _FakePdfImage();
  }

  @override
  Future<void> close() async {
    owner.activePages--;
    owner.closedPages++;
  }
}

class _FakePdfImage extends Fake implements PdfPageImage {
  @override
  Uint8List get bytes => Uint8List.fromList([1, 2, 3]);
}

class FakePdfPlatform extends PdfxPlatform {
  final documents = <FakePdfDocument>[];
  bool failRender = false;

  @override
  Future<PdfDocument> openFile(String filePath, {String? password}) async {
    final document = FakePdfDocument()..failRender = failRender;
    documents.add(document);
    return document;
  }

  @override
  Future<PdfDocument> openAsset(String name, {String? password}) =>
      throw UnimplementedError();

  @override
  Future<PdfDocument> openData(FutureOr<Uint8List> data, {String? password}) =>
      throw UnimplementedError();
}
