import 'dart:js_interop';
import 'dart:convert';
// Browser-only integration test; no production native imports.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_viewer/web/pdfjs_safety.dart';
import 'package:pdf_viewer/web/web_remote_api_client.dart';

extension type _TestLibrary._(JSObject _) implements JSObject {
  external factory _TestLibrary({JSFunction getDocument, String version});
  external JSFunction get getDocument;
  external String get version;
}

extension type _TestOptions._(JSObject _) implements JSObject {
  external factory _TestOptions({bool isEvalSupported, String url});
  external bool get isEvalSupported;
  external String get url;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const apiBase = 'http://127.0.0.1:8766';
  setUp(() async {
    await html.HttpRequest.getString('$apiBase/test/reset');
  });
  testWidgets('PDF.js receives eval disabled and retains its other exports', (
    tester,
  ) async {
    var calls = 0;
    final source = _TestLibrary(
      version: '3.11.174',
      getDocument: ((JSObject raw) {
        final options = _TestOptions._(raw);
        expect(options.isEvalSupported, isFalse);
        expect(options.url, 'sample.pdf');
        calls++;
        return 7.toJS;
      }).toJS,
    );
    final safe = _TestLibrary._(securePdfJsLibrary(source));
    expect(safe.version, source.version);
    expect(securePdfJsLibrary(safe), same(safe));
    final result = safe.getDocument.callAsFunction(
      safe,
      _TestOptions(isEvalSupported: true, url: 'sample.pdf'),
    );
    expect((result as JSNumber).toDartInt, 7);
    expect(calls, 1);
  });

  testWidgets(
    'failed folder requests can retry without secondary async errors',
    (tester) async {
      final client = WebRemoteApiClient(baseUrl: apiBase);
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          client.listFolders(),
          throwsA(isA<WebRemoteException>()),
        );
        await Future<void>.delayed(Duration.zero);
      }
      expect(await client.listFolders(), isEmpty);
      final counts = jsonDecode(
        await html.HttpRequest.getString('$apiBase/test/counts'),
      );
      expect(counts['/folders'], 3);
    },
  );

  testWidgets('failed memoized requests evict the failed future safely', (
    tester,
  ) async {
    final client = WebRemoteApiClient(baseUrl: apiBase);
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        client.listFolderChildren('missing-folder'),
        throwsA(isA<WebRemoteException>()),
      );
      await Future<void>.delayed(Duration.zero);
    }
    expect(await client.listFolderChildren('missing-folder'), isEmpty);
    final counts = jsonDecode(
      await html.HttpRequest.getString('$apiBase/test/counts'),
    );
    expect(counts['/folders/children'], 3);
  });

  testWidgets('non-JSON API response is a recoverable API error', (
    tester,
  ) async {
    final client = WebRemoteApiClient(baseUrl: '$apiBase/invalid-json');
    await expectLater(client.listFolders(), throwsA(isA<WebRemoteException>()));
  });

  testWidgets(
    'unauthorized thumbnail preserves status without retry or PDF fallback',
    (tester) async {
      final client = WebRemoteApiClient(baseUrl: apiBase);
      await expectLater(
        client.fetchThumbnail('protected', page: 1),
        throwsA(
          isA<WebRemoteException>()
              .having((error) => error.statusCode, 'HTTP status', 401)
              .having(
                (error) => error.message,
                'message',
                'authentication required',
              ),
        ),
      );
      final counts = jsonDecode(
        await html.HttpRequest.getString('$apiBase/test/counts'),
      );
      expect(counts['/media/protected/thumb'], 1);
      expect(counts.containsKey('/media/protected/download'), isFalse);
    },
  );

  testWidgets(
    'real PDF.js worker renders two pages and recovers after corrupt data',
    (tester) async {
      final client = WebRemoteApiClient(baseUrl: apiBase);
      for (var page = 1; page <= 2; page++) {
        final bytes = await client.fetchThumbnail(
          'sample',
          page: page,
          width: 320,
        );
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        try {
          expect(frame.image.width, 320);
          final rgba = (await frame.image.toByteData())!;
          final center =
              ((frame.image.height ~/ 2) * frame.image.width +
                  frame.image.width ~/ 2) *
              4;
          expect(rgba.getUint8(center), page == 1 ? 255 : 0);
          expect(rgba.getUint8(center + 2), page == 1 ? 0 : 255);
        } finally {
          frame.image.dispose();
          codec.dispose();
        }
      }
      await expectLater(
        client.fetchThumbnail('corrupt', page: 1),
        throwsA(isA<WebRemoteException>()),
      );
      expect(
        await client.fetchThumbnail('sample', page: 1, width: 320),
        isNotEmpty,
      );
    },
  );
}
