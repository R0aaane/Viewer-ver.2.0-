import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/saved_media_repository_impl.dart';
import '../../../../domain/models/media_post.dart';
import '../../../../domain/models/post_image.dart';
import '../../../../domain/models/save_image_result.dart';
import '../../../../domain/models/saved_media_record.dart';
import '../../../../domain/repositories/saved_media_repository.dart';
import '../../../../services/file_storage_service.dart';
import '../../../../services/gallery_save_service.dart';
import '../../../../services/host_saved_images_service.dart';
import '../../../../services/image_download_service.dart';
import '../../../../services/media_save_service.dart';
import '../../../../services/service_providers.dart';
import '../models/saved_media_filter_state.dart';

final dioProvider = Provider<Dio>((ref) => Dio());

final fileStorageServiceProvider = Provider<FileStorageService>(
  (ref) => FileStorageService(),
);

final imageDownloadServiceProvider = Provider<ImageDownloadService>(
  (ref) => ImageDownloadService(ref.watch(dioProvider)),
);

final gallerySaveServiceProvider = Provider<GallerySaveService>(
  (ref) => GallerySaveService(),
);

final hostSavedImagesServiceProvider = Provider<HostSavedImagesService>(
  (ref) => HostSavedImagesService(),
);

final savedMediaRepositoryProvider = Provider<SavedMediaRepository>(
  (ref) => createSavedMediaRepository(),
);

final mediaSaveServiceProvider = Provider<MediaSaveService>(
  (ref) => MediaSaveService(
    repository: ref.watch(savedMediaRepositoryProvider),
    fileStorageService: ref.watch(fileStorageServiceProvider),
    imageDownloadService: ref.watch(imageDownloadServiceProvider),
    gallerySaveService: ref.watch(gallerySaveServiceProvider),
    hostSavedImagesService: ref.watch(hostSavedImagesServiceProvider),
  ),
);

final savedMediaControllerProvider =
    AsyncNotifierProvider<SavedMediaController, List<SavedMediaRecord>>(
      SavedMediaController.new,
    );

final savedMediaFilterProvider =
    NotifierProvider<SavedMediaFilterController, SavedMediaFilterState>(
      SavedMediaFilterController.new,
    );

final savedMediaFilteredRecordsProvider = Provider<List<SavedMediaRecord>>((
  ref,
) {
  final records =
      ref.watch(savedMediaControllerProvider).valueOrNull ??
      const <SavedMediaRecord>[];
  final filter = ref.watch(savedMediaFilterProvider);

  final filtered = records
      .where((record) {
        final authorMatch =
            filter.authorUsername == null ||
            filter.authorUsername == record.authorUsername;
        final favoriteMatch = !filter.onlyFavorites || record.favorite;
        final normalizedTagQuery = filter.tagQuery.trim().toLowerCase();
        final tagMatch =
            normalizedTagQuery.isEmpty ||
            record.tags.any((tag) => tag.contains(normalizedTagQuery));
        return authorMatch && favoriteMatch && tagMatch;
      })
      .toList(growable: false);

  switch (filter.sort) {
    case SavedMediaSort.savedAtDesc:
      filtered.sort((a, b) => b.savedAt.compareTo(a.savedAt));
  }
  return filtered;
});

final savedMediaAuthorsProvider = Provider<List<String>>((ref) {
  final records =
      ref.watch(savedMediaControllerProvider).valueOrNull ??
      const <SavedMediaRecord>[];
  final authors =
      records.map((record) => record.authorUsername).toSet().toList()..sort();
  return authors;
});

final savedMediaTagsProvider = Provider<List<String>>((ref) {
  final records =
      ref.watch(savedMediaControllerProvider).valueOrNull ??
      const <SavedMediaRecord>[];
  final tags = records.expand((record) => record.tags).toSet().toList()..sort();
  return tags;
});

final savedMediaRecordProvider = Provider.family<SavedMediaRecord?, String>((
  ref,
  recordId,
) {
  final records =
      ref.watch(savedMediaControllerProvider).valueOrNull ??
      const <SavedMediaRecord>[];
  for (final record in records) {
    if (record.recordId == recordId) {
      return record;
    }
  }
  return null;
});

class SavedMediaController extends AsyncNotifier<List<SavedMediaRecord>> {
  @override
  Future<List<SavedMediaRecord>> build() async {
    final mediaSaveService = ref.read(mediaSaveServiceProvider);
    await mediaSaveService.importExistingSavedImageFiles();
    await mediaSaveService.migrateSavedMediaToAuthorFolders();
    return _getAllWithDisplayNameCompletion();
  }

  Future<SaveImageResult> saveImage({
    required MediaPost post,
    required PostImage image,
  }) async {
    final result = await ref
        .read(mediaSaveServiceProvider)
        .saveImage(post: post, image: image);
    state = AsyncData(await _getAllWithDisplayNameCompletion());
    return result;
  }

  Future<void> deleteRecord(SavedMediaRecord record) async {
    await ref.read(mediaSaveServiceProvider).deleteRecord(record);
    state = AsyncData(await _getAllWithDisplayNameCompletion());
  }

