// Loopback-only API fixtures for integration_test/web_compatibility_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

// A non-embedded Japanese CID font intentionally requires external PDF.js cMaps.
List<int> _japanesePdf() {
  const content = 'BT /F1 24 Tf 40 100 Td <65E5672C8A9E> Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>',
    '<< /Type /Font /Subtype /Type0 /BaseFont /HeiseiMin-W3 '
        '/Encoding /UniJIS-UCS2-H /DescendantFonts [5 0 R] >>',
    '<< /Type /Font /Subtype /CIDFontType0 /BaseFont /HeiseiMin-W3 '
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> '
        '/DW 1000 >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(buffer.toString());
}

Future<void> main() async {
  final document = pw.Document();
  for (final color in [const PdfColor(1, 0, 0), const PdfColor(0, 0, 1)]) {
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Center(
          child: pw.Container(width: 100, height: 100, color: color),
        ),
      ),
    );
  }
  final pdf = await document.save();
  final counts = <String, int>{};
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8766);
  stdout.writeln('Web test API listening on http://127.0.0.1:8766');
  await for (final request in server) {
    final response = request.response;
    response.headers.set(
      'Access-Control-Allow-Origin',
      'http://127.0.0.1:8765',
    );
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    response.headers.contentType = ContentType.json;
    final path = request.uri.path;
    if (path.startsWith('/media/')) {
      counts.update(path, (n) => n + 1, ifAbsent: () => 1);
    }
    if (request.method == 'OPTIONS') {
      response.statusCode = 204;
    } else if (path == '/test/reset') {
      counts.clear();
      response.write('{}');
    } else if (path == '/test/counts') {
      response.write(jsonEncode(counts));
    } else if (path == '/folders' || path == '/folders/children') {
      final count = counts.update(path, (n) => n + 1, ifAbsent: () => 1);
      if (count <= 2) {
        response.statusCode = 400;
        response.write('{"detail":"intentional test failure"}');
      } else {
        response.write('[]');
      }
    } else if (path.startsWith('/invalid-json/')) {
      response.headers.contentType = ContentType.html;
      response.write('<!DOCTYPE html><title>Wrong API endpoint</title>');
    } else if (path.startsWith('/media/protected/')) {
      response.statusCode = 401;
      response.write('{"detail":"authentication required"}');
    } else if (path == '/media/sample/download') {
      response.headers.contentType = ContentType('application', 'pdf');
      response.add(pdf);
    } else if (path == '/media/corrupt/download') {
      response.headers.contentType = ContentType('application', 'pdf');
      response.add('%PDF-broken'.codeUnits);
    } else if (path == '/media/japanese/download') {
      response.headers.contentType = ContentType('application', 'pdf');
      response.add(_japanesePdf());
    } else {
      response.statusCode = 404;
      response.write('{"detail":"not found"}');
    }
    await response.close();
  }
}
