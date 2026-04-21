import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ControllerBackIntent extends Intent {
  const ControllerBackIntent();
}

class ControllerNavigationService {
  const ControllerNavigationService._();

  static const Duration initialRepeatDelay = Duration(milliseconds: 360);
  static const Duration repeatInterval = Duration(milliseconds: 120);

  static const Map<ShortcutActivator, Intent> shortcuts =
      <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
          TraversalDirection.left,
        ),
        SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(
          TraversalDirection.right,
        ),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
          TraversalDirection.up,
        ),
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
          TraversalDirection.down,
        ),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButton1): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonSelect): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.escape): ControllerBackIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonB): ControllerBackIntent(),
        SingleActivator(LogicalKeyboardKey.gameButton2): ControllerBackIntent(),
        SingleActivator(LogicalKeyboardKey.goBack): ControllerBackIntent(),
        SingleActivator(LogicalKeyboardKey.browserBack): ControllerBackIntent(),
      };

  static Intent? intentForKey(LogicalKeyboardKey key) {
    for (final entry in shortcuts.entries) {
      final activator = entry.key;
      if (activator is SingleActivator && activator.trigger == key) {
        return entry.value;
      }
    }
    return null;
  }

  static bool isLikelyControllerInput(LogicalKeyboardKey key) {
    final debugName = (key.debugName ?? '').toLowerCase();
    return debugName.contains('game button') ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.select;
  }

  static String describeEvent(KeyEvent event) {
    final keyName = event.logicalKey.debugName?.trim();
    final fallback = '0x${event.logicalKey.keyId.toRadixString(16)}';
    final phase = switch (event) {
      KeyRepeatEvent() => 'repeat',
      KeyUpEvent() => 'up',
      _ => 'down',
    };
    return '$phase: ${keyName == null || keyName.isEmpty ? fallback : keyName}';
  }

  static String describeIntent(Intent? intent) {
    if (intent == null) {
      return 'unmapped';
    }
    if (intent is DirectionalFocusIntent) {
      return 'focus ${intent.direction.name}';
    }
    if (intent is ActivateIntent || intent is ButtonActivateIntent) {
      return 'activate';
    }
    if (intent is ControllerBackIntent) {
      return 'back';
    }
    return intent.runtimeType.toString();
  }

  static Intent? intentForActionName(String action) {
    return switch (action) {
      'left' => const DirectionalFocusIntent(TraversalDirection.left),
      'right' => const DirectionalFocusIntent(TraversalDirection.right),
      'up' => const DirectionalFocusIntent(TraversalDirection.up),
      'down' => const DirectionalFocusIntent(TraversalDirection.down),
      'activate' => const ActivateIntent(),
      'back' => const ControllerBackIntent(),
      _ => null,
    };
  }
}

enum _RepeatBehavior { none, oncePerPress, directional }

class _RepeatState {
  bool dispatched = false;
  Duration? firstDispatchAt;
  Duration? lastDispatchAt;
}

class ControllerShortcutManager extends ShortcutManager {
  ControllerShortcutManager({
    Map<ShortcutActivator, Intent> shortcuts =
        ControllerNavigationService.shortcuts,
    this.initialRepeatDelay = ControllerNavigationService.initialRepeatDelay,
    this.repeatInterval = ControllerNavigationService.repeatInterval,
  }) : super(shortcuts: shortcuts);

  final Duration initialRepeatDelay;
  final Duration repeatInterval;
  final Map<LogicalKeyboardKey, _RepeatState> _repeatStates =
      <LogicalKeyboardKey, _RepeatState>{};

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    if (event is KeyUpEvent) {
      _repeatStates.remove(event.logicalKey);
      return modal
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.ignored;
    }

    final intent = _findMatchingIntent(event);
    if (intent == null) {
      return modal
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.ignored;
    }
    if (!_shouldDispatch(event, intent)) {
      return KeyEventResult.handled;
    }

    final targetContext = primaryFocus?.context;
    if (targetContext == null) {
      return modal
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.ignored;
    }

