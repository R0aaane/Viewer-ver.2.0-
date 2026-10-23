import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps reader keys local to the viewer, below the app's focus navigation.
class WebReaderKeyboardShortcuts extends StatelessWidget {
  final Widget child;
  final VoidCallback onPreviousPage;
  final VoidCallback onNextPage;
  final bool enabled;

  const WebReaderKeyboardShortcuts({
    super.key,
    required this.child,
    required this.onPreviousPage,
    required this.onNextPage,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (!enabled || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
          return KeyEventResult.ignored;
        }
        final focusedContext = FocusManager.instance.primaryFocus?.context;
        if (focusedContext?.widget is EditableText ||
            focusedContext?.findAncestorWidgetOfExactType<EditableText>() !=
                null) {
          return KeyEventResult.ignored;
        }
        final keyboard = HardwareKeyboard.instance;
        if (const SingleActivator(
          LogicalKeyboardKey.arrowRight,
        ).accepts(event, keyboard)) {
          onNextPage();
          return KeyEventResult.handled;
        }
        if (const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
        ).accepts(event, keyboard)) {
          onPreviousPage();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
