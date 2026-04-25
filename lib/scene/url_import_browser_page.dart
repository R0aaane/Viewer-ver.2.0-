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
    '2mdn.net',
    'ad.gt',
    'adform.net',
    'adition.com',
    'adnxs.com',
    'adroll.com',
    'adsafeprotected.com',
    'adservice.google.com',
    'adsterra.com',
    'ads-twitter.com',
    'adskeeper.com',
    'advertising.com',
    'analytics.google.com',
    'appier.net',
    'bidr.io',
    'casalemedia.com',
    'contextweb.com',
    'creativecdn.com',
    'criteo.com',
    'doubleclick.net',
    'ero-advertising.com',
    'exoclick.com',
    'exosrv.com',
    'google-analytics.com',
    'googlesyndication.com',
    'googleadservices.com',
    'googletagmanager.com',
    'googletagservices.com',
    'hilltopads.net',
    'imrworldwide.com',
    'juicyads.com',
    'lijit.com',
    'mgid.com',
    'moatads.com',
    'openx.net',
    'openx.com',
    'popads.net',
    'propellerads.com',
    'pubmatic.com',
    'quantserve.com',
    'revcontent.com',
    'rubiconproject.com',
    'sharethrough.com',
    'smartadserver.com',
    'serving-sys.com',
    'amazon-adsystem.com',
    'taboola.com',
    'trafficjunky.net',
    'yieldmo.com',
    'outbrain.com',
    'adsrvr.org',
    'scorecardresearch.com',
    'yieldmanager.com',
    'zedo.com',
  ];
  static const List<String> _blockedUrlFragments = <String>[
    '/ad-delivery/',
    '/adserver/',
    '/adservice/',
    '/adsystem/',
    '/advert/',
    '/analytics.js',
    '/banner-ad',
    '/banners/',
    '/bidder/',
    '/pagead/',
    '/popads/',
    '/popunder',
    '/prebid',
    '/sponsor/',
    '?ad_id=',
    '&ad_id=',
    'adunit=',
    'adzone=',
  ];
  static const String _adBlockScript = r'''
(() => {
  if (window.__pdfViewerAdBlockInstalled) {
    return;
  }
  window.__pdfViewerAdBlockInstalled = true;

  const blockedHosts = [
    '2mdn.net',
    'ad.gt',
    'adform.net',
    'adition.com',
    'adnxs.com',
    'adroll.com',
    'adsafeprotected.com',
    'adservice.google.com',
    'adsterra.com',
    'ads-twitter.com',
    'adskeeper.com',
    'advertising.com',
    'analytics.google.com',
    'appier.net',
    'bidr.io',
    'casalemedia.com',
    'contextweb.com',
    'creativecdn.com',
    'criteo.com',
    'doubleclick.net',
    'ero-advertising.com',
    'exoclick.com',
    'exosrv.com',
    'google-analytics.com',
    'googlesyndication.com',
    'googleadservices.com',
    'googletagmanager.com',
    'googletagservices.com',
    'hilltopads.net',
    'imrworldwide.com',
    'juicyads.com',
    'lijit.com',
    'mgid.com',
    'moatads.com',
    'openx.net',
    'openx.com',
    'popads.net',
    'propellerads.com',
    'pubmatic.com',
    'quantserve.com',
    'revcontent.com',
    'rubiconproject.com',
    'sharethrough.com',
    'smartadserver.com',
    'serving-sys.com',
    'amazon-adsystem.com',
    'taboola.com',
    'trafficjunky.net',
    'yieldmo.com',
    'outbrain.com',
    'adsrvr.org',
    'scorecardresearch.com',
    'yieldmanager.com',
    'zedo.com',
  ];
  const blockedUrlFragments = [
    '/ad-delivery/',
    '/adserver/',
    '/adservice/',
    '/adsystem/',
    '/advert/',
    '/analytics.js',
    '/banner-ad',
    '/banners/',
    '/bidder/',
    '/pagead/',
    '/popads/',
    '/popunder',
    '/prebid',
    '/sponsor/',
    '?ad_id=',
    '&ad_id=',
    'adunit=',
    'adzone=',
  ];
  const cosmeticSelectors = [
    'ins.adsbygoogle',
    '[data-ad-client]',
    '[data-ad-slot]',
    '[aria-label*="advertisement" i]',
    '[id^="ad_"]',
    '[id^="ad-"]',
    '[id*="-ad-" i]',
    '[id*="google_ads" i]',
    '[class^="ad_"]',
    '[class^="ad-"]',
    '[class*=" ad-" i]',
    '[class*="-ad-" i]',
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
      const text = parsed.href.toLowerCase();
      return blockedHosts.some((suffix) => host === suffix || host.endsWith(`.${suffix}`)) ||
        blockedUrlFragments.some((fragment) => text.includes(fragment));
    } catch (_) {
      const text = String(value).toLowerCase();
      return blockedHosts.some((suffix) => text.includes(suffix)) ||
        blockedUrlFragments.some((fragment) => text.includes(fragment));
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

  const blockNode = (node) => {
    const tagName = (node.tagName || '').toUpperCase();
    if (tagName === 'SCRIPT' || tagName === 'IFRAME' || tagName === 'LINK') {
      node.remove();
      return;
    }
    hideNode(node);
  };

  const removeAds = () => {
    for (const selector of cosmeticSelectors) {
      for (const node of document.querySelectorAll(selector)) {
        hideNode(node);
      }
    }
    for (const node of document.querySelectorAll('iframe[src], img[src], script[src], link[href], a[href]')) {
      const source = node.getAttribute('src') || node.getAttribute('href') || '';
      if (shouldBlock(source)) {
        blockNode(node);
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

  final List<_BrowserTabState> _tabs = <_BrowserTabState>[];
  int _activeTabIndex = 0;
  int _nextTabId = 1;
  bool _adBlockEnabled = true;

  bool get _usesWindowsWebView => Platform.isWindows;
  _BrowserTabState get _activeTab => _tabs[_activeTabIndex];
  TextEditingController get _addressController => _activeTab.addressController;
  String get _currentUrl => _activeTab.currentUrl;
  String get _pageTitle => _activeTab.pageTitle;
  bool get _loading => _activeTab.loading;
  int get _progress => _activeTab.progress;
  bool get _canGoBack => _activeTab.canGoBack;
  bool get _canGoForward => _activeTab.canGoForward;
  bool get _canUseCurrentUrl => _isHttpUrl(_currentUrl);

  @override
  void initState() {
    super.initState();
    final initialUrl =
        _normalizeInputToUrl(widget.initialUrl) ?? _quickLinks[0];
    _createTab(initialUrl);
  }

  _BrowserTabState _createTab(String initialUrl) {
    final tab = _BrowserTabState(
      id: _nextTabId++,
      initialUrl: initialUrl,
      defaultTitle: _defaultTitle,
    );
    _tabs.add(tab);

    if (_usesWindowsWebView) {
      unawaited(_initializeWindowsWebview(tab, initialUrl));
    } else {
      _initializeMobileWebview(tab, initialUrl);
    }
    return tab;
  }

  void _initializeMobileWebview(_BrowserTabState tab, String initialUrl) {
    final controller = mobile_webview.WebViewController()
      ..setJavaScriptMode(mobile_webview.JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        mobile_webview.NavigationDelegate(
          onNavigationRequest: (request) {
            if (_adBlockEnabled && _shouldBlockUrl(request.url)) {
              _showSnackBar('広告またはトラッカーへの移動をブロックしました');
              return mobile_webview.NavigationDecision.prevent;
            }
            _setCurrentUrl(request.url, tab: tab);
            return mobile_webview.NavigationDecision.navigate;
          },
          onPageStarted: (url) {
            _setCurrentUrl(url, tab: tab);
            _scheduleMobileAdBlock(tab);
            if (!mounted) {
              return;
            }
            setState(() {
              tab.loading = true;
              tab.progress = 0;
            });
          },
          onPageFinished: (url) async {
            _setCurrentUrl(url, tab: tab);
            await _applyMobileAdBlockIfNeeded(tab);
            await _refreshMobileNavigationState(tab);
            if (!mounted) {
              return;
            }
            setState(() {
              tab.loading = false;
              tab.progress = 100;
            });
          },
          onProgress: (progress) {
            if (!mounted) {
              return;
            }
            setState(() {
              tab.progress = progress;
            });
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url == null) {
              return;
            }
            if (!mounted) {
              _setCurrentUrl(url, tab: tab);
              return;
            }
            setState(() {
              _setCurrentUrl(url, tab: tab);
            });
          },
          onWebResourceError: (error) {
            if (!mounted) {
              return;
            }
            setState(() {
              tab.loading = false;
            });
            _showSnackBar('ページを開けませんでした: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(initialUrl));
    tab.mobileController = controller;
    _scheduleMobileAdBlock(tab);
  }

  Future<void> _initializeWindowsWebview(
    _BrowserTabState tab,
    String initialUrl,
  ) async {
    final String? version;
    try {
      version = await windows_webview.WebviewController.getWebViewVersion();
    } on MissingPluginException {
      if (!mounted) {
        return;
      }
      setState(() {
        tab.loading = false;
        tab.windowsUnavailableReason =
            'Windows 用の内蔵ブラウザプラグインがまだ読み込まれていません。'
            '\nプラグイン追加後はホットリロードではなく、アプリを完全終了して再起動してください。';
      });
      return;
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        tab.loading = false;
        final message = error.message?.trim();
        tab.windowsUnavailableReason = message == null || message.isEmpty
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
        tab.loading = false;
        tab.windowsUnavailableReason =
            'Windows では Microsoft Edge WebView2 Runtime が必要です。'
            '\nWebView2 をインストールしてからもう一度お試しください。';
      });
      return;
    }

    final controller = windows_webview.WebviewController();
    tab.windowsController = controller;

    try {
      await controller.initialize();
      await controller.setBackgroundColor(Colors.transparent);
      await controller.setPopupWindowPolicy(
        windows_webview.WebviewPopupWindowPolicy.sameWindow,
      );
      await _syncWindowsAdBlockScript(tab, force: true);

      tab.windowsSubscriptions.add(
        controller.url.listen((url) {
          if (!mounted) {
            _setCurrentUrl(url, tab: tab);
            return;
          }
          setState(() {
            _setCurrentUrl(url, tab: tab);
          });
        }),
      );
      tab.windowsSubscriptions.add(
        controller.title.listen((title) {
          if (!mounted) {
            return;
          }
          setState(() {
            tab.pageTitle = title.trim().isEmpty ? _defaultTitle : title.trim();
          });
        }),
      );
      tab.windowsSubscriptions.add(
        controller.loadingState.listen((state) {
          if (!mounted) {
            return;
          }
          setState(() {
            tab.loading = state == windows_webview.LoadingState.loading;
            if (tab.loading) {
              tab.progress = 0;
            } else {
              tab.progress = 100;
              unawaited(_syncWindowsAdBlockScript(tab));
            }
          });
        }),
      );
      tab.windowsSubscriptions.add(
        controller.historyChanged.listen((history) {
          if (!mounted) {
            return;
          }
          setState(() {
            tab.canGoBack = history.canGoBack;
            tab.canGoForward = history.canGoForward;
          });
        }),
      );
      tab.windowsSubscriptions.add(
        controller.onLoadError.listen((status) {
          if (!mounted) {
            return;
          }
          setState(() {
            tab.loading = false;
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
        tab.loading = false;
        tab.windowsUnavailableReason =
            'Windows 用の内蔵ブラウザプラグインがまだ読み込まれていません。'
            '\nアプリを完全終了して再起動すると解消することがあります。';
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        tab.loading = false;
        final message = error.message?.trim();
        tab.windowsUnavailableReason = message == null || message.isEmpty
            ? '内蔵ブラウザの初期化に失敗しました: ${error.code}'
            : '内蔵ブラウザの初期化に失敗しました: $message';
      });
    }
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.dispose();
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
    return _blockedHostSuffixes.any(lowered.contains) ||
        _blockedUrlFragments.any(lowered.contains);
  }

  void _scheduleMobileAdBlock(_BrowserTabState tab) {
    if (_adBlockEnabled) {
      unawaited(_runScheduledMobileAdBlock(tab));
    }
  }

  Future<void> _runScheduledMobileAdBlock(_BrowserTabState tab) async {
    const delays = <Duration>[
      Duration(milliseconds: 150),
      Duration(milliseconds: 500),
      Duration(milliseconds: 1100),
    ];
    for (final delay in delays) {
      await Future<void>.delayed(delay);
      if (!mounted || !_adBlockEnabled || tab.mobileController == null) {
        return;
      }
      await _applyMobileAdBlockIfNeeded(tab);
    }
  }

  Future<void> _applyMobileAdBlockIfNeeded(_BrowserTabState tab) async {
    if (!_adBlockEnabled) {
      return;
    }
    final controller = tab.mobileController;
    if (controller == null) {
      return;
    }
    try {
      await controller.runJavaScript(_adBlockScript);
    } on PlatformException {
      // Ignore adblock injection failures and keep browsing usable.
    }
  }

  Future<void> _syncWindowsAdBlockScript(
    _BrowserTabState tab, {
    bool force = false,
  }) async {
    final controller = tab.windowsController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (_adBlockEnabled) {
      if (tab.windowsAdBlockScriptId == null || force) {
        if (tab.windowsAdBlockScriptId != null) {
          try {
            await controller.removeScriptToExecuteOnDocumentCreated(
              tab.windowsAdBlockScriptId!,
            );
          } on PlatformException {
            // Ignore cleanup failure and overwrite with a fresh registration.
          }
        }
        tab.windowsAdBlockScriptId = await controller
            .addScriptToExecuteOnDocumentCreated(_adBlockScript);
      }
      try {
        await controller.executeScript(_adBlockScript);
      } on PlatformException {
        // Ignore injection failure for the current page.
      }
      return;
    }

    final scriptId = tab.windowsAdBlockScriptId;
    tab.windowsAdBlockScriptId = null;
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
      for (final tab in _tabs) {
        await _syncWindowsAdBlockScript(tab, force: true);
      }
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

  void _setCurrentUrl(String url, {_BrowserTabState? tab}) {
    if (!_isHttpUrl(url)) {
      return;
    }
    final target = tab ?? _activeTab;
    target.currentUrl = url;
    if (target.addressController.text.trim() != url.trim()) {
      target.addressController.value = TextEditingValue(
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
    final tab = _activeTab;
    setState(() {
      _setCurrentUrl(normalized, tab: tab);
      tab.loading = true;
      tab.progress = 0;
    });

    if (_usesWindowsWebView) {
      final controller = tab.windowsController;
      if (controller == null || !controller.value.isInitialized) {
        _showSnackBar('内蔵ブラウザを初期化中です');
        return;
      }
      await controller.loadUrl(normalized);
      return;
    }

    final controller = tab.mobileController;
    if (controller == null) {
      _showSnackBar('内蔵ブラウザを初期化中です');
      return;
    }
    await controller.loadRequest(Uri.parse(normalized));
  }

  Future<void> _refreshMobileNavigationState(_BrowserTabState tab) async {
    final controller = tab.mobileController;
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
      tab.pageTitle = title?.trim().isNotEmpty == true
          ? title!.trim()
          : _defaultTitle;
      if (currentUrl != null && currentUrl.trim().isNotEmpty) {
        _setCurrentUrl(currentUrl, tab: tab);
      }
      tab.canGoBack = canGoBack;
      tab.canGoForward = canGoForward;
    });
  }

  Future<void> _goBack() async {
    if (!_canGoBack) {
      return;
    }
    final tab = _activeTab;
    if (_usesWindowsWebView) {
      final controller = tab.windowsController;
      if (controller == null || !controller.value.isInitialized) {
        return;
      }
      await controller.goBack();
      return;
    }
    final controller = tab.mobileController;
    if (controller == null) {
      return;
    }
    await controller.goBack();
    await _refreshMobileNavigationState(tab);
  }

  Future<void> _goForward() async {
    if (!_canGoForward) {
      return;
    }
    final tab = _activeTab;
    if (_usesWindowsWebView) {
      final controller = tab.windowsController;
      if (controller == null || !controller.value.isInitialized) {
        return;
      }
      await controller.goForward();
      return;
    }
    final controller = tab.mobileController;
    if (controller == null) {
      return;
    }
    await controller.goForward();
    await _refreshMobileNavigationState(tab);
  }

  Future<void> _reload() async {
    final tab = _activeTab;
    if (_usesWindowsWebView) {
      final controller = tab.windowsController;
      if (controller == null || !controller.value.isInitialized) {
        return;
      }
      setState(() {
        tab.loading = true;
        tab.progress = 0;
      });
      await controller.reload();
      return;
    }
    final controller = tab.mobileController;
    if (controller == null) {
      return;
    }
    setState(() {
      tab.loading = true;
      tab.progress = 0;
    });
    await controller.reload();
    await _refreshMobileNavigationState(tab);
  }

  void _openNewTab() {
    final tab = _createTab(_quickLinks[0]);
    setState(() {
      _activeTabIndex = _tabs.indexOf(tab);
    });
  }

  void _selectTab(int index) {
    if (index == _activeTabIndex || index < 0 || index >= _tabs.length) {
      return;
    }
    setState(() {
      _activeTabIndex = index;
    });
  }

  void _closeTab(int index) {
    if (_tabs.length <= 1 || index < 0 || index >= _tabs.length) {
      return;
    }
    final removed = _tabs[index];
    setState(() {
      _tabs.removeAt(index);
      if (_activeTabIndex >= _tabs.length) {
        _activeTabIndex = _tabs.length - 1;
      } else if (index < _activeTabIndex) {
        _activeTabIndex -= 1;
      }
    });
    removed.dispose();
  }

  String _tabLabel(_BrowserTabState tab) {
    final title = tab.pageTitle.trim();
    if (title.isNotEmpty && title != _defaultTitle) {
      return title;
    }
    final host = Uri.tryParse(tab.currentUrl)?.host.trim();
    if (host != null && host.isNotEmpty) {
      return host;
    }
    return '新しいタブ';
  }

  Widget _buildTabStrip() {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemBuilder: (context, index) {
                final tab = _tabs[index];
                final selected = index == _activeTabIndex;
                return InputChip(
                  selected: selected,
                  showCheckmark: false,
                  avatar: Icon(
                    selected ? Icons.radio_button_checked : Icons.public,
                    size: 18,
                  ),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      _tabLabel(tab),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onPressed: () => _selectTab(index),
                  onDeleted: _tabs.length > 1 ? () => _closeTab(index) : null,
                  deleteIcon: const Icon(Icons.close, size: 18),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                );
              },
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemCount: _tabs.length,
            ),
          ),
          IconButton(
            onPressed: _openNewTab,
            icon: const Icon(Icons.add),
            tooltip: '新しいタブ',
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildBrowserSurface() {
    final tab = _activeTab;
    if (_usesWindowsWebView) {
      if (tab.windowsUnavailableReason != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              tab.windowsUnavailableReason!,
              textAlign: TextAlign.center,
            ),
          ),
        );
      }

      final controller = tab.windowsController;
      if (controller == null || !controller.value.isInitialized) {
        return const Center(child: CircularProgressIndicator());
      }

      return KeyedSubtree(
        key: ValueKey<int>(tab.id),
        child: Stack(
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
        ),
      );
    }

    final controller = tab.mobileController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return KeyedSubtree(
      key: ValueKey<int>(tab.id),
      child: Stack(
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
      ),
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
            _buildTabStrip(),
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

class _BrowserTabState {
  final int id;
  final TextEditingController addressController;
  final List<StreamSubscription<dynamic>> windowsSubscriptions =
      <StreamSubscription<dynamic>>[];

  mobile_webview.WebViewController? mobileController;
  windows_webview.WebviewController? windowsController;
  String? windowsAdBlockScriptId;

  String currentUrl;
  String pageTitle;
  String? windowsUnavailableReason;
  bool loading = true;
  int progress = 0;
  bool canGoBack = false;
  bool canGoForward = false;

  _BrowserTabState({
    required this.id,
    required String initialUrl,
    required String defaultTitle,
  }) : currentUrl = initialUrl,
       pageTitle = defaultTitle,
       addressController = TextEditingController(text: initialUrl);

  void dispose() {
    addressController.dispose();
    for (final subscription in windowsSubscriptions) {
      unawaited(subscription.cancel());
    }
    final controller = windowsController;
    if (controller != null) {
      unawaited(controller.dispose());
    }
  }
}
