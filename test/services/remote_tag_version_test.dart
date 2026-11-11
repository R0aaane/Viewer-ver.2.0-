import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/remote_tag_api_client.dart';

void main() {
  test(
    'legacy tag client sends the observed version and epoch and requires reread after conflict',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var version = 7;
      Map? submitted;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.method != 'GET') {
          submitted =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if (submitted!['expectedVersion'] != version ||
              submitted!['expectedEpoch'] != 'restored-epoch') {
            request.response.statusCode = 409;
            request.response.write('{"detail":"reload before editing"}');
            await request.response.close();
            return;
          }
          version++;
        }
        request.response.write(
          jsonEncode({
            'mediaId': 'image',
            'version': version,
            'epoch': 'restored-epoch',
            'items': [],
          }),
        );
        await request.response.close();
      });
      final client = RemoteTagApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      await client.fetchItemTags('image');
      version = 8;
      await expectLater(
        client.replaceTagsForItem('image', []),
        throwsA(isA<MetadataException>()),
      );
      expect(submitted!['expectedVersion'], 7);
      expect(submitted!['expectedEpoch'], 'restored-epoch');
      await client.fetchItemTags('image');
      await client.replaceTagsForItem('image', []);
      expect(submitted!['expectedVersion'], 8);
      expect(version, 9);
    },
  );
}
