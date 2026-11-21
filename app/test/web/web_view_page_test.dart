// Generic embedded page safe areas and keyboard layout.
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:dsh_app/ui/chat/render/mermaid_preview.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/web/web_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../chat/support/harness.dart';
import 'support/fake_webview.dart';

final _url = Uri.parse('http://127.0.0.1:3080/?token=t');

/// A window: logical size and system padding (status bar, gesture bar, cutout).
typedef _Window = ({Size size, EdgeInsets padding});

/// Pixel 7 emulator (dpr 2.625), punch-hole on the left in landscape.
const _phonePortrait = (size: Size(411.4, 914.3), padding: EdgeInsets.fromLTRB(0, 52, 0, 24));
const _phoneLandscape = (size: Size(914.3, 411.4), padding: EdgeInsets.fromLTRB(52, 28, 0, 24));

void _useWindow(WidgetTester tester, _Window w) {
  const dpr = 2.0;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = w.size * dpr;
  final p = FakeViewPadding(
    left: w.padding.left * dpr,
    top: w.padding.top * dpr,
    right: w.padding.right * dpr,
    bottom: w.padding.bottom * dpr,
  );
  tester.view.padding = p;
  tester.view.viewPadding = p;
  addTearDown(tester.view.reset);
}

/// The cutout's inset, on both sides in landscape.
const _side = 52.0;

Finder _button(String tooltip) => find.byWidgetPredicate(
  (w) => w is GlassIconButton && w.tooltip == tooltip,
  description: 'GlassIconButton($tooltip)',
);

late FakeWebViewPlatform _platform;

Future<void> _pump(WidgetTester tester, _Window window, {Brightness brightness = Brightness.light}) async {
  _useWindow(tester, window);
  await tester.pumpWidget(
    testApp(
      WebViewPage(url: _url, title: '远程控制台', subtitle: 'dsh.r2049.cn', allowOpenExternal: true),
      brightness: brightness,
    ),
  );
  // The WebView loads once it is set up and guarded.
  for (var i = 0; i < 20 && _platform.controller.loads.isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  _platform.controller.finish();
  await tester.pump();
}

void main() {
  setUp(() => WebViewPlatform.instance = _platform = FakeWebViewPlatform());

  test('content clears the toolbar and bottom gesture area', () {
    final normal = WebPageInsets.resolve(padding: const EdgeInsets.only(top: 24, bottom: 32), keyboard: 0);
    expect(normal.rootTop, 100);
    expect(normal.rootBottom, 32);
    final keyboard = WebPageInsets.resolve(padding: EdgeInsets.zero, keyboard: 300);
    expect(keyboard.rootBottom, 0);
    expect(normal.script, contains('padding-top:100.0px'));
  });

  group('the keyboard', () {
    setUp(WebKeyboard.forgetHeights);

    test('the page moves once per slide: at rest, or up front when the end is known', () {
      final k = WebKeyboard();
      // The first time: the page stays until the keyboard comes to rest.
      for (final h in <double>[12, 80, 190, 260]) {
        expect(k.report(h, 411), isFalse);
        expect(k.height, 0);
      }
      expect(k.settle(260, 411), isTrue);
      expect(k.height, 260);
      // Closing: down at once, and nothing more on the way.
      expect(k.report(250, 411), isTrue);
      expect(k.height, 0);
      expect(k.report(90, 411), isFalse);
      expect(k.settle(0, 411), isFalse);
      // Opening again in a window this wide: straight to where it ends.
      expect(k.report(10, 411), isTrue);
      expect(k.height, 260);
      expect(k.report(150, 411), isFalse);
      // A different height at rest still wins.
      expect(k.settle(280, 411), isTrue);
      expect(k.height, 280);
      // Another width (the phone on its side) is learnt anew.
      k
        ..report(0, 411)
        ..settle(0, 411);
      expect(k.report(40, 914), isFalse);
      expect(k.height, 0);
    });

    test('the heights outlive the run', () async {
      SharedPreferences.setMockInitialValues({WebKeyboard.prefsKey: '{"411": 300.0, "x": 1}'});
      WebKeyboard.forgetHeights(restore: true);
      await WebKeyboard.restore();
      // A cold start's first keyboard goes straight to where it ends.
      final k = WebKeyboard();
      expect(k.report(10, 411), isTrue);
      expect(k.height, 300);
      k.settle(320, 411);
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(WebKeyboard.prefsKey)!), {'411': 320.0});
    });

    testWidgets('other sites shrink above the keyboard once, not on every frame', (tester) async {
      await _pump(tester, _phonePortrait);
      final heights = <double>{};
      for (final h in <double>[20, 120, 240, 320]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * 2.0);
        await tester.pump(const Duration(milliseconds: 16));
        heights.add(tester.getRect(find.byKey(fakeWebViewKey)).height);
      }
      expect(heights, {_phonePortrait.size.height});
      await tester.pump(WebKeyboard.rest);
      await tester.pump();
      expect(tester.getRect(find.byKey(fakeWebViewKey)).bottom, _phonePortrait.size.height - 320);
      tester.view.resetViewInsets();
    });
  });

  testWidgets('chart preview keeps its header and chart out of a side cutout', (tester) async {
    _useWindow(tester, _phoneLandscape);
    await tester.pumpWidget(testApp(const MermaidPreviewPage(source: 'graph LR; A-->B')));
    final back = tester.getRect(_button('返回'));
    final copy = tester.getRect(_button('复制代码'));
    expect(back.left, _side + 12);
    expect(_phoneLandscape.size.width - copy.right, _side + 12);
    expect(back.center.dy, copy.center.dy);
    final chart = tester.getRect(find.byKey(fakeWebViewKey));
    expect(chart.left, _side);
    expect(chart.right, _phoneLandscape.size.width - _side);
    expect(chart.bottom, _phoneLandscape.size.height - 24);
  });
}
