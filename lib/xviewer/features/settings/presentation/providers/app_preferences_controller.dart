import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/constants/storage_keys.dart';

enum AppBackgroundMode { white, black }

class AppPreferences {
  const AppPreferences({
    required this.backgroundMode,
    required this.savedItemsLabel,
  });

  static const defaultSavedItemsLabel = 'Saved Images';

  final AppBackgroundMode backgroundMode;
  final String savedItemsLabel;

  bool get useBlackBackground => backgroundMode == AppBackgroundMode.black;

  AppPreferences copyWith({
    AppBackgroundMode? backgroundMode,
    String? savedItemsLabel,
  }) {
    return AppPreferences(
      backgroundMode: backgroundMode ?? this.backgroundMode,
      savedItemsLabel: savedItemsLabel ?? this.savedItemsLabel,
    );
  }

  static const defaults = AppPreferences(
    backgroundMode: AppBackgroundMode.white,
    savedItemsLabel: defaultSavedItemsLabel,
  );
}

final appPreferencesProvider =
    StateNotifierProvider<AppPreferencesController, AppPreferences>(
      (ref) => AppPreferencesController(),
    );

class AppPreferencesController extends StateNotifier<AppPreferences> {
  AppPreferencesController() : super(AppPreferences.defaults) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final backgroundModeName = prefs.getString(StorageKeys.appBackgroundMode);
    final savedItemsLabel =
        prefs.getString(StorageKeys.savedItemsLabel) ??
        AppPreferences.defaultSavedItemsLabel;

    state = AppPreferences(
      backgroundMode: AppBackgroundMode.values.firstWhere(
        (mode) => mode.name == backgroundModeName,
        orElse: () => AppPreferences.defaults.backgroundMode,
      ),
      savedItemsLabel: _normalizeSavedItemsLabel(savedItemsLabel),
    );
  }

  Future<void> setBackgroundMode(AppBackgroundMode mode) async {
    if (state.backgroundMode == mode) {
      return;
    }

    state = state.copyWith(backgroundMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.appBackgroundMode, mode.name);
  }

  Future<void> setSavedItemsLabel(String label) async {
    final normalized = _normalizeSavedItemsLabel(label);
    if (state.savedItemsLabel == normalized) {
      return;
    }

    state = state.copyWith(savedItemsLabel: normalized);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.savedItemsLabel, normalized);
  }

  Future<void> reset() async {
    state = AppPreferences.defaults;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.appBackgroundMode);
    await prefs.remove(StorageKeys.savedItemsLabel);
  }

  String _normalizeSavedItemsLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      return AppPreferences.defaultSavedItemsLabel;
    }
    return trimmed;
  }
}
