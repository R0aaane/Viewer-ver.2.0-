import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile_webview;
import 'package:webview_windows/webview_windows.dart' as windows_webview;

class UrlImportBrowserPage extends StatefulWidget {
  final String? initialUrl;

  const UrlImportBrowserPage({super.key, this.initialUrl});

  static bool get isSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  static Future<String?> show(BuildContext context, {String? initialUrl}) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => UrlImportBrowserPage(initialUrl: initialUrl),
      ),
    );
  }

  @override
  State<UrlImportBrowserPage> createState() => _UrlImportBrowserPageState();
}

class _UrlImportBrowserPageState extends State<UrlImportBrowserPage> {
  static const List<String> _quickLinks = <String>[
    'https://kemono.su',
    'https://coomer.su',
    'https://hitomi.la',
  ];
  static const String _defaultTitle = 'URL ブラウザ';
  static const List<String> _blockedHostSuffixes = <String>[
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'googletagmanager.com',
    'adnxs.com',
    'amazon-adsystem.com',
    'criteo.com',
    'taboola.com',
    'outbrain.com',
    'adsrvr.org',
    'scorecardresearch.com',
    'yieldmanager.com',
    'zedo.com',
  ];
  static const String _adBlockScript = r'''
(() => {
  if (window.__pdfViewerAdBlockInstalled) {
    return;
  }
  window.__pdfViewerAdBlockInstalled = true;

  const blockedHosts = [
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'googletagmanager.com',
    'adnxs.com',
    'amazon-adsystem.com',
    'criteo.com',
    'taboola.com',
    'outbrain.com',
    'adsrvr.org',
    'scorecardresearch.com',
    'yieldmanager.com',
    'zedo.com',
  ];
  const cosmeticSelectors = [
    'ins.adsbygoogle',
    '[data-ad-client]',
    '[data-ad-slot]',
    '[id*="google_ads" i]',
    '[class*="adsbygoogle" i]',
    '[class*="advert" i]',
    '[id*="advert" i]',
    '[class*="sponsor" i]',
    '[id*="sponsor" i]',
    '.advertisement',
    '.ad-banner',
    '.ad-container',
    '.adsbox',
    '.sponsored-content',
    'iframe[src*="doubleclick" i]',
    'iframe[src*="googlesyndication" i]',
    'iframe[src*="adservice" i]',
    'iframe[src*="taboola" i]',
    'iframe[src*="outbrain" i]',
    'script[src*="doubleclick" i]',
    'script[src*="googlesyndication" i]',
    'script[src*="googletagmanager" i]',
  ];

  const shouldBlock = (value) => {
    if (!value) {
      return false;
    }
    try {
      const parsed = new URL(String(value), location.href);
      const host = parsed.hostname.toLowerCase();
      return blockedHosts.some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
    } catch (_) {
      const text = String(value).toLowerCase();
      return blockedHosts.some((suffix) => text.includes(suffix));
    }
  };

  const hideNode = (node) => {
    if (!node || !node.style) {
      return;
    }
    node.style.setProperty('display', 'none', 'important');
    node.style.setProperty('visibility', 'hidden', 'important');
    node.style.setProperty('pointer-events', 'none', 'important');
    node.setAttribute('aria-hidden', 'true');
  };

  const removeAds = () => {
    for (const selector of cosmeticSelectors) {
      for (const node of document.querySelectorAll(selector)) {
        hideNode(node);
      }
    }
    for (const node of document.querySelectorAll('iframe[src], img[src], script[src], a[href]')) {
      const source = node.getAttribute('src') || node.getAttribute('href') || '';
      if (shouldBlock(source)) {
        hideNode(node);
      }
    }
  };

  const style = document.createElement('style');
  style.id = 'pdf-viewer-adblock-style';
  style.textContent = `${cosmeticSelectors.join(',')} { display: none !important; visibility: hidden !important; }`;
  (document.head || document.documentElement).appendChild(style);

  const originalFetch = window.fetch;
  if (typeof originalFetch === 'function') {
    window.fetch = function(input, init) {
      const candidate = typeof input === 'string'
        ? input
        : input && typeof input === 'object' && 'url' in input
          ? input.url
          : String(input ?? '');
      if (shouldBlock(candidate)) {
        return Promise.resolve(new Response('', { status: 204, statusText: 'Blocked' }));
      }
      return originalFetch.apply(this, [input, init]);
    };
  }

  const originalOpen = XMLHttpRequest.prototype.open;
  const originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url, ...rest) {
    this.__pdfViewerBlocked = shouldBlock(url);
    if (this.__pdfViewerBlocked) {
      return;
    }
    return originalOpen.call(this, method, url, ...rest);
  };
  XMLHttpRequest.prototype.send = function(...args) {
    if (this.__pdfViewerBlocked) {
      try {
        this.abort();
      } catch (_) {}
      return;
    }
    return originalSend.apply(this, args);
  };

  const originalWindowOpen = window.open;
  window.open = function(url, ...rest) {
    if (shouldBlock(url)) {
      return null;
    }
    return typeof originalWindowOpen === 'function'
      ? originalWindowOpen.call(window, url, ...rest)
      : null;
  };

  document.addEventListener('click', (event) => {
    const target = event.target;
    const anchor = target && target.closest ? target.closest('a[href]') : null;
    if (anchor && shouldBlock(anchor.href)) {
      event.preventDefault();
      event.stopPropagation();
    }
  }, true);

  const observer = new MutationObserver(() => {
    removeAds();
  });
  observer.observe(document.documentElement || document, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['src', 'href', 'class', 'id', 'style'],
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', removeAds, { once: true });
  }
  window.addEventListener('load', removeAds, { once: true });
  removeAds();
})();
''';

