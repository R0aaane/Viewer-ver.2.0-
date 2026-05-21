import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../core/errors/app_exception.dart';
import '../domain/models/media_post.dart';
import '../domain/models/post_image.dart';
import '../domain/models/save_failure_reason.dart';
import '../domain/models/save_image_result.dart';
import '../domain/models/save_location_type.dart';
import '../domain/models/saved_media_record.dart';
import '../domain/repositories/saved_media_repository.dart';
import 'downloaded_image.dart';
import 'file_storage_service.dart';
import 'gallery_save_service.dart';
import 'host_saved_images_service.dart';
import 'image_download_service.dart';

class MediaSaveService {
  MediaSaveService({
    required SavedMediaRepository repository,
    required FileStorageService fileStorageService,
    required ImageDownloadService imageDownloadService,
    required GallerySaveService gallerySaveService,
    required HostSavedImagesService hostSavedImagesService,
  }) : _repository = repository,
       _fileStorageService = fileStorageService,
       _imageDownloadService = imageDownloadService,
       _gallerySaveService = gallerySaveService,
       _hostSavedImagesService = hostSavedImagesService;

  final SavedMediaRepository _repository;
  final FileStorageService _fileStorageService;
  final ImageDownloadService _imageDownloadService;
  final GallerySaveService _gallerySaveService;
  final HostSavedImagesService _hostSavedImagesService;

  Future<SaveImageResult> saveImage({
    required MediaPost post,
    required PostImage image,
  }) async {
    final accountFolderName = _buildAccountFolderName(post.authorUsername);
    final existing = await _repository.findByMediaKey(image.mediaKey);
    if (existing != null) {
      return SaveImageResult(
        record: existing,
        locationType: existing.saveLocationType,
        wasDuplicate: true,
        usedFallback: false,
        savedPath: existing.localSavedPath,
        galleryContentUri: existing.galleryContentUri,
        failureReason: SaveFailureReason.duplicate,
        message: 'This image is already saved',
      );
    }

    final fileName = _buildFileName(post: post, image: image);
    final DownloadedImage downloadedImage;
    try {
      downloadedImage = await _imageDownloadService.downloadImage(
        imageUrl: image.imageUrl,
        fileName: fileName,
      );
    } on AppException catch (error) {
      throw SaveImageException(
        SaveFailureReason.downloadFailed,
        error.message,
        details: error.details,
      );
    }

    GallerySaveResult? gallerySave;
    HostSavedImageResult? hostSave;
    SaveFailureReason? fallbackReason;

    if (await _hostSavedImagesService.shouldSaveToHost()) {
      try {
        hostSave = await _hostSavedImagesService.saveImage(
          bytes: downloadedImage.bytes,
          fileName: downloadedImage.fileName,
          mimeType: downloadedImage.mimeType,
          accountFolderName: accountFolderName,
        );
      } catch (_) {
        fallbackReason = SaveFailureReason.writeFailed;
      }
    } else if (_shouldTryGallerySave()) {
      try {
        await _ensureGalleryPermissionIfNeeded();
        gallerySave = await _gallerySaveService.saveImage(
          bytes: downloadedImage.bytes,
          fileName: downloadedImage.fileName,
          mimeType: downloadedImage.mimeType,
          albumName: _buildGalleryAlbumName(accountFolderName),
        );
      } on SaveImageException catch (error) {
        fallbackReason = error.reason;
      } on AppException catch (_) {
        fallbackReason = SaveFailureReason.galleryUnavailable;
      } catch (_) {
        fallbackReason = SaveFailureReason.writeFailed;
      }
    } else {
      fallbackReason = SaveFailureReason.unsupportedPlatform;
    }

    final previewPath = await _savePreviewCopyOrRollback(
      image: downloadedImage,
      accountFolderName: accountFolderName,
      galleryContentUri: gallerySave?.contentUri,
    );
    final now = DateTime.now();

    final record = SavedMediaRecord(
      recordId: '${post.postId}_${image.mediaKey}',
      postId: post.postId,
      mediaKey: image.mediaKey,
      authorName: post.authorName,
      authorUsername: post.authorUsername,
      text: post.text,
      imageUrl: image.imageUrl,
      sourceImageUrl: image.imageUrl,
      localSavedPath:
          hostSave?.savedPath ?? gallerySave?.savedPath ?? previewPath,
      previewFilePath: previewPath,
      originalPostUrl: post.originalPostUrl,
      createdAt: post.createdAt,
      savedAt: now,
      saveLocationType: hostSave != null
          ? SaveLocationType.remoteHost
          : gallerySave != null
          ? SaveLocationType.gallery
          : SaveLocationType.appPrivate,
      galleryContentUri: gallerySave?.contentUri,
      galleryDisplayName:
          hostSave?.displayName ??
          gallerySave?.displayName ??
          downloadedImage.fileName,
    );

    await _repository.save(record);

    return SaveImageResult(
      record: record,
      locationType: record.saveLocationType,
      wasDuplicate: false,
      usedFallback: hostSave == null && gallerySave == null,
      savedPath: record.localSavedPath,
      galleryContentUri: record.galleryContentUri,
      failureReason: hostSave == null && gallerySave == null
          ? fallbackReason
          : null,
      message: hostSave != null
          ? 'Saved to host Saved_images'
          : gallerySave != null
          ? 'Saved to gallery'
          : 'Saved to app storage because host/gallery save was unavailable',
    );
  }

