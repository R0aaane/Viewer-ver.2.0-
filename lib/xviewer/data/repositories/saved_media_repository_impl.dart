import 'package:collection/collection.dart';
import 'package:hive/hive.dart';

import '../../core/constants/storage_keys.dart';
import '../../domain/models/saved_media_record.dart';
import '../../domain/repositories/saved_media_repository.dart';

class SavedMediaRepositoryImpl implements SavedMediaRepository {
  SavedMediaRepositoryImpl(this._box);

  final Box<Map<dynamic, dynamic>> _box;

  @override
  Future<void> delete(String recordId) async {
    await _box.delete(recordId);
  }

  @override
  Future<SavedMediaRecord?> findByRecordId(String recordId) async {
    final value = _box.get(recordId);
    if (value == null) {
      return null;
    }

    return SavedMediaRecord.fromJson(
      Map<String, dynamic>.from(value.cast<String, dynamic>()),
    );
  }

  @override
  Future<SavedMediaRecord?> findByMediaKey(String mediaKey) async {
    final records = await getAll();
    return records.firstWhereOrNull((record) => record.mediaKey == mediaKey);
  }

  @override
  Future<List<SavedMediaRecord>> getAll() async {
    return _box.values
        .map(
          (value) => SavedMediaRecord.fromJson(
            Map<String, dynamic>.from(value.cast<String, dynamic>()),
          ),
        )
        .toList()
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  }

  @override
  Future<void> save(SavedMediaRecord record) async {
    await _box.put(record.recordId, record.toJson());
  }
}

SavedMediaRepository createSavedMediaRepository() {
  final box = Hive.box<Map<dynamic, dynamic>>(StorageKeys.savedMediaBox);
  return SavedMediaRepositoryImpl(box);
}
