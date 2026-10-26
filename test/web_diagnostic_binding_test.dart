import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/web/web_diagnostic_binding.dart';

class _LayoutBox extends RenderBox {
  int layouts = 0;

  @override
  void performLayout() {
    layouts++;
    size = constraints.smallest;
  }
}

void main() {
  test('diagnostic binding initializes its owner before the first frame', () {
    final phases = <String>[];
    final binding = WebDiagnosticBinding(report: (phase, _) => phases.add(phase));
    expect(binding.rootPipelineOwner, isA<WebDiagnosticPipelineOwner>());
    binding.drawFrame();
    expect(phases, containsAll(['layout', 'paint', 'frameworkFrame']));
  });

  test('root probe measures dirty layout in a child pipeline owner', () {
    final phases = <String>[];
    final root = WebDiagnosticPipelineOwner(
      report: (phase, ms) {
        expect(ms, greaterThanOrEqualTo(0));
        phases.add(phase);
      },
    );
    final child = PipelineOwner();
    final box = _LayoutBox();
    root.adoptChild(child);
    child.rootNode = box;
    box.layout(const BoxConstraints.tightFor(width: 10, height: 10));
    box.layouts = 0;
    box.markNeedsLayout();
    root.flushLayout();
    root.flushPaint();
    expect(box.layouts, 1);
    expect(phases, ['layout', 'paint']);
    child.rootNode = null;
    root.dropChild(child);
    box.dispose();
    child.dispose();
    root.dispose();
  });

  test('failed reporting cannot stop normal layout processing', () {
    final root = WebDiagnosticPipelineOwner(
      report: (_, _) => throw StateError('probe failure'),
    );
    final box = _LayoutBox();
    root.rootNode = box;
    box.layout(const BoxConstraints.tightFor(width: 10, height: 10));
    box.layouts = 0;
    box.markNeedsLayout();
    root.flushLayout();
    expect(box.layouts, 1);
    root.rootNode = null;
    box.dispose();
    root.dispose();
  });
}
