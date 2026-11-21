import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../common/empty_view.dart';
import '../common/expand_reveal.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'web_back.dart';
import 'web_file_chooser.dart';
import 'web_view_guard.dart';

/// Full-bleed browser surface shared by companion, terminal and media pages.
class WebViewPage extends StatefulWidget {
  const WebViewPage({
    super.key,
    required this.url,
    required this.title,
    this.subtitle,
    this.allowOpenExternal = false,
    this.externalDisabledReason,
    this.reloadAfterBackground,
    this.lightBackground = const Color(0xFFFFFFFF),
    this.darkBackground = const Color(0xFF151517),
  });

  final Uri url;
  final String title;
  final String? subtitle;
  final bool allowOpenExternal;
  final String? externalDisabledReason;
  final Duration? reloadAfterBackground;
  final Color lightBackground;
  final Color darkBackground;

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

abstract final class WebChromeMetrics {
  static const barHeight = 52.0;
  static const edge = 12.0;
  static const gestureFloor = 12.0;
}

/// Safe vertical content bounds; the WebView itself handles the safe sides
/// and shrinks above the keyboard.
@immutable
class WebPageInsets {
  const WebPageInsets({required this.rootTop, required this.rootBottom});

  factory WebPageInsets.resolve({required EdgeInsets padding, required double keyboard}) => WebPageInsets(
    rootTop: padding.top + WebChromeMetrics.barHeight + 24,
    rootBottom: keyboard > 0 ? 0 : math.max(padding.bottom, WebChromeMetrics.gestureFloor),
  );

  final double rootTop;
  final double rootBottom;

  String get script =>
      """
(function () {
  if (!document.documentElement) return;
  var s = document.getElementById('dsh-app-insets');
  if (!s) {
    s = document.createElement('style'); s.id = 'dsh-app-insets'; document.head.appendChild(s);
  }
  var css = document.getElementById('root')
    ? '#root{position:fixed!important;top:${rootTop.toStringAsFixed(1)}px!important;bottom:${rootBottom.toStringAsFixed(1)}px!important;left:0!important;right:0!important;height:auto!important;min-height:0!important;margin:0!important}html,body{overflow:hidden!important;overscroll-behavior:none!important}'
    : 'body{padding-top:${rootTop.toStringAsFixed(1)}px!important;padding-bottom:${rootBottom.toStringAsFixed(1)}px!important;box-sizing:border-box}';
  if (s.textContent !== css) s.textContent = css;
})();
""";

  @override
  bool operator ==(Object other) =>
      other is WebPageInsets && other.rootTop == rootTop && other.rootBottom == rootBottom;

  @override
  int get hashCode => Object.hash(rootTop, rootBottom);
}

/// The keyboard height a page is laid out for.
///
/// Flutter reports the keyboard's height on every frame of its slide. Laying
/// a web page out again on each of them (and, for a WebView that shrinks,
/// resizing the platform view and its texture) is what made opening and
/// closing the keyboard stutter. The page moves once per slide instead, as in
/// a browser: right away when the slide's end is known — a keyboard opening
/// to the height it had last time in a window this wide, or one closing —
/// else once the reports stop ([settle], [rest] after the last one). The
/// heights outlive the app's process ([restore]), so a cold start's first
/// keyboard is known up front too.
class WebKeyboard {
  /// Quiet time after which the keyboard counts as at rest.
  static const rest = Duration(milliseconds: 100);

  /// The last height an open keyboard came to rest at, per window width
  /// (shared by every page: it is the phone's keyboard).
  static final _open = <int, double>{};

  /// Where [_open] is kept between runs.
  static const prefsKey = 'web.keyboard';

  static Future<void>? _restored;

