// The remote-only root never installs managed skills into an on-device engine.
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('opening the root does not load runtime or resolve a local skills folder', (tester) async {
    var resolvedRoot = false;
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(
      home: const RootGate(home: Scaffold(body: Text('remote home'))),
      brightness: Brightness.light,
      prefs: const OnboardingPrefs(loaded: true, welcomeSeen: true, localDeclined: true),
      overrides: [
        localRuntimeProvider.overrideWith(() => throw StateError('must not load native runtime')),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        uiRootfsResolverProvider.overrideWithValue(() async {
          resolvedRoot = true;
          throw StateError('must not resolve on-device runtime');
        }),
      ],
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('remote home'), findsOneWidget);
    expect(resolvedRoot, isFalse);
  });
}
