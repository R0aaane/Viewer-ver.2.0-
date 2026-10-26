import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

typedef WebPhaseReporter = void Function(String phase, double milliseconds);

void _measure(String phase, VoidCallback operation, WebPhaseReporter report) {
  final watch = Stopwatch()..start();
  try {
    operation();
  } finally {
    watch.stop();
    try {
      report(phase, watch.elapsedMicroseconds / 1000);
    } catch (_) {
      // Diagnostic failures must not replace rendering errors or stop the app.
    }
  }
}

/// Only instantiated for ?perf=1, before any binding has been created.
class WebDiagnosticBinding extends WidgetsFlutterBinding {
  final WebPhaseReporter report;

  WebDiagnosticBinding({required this.report});

  @override
  PipelineOwner createRootPipelineOwner() => WebDiagnosticPipelineOwner(
    report: report,
    onNeedVisualUpdate: ensureVisualUpdate,
  );

  @override
  void drawFrame() => _measure('frameworkFrame', super.drawFrame, report);
}

final class WebDiagnosticPipelineOwner extends PipelineOwner {
  final WebPhaseReporter report;

  WebDiagnosticPipelineOwner({required this.report, super.onNeedVisualUpdate});

  @override
  void flushLayout() => _measure('layout', super.flushLayout, report);

  @override
  void flushPaint() => _measure('paint', super.flushPaint, report);
}
