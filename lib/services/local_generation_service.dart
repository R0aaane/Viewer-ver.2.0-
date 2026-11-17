import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import 'auth_token_store.dart';
import 'app_settings_service.dart';

/// A separate loopback worker reuses the durable generation queue without
/// changing the remote library connection or sharing its credentials.
class LocalGenerationService {
  static final instance = LocalGenerationService();
  static const baseUrl = 'http://127.0.0.1:18890';
  Future<String>? _starting;
  String? libraryPath;
  String? _configPath;
  Future<void>? _preparingComfy;

  Future<String> start({bool requireComfy = true}) async {
    final token = await (_starting ??= _start().whenComplete(() => _starting = null));
    await _configureRelay(token);
    if (requireComfy) {
      await (_preparingComfy ??= _prepareComfy().whenComplete(() => _preparingComfy = null));
    }
    return token;
  }

  Future<void> _configureRelay(String token) async {
    final settings = await AppSettingsService().loadMetadataSettings();
    if (!settings.isClientMode) return;
    final client = Dio(BaseOptions(connectTimeout: const Duration(seconds: 3), receiveTimeout: const Duration(seconds: 5)));
    try {
      await client.post('$baseUrl/generated/relay', data: {
        'base_url': settings.remoteApiBaseUrl, 'token': settings.authToken ?? '',
      }, options: Options(headers: {'Authorization': 'Bearer $token'}));
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final detail = error.response?.data;
      final reason = detail is Map && detail['detail'] is String ? detail['detail'] as String : 'サービスの起動状態を確認してください';
      throw StateError('ホストへの送信設定を反映できません（${status ?? error.type.name}）: $reason');
    } finally { client.close(force: true); }
  }

  Future<void> _prepareComfy() async {
    final config = jsonDecode(await File(_configPath!).readAsString()) as Map;
    final comfyUrl = Uri.parse(config['comfyUrl'] as String);
    final client = Dio(BaseOptions(connectTimeout: const Duration(seconds: 2), receiveTimeout: const Duration(seconds: 3)));
    try {
      try {
        await client.get('$comfyUrl/system_stats');
      } on DioException {
        await Process.start(
          config['pythonPath'] as String,
          [
            '-s',
            'ComfyUI/main.py',
            '--windows-standalone-build',
            '--listen',
            '127.0.0.1',
            '--port',
            '${comfyUrl.port}',
          ],
          workingDirectory: config['comfyRoot'] as String,
          mode: ProcessStartMode.detached,
        );
        var available = false;
        for (var i = 0; i < 180; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          try {
            await client.get('$comfyUrl/system_stats');
            available = true;
            break;
          } on DioException {
            /* ComfyUI is still loading its nodes. */
          }
        }
        if (!available) throw StateError('ComfyUIの起動が完了しませんでした。起動ログを確認してください。');
      }
      await _configureLora(client, comfyUrl, config['presetsPath'] as String);
    } finally { client.close(force: true); }
  }

  Future<void> _configureLora(Dio client, Uri comfyUrl, String path) async {
    final response = await client.get('$comfyUrl/object_info/LoraLoader');
    final choices = List<String>.from(response.data['LoraLoader']['input']['required']['lora_name'][0]);
    final file = File(path);
    final original = await file.readAsString();
    final presets = jsonDecode(original) as List;
    presets.removeWhere((entry) => entry['id'] == 'local-txt2img-lora');
    final bases = presets.where((entry) => entry['id'] == 'txt2img');
    if (choices.isNotEmpty && bases.isNotEmpty) {
      final entry = jsonDecode(jsonEncode(bases.first)) as Map<String, dynamic>;
      final graph = entry['workflow'] as Map;
      // Only extend the known standard workflow; custom workflows stay untouched.
      if (graph['4']?['class_type'] == 'CheckpointLoaderSimple' &&
          graph['3']?['class_type'] == 'KSampler' &&
          graph['6']?['class_type'] == 'CLIPTextEncode' && graph['7']?['class_type'] == 'CLIPTextEncode') {
        entry['id'] = 'local-txt2img-lora';
        entry['name'] = 'イラスト（LoRAを使用）';
        graph['local_lora'] = {'class_type': 'LoraLoader', 'inputs': {
          'model': ['4', 0], 'clip': ['4', 1], 'lora_name': choices.first,
          'strength_model': 0.8, 'strength_clip': 0.8,
        }};
        graph['3']['inputs']['model'] = ['local_lora', 0];
        graph['6']['inputs']['clip'] = ['local_lora', 1];
        graph['7']['inputs']['clip'] = ['local_lora', 1];
        final parameters = entry['parameters'] as Map;
        parameters['lora_name'] = {'node': 'local_lora', 'input': 'lora_name', 'type': 'choice',
          'label': 'LoRA（選択モデルと同じ系列を指定）', 'choices': choices,
          'default': choices.firstWhere((name) => name.toLowerCase().contains('illustrious'), orElse: () => choices.first)};
        for (final target in ['model', 'clip']) {
          parameters['lora_strength_$target'] = {'node': 'local_lora', 'input': 'strength_$target',
            'type': 'number', 'label': 'LoRA強度（$target）', 'min': -2, 'max': 2, 'default': 0.8};
        }
        presets.add(entry);
      }
    }
    final updated = const JsonEncoder.withIndent('  ').convert(presets);
    if (jsonEncode(jsonDecode(original)) != jsonEncode(presets)) {
      final temporary = File('$path.tmp');
      await temporary.writeAsString(updated, flush: true);
      await temporary.rename(path);
    }
  }

