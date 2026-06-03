import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../models/reading_progress.dart';
import '../repository/remote_reading_progress_repository.dart';
import '../services/app_settings_service.dart';
import '../services/media_id_resolver.dart';
import '../services/remote_media_api_client.dart';
import '../services/reading_progress_service.dart';

class AppReadingProgressService {
  final AppSettingsService _settingsService;
  final MediaIdResolver _idResolver;

  AppReadingProgressService({
    AppSettingsService? settingsService,
    MediaIdResolver? idResolver,
  }) : _settingsService = settingsService ?? AppSettingsService(),
       _idResolver = idResolver ?? MediaIdResolver();

  Future<ReadingProgressEntry?> fetchProgressForItem(MediaItem item) async {
    if (item.kind != MediaKind.pdf) {
      return null;
    }
    final service = await _buildService();
    if (service == null) {
      return null;
    }
    final identity = await _idResolver.resolve(item);
    return service.fetchProgress(identity.stableId);
  }

  Future<List<ReadingProgressEntry>> fetchRecent({int limit = 24}) async {
    final service = await _buildService();
    if (service == null) {
      return const <ReadingProgressEntry>[];
    }
    return service.fetchRecent(limit: limit);
  }

  Future<ReadingProgressEntry?> saveProgressForItem(
    MediaItem item, {
    required int currentPage,
    int? totalPages,
    DateTime? lastReadAt,
    DateTime? updatedAt,
    bool? isBookmarked,
  }) async {
    if (item.kind != MediaKind.pdf) {
      return null;
    }
    final service = await _buildService();
    if (service == null) {
      return null;
    }
    final identity = await _idResolver.resolve(item);
    return service.saveProgress(
      mediaId: identity.stableId,
      identity: identity.toJson(),
      currentPage: currentPage,
      totalPages: totalPages,
      lastReadAt: lastReadAt,
      updatedAt: updatedAt,
      isBookmarked: isBookmarked,
    );
  }

  Future<ReadingProgressService?> _buildService() async {
    final settings = await _settingsService.loadMetadataSettings();
    final baseUrl = switch (settings.appMode) {
      AppMode.host => settings.hostLoopbackApiBaseUrl,
      AppMode.client => settings.remoteApiBaseUrl,
      AppMode.standalone => '',
    };
    final token = settings.authToken?.trim();
    final client = RemoteMediaApiClient(
      baseUrl: baseUrl,
      authToken: token == null || token.isEmpty ? null : token,
    );
    if (!client.isConfigured) {
      return null;
    }
    return ReadingProgressService(RemoteReadingProgressRepository(client));
  }
}
