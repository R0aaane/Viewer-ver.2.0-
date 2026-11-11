import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/metadata_settings.dart';

typedef GalleryJson = Map<String, dynamic>;

enum GalleryConnection {
  unknown,
  connected,
  offline,
  unauthorized,
  unavailable,
}

/// Scoped to one host and credential. Closing the gallery releases its cache.
class GeneratedMediaRepository {
  final Dio _client;
  final connection = ValueNotifier(GalleryConnection.unknown);
  final int thumbnailBudget;
  final _cache = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};
  int _bytes = 0;
  bool _closed = false;
  bool _syncing = false;
  bool _deltaSupported = true;
  String? _epoch;
  int _cursor = 0;
  bool _cursorLoaded = false;
  int cacheGeneration = 0;

  Future<bool> synchronize() async {
    if (_closed || _syncing || !_deltaSupported) return false;
    _syncing = true;
    var changed = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key =
          'generated.sync.${remoteSourceId(_client.options.baseUrl, headers['Authorization'])}';
      if (!_cursorLoaded) {
        final raw = prefs.getString(key);
        try {
          if (raw != null) {
            final saved = jsonDecode(raw) as Map;
            _cursor = saved['cursor'] as int;
            if (_cursor < 0) throw const FormatException('Invalid sync cursor');
            _epoch = saved['epoch'] as String?;
          }
        } catch (_) {
          _cursor = 0;
          _epoch = null;
          await prefs.remove(key);
        }
        _cursorLoaded = true;
      }
      // Bound each poll. Large backlogs continue at the next poll.
      for (var batch = 0; batch < 8 && !_closed; batch++) {
        final result = (await _client.get<GalleryJson>(
          '/changes',
          queryParameters: {'after': _cursor, 'epoch': ?_epoch, 'limit': 250},
        )).data!;
        if (_closed) break;
        if (result['resetRequired'] == true) {
          _cache.clear();
          _bytes = 0;
          _cursor = 0;
          _epoch = result['epoch'];
          changed = true;
          continue;
        }
        for (final event in result['items'] as List) {
          final removed = _cache.remove(event['mediaId']);
          if (removed != null) _bytes -= removed.lengthInBytes;
          changed = true;
        }
        _cursor = result['cursor'] as int;
        _epoch = result['epoch'] as String;
        await prefs.setString(
          key,
          jsonEncode({'cursor': _cursor, 'epoch': _epoch}),
        );
        if (result['hasMore'] != true) break;
      }
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) _deltaSupported = false;
    } finally {
      if (changed) cacheGeneration++;
      _syncing = false;
    }
    return changed;
  }

  GeneratedMediaRepository(
    String baseUrl,
    String? token, {
    this.thumbnailBudget = 32 * 1024 * 1024,
    Dio? client,
  }) : _client =
           client ??
           Dio(
             BaseOptions(
               baseUrl: '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/generated',
               headers: {
                 if ((token ?? '').trim().isNotEmpty)
                   'Authorization': 'Bearer ${token!.trim()}',
               },
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 30),
             ),
           ) {
    _client.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          if (!_closed) connection.value = GalleryConnection.connected;
          handler.next(response);
        },
        onError: (error, handler) {
          if (!_closed && error.type != DioExceptionType.cancel) {
            connection.value = switch (error.response?.statusCode) {
              null => GalleryConnection.offline,
              401 || 403 => GalleryConnection.unauthorized,
              503 => GalleryConnection.unavailable,
              _ => GalleryConnection.connected,
            };
          }
          handler.next(error);
        },
      ),
    );
  }

  String originalUrl(String id) => '${_client.options.baseUrl}/media/$id';
  Map<String, String> get headers =>
      Map<String, String>.from(_client.options.headers);
  int get cachedBytes => _bytes;

  bool _checkingConnection = false;
  Future<void> checkConnection() async {
    if (_closed || _checkingConnection) return;
    _checkingConnection = true;
    try {
      await _client.get('/events', queryParameters: {'limit': 1});
    } on DioException {
      // The interceptor publishes the connection state for all requests.
    } finally {
      _checkingConnection = false;
    }
  }

  Future<GalleryJson> search(GalleryJson query) async =>
      (await _client.post<GalleryJson>('/search', data: query)).data!;
  Future<List<GalleryJson>> presets() async => List<GalleryJson>.from(
    (await _client.get<GalleryJson>('/presets')).data!['items'],
  );
  Future<List<GalleryJson>> jobs({double? before}) async =>
      List<GalleryJson>.from(
        (await _client.get<GalleryJson>(
          '/jobs',
          queryParameters: {'before': ?before},
        )).data!['items'],
      );
  Future<GalleryJson> submitJob(String key, GalleryJson request) async =>
      (await _client.post<GalleryJson>(
        '/jobs',
        data: request,
        options: Options(headers: {'Idempotency-Key': key}),
      )).data!;
  Future<void> cancelJob(String id) => _client.post('/jobs/$id/cancel');
  Future<GalleryJson> detail(String id) async =>
      (await _client.get<GalleryJson>('/media/$id/details')).data!;
  Future<GalleryJson> reanalyze(String id) async =>
      (await _client.post<GalleryJson>('/media/$id/reanalyze')).data!;
  Future<void> favorite(String id, bool value, {int? version, String? epoch}) =>
      _client.put(
        '/media/$id/favorite',
        queryParameters: {'value': value, 'expected_version': ?version},
        options: Options(headers: {'X-Sync-Epoch': ?epoch}),
      );
  Future<void> editImage(
    String id,
    int version, {
    String? name,
    bool? deleted,
    String? epoch,
  }) => _client.patch(
    '/media/$id',
    data: {'expected_version': version, 'name': ?name, 'deleted': ?deleted},
    options: Options(headers: {'X-Sync-Epoch': ?epoch}),
  );
  Future<void> editTags(
    Map<String, int> versions,
    String operation,
    String category,
    String name, {
    String? epoch,
  }) => _client.post(
    '/tags',
    data: {
      'media_ids': versions.keys.toList(),
      'expected_versions': versions,
      'operation': operation,
      'tag': {'category': category, 'name': name},
    },
    options: Options(headers: {'X-Sync-Epoch': ?epoch}),
  );

  Future<Uint8List> thumbnail(String id) {
    final hit = _cache.remove(id);
    if (hit != null) {
      _cache[id] = hit;
      return Future.value(hit);
    }
    return _pending.putIfAbsent(
      id,
      () => _load(id).whenComplete(() {
        _pending.remove(id);
      }),
    );
  }

  Future<Uint8List> _load(String id) async {
    final response = await _client.get<List<int>>(
      '/media/$id/thumbnail',
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data!;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    if (!_closed &&
        bytes.lengthInBytes <= thumbnailBudget &&
        bytes.isNotEmpty) {
      while (_bytes + bytes.lengthInBytes > thumbnailBudget &&
          _cache.isNotEmpty) {
        _bytes -= _cache.remove(_cache.keys.first)!.lengthInBytes;
      }
      _cache[id] = bytes;
      _bytes += bytes.lengthInBytes;
    }
    return bytes;
  }

  void close() {
    _closed = true;
    _client.close(force: true);
    _cache.clear();
    _bytes = 0;
    connection.dispose();
  }
}
