import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/metadata_settings.dart';

const String _fallbackAppVersion = String.fromEnvironment(
  'PDF_VIEWER_APP_VERSION',
  defaultValue: '1.0.64+74',
);
const String defaultAppUpdateVersion = String.fromEnvironment(
  'PDF_VIEWER_UPDATE_VERSION',
);
const String defaultAppUpdateUrl = String.fromEnvironment(
  'PDF_VIEWER_UPDATE_URL',
);

class AppVersionMismatch {
  final String localVersion;
  final String hostVersion;
  final String latestVersion;
  final String hostUrl;
  final String? updateUrl;
  final List<String> knownVersions;

  const AppVersionMismatch({
    required this.localVersion,
    required this.hostVersion,
    required this.latestVersion,
    required this.hostUrl,
    this.updateUrl,
    this.knownVersions = const <String>[],
  });

  bool get isLocalOlder => compareAppVersions(localVersion, latestVersion) < 0;

  bool get isHostOlder => compareAppVersions(hostVersion, latestVersion) < 0;

  bool get hasUpdateUrl => updateUrl?.trim().isNotEmpty == true;
}

class HostUpdateStatus {
  final String state;
  final String message;
  final int? pid;

  const HostUpdateStatus({
    required this.state,
    required this.message,
    this.pid,
  });

  String get displayText {
    final stateLabel = switch (state) {
      'idle' => 'サーバー起動中',
      'queued' => '更新待機中',
      'running' => '更新処理中',
      'checking' => '更新確認中',
      'building' => 'ビルド中',
      'restarting' => '再起動中',
      'succeeded' => '更新完了',
      'failed' => 'エラー発生中',
      'unknown' => '状態不明',
      _ => state,
    };
    final detail = message.trim();
    if (detail.isEmpty) {
      return stateLabel;
    }
    return '$stateLabel: $detail';
  }
}

class _HostVersionInfo {
  final String version;
  final String? latestKnownVersion;
  final List<String> clientVersions;
  final String? updateVersion;
  final String? updateUrl;

  const _HostVersionInfo({
    required this.version,
    required this.latestKnownVersion,
    required this.clientVersions,
    required this.updateVersion,
    required this.updateUrl,
  });
}

class AppVersionService {
  static const String _lastStartedVersionKey = 'prefs.app.lastStartedVersion';