  Future<void> toggleFavorite(String recordId) async {
    final repository = ref.read(savedMediaRepositoryProvider);
    final record = await repository.findByRecordId(recordId);
    if (record == null) {
      return;
    }

    await repository.save(record.copyWith(favorite: !record.favorite));
    state = AsyncData(await _getAllWithDisplayNameCompletion());
  }

  Future<void> addTag({
    required String recordId,
    required String rawTag,
  }) async {
    final repository = ref.read(savedMediaRepositoryProvider);
    final record = await repository.findByRecordId(recordId);
    if (record == null) {
      return;
    }

    final normalizedTag = _normalizeTag(rawTag);
    if (normalizedTag == null) {
      return;
    }

    final updatedTags = {...record.tags, normalizedTag}.toList()..sort();
    await repository.save(record.copyWith(tags: updatedTags));
    state = AsyncData(await _getAllWithDisplayNameCompletion());
  }

  Future<void> removeTag({
    required String recordId,
    required String tag,
  }) async {
    final repository = ref.read(savedMediaRepositoryProvider);
    final record = await repository.findByRecordId(recordId);
    if (record == null) {
      return;
    }

    final updatedTags = record.tags.where((entry) => entry != tag).toList();
    await repository.save(record.copyWith(tags: updatedTags));
    state = AsyncData(await _getAllWithDisplayNameCompletion());
  }

  Future<void> applyAuthorDisplayName({
    required String authorUsername,
    required String displayName,
  }) async {
    final username = authorUsername.trim();
    final name = displayName.trim();
    if (username.isEmpty || name.isEmpty) {
      return;
    }

    await ref
        .read(creatorDisplayNameServiceProvider)
        .saveDisplayName(authorUsername: username, displayName: name);

    final repository = ref.read(savedMediaRepositoryProvider);
    final records = await repository.getAll();
    for (final record in records) {
      if (_normalizeUsername(record.authorUsername) !=
          _normalizeUsername(username)) {
        continue;
      }
      if (!_isMissingDisplayName(record)) {
        continue;
      }
      await repository.save(record.copyWith(authorName: name));
    }
    state = AsyncData(await _getAllWithDisplayNameCompletion());
  }

  Future<String> getStorageDirectory() {
    return ref.read(mediaSaveServiceProvider).getStorageDirectoryDescription();
  }

  Future<void> setSavedImagesDirectory(String path) async {
    await ref.read(fileStorageServiceProvider).setSavedImagesDirectory(path);
    state = AsyncData(await _getAllWithDisplayNameCompletion());
  }

  Future<void> resetSavedImagesDirectory() async {
    await ref.read(fileStorageServiceProvider).resetSavedImagesDirectory();
    state = AsyncData(await _getAllWithDisplayNameCompletion());
  }

  Future<void> syncHostSavedImages() async {
    await ref.read(mediaSaveServiceProvider).syncHostSavedImages();
    state = AsyncData(await _getAllWithDisplayNameCompletion());
  }

  Future<void> openGalleryApp() {
    return ref.read(mediaSaveServiceProvider).openGalleryApp();
  }

  String? _normalizeTag(String rawTag) {
    final normalized = rawTag.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  Future<List<SavedMediaRecord>> _getAllWithDisplayNameCompletion() async {
    final repository = ref.read(savedMediaRepositoryProvider);
    final records = await repository.getAll();
    final knownNames = <String, String>{};

    for (final record in records) {
      if (_isMissingDisplayName(record)) {
        continue;
      }
      knownNames[_normalizeUsername(record.authorUsername)] = record.authorName;
    }

    final overrides = await ref
        .read(creatorDisplayNameServiceProvider)
        .getAllDisplayNames();
    knownNames.addAll(overrides);

    var changed = false;
    final completed = <SavedMediaRecord>[];
    for (final record in records) {
      final name = knownNames[_normalizeUsername(record.authorUsername)];
      if (name == null || name.isEmpty || !_isMissingDisplayName(record)) {
        completed.add(record);
        continue;
      }

      final updated = record.copyWith(authorName: name);
      await repository.save(updated);
      completed.add(updated);
      changed = true;
    }

    return changed ? repository.getAll() : completed;
  }

  bool _isMissingDisplayName(SavedMediaRecord record) {
    final name = record.authorName.trim();
    final username = record.authorUsername.trim();
    return name.isEmpty ||
        name == 'Unknown' ||
        name == 'unknown_user' ||
        _normalizeUsername(name) == _normalizeUsername(username);
  }

  String _normalizeUsername(String value) {
    return value.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
  }
}

class SavedMediaFilterController extends Notifier<SavedMediaFilterState> {
  @override
  SavedMediaFilterState build() {
    return const SavedMediaFilterState();
  }

  void setAuthor(String? authorUsername) {
    state = authorUsername == null || authorUsername.isEmpty
        ? state.copyWith(clearAuthor: true)
        : state.copyWith(authorUsername: authorUsername);
  }

  void toggleFavoritesOnly() {
    state = state.copyWith(onlyFavorites: !state.onlyFavorites);
  }

  void setTagQuery(String value) {
    state = state.copyWith(tagQuery: value.trim().toLowerCase());
  }

  void clear() {
    state = state.clear();
  }
}
