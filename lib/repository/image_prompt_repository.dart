import 'dart:typed_data';
import 'package:dio/dio.dart';

typedef PromptJson = Map<String, dynamic>;

class ImagePromptRepository {
  final Dio client;
  ImagePromptRepository(String baseUrl, String token, {Dio? dio}) : client = dio ?? Dio(BaseOptions(
    baseUrl: '$baseUrl/image-prompt', headers: {'Authorization': 'Bearer $token'},
    connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 30)));
  Future<PromptJson> load(String source, int page) async => (await client.get<PromptJson>('/document', queryParameters: {'source': source, 'page': page})).data!;
  Future<PromptJson> job(String id) async => (await client.get<PromptJson>('/jobs/$id')).data!;
  Future<PromptJson> analyze(String source, int page, Uint8List image) async => (await client.post<PromptJson>('/jobs', data: FormData.fromMap({
    'source': source, 'page': page, 'image': MultipartFile.fromBytes(image, filename: 'page.png'),
  }))).data!;
  Future<PromptJson> save(PromptJson edit) async => (await client.put<PromptJson>('/document', data: edit)).data!;
  void close() => client.close(force: true);
}