  final List<StreamSubscription<dynamic>> _windowsSubscriptions =
      <StreamSubscription<dynamic>>[];
  late final TextEditingController _addressController;

  mobile_webview.WebViewController? _mobileController;
  windows_webview.WebviewController? _windowsController;
  String? _windowsAdBlockScriptId;

  String _currentUrl = '';
  String _pageTitle = _defaultTitle;
  String? _windowsUnavailableReason;
  bool _loading = true;
  int _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _adBlockEnabled = true;

  bool get _usesWindowsWebView => Platform.isWindows;
  bool get _canUseCurrentUrl => _isHttpUrl(_currentUrl);

  @override
  void initState() {
    super.initState();
    final initialUrl =
        _normalizeInputToUrl(widget.initialUrl) ?? _quickLinks[0];
    _currentUrl = initialUrl;
    _addressController = TextEditingController(text: initialUrl);

    if (_usesWindowsWebView) {
      unawaited(_initializeWindowsWebview(initialUrl));
      return;
    }
    _initializeMobileWebview(initialUrl);
  }

  void _initializeMobileWebview(String initialUrl) {
    final controller = mobile_webview.WebViewController()
      ..setJavaScriptMode(mobile_webview.JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        mobile_webview.NavigationDelegate(
          onNavigationRequest: (request) {
            if (_adBlockEnabled && _shouldBlockUrl(request.url)) {
              _showSnackBar('広告またはトラッカーへの移動をブロックしました');
              return mobile_webview.NavigationDecision.prevent;
            }
            _setCurrentUrl(request.url);
            return mobile_webview.NavigationDecision.navigate;
          },
          onPageStarted: (url) {
            _setCurrentUrl(url);
            if (!mounted) {
              return;
            }
            setState(() {
              _loading = true;
              _progress = 0;
            });
          },
          onPageFinished: (url) async {
            _setCurrentUrl(url);
            await _applyMobileAdBlockIfNeeded();
            await _refreshMobileNavigationState();
            if (!mounted) {
              return;
            }
            setState(() {
              _loading = false;
              _progress = 100;
            });
          },
          onProgress: (progress) {
            if (!mounted) {
              return;
            }
            setState(() {
              _progress = progress;
            });
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url == null) {
              return;
            }
            if (!mounted) {
              _setCurrentUrl(url);
              return;
            }
            setState(() {
              _setCurrentUrl(url);
            });
          },
          onWebResourceError: (error) {
            if (!mounted) {
              return;
            }
            setState(() {
              _loading = false;
            });
            _showSnackBar('ページを開けませんでした: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(initialUrl));
    _mobileController = controller;
  }

  Future<void> _initializeWindowsWebview(String initialUrl) async {
    final String? version;
    try {
      version = await windows_webview.WebviewController.getWebViewVersion();
    } on MissingPluginException {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _windowsUnavailableReason =
            'Windows 用の内蔵ブラウザプラグインがまだ読み込まれていません。'
            '\nプラグイン追加後はホットリロードではなく、アプリを完全終了して再起動してください。';
      });
      return;
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        final message = error.message?.trim();
        _windowsUnavailableReason = message == null || message.isEmpty
            ? 'Windows 内蔵ブラウザの確認に失敗しました: ${error.code}'
            : 'Windows 内蔵ブラウザの確認に失敗しました: $message';
      });
      return;
    }