    final action = Actions.maybeFind<Intent>(targetContext, intent: intent);
    if (action == null) {
      return modal
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.ignored;
    }

    final (enabled, invokeResult) = Actions.of(
      targetContext,
    ).invokeActionIfEnabled(action, intent, targetContext);
    if (!enabled) {
      return modal
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.ignored;
    }
    return action.toKeyEventResult(intent, invokeResult);
  }

  Intent? _findMatchingIntent(KeyEvent event) {
    final state = HardwareKeyboard.instance;
    for (final entry in shortcuts.entries) {
      if (entry.key.accepts(event, state)) {
        return entry.value;
      }
    }
    return null;
  }

  bool _shouldDispatch(KeyEvent event, Intent intent) {
    final behavior = _repeatBehaviorFor(intent);
    if (behavior == _RepeatBehavior.none) {
      return true;
    }

    final state = _repeatStates.putIfAbsent(
      event.logicalKey,
      () => _RepeatState(),
    );
    final now = event.timeStamp;

    if (behavior == _RepeatBehavior.oncePerPress) {
      if (event is KeyRepeatEvent || state.dispatched) {
        return false;
      }
      state
        ..dispatched = true
        ..firstDispatchAt = now
        ..lastDispatchAt = now;
      return true;
    }

    if (event is KeyRepeatEvent) {
      final firstDispatchAt = state.firstDispatchAt ?? now;
      final lastDispatchAt = state.lastDispatchAt ?? firstDispatchAt;
      if (now - firstDispatchAt < initialRepeatDelay) {
        return false;
      }
      if (now - lastDispatchAt < repeatInterval) {
        return false;
      }
      state
        ..dispatched = true
        ..firstDispatchAt = firstDispatchAt
        ..lastDispatchAt = now;
      return true;
    }

    if (state.dispatched) {
      final lastDispatchAt = state.lastDispatchAt ?? now;
      if (now - lastDispatchAt < repeatInterval) {
        return false;
      }
    }

    state
      ..dispatched = true
      ..firstDispatchAt ??= now
      ..lastDispatchAt = now;
    return true;
  }

  _RepeatBehavior _repeatBehaviorFor(Intent intent) {
    if (intent is DirectionalFocusIntent) {
      return _RepeatBehavior.directional;
    }
    if (intent is ActivateIntent ||
        intent is ButtonActivateIntent ||
        intent is ControllerBackIntent) {
      return _RepeatBehavior.oncePerPress;
    }
    return _RepeatBehavior.none;
  }
}

class ControllerNavigationShell extends StatefulWidget {
  final Widget child;

  const ControllerNavigationShell({super.key, required this.child});

  @override
  State<ControllerNavigationShell> createState() =>
      _ControllerNavigationShellState();
}

class _ControllerNavigationShellState extends State<ControllerNavigationShell> {
  static const MethodChannel _platformChannel = MethodChannel(
    'pdf_viewer/controller_navigation',
  );

  late final ControllerShortcutManager _shortcutManager =
      ControllerShortcutManager();
  late final KeyEventCallback _hardwareKeyHandler = _handleHardwareKeyEvent;

