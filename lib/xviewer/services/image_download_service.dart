import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/errors/app_exception.dart';
import 'downloaded_image.dart';

class ImageDownloadService {
  ImageDownloadService(this._dio);

  final Dio _dio;

  Future<DownloadedImage> downloadImage({
    required String imageUrl,
    required String fileName,
    String mimeType = 'image/jpeg',
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        imageUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const AppException('Downloaded image was empty');
      }

      return DownloadedImage(
        bytes: Uint8List.fromList(data),
        fileName: fileName,
        mimeType: mimeType,
        sourceUrl: imageUrl,
      );
    } on DioException catch (error) {
      throw AppException(
        'Failed to download image',
        details: error.message ?? error.error,
      );
    }
  }
}
