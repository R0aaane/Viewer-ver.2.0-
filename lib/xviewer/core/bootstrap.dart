import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants/storage_keys.dart';
import '../services/x_auth_config_service.dart';

Future<void> bootstrap() async {
  await XAuthConfigService.loadEnvAsset();
  final prefs = await SharedPreferences.getInstance();
  final savedImagesDirectory = prefs
      .getString(StorageKeys.savedImagesDirectory)
      ?.trim();
  if (savedImagesDirectory == null || savedImagesDirectory.isEmpty) {
    await Hive.initFlutter();
  } else {
    await Hive.initFlutter(savedImagesDirectory);
  }
  await Hive.openBox<Map<dynamic, dynamic>>(StorageKeys.savedMediaBox);
}
