import 'package:flutter/material.dart';

void configureGlobalErrorHandling() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
    if (details.stack != null) {
      debugPrintStack(label: '[FlutterError]', stackTrace: details.stack);
    }
  };

  ErrorWidget.builder = (details) {
    debugPrint('[ErrorWidget] ${details.exceptionAsString()}');
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: const Color(0xFF160F10),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '画面の描画中にエラーが発生しました。\n${details.exceptionAsString()}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  };
}
