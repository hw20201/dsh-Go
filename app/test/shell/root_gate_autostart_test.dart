import 'dart:async';

import 'package:dsh_app/state/hosts_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/onboarding_flow.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safe_mode/support.dart';
import 'golden_harness.dart';

class _DelayedHost extends ActiveHostController {
  final restored = Completer<void>();

  @override
  HostRef build() => HostRef.local;

  @override
  Future<void> get ready => restored.future;

  void finish() {
    state = HostRef.direct('saved-host');
    restored.complete();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('saved host restores before the one-time onboarding decision', (tester) async {
    final host = _DelayedHost();
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RootGate(home: Scaffold(body: Text('saved remote home'))),
        brightness: Brightness.light,
        prefs: const OnboardingPrefs(loaded: true),
        overrides: [
          activeHostProvider.overrideWith(() => host),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          localRuntimeProvider.overrideWith(() => throw StateError('native runtime must not load')),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('saved remote home'), findsNothing);
    expect(find.byType(OnboardingFlow), findsNothing);
    host.finish();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('saved remote home'), findsOneWidget);
    expect(find.byType(OnboardingFlow), findsNothing);
  });
  test('legacy setup progress never resumes local install', () {
    for (final step in SetupStep.values) {
      final prefs = OnboardingPrefs(loaded: true, welcomeSeen: true, setupStep: step);
      expect(initialOnboardingStep(prefs: prefs), isNull, reason: '$step');
    }
  });

  testWidgets('local autostart preferences cannot start the removed runtime', (tester) async {
    final runtime = RecordingRuntime(
      const LocalRuntimeState(loaded: false, status: RuntimeStatus(phase: RuntimePhase.installing)),
    );
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RootGate(home: Scaffold(body: Text('remote home'))),
        brightness: Brightness.light,
        prefs: const OnboardingPrefs(loaded: true, welcomeSeen: true, localDeclined: true),
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          settingsProvider.overrideWith(
            () => FakeSettings(AppSettings(loaded: true, apiKey: 'key', autoStartLocal: true)),
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('remote home'), findsOneWidget);
    expect(runtime.starts, isEmpty);
  });

  test('first run enters welcome then remote/tavern choice only', () {
    expect(initialOnboardingStep(prefs: const OnboardingPrefs(loaded: true)), OnboardingStep.welcome);
    expect(initialOnboardingStep(prefs: const OnboardingPrefs(loaded: true, welcomeSeen: true)), OnboardingStep.choice);
  });
}