  Timer? _debugOverlayTimer;
  String? _latestInputLabel;
  String? _latestMappedAction;
  bool _latestWasControllerInput = false;
  String? _controllerBackendStatus;
  String? _controllerBackendDetail;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _controllerBackendStatus = 'Checking XInput controllers';
      _controllerBackendDetail = 'Use d-pad, left stick, A/B, or arrow keys';
      unawaited(_installPlatformChannel());
    }
  }

  @override
  void dispose() {
    _debugOverlayTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _platformChannel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    if (!kDebugMode || event.synthesized || event is KeyUpEvent) {
      return false;
    }

    final mappedIntent = ControllerNavigationService.intentForKey(
      event.logicalKey,
    );
    _recordLatestInput(
      inputLabel: ControllerNavigationService.describeEvent(event),
      mappedAction: ControllerNavigationService.describeIntent(mappedIntent),
      wasControllerInput: ControllerNavigationService.isLikelyControllerInput(
        event.logicalKey,
      ),
    );
    return false;
  }

  Future<void> _installPlatformChannel() async {
    _platformChannel.setMethodCallHandler(_handlePlatformMethodCall);
    try {
      final rawStatus = await _platformChannel.invokeMethod<Object?>(
        'getStatus',
      );
      _applyPlatformStatus(rawStatus);
    } on MissingPluginException {
      _applyStaticPlatformStatus(
        status: 'Native controller bridge unavailable',
        detail: 'Keyboard mapping is active',
      );
    } on PlatformException {
      _applyStaticPlatformStatus(
        status: 'Failed to query controller status',
        detail: 'Keyboard mapping is active',
      );
    }
  }

  Future<void> _handlePlatformMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'controllerStatus':
        _applyPlatformStatus(call.arguments);
        return;
      case 'controllerAction':
        _handlePlatformAction(call.arguments);
        return;
    }
  }

  void _handlePlatformAction(dynamic arguments) {
    final payload = _asArgumentMap(arguments);
    final actionName = _readString(payload, 'action');
    if (actionName == null) {
      return;
    }

    final intent = ControllerNavigationService.intentForActionName(actionName);
    _invokeIntent(intent);
    _recordLatestInput(
      inputLabel:
          '${_readString(payload, "backend") ?? "controller"}: ${_readString(payload, "control") ?? "input"}',
      mappedAction: ControllerNavigationService.describeIntent(intent),
      wasControllerInput: true,
    );
  }

  void _invokeIntent(Intent? intent) {
    if (intent == null) {
      return;
    }

    final targetContext = primaryFocus?.context ?? context;
    final action = Actions.maybeFind<Intent>(targetContext, intent: intent);
    if (action == null) {
      if (intent is ControllerBackIntent) {
        Navigator.maybeOf(context)?.maybePop();
      }
      return;
    }

    final (enabled, invokeResult) = Actions.of(
      targetContext,
    ).invokeActionIfEnabled(action, intent, targetContext);
    if (!enabled) {
      if (intent is ControllerBackIntent) {
        Navigator.maybeOf(context)?.maybePop();
      }
      return;
    }
    action.toKeyEventResult(intent, invokeResult);
  }

  void _applyPlatformStatus(dynamic arguments) {
    final payload = _asArgumentMap(arguments);
    final connected = _readBool(payload, 'connected') ?? false;
    final backend = _readString(payload, 'backend') ?? 'controller';
    final controllerIndex = _readInt(payload, 'controllerIndex');

    _applyStaticPlatformStatus(
      status: connected
          ? '$backend controller ${controllerIndex ?? 0} connected'
          : 'No $backend controller detected',
      detail: connected
          ? 'Use d-pad, left stick, A/B, or arrow keys'
          : 'Keyboard mapping is active',
    );
  }

  void _applyStaticPlatformStatus({
    required String status,
    required String detail,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      _controllerBackendStatus = status;
      _controllerBackendDetail = detail;
    });
  }

  Map<Object?, Object?> _asArgumentMap(dynamic arguments) {
    if (arguments is Map<Object?, Object?>) {
      return arguments;
    }
    if (arguments is Map) {
      return arguments.map(
        (key, value) => MapEntry<Object?, Object?>(key, value),
      );
    }
    return const <Object?, Object?>{};
  }

  String? _readString(Map<Object?, Object?> payload, String key) {
    final value = payload[key];
    if (value == null) {
      return null;
    }
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  bool? _readBool(Map<Object?, Object?> payload, String key) {
    final value = payload[key];
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') {
        return true;
      }
      if (normalized == 'false') {
        return false;
      }
    }
    return null;
  }

  int? _readInt(Map<Object?, Object?> payload, String key) {
    final value = payload[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  void _recordLatestInput({
    required String inputLabel,
    required String mappedAction,
    required bool wasControllerInput,
  }) {
    if (!kDebugMode || !mounted) {
      return;
    }

    setState(() {
      _latestInputLabel = inputLabel;
      _latestMappedAction = mappedAction;
      _latestWasControllerInput = wasControllerInput;
    });

    _debugOverlayTimer?.cancel();
    _debugOverlayTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _latestInputLabel = null;
        _latestMappedAction = null;
        _latestWasControllerInput = false;
      });
    });
  }

  Widget _buildDebugInputMonitor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final latestInputLabel = _latestInputLabel;
    final latestMappedAction = _latestMappedAction;
    final waiting = latestInputLabel == null;

    final title = waiting
        ? (_controllerBackendStatus ?? 'Waiting for controller input')
        : latestInputLabel;
    final subtitle = waiting
        ? (_controllerBackendDetail ??
              'Use d-pad, left stick, A/B, or arrow keys')
        : 'mapped: $latestMappedAction';
    final borderColor = waiting
        ? scheme.outline.withValues(alpha: 0.35)
        : (_latestWasControllerInput ? scheme.primary : scheme.tertiary);

    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 140),
              opacity: waiting ? 0.72 : 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor, width: 1.2),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: DefaultTextStyle(
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall!.copyWith(color: Colors.white),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts.manager(
      manager: _shortcutManager,
      child: Actions(
        actions: <Type, Action<Intent>>{
          ControllerBackIntent: CallbackAction<ControllerBackIntent>(
            onInvoke: (intent) => Navigator.maybeOf(context)?.maybePop(),
          ),
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Focus(
              autofocus: true,
              skipTraversal: true,
              debugLabel: 'controller-navigation-shell',
              child: widget.child,
            ),
            if (kDebugMode) _buildDebugInputMonitor(context),
          ],
        ),
      ),
    );
  }
}

