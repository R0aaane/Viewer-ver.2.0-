import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'auth_token_store.dart';

/// Dedicated analysis host, independent of the remote media-library connection.
class ImagePromptHostService {
  static final instance = ImagePromptHostService();
  static const baseUrl = 'http://127.0.0.1:18891';
  Future<String>? _starting;
  Future<String> start() => _starting ??= _start().whenComplete(() => _starting = null);

  Future<String> _start() async {
    if (!Platform.isWindows) throw StateError('このPCの解析ホストはWindows版から起動してください。');
    Directory? root;
    for (final location in [Directory.current, File(Platform.resolvedExecutable).parent]) {
      var current = location.absolute;
      for (var i = 0; i < 10; i++) {
        if (File(p.join(current.path, 'server', 'main.py')).existsSync() && File(p.join(current.path, 'pubspec.yaml')).existsSync()) {
          root = current; break;
        }
        current = current.parent;
      }
      if (root != null) break;
    }
    if (root == null) throw StateError('解析ホストのサーバーファイルが見つかりません。');
    final data = p.join(root.path, 'data', 'local_analysis');
    final configFile = File(p.join(data, 'config.json'));
    if (!await configFile.exists()) throw StateError('解析ホストの設定がありません。data/local_analysis/config.jsonを設定してください。');
    final config = jsonDecode(await configFile.readAsString()) as Map;
    const storage = FlutterSecureStorage();
    var token = await storage.read(key: 'pdf_viewer.imagePromptToken');
    if (token == null) {
      token = AuthTokenStore.generate();
      await storage.write(key: 'pdf_viewer.imagePromptToken', value: token);
    }
    final client = Dio(BaseOptions(connectTimeout: const Duration(seconds: 2), receiveTimeout: const Duration(seconds: 3)));
    Future<bool> ready() async {
      try {
        await client.get('$baseUrl/image-prompt/configuration', options: Options(headers: {'Authorization': 'Bearer $token'}));
        return true;
      } on DioException { return false; }
    }
    try {
      if (await ready()) return token;
      try {
        final socket = await Socket.connect('127.0.0.1', 18891, timeout: const Duration(seconds: 1));
        socket.destroy();
        throw StateError('解析ホストのポート18891が使用中です。');
      } on SocketException { /* port is free */ }
      await Process.start(p.join(root.path, '.venv', 'Scripts', 'python.exe'),
        ['-m', 'uvicorn', 'server.main:app', '--host', '127.0.0.1', '--port', '18891', '--no-proxy-headers'],
        workingDirectory: root.path, mode: ProcessStartMode.detached,
        environment: {
          'MEDIA_SERVER_HOST': '127.0.0.1', 'MEDIA_SERVER_PORT': '18891',
          'MEDIA_SERVER_AUTH_TOKEN': token, 'MEDIA_SERVER_TAILNET_WITHOUT_TOKEN': 'false',
          'MEDIA_SERVER_ALLOWED_NETWORKS': '127.0.0.0/8;::1/128',
          'MEDIA_SERVER_DATA_DIR': data, 'MEDIA_SERVER_DB_PATH': p.join(data, 'metadata.db'),
          'MEDIA_SERVER_THUMBS_DIR': p.join(data, 'thumbs'), 'MEDIA_SERVER_MEDIA_ROOTS': '',
          'MEDIA_SERVER_STARTUP_RESCAN': 'false',
          'MEDIA_SERVER_GPU_LOCK_PATH': p.join(root.path, 'data', 'gpu_coordination.sqlite'), 'MEDIA_SERVER_COMFY_URL': '',
          'MEDIA_SERVER_COMFY_OUTPUT_DIR': '', 'MEDIA_SERVER_GENERATED_LIBRARY_DIR': '',
          'MEDIA_SERVER_COMFY_PRESETS_PATH': '',
          'MEDIA_SERVER_XVIEWER_SAVED_IMAGES_DIR': p.join(data, 'xsaved'),
          'MEDIA_SERVER_OLLAMA_URL': config['ollamaUrl'] as String? ?? 'http://127.0.0.1:11434',
          'MEDIA_SERVER_WD14_DIR': config['wd14Directory'] as String,
          'MEDIA_SERVER_IMAGE_PROMPT_COMFY_URL': config['comfyUrl'] as String? ?? 'http://127.0.0.1:8188',
          'MEDIA_SERVER_IMAGE_PROMPT_NUM_GPU': '${config['numGpu'] ?? -1}',
        });
      for (var i = 0; i < 45; i++) {
        if (await ready()) return token;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      throw StateError('解析ホストを起動できませんでした。設定とPython依存関係を確認してください。');
    } finally { client.close(force: true); }
  }
}
