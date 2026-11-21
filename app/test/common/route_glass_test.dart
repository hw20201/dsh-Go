// A route transition must not pay for glass: while a page slides in or out,
// its chrome samples nothing (opaque fallback), and the blur clears back in
// once the route settles, without rebuilding the content.
//
//   flutter test test/common/route_glass_test.dart

import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Counted extends StatefulWidget {
  const _Counted(this.inits);

  final List<int> inits;

  @override
  State<_Counted> createState() => _CountedState();
}

class _CountedState extends State<_Counted> {
  @override
  void initState() {
    super.initState();
    widget.inits.add(1);
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 120, child: Text('页面内容'));
}

/// The chrome glass on a page: one BackdropFilter, grouped like the chat header.
Widget _chromeGlass({required String label, required List<int> inits}) {
  return BackdropGroup(
    child: GlassSurface(
      key: ValueKey('glass-$label'),
      tier: GlassTier.chrome,
      stadium: true,
      grouped: true,
      child: _Counted(inits),
    ),
  );
}

bool _blurring(WidgetTester tester, String label) {
  final filter = find.descendant(of: find.byKey(ValueKey('glass-$label')), matching: find.byType(BackdropFilter));
  return tester.widget<BackdropFilter>(filter).enabled;
}

Color _fill(WidgetTester tester, String label) {
  final box = find.descendant(of: find.byKey(ValueKey('glass-$label')), matching: find.byType(DecoratedBox));
  final decoration = tester.widgetList<DecoratedBox>(box).first.decoration as ShapeDecoration;
  return decoration.color!;
}

GlassStyle _chromeStyle(WidgetTester tester, String label) =>
    DshSurfaces.of(tester.element(find.byKey(ValueKey('glass-$label')))).glass(GlassTier.chrome);

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              _chromeGlass(label: 'home', inits: _homeInits),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: _chromeGlass(label: 'second', inits: _secondInits),
                      ),
                    ),
                  );
                },
                child: const Text('去第二页'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _homeInits = <int>[];
final _secondInits = <int>[];

void main() {
  setUp(() {
    _homeInits.clear();
    _secondInits.clear();
  });

  testWidgets('push: no blur while the page slides in; at rest it clears back in', (tester) async {
    await _pumpApp(tester);
    expect(_blurring(tester, 'home'), isTrue);
    await tester.tap(find.text('去第二页'));
    await tester.pump(); // the tap is recognised here; the push starts
    await tester.pump(const Duration(milliseconds: 50));
    // Mid-push: the incoming page is built and its glass is opaque, not sampling.
    expect(find.byKey(const ValueKey('glass-second')), findsOneWidget);
    expect(_blurring(tester, 'second'), isFalse);
    expect(_fill(tester, 'second'), _chromeStyle(tester, 'second').fallbackFill);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_blurring(tester, 'second'), isFalse);
    await tester.pumpAndSettle();
    expect(_blurring(tester, 'second'), isTrue);
    expect(_fill(tester, 'second'), _chromeStyle(tester, 'second').fill);
    expect(_secondInits.length, 1, reason: 'the blur coming on does not rebuild the content');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('push: the page underneath does not blur while a page slides over it', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('去第二页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));
    // The page underneath is still in the tree while covered. Its grouped
    // filter leaves the tree while it is obscured, so the mid-push check is
    // the fill: it must be the opaque fallback, not the glass fill.
    expect(find.byKey(const ValueKey('glass-home')), findsOneWidget);
    expect(_fill(tester, 'home'), _chromeStyle(tester, 'home').fallbackFill);
    await tester.pumpAndSettle();
    // Once the page is fully covered its grouped filter leaves the tree, so
    // there is nothing left to sample; the "fades back when visible again"
    // half is asserted in the pop test below.
  });

  testWidgets('pop: the leaving page does not blur while it slides out', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('去第二页'));
    await tester.pumpAndSettle();
    expect(_blurring(tester, 'second'), isTrue);
    Navigator.of(tester.element(find.byKey(const ValueKey('glass-second')))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_blurring(tester, 'second'), isFalse);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('glass-second')), findsNothing);
    // Back on the home page: its glass has faded back to blur.
    expect(_blurring(tester, 'home'), isTrue);
    expect(_fill(tester, 'home'), _chromeStyle(tester, 'home').fill);
  });

  testWidgets('remove animations: glass from the first frame', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pumpApp(tester);
    await tester.tap(find.text('去第二页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_blurring(tester, 'second'), isTrue);
  });

  testWidgets('at rest the glass is the plain glass', (tester) async {
    await _pumpApp(tester);
    final glass = _chromeStyle(tester, 'home');
    expect(_fill(tester, 'home'), glass.fill);
  });
}