  Future<String> _start() async {
    Directory? root;
    for (final start in [
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ]) {
      var candidate = start.absolute;
      for (var i = 0; i < 10; i++) {
        if (File(p.join(candidate.path, 'server', 'main.py')).existsSync() &&
            File(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
          root = candidate;
          break;
        }
        candidate = candidate.parent;
      }
      if (root != null) break;
    }
    if (root == null) throw StateError('アプリのサーバーファイルが見つかりません。');
    final configFile = File(
      p.join(root.path, 'data', 'local_generation', 'connection.json'),
    );
    if (!await configFile.exists()) {
      throw StateError('このPCのComfyUI接続設定がありません。');
    }
    _configPath = configFile.path;
    final config = jsonDecode(await configFile.readAsString()) as Map;
    libraryPath = config['libraryPath'] as String;
    const storage = FlutterSecureStorage();
    var token = await storage.read(key: 'pdf_viewer.localGenerationToken');
    if (token == null) {
      token = AuthTokenStore.generate();
      await storage.write(key: 'pdf_viewer.localGenerationToken', value: token);
    }
    final client = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 3),
      ),
    );
    Future<bool> ready() async {
      try {
        await client.post(
          '$baseUrl/generated/search', data: {'limit': 1},
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
        return true;
      } on DioException {
        return false;
      }
    }

    try {
      final comfyUrl = Uri.parse(config['comfyUrl'] as String);
      if (comfyUrl.host != '127.0.0.1' || comfyUrl.scheme != 'http') {
        throw StateError('ComfyUIはこのPCの127.0.0.1を指定してください。');
      }
      if (await ready()) return token;
      // Refuse to replace an unrelated listener.
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          18890,
          timeout: const Duration(seconds: 1),
        );
        socket.destroy();
        throw StateError('ローカル生成用ポート18890が使用中です。');
      } on SocketException {
        /* available */
      }
      final data = configFile.parent.path;
      await Process.start(
        p.join(root.path, '.venv', 'Scripts', 'python.exe'),
        [
          '-m',
          'uvicorn',
          'server.main:app',
          '--host',
          '127.0.0.1',
          '--port',
          '18890',
          '--no-proxy-headers',
        ],
        workingDirectory: root.path,
        mode: ProcessStartMode.detached,
        environment: {
          'MEDIA_SERVER_ENABLE_GENERATED_RELAY': 'true',
          'MEDIA_SERVER_HOST': '127.0.0.1',
          'MEDIA_SERVER_PORT': '18890',
          'MEDIA_SERVER_AUTH_TOKEN': token,
          'MEDIA_SERVER_TAILNET_WITHOUT_TOKEN': 'false',
          'MEDIA_SERVER_ALLOWED_NETWORKS': '127.0.0.0/8;::1/128',
          'MEDIA_SERVER_DATA_DIR': data,
          'MEDIA_SERVER_DB_PATH': p.join(data, 'metadata.db'),
          'MEDIA_SERVER_THUMBS_DIR': p.join(data, 'thumbs'),
          'MEDIA_SERVER_MEDIA_ROOTS': '',
          'MEDIA_SERVER_STARTUP_RESCAN': 'false',
          'MEDIA_SERVER_GPU_LOCK_PATH': p.join(root.path, 'data', 'gpu_coordination.sqlite'),
          'MEDIA_SERVER_XVIEWER_SAVED_IMAGES_DIR': p.join(data, 'xsaved'),
          'MEDIA_SERVER_COMFY_URL': comfyUrl.toString(),
          'MEDIA_SERVER_COMFY_OUTPUT_DIR': config['outputPath'] as String,
          'MEDIA_SERVER_GENERATED_LIBRARY_DIR': libraryPath!,
          'MEDIA_SERVER_COMFY_PRESETS_PATH': config['presetsPath'] as String,
        },
      );
      for (var i = 0; i < 60; i++) {
        if (await ready()) return token;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      throw StateError('ローカル生成サービスを起動できませんでした。');
    } finally {
      client.close(force: true);
    }
  }
}
