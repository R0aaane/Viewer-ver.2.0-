import 'package:hive_flutter/hive_flutter.dart';

import 'constants/storage_keys.dart';
import '../services/x_auth_config_service.dart';

Future<void> bootstrap() async {
  await XAuthConfigService.loadEnvAsset();
  await Hive.initFlutter();
  await Hive.openBox<Map<dynamic, dynamic>>(StorageKeys.savedMediaBox);
}
