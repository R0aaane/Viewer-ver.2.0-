import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/web/web_reader_keyboard_shortcuts.dart';

void main() {
  testWidgets(
    'viewer arrows turn pages, including held keys, without key-up duplication',
    (tester) async {
      var next = 0;
      var previous = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: WebReaderKeyboardShortcuts(
            onPreviousPage: () => previous++,
            onNextPage: () => next++,
            child: const Scaffold(body: Text('reader')),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      expect(next, 1);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      expect(next, 2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      expect(next, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(previous, 1);
    },
  );

  testWidgets('toolbar focus does not turn page keys into focus navigation', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var next = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WebReaderKeyboardShortcuts(
          onPreviousPage: () {},
          onNextPage: () => next++,
          child: Scaffold(
            body: Row(
              children: [
                TextButton(
                  focusNode: focus,
                  onPressed: () {},
                  child: const Text('toolbar'),
                ),
                TextButton(onPressed: () {}, child: const Text('other')),
              ],
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(next, 1);
    expect(focus.hasPrimaryFocus, isTrue);
  });

  testWidgets('text editing keeps arrow keys and modifier combinations', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    var pageChanges = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WebReaderKeyboardShortcuts(
          onPreviousPage: () => pageChanges++,
          onNextPage: () => pageChanges++,
          child: Scaffold(body: TextField(controller: controller)),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(controller.selection.baseOffset, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(controller.selection.baseOffset, 2);
    expect(pageChanges, 0);
  });

  testWidgets('disabled reader and modified arrows do not turn pages', (
    tester,
  ) async {
    var changes = 0;
    Widget build(bool enabled) => MaterialApp(
      home: WebReaderKeyboardShortcuts(
        enabled: enabled,
        onPreviousPage: () => changes++,
        onNextPage: () => changes++,
        child: const Scaffold(body: Text('reader')),
      ),
    );
    await tester.pumpWidget(build(false));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(changes, 0);
    await tester.pumpWidget(build(true));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(changes, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(changes, 1);
  });

  testWidgets(
    'dialog keys do not change underlying pages and closing restores reader keys',
    (tester) async {
      var changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: WebReaderKeyboardShortcuts(
            onPreviousPage: () => changes++,
            onNextPage: () => changes++,
            child: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('close'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(changes, 0);
      await tester.tap(find.text('close'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(changes, 1);
    },
  );
}
