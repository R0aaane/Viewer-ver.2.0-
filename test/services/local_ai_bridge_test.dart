import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/local_ai_bridge.dart';

void main() {
  late Directory directory;
  late LocalAiBridge bridge;
  late HttpClient http;
  late Map<String, dynamic> session;
  final opened = <String>[];
  var homeCount = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('localai-bridge-test-');
    opened.clear();
    homeCount = 0;
    bridge = LocalAiBridge(
      dataDirectory: directory.path,
      port: 0,
      open: (d) async {
        opened.add(d.title);
        return true;
      },
      showHome: () => homeCount++,
    );
    for (final name in ['design.pdf', 'design notes.pdf']) {
      await File('${directory.path}/$name').writeAsString('%PDF-1.4');
    }
    await bridge.start(
      ['design.pdf', 'design notes.pdf']
          .map((name) => LocalAiDocument('${directory.path}/$name', name))
          .toList(),
    );
    session = jsonDecode(
      await File('${directory.path}/pdf-viewer-session.json').readAsString(),
    );
    http = HttpClient()..findProxy = (_) => 'DIRECT';
  });
  tearDown(() async {
    http.close(force: true);
    await bridge.stop();
    bridge.dispose();
    await directory.delete(recursive: true);
  });

  Future<(int, String)> command(
    String action,
    String query, {
    String? token,
    String? origin,
  }) async {
    final request = await http.postUrl(
      Uri.parse('http://127.0.0.1:${session['port']}/command'),
    );
    request.headers.set('authorization', 'Bearer ${token ?? session['token']}');
    if (origin != null) request.headers.set('origin', origin);
    request.write(jsonEncode({'action': action, 'query': query}));
    final response = await request.close();
    return (response.statusCode, await utf8.decoder.bind(response).join());
  }

  test('authentication and browser origins cannot execute', () async {
    expect((await command('open', 'design', token: 'wrong')).$1, 401);
    expect(
      (await command('open', 'design', origin: 'https://example.com')).$1,
      401,
    );
    expect(opened, isEmpty);
  });
  test('exact match opens, ambiguity and arbitrary paths do not', () async {
    expect((await command('open', 'design')).$2, contains('開きました'));
    expect(opened, ['design.pdf']);
    expect((await command('open', 'des')).$2, contains('複数'));
    expect((await command('open', '../secret.pdf')).$2, contains('ありません'));
    expect((await command('shell', 'design')).$1, 400);
    expect(opened, hasLength(1));
  });
  test(
    'recommendations appear without opening documents and stop revokes session',
    () async {
      expect((await command('recommend', 'des')).$1, 200);
      expect(bridge.recommendations, hasLength(2));
      expect(homeCount, 1);
      expect(opened, isEmpty);
      await bridge.stop();
      expect(
        await File('${directory.path}/pdf-viewer-session.json').exists(),
        isFalse,
      );
      expect(bridge.recommendations, isEmpty);
    },
  );
  test('deleted document is not opened', () async {
    await File('${directory.path}/design.pdf').delete();
    expect((await command('open', 'design')).$2, contains('削除'));
    expect(opened, isEmpty);
  });
}
