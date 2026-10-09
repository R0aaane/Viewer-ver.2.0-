import 'dart:js_interop';
import 'dart:convert';
// Browser-only integration test; no production native imports.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_viewer/web/pdfjs_safety.dart';
import 'package:pdf_viewer/web/pdfjs_runtime_config.dart';
import 'package:pdf_viewer/web/web_remote_api_client.dart';

extension type _TestLibrary._(JSObject _) implements JSObject {
  external factory _TestLibrary({JSFunction getDocument, String version});
  external JSFunction get getDocument;
  external String get version;
}

extension type _TestOptions._(JSObject _) implements JSObject {
  external factory _TestOptions({
    bool isEvalSupported,
    String url,
    String? standardFontDataUrl,
    String? wasmUrl,
  });
  external bool get isEvalSupported;
  external String get url;
  external String get standardFontDataUrl;
  external String get wasmUrl;
}

@JS('pdfjsLib')
external _RuntimeLibrary get _runtime;

extension type _RuntimeLibrary(JSObject _) implements JSObject {
  external String get version;
  external _LoadingTask getDocument(_LoadOptions options);
}

extension type _LoadOptions._(JSObject _) implements JSObject {
  external factory _LoadOptions({
    String url,
    String cMapUrl,
    bool cMapPacked,
    _PdfWorker worker,
  });
}

@JS('pdfjsLib.PDFWorker')
extension type _PdfWorker._(JSObject _) implements JSObject {
  external factory _PdfWorker();
  external JSPromise<JSAny?> get promise;
  external _WorkerPort get port;
  external void destroy();
}

extension type _WorkerPort(JSObject _) implements JSObject {
  external _Constructor get constructor;
}

extension type _Constructor(JSObject _) implements JSObject {
  external String get name;
}

extension type _LoadingTask(JSObject _) implements JSObject {
  external JSPromise<_Document> get promise;
  external JSPromise<JSAny?> destroy();
}

extension type _FakeTask._(JSObject _) implements JSObject {
  external factory _FakeTask({JSPromise<JSObject> promise, JSFunction destroy});
}

@JS('Promise.reject')
external JSPromise<JSObject> _rejectedPromise(JSAny error);

extension type _TestPromise(JSObject _) implements JSObject {
  external JSPromise<JSAny?> then(JSFunction? onValue, JSFunction? onError);
}

extension type _Document(JSObject _) implements JSObject {
  external int get numPages;
  external JSPromise<_Page> getPage(int page);
  external JSPromise<JSAny?> destroy();
}

extension type _Page(JSObject _) implements JSObject {
  external JSPromise<_TextContent> getTextContent();
}

extension type _TextContent(JSObject _) implements JSObject {
  external JSArray<_TextItem> get items;
}

extension type _TextItem(JSObject _) implements JSObject {
  external String? get str;
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
    final tasks = <JSObject>[];
    final source = _TestLibrary(
      version: '3.11.174',
      getDocument: ((JSObject raw) {
        final options = _TestOptions._(raw);
        expect(options.isEvalSupported, isFalse);
        expect(options.url, 'sample.pdf');
        expect(
          options.standardFontDataUrl,
          calls == 0
              ? '${pdfJsDistributionUrl}standard_fonts/'
              : 'custom-fonts/',
        );
        expect(
          options.wasmUrl,
          calls == 0 ? '${pdfJsDistributionUrl}wasm/' : 'custom-wasm/',
        );
        calls++;
        final task = _FakeTask(
          promise: Future<JSObject>.value(JSObject()).toJS,
          destroy: (() => Future<JSAny?>.value(null).toJS).toJS,
        );
        tasks.add(task);
        return task;
      }).toJS,
    );
    final safe = _TestLibrary._(securePdfJsLibrary(source));
    expect(safe.version, source.version);
    expect(securePdfJsLibrary(safe), same(safe));
    final result = safe.getDocument.callAsFunction(
      safe,
      _TestOptions(isEvalSupported: true, url: 'sample.pdf'),
    );
    expect(result, same(tasks.first));
    expect(calls, 1);
    safe.getDocument.callAsFunction(
      safe,
      _TestOptions(
        url: 'sample.pdf',
        standardFontDataUrl: 'custom-fonts/',
        wasmUrl: 'custom-wasm/',
      ),
    );
    expect(calls, 2);
  });

  testWidgets(
    'PDF.js compatibility closes successful and failed loading tasks',
    (tester) async {
      for (final failOpen in [false, true]) {
        var destroyed = 0;
        final failure = JSObject();
        final source = _TestLibrary(
          version: pdfJsVersion,
          getDocument: ((JSObject _) => _FakeTask(
            promise: failOpen
                ? _rejectedPromise(failure)
                : Future<JSObject>.value(JSObject()).toJS,
            destroy: (() {
              destroyed++;
              return Future<JSAny?>.value(null).toJS;
            }).toJS,
          )).toJS,
        );
        final safe = _RuntimeLibrary(securePdfJsLibrary(source));
        final task = safe.getDocument(_LoadOptions(url: 'test.pdf'));
        if (failOpen) {
          // Native JS callbacks run outside the test zone; return the identity
          // check and assert in the Dart test continuation.
          final preserved = await _TestPromise(task.promise)
              .then(
                ((JSAny? value) => false.toJS).toJS,
                ((JSAny? error) => identical(error, failure).toJS).toJS,
              )
              .toDart;
          expect((preserved as JSBoolean).toDart, isTrue);
        } else {
          final document = await task.promise.toDart;
          expect(destroyed, 0);
          await document.destroy().toDart;
        }
        expect(destroyed, 1);
      }
    },
  );

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

  testWidgets('pinned PDF.js uses a real worker and decodes Japanese cMaps', (
    tester,
  ) async {
    final client = WebRemoteApiClient(baseUrl: apiBase);
    // Exercise the application's actual loader and pdfx renderer first.
    expect(
      await client.fetchThumbnail('japanese', page: 1, width: 320),
      isNotEmpty,
    );
    expect(_runtime.version, pdfJsVersion);
    final worker = _PdfWorker();
    _LoadingTask? task;
    try {
      await worker.promise.toDart;
      expect(worker.port.constructor.name, 'Worker');
      task = _runtime.getDocument(
        _LoadOptions(
          url: '$apiBase/media/japanese/download',
          cMapUrl: '${pdfJsDistributionUrl}cmaps/',
          cMapPacked: true,
          worker: worker,
        ),
      );
      final document = await task.promise.toDart;
      expect(document.numPages, 1);
      final page = await document.getPage(1).toDart;
      final text = await page.getTextContent().toDart;
      expect(text.items.toDart.map((item) => item.str ?? '').join(), '日本語');
    } finally {
      await task?.destroy().toDart;
      worker.destroy();
    }
  });
}
