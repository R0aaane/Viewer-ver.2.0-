import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/repository/generated_media_repository.dart';

void main() {
  test(
    'thumbnail requests share downloads, evict by bytes and retry offline failures',
    () async {
      final client = Dio(
        BaseOptions(baseUrl: 'http://fixture.invalid/generated'),
      );
      final requests = <String>[];
      var online = true;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options.path);
            if (!online) {
              handler.reject(
                DioException.connectionError(
                  requestOptions: options,
                  reason: 'offline',
                ),
                true,
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: Uint8List(options.path.contains('oversize') ? 7 : 3),
                ),
                true,
              );
            }
          },
        ),
      );
      final repo = GeneratedMediaRepository(
        '',
        '',
        client: client,
        thumbnailBudget: 6,
      );
      addTearDown(repo.close);
      await Future.wait([repo.thumbnail('a'), repo.thumbnail('a')]);
      await repo.thumbnail('b');
      await repo.thumbnail('a');
      await repo.thumbnail('c');
      expect(requests.length, 3);
      expect(repo.cachedBytes, 6);
      await repo.thumbnail('b');
      expect(requests.length, 4);
      await repo.thumbnail('oversize');
      expect(repo.cachedBytes, 6);
      online = false;
      await expectLater(
        repo.thumbnail('missing'),
        throwsA(isA<DioException>()),
      );
      expect(repo.connection.value, GalleryConnection.offline);
      online = true;
      await repo.thumbnail('missing');
      expect(repo.connection.value, GalleryConnection.connected);
      expect(repo.cachedBytes, 6);
    },
  );
}