class ControllerNavigationRegion extends StatefulWidget {
  final Widget child;
  final String? debugLabel;
  final bool autofocusBoundary;
  final bool autofocusFirstFocusable;
  final FocusTraversalPolicy? policy;

  const ControllerNavigationRegion({
    super.key,
    required this.child,
    this.debugLabel,
    this.autofocusBoundary = true,
    this.autofocusFirstFocusable = false,
    this.policy,
  });

  @override
  State<ControllerNavigationRegion> createState() =>
      _ControllerNavigationRegionState();
}

class _ControllerNavigationRegionState
    extends State<ControllerNavigationRegion> {
  late final FocusNode _focusNode = FocusNode(debugLabel: widget.debugLabel);
  bool _autofocusQueued = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange(bool hasFocus) {
    if (!hasFocus || !widget.autofocusFirstFocusable || _autofocusQueued) {
      return;
    }
    _autofocusQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autofocusQueued = false;
      if (!mounted || !_focusNode.hasPrimaryFocus) {
        return;
      }
      _focusNode.nextFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: widget.policy ?? ReadingOrderTraversalPolicy(),
      child: Focus(
        focusNode: _focusNode,
        autofocus: widget.autofocusBoundary,
        canRequestFocus: true,
        skipTraversal: true,
        onFocusChange: _handleFocusChange,
        child: widget.child,
      ),
    );
  }
}

Future<T?> showControllerDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool? requestFocus,
  bool autofocusBoundary = true,
  bool autofocusFirstFocusable = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    traversalEdgeBehavior: traversalEdgeBehavior,
    requestFocus: requestFocus,
    builder: (dialogContext) => ControllerNavigationRegion(
      debugLabel: 'controller-dialog',
      autofocusBoundary: autofocusBoundary,
      autofocusFirstFocusable: autofocusFirstFocusable,
      child: builder(dialogContext),
    ),
  );
}

Future<T?> showControllerModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  Color? backgroundColor,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: backgroundColor,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    builder: (sheetContext) => ControllerNavigationRegion(
      debugLabel: 'controller-bottom-sheet',
      autofocusFirstFocusable: true,
      child: builder(sheetContext),
    ),
  );
}