  /// Reads the heights of earlier runs, once per run; heights seen since win.
  static Future<void> restore() => _restored ??= () async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonDecode(prefs.getString(prefsKey) ?? '{}');
      if (json is! Map) return;
      for (final MapEntry(:key, :value) in json.entries) {
        final width = int.tryParse('$key');
        if (width != null && value is num && value > 0) _open.putIfAbsent(width, value.toDouble);
      }
    } catch (_) {
      // No storage (tests, a broken store): learnt again this run.
    }
  }();

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode({for (final e in _open.entries) '${e.key}': e.value}));
    } catch (_) {}
  }

  /// Forgets every height; with [restore], the next [restore] reads the
  /// stored ones again.
  @visibleForTesting
  static void forgetHeights({bool restore = false}) {
    _open.clear();
    _restored = restore ? null : Future<void>.value();
  }

  /// What the page is laid out for.
  double get height => _height;
  double _height = 0;

  /// The height last seen at rest.
  double _rest = 0;

  /// The keyboard reports [raw] in a window [width] wide. True when [height]
  /// changed.
  bool report(double raw, double width) {
    final before = _height;
    if (raw == _rest) {
      _height = raw;
    } else if (raw > _rest) {
      // Opening (or growing): where it ends is known from last time.
      final known = _rest == 0 ? _open[width.round()] : null;
      if (known != null) _height = known;
    } else {
      // Closing: the page goes back down at once, under the keyboard.
      _height = 0;
    }
    return _height != before;
  }

  /// The reports stopped at [raw]. True when [height] changed.
  bool settle(double raw, double width) {
    final before = _height;
    _rest = _height = raw;
    if (raw > 0 && _open[width.round()] != raw) {
      _open[width.round()] = raw;
      unawaited(_save());
    }
    return _height != before;
  }
}

class _WebViewPageState extends State<WebViewPage> {
  late WebViewController _controller;
  late final AppLifecycleListener _lifecycle;
  late final WebViewGuard _guard = WebViewGuard(onGone: _onRendererGone);
  final _files = WebFileChooser();
  int _progress = 0;
  bool _loading = true;
  String? _error;
  DateTime? _hiddenAt;
  Brightness? _bgFor;
  WebPageInsets? _insets;
  WebPageInsets? _appliedInsets;

  /// The keyboard the page is laid out for ([WebKeyboard]).
  final _keyboard = WebKeyboard();
  double _keyboardRaw = 0;
  Timer? _keyboardRest;

  /// The renderer died (crash, or killed in the background): the WebView is
  /// unusable and the page says so until it is reopened.
  bool _gone = false;

  /// Each reopen is a new WebView (a new platform view).
  int _generation = 0;

  /// The app's look the WebView follows (set before the first frame).
  bool _dark = false;
  int _textZoom = 100;

  @override
  void initState() {
    super.initState();
    unawaited(WebKeyboard.restore());
    _open();
    _lifecycle = AppLifecycleListener(onHide: _onHide, onShow: _onShow);
  }

  /// A new WebView for [WebViewPage.url].
  void _open() {
    _files.invalidate();
    final controller = _controller = WebViewController();
    _loading = true;
    _progress = 0;
    _error = null;
    _appliedInsets = null;
    unawaited(_setUp(controller));
  }