  Future<void> deleteRecord(SavedMediaRecord record) async {
    await _fileStorageService.deleteFile(record.previewFilePath);
    if (record.saveLocationType == SaveLocationType.appPrivate &&
        record.localSavedPath != record.previewFilePath) {
      await _fileStorageService.deleteFile(record.localSavedPath);
    }
    if (record.saveLocationType == SaveLocationType.gallery &&
        (record.galleryContentUri?.isNotEmpty ?? false)) {
      try {
        await _gallerySaveService.deleteImage(record.galleryContentUri!);
      } catch (_) {
        debugPrint(
          '[xviewer][save] Failed to delete gallery asset: ${record.galleryContentUri}',
        );
      }
    }
    await _repository.delete(record.recordId);
  }

  Future<void> migrateSavedMediaToAuthorFolders() async {
    final records = await _repository.getAll();
    for (final record in records) {
      try {
        final migrated = await _migrateRecordToAuthorFolder(record);
        if (migrated != null) {
          await _repository.save(migrated);
        }
      } catch (error, stackTrace) {
        debugPrint(
          '[xviewer][save] Failed to migrate saved media record=${record.recordId}: $error',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  Future<int> importExistingSavedImageFiles() async {
    final files = await _fileStorageService.listSavedImageFiles();
    if (files.isEmpty) {
      return 0;
    }

    final baseDirectory = p.normalize(
      await _fileStorageService.getBaseDirectoryPath(),
    );
    final existingRecords = await _repository.getAll();
    final existingRecordIds = existingRecords
        .map((record) => record.recordId)
        .toSet();
    final existingPaths = existingRecords
        .expand((record) => [record.previewFilePath, record.localSavedPath])
        .map(p.normalize)
        .toSet();
    var importedCount = 0;

    for (final file in files) {
      final filePath = p.normalize(file.path);
      if (existingPaths.contains(filePath)) {
        continue;
      }

      final record = await _buildImportedRecord(
        file: file,
        baseDirectory: baseDirectory,
        existingRecordIds: existingRecordIds,
      );
      await _repository.save(record);
      existingRecordIds.add(record.recordId);
      existingPaths.add(filePath);
      importedCount += 1;
    }

    if (importedCount > 0) {
      debugPrint(
        '[xviewer][save] Imported $importedCount existing image files.',
      );
    }
    return importedCount;
  }

  Future<String> getStorageDirectoryDescription() async {
    final privateRoot = await _fileStorageService.getBaseDirectoryPath();
    final hostDescription = await _hostSavedImagesService.getHostDescription();
    if (hostDescription != null) {
      return '$hostDescription, Local preview cache: $privateRoot/<twitter-id>';
    }
    if (!_shouldTryGallerySave()) {
      return '$privateRoot/<twitter-id>';
    }
    return 'Gallery: Pictures/Xviewer/<twitter-id>, '
        'Preview cache: $privateRoot/<twitter-id>';
  }

  Future<SavedMediaRecord> _buildImportedRecord({
    required File file,
    required String baseDirectory,
    required Set<String> existingRecordIds,
  }) async {
    final fileName = p.basename(file.path);
    final stem = p.basenameWithoutExtension(fileName);
    final separatorIndex = stem.indexOf('_');
    final postId = separatorIndex <= 0
        ? stem
        : stem.substring(0, separatorIndex);
    final mediaKey = separatorIndex <= 0
        ? stem
        : stem.substring(separatorIndex + 1);
    final authorUsername = _resolveImportedAuthorUsername(
      filePath: file.path,
      baseDirectory: baseDirectory,
    );
    final recordId = _deduplicateRecordId(
      stem.isEmpty ? file.path.hashCode.toString() : stem,
      existingRecordIds,
    );
    final savedAt = await file.lastModified();

    return SavedMediaRecord(
      recordId: recordId,
      postId: postId,
      mediaKey: mediaKey,
      authorName: authorUsername,
      authorUsername: authorUsername,
      text: '',
      imageUrl: file.uri.toString(),
      sourceImageUrl: file.uri.toString(),
      localSavedPath: file.path,
      previewFilePath: file.path,
      originalPostUrl: postId.isEmpty
          ? ''
          : 'https://x.com/$authorUsername/status/$postId',
      createdAt: savedAt,
      savedAt: savedAt,
      saveLocationType: SaveLocationType.appPrivate,
      galleryDisplayName: fileName,
    );
  }

  String _resolveImportedAuthorUsername({
    required String filePath,
    required String baseDirectory,
  }) {
    final parentPath = p.normalize(p.dirname(filePath));
    if (parentPath == baseDirectory) {
      return 'unknown_user';
    }

    final parentName = p.basename(parentPath).trim();
    return parentName.isEmpty ? 'unknown_user' : parentName;
  }

  String _deduplicateRecordId(
    String preferredId,
    Set<String> existingRecordIds,
  ) {
    var candidate = preferredId;
    var suffix = 2;
    while (existingRecordIds.contains(candidate)) {
      candidate = '${preferredId}_$suffix';
      suffix += 1;
    }
    return candidate;
  }

  Future<SavedMediaRecord?> _migrateRecordToAuthorFolder(
    SavedMediaRecord record,
  ) async {
    final accountFolderName = _buildAccountFolderName(record.authorUsername);
    final previewFileName = _resolvePreviewFileName(record);
    var nextRecord = record;
    var changed = false;

    final migratedPreviewPath = await _migratePreviewFile(
      record: nextRecord,
      accountFolderName: accountFolderName,
      fileName: previewFileName,
    );
    if (migratedPreviewPath != null &&
        p.normalize(migratedPreviewPath) !=
            p.normalize(nextRecord.previewFilePath)) {
      nextRecord = nextRecord.copyWith(
        previewFilePath: migratedPreviewPath,
        localSavedPath:
            nextRecord.saveLocationType == SaveLocationType.appPrivate
            ? migratedPreviewPath
            : nextRecord.localSavedPath,
      );
      changed = true;
    }

    if (_shouldTryGallerySave() &&
        nextRecord.saveLocationType == SaveLocationType.gallery &&
        (nextRecord.galleryContentUri?.isNotEmpty ?? false)) {
      final migratedGalleryRecord = await _migrateGalleryFile(
        record: nextRecord,
        accountFolderName: accountFolderName,
        fallbackFileName: previewFileName,
      );
      if (migratedGalleryRecord != null) {
        nextRecord = migratedGalleryRecord;
        changed = true;
      }
    }

    return changed ? nextRecord : null;
  }

  Future<String?> _migratePreviewFile({
    required SavedMediaRecord record,
    required String accountFolderName,
    required String fileName,
  }) async {
    final sourcePath = await _resolveExistingPrivatePath(record);
    if (sourcePath == null) {
      return null;
    }
    final targetPath = p.join(
      await _fileStorageService.getBaseDirectoryPath(
        accountFolderName: accountFolderName,
      ),
      fileName,
    );
    if (p.normalize(sourcePath) == p.normalize(targetPath)) {
      return sourcePath;
    }

    return _fileStorageService.moveFileToDirectory(
      sourcePath: sourcePath,
      fileName: fileName,
      accountFolderName: accountFolderName,
    );
  }

  Future<SavedMediaRecord?> _migrateGalleryFile({
    required SavedMediaRecord record,
    required String accountFolderName,
    required String fallbackFileName,
  }) async {
    final targetAlbumName = _buildGalleryAlbumName(accountFolderName);
    if (_isGalleryPathInTargetAlbum(record.localSavedPath, targetAlbumName)) {
      return null;
    }

    final previewFile = File(record.previewFilePath);
    if (!await previewFile.exists()) {
      return null;
    }

    final targetFileName = (record.galleryDisplayName ?? '').trim().isNotEmpty
        ? record.galleryDisplayName!
        : fallbackFileName;
    final migratedGallery = await _gallerySaveService.saveImage(
      bytes: await previewFile.readAsBytes(),
      fileName: targetFileName,
      mimeType: _resolveMimeType(targetFileName),
      albumName: targetAlbumName,
    );

    final previousGalleryUri = record.galleryContentUri;
    if ((previousGalleryUri ?? '').isNotEmpty &&
        previousGalleryUri != migratedGallery.contentUri) {
      try {
        await _gallerySaveService.deleteImage(previousGalleryUri!);
      } catch (_) {
        debugPrint(
          '[xviewer][save] Failed to delete old gallery asset during migration: $previousGalleryUri',
        );
      }
    }

    return record.copyWith(
      localSavedPath: migratedGallery.savedPath,
      galleryContentUri: migratedGallery.contentUri,
      galleryDisplayName: migratedGallery.displayName,
    );
  }

  Future<String?> _resolveExistingPrivatePath(SavedMediaRecord record) async {
    final previewFile = File(record.previewFilePath);
    if (await previewFile.exists()) {
      return previewFile.path;
    }

    final localFile = File(record.localSavedPath);
    if (record.saveLocationType == SaveLocationType.appPrivate &&
        await localFile.exists()) {
      return localFile.path;
    }

    return null;
  }

  bool _isGalleryPathInTargetAlbum(String savedPath, String albumName) {
    final normalizedSavedPath = savedPath.replaceAll('\\', '/');
    final normalizedAlbumName = 'Pictures/$albumName/';
    return normalizedSavedPath.contains(normalizedAlbumName);
  }

  String _resolvePreviewFileName(SavedMediaRecord record) {
    final candidates = <String>[
      p.basename(record.previewFilePath),
      p.basename(record.localSavedPath),
      record.galleryDisplayName ?? '',
      _buildFileNameFromRecord(record),
    ];
    for (final candidate in candidates) {
      if (candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return '${record.postId}_${record.mediaKey}.jpg';
  }

  String _buildFileNameFromRecord(SavedMediaRecord record) {
    final baseName = '${record.postId}_${record.mediaKey}';
    final sanitized = baseName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return '$sanitized.jpg';
  }

  String _resolveMimeType(String fileName) {
    switch (p.extension(fileName).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }

  Future<void> openGalleryApp() {
    return _gallerySaveService.openGalleryApp();
  }

  bool _shouldTryGallerySave() {
    return Platform.isAndroid;
  }

  Future<void> _ensureGalleryPermissionIfNeeded() async {
    if (!Platform.isAndroid) {
      throw const SaveImageException(
        SaveFailureReason.unsupportedPlatform,
        'Gallery save is not supported on this platform',
      );
    }

    final sdkInt = await _gallerySaveService.getAndroidSdkInt();
    if (sdkInt == null || sdkInt >= 29) {
      return;
    }

    final status = await Permission.storage.request();
    if (!status.isGranted) {
      throw const SaveImageException(
        SaveFailureReason.permissionDenied,
        'Storage permission was denied',
      );
    }
  }

  Future<String> _savePreviewCopy(
    DownloadedImage image, {
    required String accountFolderName,
  }) {
    return _fileStorageService.saveBytes(
      bytes: image.bytes,
      fileName: image.fileName,
      accountFolderName: accountFolderName,
    );
  }

  Future<String> _savePreviewCopyOrRollback({
    required DownloadedImage image,
    required String accountFolderName,
    String? galleryContentUri,
  }) async {
    try {
      return await _savePreviewCopy(
        image,
        accountFolderName: accountFolderName,
      );
    } catch (error) {
      if (galleryContentUri != null && galleryContentUri.isNotEmpty) {
        try {
          await _gallerySaveService.deleteImage(galleryContentUri);
        } catch (_) {
          debugPrint(
            '[xviewer][save] Failed to rollback gallery asset: $galleryContentUri',
          );
        }
      }
      throw SaveImageException(
        SaveFailureReason.writeFailed,
        'Failed to persist saved image locally',
        details: error,
      );
    }
  }

  String _buildFileName({required MediaPost post, required PostImage image}) {
    final baseName = '${post.postId}_${image.mediaKey}';
    final sanitized = baseName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return '$sanitized.jpg';
  }

  String _buildGalleryAlbumName(String accountFolderName) {
    return 'Xviewer/$accountFolderName';
  }

  String _buildAccountFolderName(String authorUsername) {
    return _sanitizePathSegment(authorUsername) ?? 'unknown_user';
  }

  String? _sanitizePathSegment(String? value) {
    final sanitized = (value ?? '')
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.isEmpty) {
      return null;
    }
    return sanitized;
  }
}

class SaveImageException extends AppException {
  const SaveImageException(this.reason, super.message, {super.details});

  final SaveFailureReason reason;
}
