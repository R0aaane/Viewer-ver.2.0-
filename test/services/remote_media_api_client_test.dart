import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/remote_media_api_client.dart';

void main() {
  test(
    'downloadUrl uses uploadTimeout for long-running server responses',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((HttpRequest request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/download-url');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, dynamic>{
            'importedCount': 2,
            'skippedCount': 0,
            'failedCount': 0,
            'taggedCount': 2,
            'organizedCount': 2,
            'rescannedCount': 1,
          }),
        );
        await request.response.close();
      });

      final client = RemoteMediaApiClient(
        baseUrl: 'http://${server.address.host}:${server.port}',
        timeout: const Duration(milliseconds: 50),
        uploadTimeout: const Duration(milliseconds: 500),
      );

      final result = await client.downloadUrl(
        folderRaw: r'C:\library',
        sourceUrl: 'https://hitomi.la/search.html?artist%3Atest',
      );

      expect(result.importedCount, 2);
      expect(result.skippedCount, 0);
      expect(result.failedCount, 0);
      expect(result.taggedCount, 2);
      expect(result.organizedCount, 2);
      expect(result.rescannedCount, 1);
    },
  );
}