  Future<String> currentVersionLabel() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      final build = info.buildNumber.trim();
      if (version.isEmpty) {
        return _fallbackAppVersion;
      }
      return build.isEmpty ? version : '$version+$build';
    } catch (_) {
      return _fallbackAppVersion;
    }
  }

  Future<void> recordCurrentVersion() async {
    final version = await currentVersionLabel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastStartedVersionKey, version);
  }

  Future<AppVersionMismatch?> findHostVersionMismatch(
    MetadataSettings settings,
  ) async {
    await recordCurrentVersion();

    final baseUrl = switch (settings.appMode) {
      AppMode.standalone => '',
      AppMode.host => settings.hostLoopbackApiBaseUrl,
      AppMode.client => settings.remoteApiBaseUrl,
    }.trim();
    if (baseUrl.isEmpty) {
      return null;
    }

    final localVersion = await currentVersionLabel();
    final hostInfo = await _fetchHostVersion(
      baseUrl: baseUrl,
      authToken: settings.authToken,
      localVersion: localVersion,
    );
    if (hostInfo == null) {
      return null;
    }

    final knownVersions = <String>{
      localVersion,
      hostInfo.version,
      if (hostInfo.latestKnownVersion != null) hostInfo.latestKnownVersion!,
      if (hostInfo.updateVersion != null) hostInfo.updateVersion!,
      ...hostInfo.clientVersions,
    }.where((version) => version.trim().isNotEmpty).toList(growable: false);
    final latestVersion = _latestVersion(knownVersions);
    if (latestVersion == null ||
        (hostInfo.version == localVersion && latestVersion == localVersion)) {
      return null;
    }

    return AppVersionMismatch(
      localVersion: localVersion,
      hostVersion: hostInfo.version,
      latestVersion: latestVersion,
      hostUrl: baseUrl,
      updateUrl:
          _canUseHostUpdate(
            localVersion: localVersion,
            updateVersion: hostInfo.updateVersion,
            updateUrl: hostInfo.updateUrl,
          )
          ? _resolveUpdateUrl(baseUrl, hostInfo.updateUrl)
          : null,
      knownVersions: knownVersions,
    );
  }

  Future<bool> openUpdate(AppVersionMismatch mismatch) async {
    final updateUrl = mismatch.updateUrl?.trim();
    if (updateUrl == null || updateUrl.isEmpty) {
      return false;
    }
    final uri = Uri.tryParse(updateUrl);
    if (uri == null || !uri.hasScheme) {
      return false;
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<bool> requestHostUpdate(
    MetadataSettings settings,
    AppVersionMismatch mismatch,
  ) async {
    if (!mismatch.isHostOlder) {
      return false;
    }
    final uri = _buildUri(mismatch.hostUrl, '/host-update/run');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 6);

    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      final token = settings.authToken?.trim();
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.headers.set('X-Pdf-Viewer-App-Version', mismatch.localVersion);
      request.add(
        utf8.encode(
          jsonEncode(<String, String>{
            'clientVersion': mismatch.localVersion,
            'hostVersion': mismatch.hostVersion,
            'latestVersion': mismatch.latestVersion,
          }),
        ),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 300;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<HostUpdateStatus?> fetchHostUpdateStatus(
    MetadataSettings settings,
  ) async {
    final baseUrl = _baseUrlForSettings(settings);
    if (baseUrl.isEmpty) {
      return null;
    }
    final uri = _buildUri(baseUrl, '/host-update/status');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 6);

    try {
      final request = await client.getUrl(uri);
      final token = settings.authToken?.trim();
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.headers.set(
        'X-Pdf-Viewer-App-Version',
        await currentVersionLabel(),
      );

      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      final payload = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        return null;
      }
      return HostUpdateStatus(
        state: decoded['state']?.toString().trim() ?? 'unknown',
        message: decoded['message']?.toString().trim() ?? '',
        pid: _asInt(decoded['pid']),
      );
    } on FormatException {
      return null;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<_HostVersionInfo?> _fetchHostVersion({
    required String baseUrl,
    required String? authToken,
    required String localVersion,
  }) async {
    final uri = _buildUri(baseUrl, '/health');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 6);

    try {
      final request = await client.getUrl(uri);
      final token = authToken?.trim();
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.headers.set('X-Pdf-Viewer-App-Version', localVersion);

      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      final payload = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        return null;
      }
      final version = decoded['version']?.toString().trim();
      if (version == null || version.isEmpty) {
        return null;
      }
      final clientVersions = decoded['clientVersions'] is List
          ? (decoded['clientVersions'] as List)
                .map((entry) => entry.toString().trim())
                .where((entry) => entry.isNotEmpty)
                .toList(growable: false)
          : const <String>[];
      return _HostVersionInfo(
        version: version,
        latestKnownVersion: decoded['latestKnownVersion']?.toString().trim(),
        clientVersions: clientVersions,
        updateVersion: decoded['updateVersion']?.toString().trim(),
        updateUrl: decoded['updateUrl']?.toString().trim(),
      );
    } on FormatException {
      return null;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Uri _buildUri(String baseUrl, String childPath) {
    final baseUri = Uri.parse(baseUrl);
    final left = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    final right = childPath.startsWith('/') ? childPath : '/$childPath';
    return baseUri.replace(path: '$left$right');
  }

  String _baseUrlForSettings(MetadataSettings settings) {
    return switch (settings.appMode) {
      AppMode.standalone => '',
      AppMode.host => settings.hostLoopbackApiBaseUrl,
      AppMode.client => settings.remoteApiBaseUrl,
    }.trim();
  }
}

int? _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

bool _canUseHostUpdate({
  required String localVersion,
  required String? updateVersion,
  required String? updateUrl,
}) {
  final version = updateVersion?.trim();
  final url = updateUrl?.trim();
  if (version == null || version.isEmpty || url == null || url.isEmpty) {
    return false;
  }
  return compareAppVersions(localVersion, version) < 0;
}

String? _resolveUpdateUrl(String baseUrl, String? rawUpdateUrl) {
  final trimmed = rawUpdateUrl?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null) {
    return null;
  }
  if (uri.hasScheme) {
    return uri.toString();
  }
  final baseUri = Uri.tryParse(baseUrl.trim());
  if (baseUri == null || !baseUri.hasScheme) {
    return null;
  }
  return baseUri.resolveUri(uri).toString();
}

String? _latestVersion(List<String> versions) {
  if (versions.isEmpty) {
    return null;
  }
  return versions.reduce(
    (latest, current) =>
        compareAppVersions(latest, current) >= 0 ? latest : current,
  );
}

int compareAppVersions(String left, String right) {
  final leftParts = _numericVersionParts(left);
  final rightParts = _numericVersionParts(right);
  final maxLength = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;

  for (var i = 0; i < maxLength; i += 1) {
    final leftValue = i < leftParts.length ? leftParts[i] : 0;
    final rightValue = i < rightParts.length ? rightParts[i] : 0;
    if (leftValue != rightValue) {
      return leftValue.compareTo(rightValue);
    }
  }
  return left.compareTo(right);
}

List<int> _numericVersionParts(String version) {
  return RegExp(r'\d+')
      .allMatches(version)
      .map((match) => int.tryParse(match.group(0) ?? '') ?? 0)
      .toList(growable: false);
}
