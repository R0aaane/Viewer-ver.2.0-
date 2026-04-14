import 'package:flutter/material.dart';

class ControllerFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool enabled;
  final bool descendantsAreFocusable;
  final String? debugLabel;
  final BorderRadius? borderRadius;
  final Widget Function(BuildContext context, bool focused, Widget child)?
  builder;

  const ControllerFocusable({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.enabled = true,
    this.descendantsAreFocusable = false,
    this.debugLabel,
    this.borderRadius,
    this.builder,
  });

  @override
  State<ControllerFocusable> createState() => _ControllerFocusableState();
}

class _ControllerFocusableState extends State<ControllerFocusable> {
  FocusNode? _internalFocusNode;
  bool _focused = false;

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_internalFocusNode ??= FocusNode(debugLabel: widget.debugLabel));

  @override
  void dispose() {
    _internalFocusNode?.dispose();
    super.dispose();
  }

  void _handlePressed() {
    if (!widget.enabled) {
      return;
    }
    widget.onPressed?.call();
  }

  void _handleFocusChange(bool focused) {
    if (_focused == focused) {
      return;
    }
    setState(() => _focused = focused);
    if (!focused) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusNode.hasFocus) {
        return;
      }
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderRadius = widget.borderRadius ?? BorderRadius.circular(14);

    final decoratedChild =
        widget.builder?.call(context, _focused, widget.child) ??
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border: Border.all(
              color: _focused ? scheme.primary : Colors.transparent,
              width: _focused ? 2.2 : 2.2,
            ),
            boxShadow: _focused
                ? <BoxShadow>[
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.18),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: widget.child,
        );

    return FocusableActionDetector(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      descendantsAreFocusable: widget.descendantsAreFocusable,
      onShowFocusHighlight: _handleFocusChange,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (intent) => _handlePressed(),
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (intent) => _handlePressed(),
        ),
        SelectIntent: CallbackAction<SelectIntent>(
          onInvoke: (intent) => _handlePressed(),
        ),
      },
      child: Semantics(
        button: widget.onPressed != null,
        child: Material(
          color: Colors.transparent,
          borderRadius: borderRadius,
          child: InkWell(
            borderRadius: borderRadius,
            canRequestFocus: false,
            onTap: widget.enabled ? _handlePressed : null,
            onLongPress: widget.enabled ? widget.onLongPress : null,
            child: decoratedChild,
          ),
        ),
      ),
    );
  }
}