    if (!mounted) {
      return;
    }
    if (version == null) {
      setState(() {
        _loading = false;
        _windowsUnavailableReason =
            'Windows では Microsoft Edge WebView2 Runtime が必要です。'
            '\nWebView2 をインストールしてからもう一度お試しください。';
      });
      return;
    }

    final controller = windows_webview.WebviewController();
    _windowsController = controller;

    try {
      await controller.initialize();
      await controller.setBackgroundColor(Colors.transparent);
      await controller.setPopupWindowPolicy(
        windows_webview.WebviewPopupWindowPolicy.sameWindow,
      );
      await _syncWindowsAdBlockScript(force: true);

      _windowsSubscriptions.add(
        controller.url.listen((url) {
          if (!mounted) {
            _setCurrentUrl(url);
            return;
          }
          setState(() {
            _setCurrentUrl(url);
          });
        }),
      );
      _windowsSubscriptions.add(
        controller.title.listen((title) {
          if (!mounted) {
            return;
          }
          setState(() {
            _pageTitle = title.trim().isEmpty ? _defaultTitle : title.trim();
          });
        }),
      );
      _windowsSubscriptions.add(
        controller.loadingState.listen((state) {
          if (!mounted) {
            return;
          }
          setState(() {
            _loading = state == windows_webview.LoadingState.loading;
            if (_loading) {
              _progress = 0;
            } else {
              _progress = 100;
            }
          });
        }),
      );
      _windowsSubscriptions.add(
        controller.historyChanged.listen((history) {
          if (!mounted) {
            return;
          }
          setState(() {
            _canGoBack = history.canGoBack;
            _canGoForward = history.canGoForward;
          });
        }),
      );
      _windowsSubscriptions.add(
        controller.onLoadError.listen((status) {
          if (!mounted) {
            return;
          }
          setState(() {
            _loading = false;
          });
          _showSnackBar('ページを開けませんでした: $status');
        }),
      );

      await controller.loadUrl(initialUrl);
      if (!mounted) {
        return;
      }
      setState(() {});
    } on MissingPluginException {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _windowsUnavailableReason =
            'Windows 用の内蔵ブラウザプラグインがまだ読み込まれていません。'
            '\nアプリを完全終了して再起動すると解消することがあります。';
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        final message = error.message?.trim();
        _windowsUnavailableReason = message == null || message.isEmpty
            ? '内蔵ブラウザの初期化に失敗しました: ${error.code}'
            : '内蔵ブラウザの初期化に失敗しました: $message';
      });
    }
  }

  @override
  void dispose() {
    _addressController.dispose();
    for (final subscription in _windowsSubscriptions) {
      unawaited(subscription.cancel());
    }
    final controller = _windowsController;
    if (controller != null) {
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  bool _shouldBlockUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final uri = Uri.tryParse(trimmed);
    final host = uri?.host.trim().toLowerCase();
    if (host != null && host.isNotEmpty) {
      for (final suffix in _blockedHostSuffixes) {
        if (host == suffix || host.endsWith('.$suffix')) {
          return true;
        }
      }
    }
    final lowered = trimmed.toLowerCase();
    return _blockedHostSuffixes.any(lowered.contains);
  }

  Future<void> _applyMobileAdBlockIfNeeded() async {
    if (!_adBlockEnabled) {
      return;
    }
    final controller = _mobileController;
    if (controller == null) {
      return;
    }
    try {
      await controller.runJavaScript(_adBlockScript);
    } on PlatformException {
      // Ignore adblock injection failures and keep browsing usable.
    }
  }

  Future<void> _syncWindowsAdBlockScript({bool force = false}) async {
    final controller = _windowsController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (_adBlockEnabled) {
      if (_windowsAdBlockScriptId == null || force) {
        if (_windowsAdBlockScriptId != null) {
          try {
            await controller.removeScriptToExecuteOnDocumentCreated(
              _windowsAdBlockScriptId!,
            );
          } on PlatformException {
            // Ignore cleanup failure and overwrite with a fresh registration.
          }
        }
        _windowsAdBlockScriptId = await controller
            .addScriptToExecuteOnDocumentCreated(_adBlockScript);
      }
      try {
        await controller.executeScript(_adBlockScript);
      } on PlatformException {
        // Ignore injection failure for the current page.
      }
      return;
    }

    final scriptId = _windowsAdBlockScriptId;
    _windowsAdBlockScriptId = null;
    if (scriptId == null) {
      return;
    }
    try {
      await controller.removeScriptToExecuteOnDocumentCreated(scriptId);
    } on PlatformException {
      // Ignore removal failure. Reloading still gives the user a way out.
    }
  }

  Future<void> _toggleAdBlock() async {
    setState(() {
      _adBlockEnabled = !_adBlockEnabled;
    });

    if (_usesWindowsWebView) {
      await _syncWindowsAdBlockScript(force: true);
    }
    await _reload();
    _showSnackBar(_adBlockEnabled ? '簡易広告ブロックを有効にしました' : '簡易広告ブロックを無効にしました');
  }

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _setCurrentUrl(String url) {
    if (!_isHttpUrl(url)) {
      return;
    }
    _currentUrl = url;
    if (_addressController.text.trim() != url.trim()) {
      _addressController.value = TextEditingValue(
        text: url,
        selection: TextSelection.collapsed(offset: url.length),
      );
    }
  }

  bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      return false;
    }
    final scheme = uri.scheme.toLowerCase();
    return (scheme == 'http' || scheme == 'https') &&
        uri.host.trim().isNotEmpty;
  }

  String? _normalizeInputToUrl(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) {
      return null;
    }
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    return _isHttpUrl(withScheme) ? withScheme : null;
  }

  Future<void> _loadAddress(String raw) async {
    final normalized = _normalizeInputToUrl(raw);
    if (normalized == null) {
      _showSnackBar('http または https の URL を入力してください');
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _setCurrentUrl(normalized);
      _loading = true;
      _progress = 0;
    });

    if (_usesWindowsWebView) {
      final controller = _windowsController;
      if (controller == null || !controller.value.isInitialized) {
        _showSnackBar('内蔵ブラウザを初期化中です');
        return;
      }
      await controller.loadUrl(normalized);
      return;
    }

    final controller = _mobileController;
    if (controller == null) {
      _showSnackBar('内蔵ブラウザを初期化中です');
      return;
    }
    await controller.loadRequest(Uri.parse(normalized));
  }

  Future<void> _refreshMobileNavigationState() async {
    final controller = _mobileController;
    if (controller == null) {
      return;
    }
    final title = await controller.getTitle();
    final currentUrl = await controller.currentUrl();
    final canGoBack = await controller.canGoBack();
    final canGoForward = await controller.canGoForward();
    if (!mounted) {
      return;
    }
    setState(() {
      _pageTitle = title?.trim().isNotEmpty == true
          ? title!.trim()
          : _defaultTitle;
      if (currentUrl != null && currentUrl.trim().isNotEmpty) {
        _setCurrentUrl(currentUrl);
      }
      _canGoBack = canGoBack;
      _canGoForward = canGoForward;
    });
  }

  Future<void> _goBack() async {
    if (!_canGoBack) {
      return;
    }
    if (_usesWindowsWebView) {
      final controller = _windowsController;
      if (controller == null || !controller.value.isInitialized) {
        return;
      }
      await controller.goBack();
      return;
    }
    final controller = _mobileController;
    if (controller == null) {
      return;
    }
    await controller.goBack();
    await _refreshMobileNavigationState();
  }

  Future<void> _goForward() async {
    if (!_canGoForward) {
      return;
    }
    if (_usesWindowsWebView) {
      final controller = _windowsController;
      if (controller == null || !controller.value.isInitialized) {
        return;
      }
      await controller.goForward();
      return;
    }
    final controller = _mobileController;
    if (controller == null) {
      return;
    }
    await controller.goForward();
    await _refreshMobileNavigationState();
  }

  Future<void> _reload() async {
    if (_usesWindowsWebView) {
      final controller = _windowsController;
      if (controller == null || !controller.value.isInitialized) {
        return;
      }
      setState(() {
        _loading = true;
        _progress = 0;
      });
      await controller.reload();
      return;
    }
    final controller = _mobileController;
    if (controller == null) {
      return;
    }
    setState(() {
      _loading = true;
      _progress = 0;
    });
    await controller.reload();
    await _refreshMobileNavigationState();
  }

  Widget _buildBrowserSurface() {
    if (_usesWindowsWebView) {
      if (_windowsUnavailableReason != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _windowsUnavailableReason!,
              textAlign: TextAlign.center,
            ),
          ),
        );
      }

      final controller = _windowsController;
      if (controller == null || !controller.value.isInitialized) {
        return const Center(child: CircularProgressIndicator());
      }

      return Stack(
        children: [
          windows_webview.Webview(controller),
          if (_loading)
            Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(
                value: _progress <= 0 || _progress >= 100
                    ? null
                    : _progress / 100,
                minHeight: 3,
              ),
            ),
        ],
      );
    }

    final controller = _mobileController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        mobile_webview.WebViewWidget(controller: controller),
        if (_loading)
          Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(
              value: _progress <= 0 || _progress >= 100
                  ? null
                  : _progress / 100,
              minHeight: 3,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!UrlImportBrowserPage.isSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text(_defaultTitle)),
        body: const SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('この端末では内蔵ブラウザを利用できません。'),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_pageTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            onPressed: _toggleAdBlock,
            icon: Icon(
              _adBlockEnabled
                  ? Icons.shield_outlined
                  : Icons.shield_moon_outlined,
            ),
            tooltip: _adBlockEnabled ? '広告ブロック: ON' : '広告ブロック: OFF',
          ),
          IconButton(
            onPressed: _canUseCurrentUrl
                ? () => Navigator.of(context).pop(_currentUrl)
                : null,
            icon: const Icon(Icons.check_circle_outline),
            tooltip: 'このページを使う',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _addressController,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _loadAddress,
                      decoration: const InputDecoration(
                        labelText: 'URL',
                        hintText: 'https://kemono.su',
                        prefixIcon: Icon(Icons.language),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () => _loadAddress(_addressController.text),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('開く'),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemBuilder: (context, index) {
                  final url = _quickLinks[index];
                  final host = Uri.parse(url).host;
                  return ActionChip(
                    avatar: const Icon(
                      Icons.open_in_browser_outlined,
                      size: 18,
                    ),
                    label: Text(host),
                    onPressed: () => _loadAddress(url),
                  );
                },
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemCount: _quickLinks.length,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildBrowserSurface()),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withValues(alpha: 0.14),
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: _canGoBack ? _goBack : null,
                          icon: const Icon(Icons.arrow_back),
                          tooltip: '戻る',
                        ),
                        IconButton(
                          onPressed: _canGoForward ? _goForward : null,
                          icon: const Icon(Icons.arrow_forward),
                          tooltip: '進む',
                        ),
                        IconButton(
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh),
                          tooltip: '再読み込み',
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _currentUrl.isEmpty ? 'URL を開いてください' : _currentUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _canUseCurrentUrl
                            ? () => Navigator.of(context).pop(_currentUrl)
                            : null,
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('このページを取り込みに使う'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
