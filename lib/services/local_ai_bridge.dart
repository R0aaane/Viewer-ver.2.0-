import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

class LocalAiDocument {
  final String path;
  final String title;
  const LocalAiDocument(this.path, this.title);
}

/// Session-only allowlist. No filesystem paths or commands are accepted over IPC.
class LocalAiBridge extends ChangeNotifier {
  final Future<bool> Function(LocalAiDocument) open;
  final VoidCallback showHome;
  final String dataDirectory;
  final int port;
  LocalAiBridge({
    required this.open,
    required this.showHome,
    required this.dataDirectory,
    this.port = 47961,
  });

  HttpServer? _server;
  String? _token;
  bool _disposed = false;
  bool _executing = false;
  List<LocalAiDocument> _documents = [];
  List<LocalAiDocument> recommendations = [];
  String reason = '';
  bool get connected => _server != null;
  int get documentCount => _documents.length;
  File get _session => File('$dataDirectory/pdf-viewer-session.json');

  Future<void> start(List<LocalAiDocument> documents) async {
    await stop();
    if (_disposed) return;
    final valid = <LocalAiDocument>[];
    for (final document in documents.take(500)) {
      if (document.path.toLowerCase().endsWith('.pdf') &&
          await File(document.path).exists()) {
        valid.add(document);
      }
    }
    if (valid.isEmpty) throw const FormatException('PDFを選択してください。');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    if (_disposed) {
      await server.close(force: true);
      return;
    }
    _server = server;
    _documents = valid;
    final random = Random.secure();
    _token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    try {
      await _session.parent.create(recursive: true);
      await _session.writeAsString(
        jsonEncode({'port': server.port, 'token': _token}),
        flush: true,
      );
      if (_disposed) {
        await stop();
        return;
      }
      server.listen((request) => unawaited(_handle(request)), onError: (_) {});
      notifyListeners();
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final sessionToken = _token;
    try {
      if (_token == null ||
          request.headers.value('authorization') != 'Bearer $_token' ||
          request.headers.value('origin') != null) {
        request.response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/command') {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      if (_executing) {
        request.response.statusCode = HttpStatus.conflict;
        return;
      }
      _executing = true;
      try {
        final bytes = <int>[];
        await for (final chunk in request.timeout(const Duration(seconds: 5))) {
          bytes.addAll(chunk);
          if (bytes.length > 4096) throw const FormatException();
        }
        final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final query = body['query'] as String;
        final action = body['action'];
        if (query.trim().isEmpty ||
            query.length > 200 ||
            !['open', 'recommend'].contains(action)) {
          throw const FormatException();
        }
        if (_disposed || _token == null || _token != sessionToken) return;
        final needle = query.toLowerCase();
        final exact = _documents
            .where(
              (d) =>
                  d.title.toLowerCase() == needle ||
                  d.title.toLowerCase().replaceFirst(RegExp(r'\.pdf$'), '') ==
                      needle,
            )
            .toList();
        final matches = exact.isNotEmpty
            ? exact
            : _documents
                  .where((d) => d.title.toLowerCase().contains(needle))
                  .toList();
        String message;
        if (matches.isEmpty) {
          message = '共有したPDFに一致する資料がありません。資料名の一部を指定してください。';
        } else if (action == 'open') {
          if (matches.length != 1) {
            message =
                '複数の資料が一致しました。名前を絞ってください：${matches.take(5).map((d) => d.title).join('、')}';
          } else if (!await File(matches.single.path).exists()) {
            message = '資料が移動または削除されています。共有するPDFを選び直してください。';
          } else {
            if (_disposed || _token != sessionToken) return;
            message = await open(matches.single)
                ? 'ビューアーで「${matches.single.title}」を開きました。'
                : 'ビューアーが別の資料を表示中です。ホームに戻って再実行してください。';
          }
        } else {
          recommendations = matches.take(5).toList();
          reason = '資料名が「$query」に一致（本文は未解析）';
          showHome();
          notifyListeners();
          message =
              'ホームのおすすめを更新しました：${recommendations.map((d) => d.title).join('、')}。$reason';
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'message': message}));
      } finally {
        _executing = false;
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    final token = _token;
    _token = null;
    final server = _server;
    _server = null;
    _documents = [];
    recommendations = [];
    try {
      if (token != null && await _session.exists()) {
        final saved = jsonDecode(await _session.readAsString());
        if (saved['token'] == token) await _session.delete();
      }
    } catch (_) {}
    await server?.close(force: true);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
