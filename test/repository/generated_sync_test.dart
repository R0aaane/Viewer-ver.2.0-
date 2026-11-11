import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf_viewer/repository/generated_media_repository.dart';

void main() {
  test(
    'delta cursor survives reopen and offline retry, and restore epoch invalidates cache',
    () async {
      SharedPreferences.setMockInitialValues({});
      var online = true;
      var epoch = 'original';
      var head = 1;
      final observed = <int>[];
      GeneratedMediaRepository repository() {
        final client = Dio(
          BaseOptions(baseUrl: 'http://fixture.invalid/generated'),
        );
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (!online) {
                handler.reject(
                  DioException.connectionError(
                    requestOptions: options,
                    reason: 'offline',
                  ),
                  true,
                );
                return;
              }
              dynamic body = Uint8List(3);
              if (options.path == '/changes') {
                final cursor = options.queryParameters['after'] as int;
                observed.add(cursor);
                final reset =
                    options.queryParameters['epoch'] != null &&
                    options.queryParameters['epoch'] != epoch;
                body = {
                  'epoch': epoch,
                  'cursor': reset ? 0 : head,
                  'resetRequired': reset,
                  'hasMore': false,
                  'items': !reset && cursor < head
                      ? [
                          {'mediaId': 'image', 'seq': head, 'version': head},
                        ]
                      : [],
                };
              }
              handler.resolve(
                Response(requestOptions: options, statusCode: 200, data: body),
                true,
              );
            },
          ),
        );
        return GeneratedMediaRepository('', null, client: client);
      }

      final first = repository();
      await first.thumbnail('image');
      expect(first.cachedBytes, 3);
      expect(await first.synchronize(), isTrue);
      expect(first.cachedBytes, 0);
      first.close();
      final second = repository();
      addTearDown(second.close);
      expect(await second.synchronize(), isFalse);
      expect(observed.last, 1);
      online = false;
      head = 2;
      expect(await second.synchronize(), isFalse);
      online = true;
      expect(await second.synchronize(), isTrue);
      expect(observed.last, 1);
      await second.thumbnail('image');
      epoch = 'restored';
      head = 1;
      expect(await second.synchronize(), isTrue);
      expect(observed.last, 0);
      expect(second.cachedBytes, 0);
    },
  );
}