  Future<void> _setUp(WebViewController controller) async {
    await Future.wait(
      [
        controller.setJavaScriptMode(JavaScriptMode.unrestricted),
        _files.attach(controller),
        controller.setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (_) {
              if (!mounted || _gone || controller != _controller) return;
              _files.invalidate();
              _set(() {
                _loading = true;
                _error = null;
              });
            },
            onProgress: (p) {
              if (!mounted || _gone || controller != _controller) return;
              _set(() => _progress = p);
            },
            onPageFinished: (_) {
              if (!mounted || _gone || controller != _controller) return;
              _set(() => _loading = false);
              _appliedInsets = null;
              _applyInsets();
            },
            onWebResourceError: (error) {
              if (!mounted || _gone || controller != _controller) return;
              if (kDebugMode) {
                // URLs and descriptions may contain the Host's token.
                debugPrint(
                  '[webview] resource: code=${error.errorCode} '
                  'type=${error.errorType?.name ?? 'unknown'} mainFrame=${error.isForMainFrame}',
                );
              }
              if (error.isForMainFrame ?? true) {
                _set(() {
                  _loading = false;
                  _error = error.description;
                });
              }
            },
          ),
        ),
      ].map((f) => f.catchError((_) {})),
    );
    if (!mounted || controller != _controller) return;
    // After the navigation delegate: the guard wraps the client it set.
    await _guard.attach(controller, dark: _dark, textZoom: _textZoom);
    if (!mounted || controller != _controller) return;
    await controller.loadRequest(widget.url).catchError((_) {});
  }

  void _onRendererGone(bool crashed) {
    if (_gone || !mounted) return;
    _files.invalidate();
    setState(() {
      _gone = true;
      _loading = false;
    });
    // The dead WebView leaves the tree this frame; then it is destroyed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_guard.destroy());
    });
  }

  /// Recreate a renderer that closed while the page was open.
  void _reopen() {
    setState(() {
      _gone = false;
      _generation++;
      _bgFor = null;
      _open();
    });
    _syncLook();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLook();
    _followKeyboard();
  }

  /// Hands the keyboard's height to [_keyboard] on every report; build lays
  /// the page out for [WebKeyboard.height].
  void _followKeyboard() {
    final raw = MediaQuery.viewInsetsOf(context).bottom;
    if (raw == _keyboardRaw) return;
    _keyboardRaw = raw;
    final width = MediaQuery.sizeOf(context).width;
    _keyboard.report(raw, width);
    _keyboardRest?.cancel();
    _keyboardRest = Timer(WebKeyboard.rest, () {
      if (mounted && _keyboard.settle(_keyboardRaw, width)) setState(() {});
    });
  }

  /// The page colour behind the page, its light or dark, its text size: the
  /// app's.
  void _syncLook() {
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    final zoom = MediaQuery.textScalerOf(context).scale(100).round().clamp(50, 300);
    if (_bgFor != brightness) {
      _bgFor = brightness;
      if (!_gone) {
        unawaited(_controller.setBackgroundColor(_background(brightness)).catchError((_) {}));
      }
    }
    if (dark != _dark) {
      _dark = dark;
      if (!_gone) unawaited(_guard.setDark(dark));
    }
    if (zoom != _textZoom) {
      _textZoom = zoom;
      if (!_gone) unawaited(_guard.setTextZoom(zoom));
    }
  }

  void _applyInsets() {
    final insets = _insets;
    if (_loading || _gone || insets == null || _appliedInsets == insets) {
      return;
    }
    _appliedInsets = insets;
    unawaited(_controller.runJavaScript(insets.script).catchError((_) {}));
  }

  Color _background(Brightness b) => b == Brightness.dark ? widget.darkBackground : widget.lightBackground;

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  void _onHide() => _hiddenAt = DateTime.now();

  Future<void> _onShow() async {
    final after = widget.reloadAfterBackground;
    final hidden = _hiddenAt;
    _hiddenAt = null;
    if (after == null || hidden == null || _gone || DateTime.now().difference(hidden) <= after) return;
    await _controller.reload();
  }

  @override
  void dispose() {
    _keyboardRest?.cancel();
    _files.dispose();
    _guard.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  late final _backs = WebBackDispatcher(
    canGoBack: () => _gone ? Future.value(false) : _controller.canGoBack(),
    goBack: () => _controller.goBack(),
    leave: _leave,
    isActive: () => mounted,
  );

  Future<void> _back() => _backs.press();

  Future<void> _leave() async {
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openExternal() async {
    final current = _gone ? null : await _controller.currentUrl();
    final uri = Uri.tryParse(current ?? '') ?? widget.url;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = _background(theme.brightness);
    final media = MediaQuery.of(context);
    final keyboard = _keyboard.height;
    final padding = media.padding.copyWith(bottom: media.viewPadding.bottom);
    final insets = WebPageInsets.resolve(padding: padding, keyboard: keyboard);
    final shrink = keyboard;
    if (insets != _insets) {
      _insets = insets;
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyInsets());
    }
    final fadeHeight = insets.rootTop;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: dshSystemOverlay(ThemeData.estimateBrightnessForColor(bg)),
        child: Scaffold(
          backgroundColor: bg,
          // The keyboard never resizes the page as it slides ([WebKeyboard]).
          resizeToAvoidBottomInset: false,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: EdgeInsets.only(left: padding.left, right: padding.right, bottom: shrink),
                // A dead WebView leaves the tree; a reopen is a new one.
                child: _gone
                    ? const SizedBox.expand()
                    : WebViewWidget(key: ValueKey(_generation), controller: _controller),
              ),
              // No divider: the page colour fades in behind the controls.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: fadeHeight,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: featherFade(
                        color: bg,
                        height: fadeHeight,
                        solidUntil: padding.top + WebChromeMetrics.barHeight / 2,
                      ),
                    ),
                  ),
                ),
              ),
              // Under the controls: the way back stays where it always is.
              if (_gone)
                Positioned.fill(
                  child: ColoredBox(
                    color: bg,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        padding.left,
                        padding.top + WebChromeMetrics.barHeight,
                        padding.right,
                        insets.rootBottom + shrink,
                      ),
                      child: RendererGone(label: context.l10n.webPageClosed, onReopen: _reopen),
                    ),
                  ),
                )
              else if (_error case final error?)
                Positioned.fill(
                  child: ColoredBox(
                    color: bg,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        padding.left,
                        padding.top + WebChromeMetrics.barHeight,
                        padding.right,
                        insets.rootBottom + shrink,
                      ),
                      child: _LoadError(detail: error, onRetry: () => unawaited(_controller.loadRequest(widget.url))),
                    ),
                  ),
                ),
              if (_loading)
                Positioned(
                  top: padding.top,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    value: _progress <= 0 ? null : _progress / 100,
                    minHeight: 2,
                    borderRadius: BorderRadius.zero,
                    backgroundColor: Colors.transparent,
                  ),
                ),
              _bar(context, padding),
            ],
          ),
        ),
      ),
    );
  }

  Widget _leading(double size) => GlassIconButton(
    icon: AppIcons.back,
    tooltip: context.l10n.commonBack,
    size: size,
    iconSize: math.min(22, size * 0.6),
    onPressed: _back,
  );

  Widget _bar(BuildContext context, EdgeInsets padding) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Positioned(
      key: const ValueKey('web-controls-bar'),
      left: 0,
      right: 0,
      top: padding.top,
      height: WebChromeMetrics.barHeight,
      child: GlassOverNativeView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            padding.left + WebChromeMetrics.edge,
            4,
            padding.right + WebChromeMetrics.edge,
            4,
          ),
          child: Row(
            children: [
              _leading(44),
              const SizedBox(width: 8),
              // The pill hugs its title; the actions keep to the far edge.
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: GlassSurface(
                    tier: GlassTier.chrome,
                    stadium: true,
                    grouped: true,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text.rich(
                      TextSpan(
                        text: widget.title,
                        style: theme.textTheme.titleSmall,
                        children: [
                          if (widget.subtitle case final sub?)
                            TextSpan(
                              text: ' · $sub',
                              style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: AppIcons.refresh,
                tooltip: context.l10n.webRefresh,
                onPressed: () => _gone ? _reopen() : unawaited(_controller.reload()),
              ),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: AppIcons.browser,
                tooltip: widget.allowOpenExternal
                    ? context.l10n.webOpenInBrowser
                    : (widget.externalDisabledReason ?? context.l10n.webBrowserUnavailable),
                onPressed: widget.allowOpenExternal ? () => unawaited(_openExternal()) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The renderer went away (crashed, or killed in the background): one quiet
/// line in place of the page — 「网页已关闭 · 重新打开」.
class RendererGone extends StatelessWidget {
  const RendererGone({super.key, required this.label, required this.onReopen});

  /// What closed: 网页已关闭, 图表已关闭.
  final String label;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary);
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: style),
          Text(' · ', style: style),
          // No side padding: the dot sits a space from either word.
          TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: theme.textTheme.bodyMedium,
            ),
            onPressed: onReopen,
            child: Text(context.l10n.webReopen),
          ),
        ],
      ),
    );
  }
}

/// The page didn't load: one line, one button, and the WebView's own
/// error text behind 「详情」.
class _LoadError extends StatefulWidget {
  const _LoadError({required this.detail, required this.onRetry});

  final String detail;
  final VoidCallback onRetry;

  @override
  State<_LoadError> createState() => _LoadErrorState();
}

class _LoadErrorState extends State<_LoadError> {
  bool _detail = false;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyView(
              icon: AppIcons.offline,
              title: context.l10n.webPageNotOpened,
              message: context.l10n.webCheckConnection,
              action: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
                onPressed: widget.onRetry,
                child: Text(context.l10n.commonRetry),
              ),
            ),
            if (widget.detail.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: colors.textTertiary),
                onPressed: () => setState(() => _detail = !_detail),
                child: Text(_detail ? context.l10n.commonCollapse : context.l10n.commonDetails),
              ),
              ExpandReveal(
                open: _detail,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: SelectableText(
                    widget.detail,
                    textAlign: TextAlign.center,
                    style: AppType.monoLabel(color: colors.textTertiary),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
