import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum ProjectCookieProfile { kemono, coomer, combined }

extension ProjectCookieProfileValue on ProjectCookieProfile {
  String get key => switch (this) {
    ProjectCookieProfile.kemono => 'kemono',
    ProjectCookieProfile.coomer => 'coomer',
    ProjectCookieProfile.combined => 'combined',
  };

  String get label => switch (this) {
    ProjectCookieProfile.kemono => 'Kemono',
    ProjectCookieProfile.coomer => 'Coomer',
    ProjectCookieProfile.combined => '共通 / Mixed',
  };

  String get fileName => '$key.txt';
}

class ProjectCookieSlot {
  final ProjectCookieProfile profile;
  final String path;
  final bool exists;
  final DateTime? modifiedAt;
  final int? sizeBytes;

  const ProjectCookieSlot({
    required this.profile,
    required this.path,
    required this.exists,
    this.modifiedAt,
    this.sizeBytes,
  });
}

class UrlImportProjectCookieStoreService {
  Future<Directory>? _cookieDirectoryFuture;

  Future<Directory> _resolveCookieDirectory() {
    return _cookieDirectoryFuture ??= () async {
      if (Platform.isAndroid || Platform.isIOS) {
        final baseDir = await getApplicationSupportDirectory();
        return Directory(p.join(baseDir.path, 'url_import_cookies'));
      }

      return Directory(
        p.join(Directory.current.path, 'data', 'url_import_cookies'),
      );
    }();
  }

  Future<Directory> ensureCookieDirectory() async {
    final dir = await _resolveCookieDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> pathForProfile(ProjectCookieProfile profile) async {
    final dir = await ensureCookieDirectory();
    return p.join(dir.path, profile.fileName);
  }

  Future<ProjectCookieSlot> getSlot(ProjectCookieProfile profile) async {
    final dir = await ensureCookieDirectory();
    final file = File(p.join(dir.path, profile.fileName));
    if (!await file.exists()) {
      return ProjectCookieSlot(
        profile: profile,
        path: file.path,
        exists: false,
      );
    }

    final stat = await file.stat();
    return ProjectCookieSlot(
      profile: profile,
      path: file.path,
      exists: true,
      modifiedAt: stat.modified,
      sizeBytes: stat.size,
    );
  }

  Future<Map<ProjectCookieProfile, ProjectCookieSlot>> loadSlots() async {
    final result = <ProjectCookieProfile, ProjectCookieSlot>{};
    for (final profile in ProjectCookieProfile.values) {
      result[profile] = await getSlot(profile);
    }
    return result;
  }

  Future<ProjectCookieSlot> importCookieFile(
    ProjectCookieProfile profile,
    String sourcePath,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Cookie ファイルが見つかりません', sourcePath);
    }

    final dir = await ensureCookieDirectory();
    final target = File(p.join(dir.path, profile.fileName));
    if (p.equals(source.path, target.path)) {
      return getSlot(profile);
    }

    await target.writeAsBytes(await source.readAsBytes(), flush: true);
    return getSlot(profile);
  }

  Future<void> deleteCookieFile(ProjectCookieProfile profile) async {
    final file = File(await pathForProfile(profile));
    if (await file.exists()) {
      await file.delete();
    }
  }
}
