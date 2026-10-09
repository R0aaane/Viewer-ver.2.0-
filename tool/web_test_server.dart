// Loopback-only API fixtures for integration_test/web_compatibility_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

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
    } else {
      response.statusCode = 404;
      response.write('{"detail":"not found"}');
    }
    await response.close();
  }
}
