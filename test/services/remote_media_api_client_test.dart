import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/remote_media_api_client.dart';

void main() {
  test(
    'stalled download bodies time out and remove the partial file',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final temp = await Directory.systemTemp.createTemp(
        'download-timeout-test-',
      );
      final finish = Completer<void>();
      addTearDown(() async {
        finish.complete();
        await server.close(force: true);
        await temp.delete(recursive: true);
      });
      server.listen((request) async {
        try {
          request.response.add([1, 2, 3]);
          await request.response.flush();
          await finish.future;
          await request.response.close();
        } catch (_) {}
      });
      final client = RemoteMediaApiClient(
        baseUrl: 'http://${server.address.host}:${server.port}',
        timeout: const Duration(milliseconds: 200),
      );
      final destination = File('${temp.path}/partial.pdf');
      await expectLater(
        client
            .downloadMediaToFile('pdf', destination)
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<RemoteMediaException>()),
      );
      expect(await destination.exists(), isFalse);
    },
  );

  test('an HTTP error preserves a destination that was never opened', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final temp = await Directory.systemTemp.createTemp('download-error-test-');
    addTearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    server.listen((request) async {
      request.response.statusCode = 404;
      await request.response.close();
    });
    final destination = File('${temp.path}/existing.pdf');
    await destination.writeAsBytes([7, 8, 9]);
    final client = RemoteMediaApiClient(
      baseUrl: 'http://${server.address.host}:${server.port}',
    );
    await expectLater(
      client.downloadMediaToFile('missing', destination),
      throwsA(isA<RemoteMediaException>()),
    );
    expect(await destination.readAsBytes(), [7, 8, 9]);
  });

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
