// Real glass, not the solid-color cards in dock_stack_test.dart: transformed
// and faded cards must not share backdrop inputs or resample while moving.
import 'package:dsh_app/ui/chat/dock/dock_pill.dart';
import 'package:dsh_app/ui/chat/dock/dock_stack.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

class _GlassCard extends StatefulWidget {
  const _GlassCard(this.label);

  final String label;
  static final mounts = <String, int>{};

  @override
  State<_GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<_GlassCard> {
  @override
  void initState() {
    super.initState();
    _GlassCard.mounts.update(widget.label, (count) => count + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DockMetrics.gap),
    child: GlassSurface(
      key: ValueKey('glass-${widget.label}'),
      tier: GlassTier.chrome,
      stadium: true,
      grouped: true,
      child: SizedBox(
        height: DockMetrics.height,
        child: Center(child: Text(widget.label)),
      ),
    ),
  );
}

Widget _deck({
  Brightness brightness = Brightness.light,
  bool noBlur = false,
  List<Widget> contents = const [_GlassCard('todo'), _GlassCard('goal'), _GlassCard('strip')],
}) {
  Widget cards = BackdropGroup(
    child: DockStack(cards: contents),
  );
  if (noBlur) cards = GlassOverNativeView(child: cards);
  return testApp(
    Scaffold(
      body: AppBackdrop(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 80), child: cards),
        ),
      ),
    ),
    brightness: brightness,
  );
}

Finder _blur(String label) => find.descendant(
  of: find.byKey(ValueKey('glass-$label')),
  matching: find.byType(BackdropFilter),
);

void _expectSampling(WidgetTester tester, bool enabled) {
  for (final label in ['todo', 'goal', 'strip']) {
    expect(tester.widget<BackdropFilter>(_blur(label)).enabled, enabled, reason: label);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _GlassCard.mounts.clear();
  });

  testWidgets('opacity-layer cards use independent backdrop inputs and replace blending', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck());
    await tester.pumpAndSettle();
    final keys = <BackdropKey>[];
    for (final label in ['todo', 'goal', 'strip']) {
      final render = tester.renderObject<RenderBackdropFilter>(_blur(label));
      if (render.backdropKey case final key?) keys.add(key);
      expect(render.blendMode, BlendMode.src, reason: label);
    }
    expect(keys.toSet().length, keys.length, reason: 'overlapping opacity layers cannot share a backdrop key');
    _expectSampling(tester, true);
  });

  for (final brightness in Brightness.values) {
    testWidgets('slow drag and held pauses stay opaque, then restore glass ($brightness)', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(_deck(brightness: brightness));
      await tester.pumpAndSettle();
      _expectSampling(tester, true);
      final finger = await tester.startGesture(tester.getCenter(find.text('strip')));
      await finger.moveBy(const Offset(0, 24));
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await finger.moveBy(const Offset(0, 1));
        await tester.pump(const Duration(milliseconds: 90));
        _expectSampling(tester, false);
      }
      await tester.pump(const Duration(milliseconds: 800));
      _expectSampling(tester, false);
      await finger.up();
      await tester.pumpAndSettle();
      _expectSampling(tester, true);
      expect(_GlassCard.mounts, {'todo': 1, 'goal': 1, 'strip': 1});
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancelled drag returns to the original card and resumes sampling', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck());
    await tester.pumpAndSettle();
    final original = tester.getRect(find.byKey(const ValueKey('glass-strip'))).top;
    final finger = await tester.startGesture(tester.getCenter(find.text('strip')));
    await finger.moveBy(const Offset(0, 30));
    await tester.pump();
    await finger.moveBy(const Offset(0, 5));
    await tester.pump();
    _expectSampling(tester, false);
    await finger.cancel();
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('glass-strip'))).top, moreOrLessEquals(original));
    _expectSampling(tester, true);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('folding and rapid successive turns preserve all mounted card content', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck());
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(DockStack), Offset(0, i.isEven ? 60 : -60));
      await tester.pump(const Duration(milliseconds: 30));
      _expectSampling(tester, false);
    }
    await tester.pumpAndSettle();
    _expectSampling(tester, true);
    await tester.tap(find.byType(DockStack));
    await tester.pump(const Duration(milliseconds: 30));
    _expectSampling(tester, false);
    await tester.pumpAndSettle();
    _expectSampling(tester, true);
    await tester.tap(find.byKey(const ValueKey('dock-fold')));
    await tester.pump(const Duration(milliseconds: 30));
    _expectSampling(tester, false);
    await tester.pumpAndSettle();
    _expectSampling(tester, true);
    expect(_GlassCard.mounts, {'todo': 1, 'goal': 1, 'strip': 1});
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced transparency still composites the deck opacity layers', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck(noBlur: true));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    final render = tester.allRenderObjects.whereType<RenderDockStack>().toSet().single;
    expect(render.needsCompositing, isTrue);
    await tester.drag(find.byType(DockStack), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap cancelling the drag recognizer preserves the last completed turn', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(DockStack), const Offset(0, 60));
    await tester.pumpAndSettle();
    final render = tester.allRenderObjects.whereType<RenderDockStack>().toSet().single;
    final turn = render.turn;
    expect(turn, 1);
    await tester.tap(find.byType(DockStack));
    await tester.pumpAndSettle();
    expect(render.turn, turn);
    await tester.tap(find.byKey(const ValueKey('dock-fold')));
    await tester.pumpAndSettle();
    expect(render.turn, turn);
    expect(tester.takeException(), isNull);
  });

  for (final remaining in [1, 2]) {
    testWidgets('card-count change during a drag resets cancellation and restores glass ($remaining)', (tester) async {
      usePhoneView(tester);
      final all = ValueNotifier(true);
      addTearDown(all.dispose);
      await tester.pumpWidget(_deck(contents: [
        ValueListenableBuilder<bool>(
          valueListenable: all,
          builder: (context, on, _) => on || remaining == 2
              ? const _GlassCard('todo')
              : const SizedBox(width: double.infinity),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: all,
          builder: (context, on, _) => on ? const _GlassCard('goal') : const SizedBox(width: double.infinity),
        ),
        const _GlassCard('strip'),
      ]));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(DockStack), const Offset(0, 60));
      await tester.pumpAndSettle();
      final render = tester.allRenderObjects.whereType<RenderDockStack>().toSet().single;
      expect(render.turn, 1);
      final finger = await tester.startGesture(tester.getCenter(find.byType(DockStack)));
      await finger.moveBy(const Offset(0, 24));
      await tester.pump();
      await finger.moveBy(const Offset(0, 6));
      await tester.pump();
      _expectSampling(tester, false);
      all.value = false;
      await tester.pump();
      await tester.pump();
      await finger.cancel();
      await tester.pumpAndSettle();
      expect(render.turn, 0, reason: 'new cards use the reset starting point');
      expect(tester.widget<BackdropFilter>(_blur('strip')).enabled, isTrue);
      all.value = true;
      await tester.pumpAndSettle();
      _expectSampling(tester, true);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a new held drag cancels clear-in even before its first tick', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(DockStack), const Offset(0, 40));
    await tester.pump();
    await tester.pump(AppMotion.standard);
    // The turn has finished and scheduled clear-in, whose value is still zero.
    final finger = await tester.startGesture(tester.getCenter(find.byType(DockStack)));
    await finger.moveBy(const Offset(0, 24));
    await tester.pump(AppMotion.glassIn);
    _expectSampling(tester, false);
    await finger.up();
    await tester.pumpAndSettle();
    _expectSampling(tester, true);
    expect(tester.takeException(), isNull);
  });
}
