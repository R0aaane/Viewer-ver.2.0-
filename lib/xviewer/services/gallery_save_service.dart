import 'dart:io';

import 'package:flutter/services.dart';

import '../core/errors/app_exception.dart';

class GallerySaveResult {
  const GallerySaveResult({
    required this.contentUri,
    required this.savedPath,
    required this.displayName,
  });

  final String contentUri;
  final String savedPath;
  final String displayName;
}

class GallerySaveService {
  static const MethodChannel _channel = MethodChannel('xviewer/gallery');

  Future<GallerySaveResult> saveImage({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    String albumName = 'Xviewer',
  }) async {
    if (!Platform.isAndroid) {
      throw const AppException(
        'Gallery save is currently supported on Android',
      );
    }

    final result = await _channel.invokeMapMethod<String, dynamic>(
      'saveImageToGallery',
      {
        'bytes': bytes,
        'fileName': fileName,
        'mimeType': mimeType,
        'albumName': albumName,
      },
    );

    if (result == null) {
      throw const AppException('Gallery save returned no result');
    }

    return GallerySaveResult(
      contentUri: result['contentUri'] as String? ?? '',
      savedPath: result['savedPath'] as String? ?? '',
      displayName: result['displayName'] as String? ?? fileName,
    );
  }

  Future<void> deleteImage(String contentUri) async {
    if (!Platform.isAndroid || contentUri.isEmpty) {
      return;
    }

    await _channel.invokeMethod<void>('deleteImageFromGallery', {
      'contentUri': contentUri,
    });
  }

  Future<void> openGalleryApp() async {
    if (!Platform.isAndroid) {
      throw const AppException(
        'Gallery app open is currently supported on Android',
      );
    }

    await _channel.invokeMethod<void>('openGalleryApp');
  }

  Future<int?> getAndroidSdkInt() async {
    if (!Platform.isAndroid) {
      return null;
    }

    return await _channel.invokeMethod<int>('getAndroidSdkInt');
  }
}
