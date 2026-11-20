// Remote-only onboarding preserves host selection, tavern and shared runtime contracts.

import 'dart:convert';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/local_footprint.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/app_mode_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/support.dart' show FakeBrowser, NoConnection;
import '../remote/support/fake_relay.dart';
import '../remote/support/fake_ssh.dart';
import '../shell/golden_harness.dart';
import 'local_optional_support.dart';

const _remote = ValueKey('runtime-option-remote');

Future<void> _frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('footprint', () {
    test('suggests the remote host on a small or full phone only', () {
      expect(roomyPhone.suggestRemote, isFalse);
      expect(smallPhone.lowMemory, isTrue);
      expect(smallPhone.suggestRemote, isTrue);
      expect(fullPhone.lowStorage, isTrue);
      expect(fullPhone.requiredStorageMb, 862);
      expect(fullPhone.requiredRoundedMb, 900);
      expect(const LocalFootprint().suggestRemote, isFalse);
      expect(LocalFootprint.round(749), 750);
    });
  });

  group('root gate', () {
    late MemorySecretStore secrets;
    late FakeSshServer server;

    setUp(() {
      secrets = MemorySecretStore();
      server = FakeSshServer();
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      });
    });

    List<Override> remote() => [
      secretStoreProvider.overrideWithValue(secrets),
      networkKicksProvider.overrideWithValue(const Stream.empty()),
      relayBackendProvider.overrideWithValue(FakeRelayBackend()),
      sshTransportFactoryProvider.overrideWithValue(server.connect),
      hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
    ];

    Future<(RecordingLocalRuntime, ProviderContainer)> pumpGate(
      WidgetTester tester, {
      RuntimeStatus status = missingStatus,
      OnboardingPrefs prefs = const OnboardingPrefs(loaded: true, welcomeSeen: true),
      AppSettings settings = const AppSettings(loaded: true),
    }) async {
      final runtime = RecordingLocalRuntime(LocalRuntimeState(loaded: true, status: status));
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const RootGate(home: Scaffold(body: Text('home'))),
          brightness: Brightness.light,
          prefs: prefs,
          overrides: [
            localRuntimeProvider.overrideWith(() => runtime),
            settingsProvider.overrideWith(() => FakeSettings(settings)),
            footprint(roomyPhone),
            ...remote(),
          ],
        ),
      );
      await _frames(tester);
      return (runtime, ProviderScope.containerOf(tester.element(find.byType(RootGate))));
    }

    Future<void> chooseRemote(WidgetTester tester) async {
      await tester.tap(find.byKey(_remote));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await _frames(tester);
    }

    testWidgets('远程主机 → pick a host → home, nothing installed', (tester) async {
      final (runtime, container) = await pumpGate(tester);
      expect(find.text('想怎么用 dsh-Go？'), findsOneWidget);
      await chooseRemote(tester);
      expect(find.byType(RemoteScreen), findsOneWidget);

      await tester.scrollUntilVisible(find.text('电脑'), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('电脑'));
      await _frames(tester);
      expect(find.byType(RemoteScreen), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(container.read(activeHostProvider), HostRef.ssh(sampleSsh.id));
      expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('back from the host list without a host: the choice again', (tester) async {
      final (runtime, container) = await pumpGate(tester);
      await chooseRemote(tester);
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(find.byType(RemoteScreen), findsNothing);
      expect(find.text('想怎么用 dsh-Go？'), findsOneWidget);
      expect(container.read(onboardingPrefsProvider).localDeclined, isFalse);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('和角色聊天 → home in 酒馆, nothing installed and no key asked for', (tester) async {
      final (runtime, container) = await pumpGate(tester);
      await tester.tap(find.byKey(const ValueKey('runtime-option-tavern')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await _frames(tester);
      expect(find.text('home'), findsOneWidget);
      expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
      expect(container.read(appModeProvider).startup, AppMode.tavern);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('a phone without the runtime opens home and starts nothing', (tester) async {
      final (runtime, _) = await pumpGate(
        tester,
        prefs: const OnboardingPrefs(loaded: true, welcomeSeen: true, localDeclined: true),
      );
      expect(find.text('home'), findsOneWidget);
      expect(runtime.calls, isEmpty);
    });
  });

  group('independent runtime contracts', () {
    testWidgets('disconnected chat has no local runtime action', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: Scaffold(body: ChatEmptyState(connected: false, onSuggestion: (_) {})),
          brightness: Brightness.light,
        ),
      );
      await _frames(tester, 6);
      expect(find.text('引擎未运行'), findsNothing);
      expect(find.text('启动引擎'), findsNothing);
      expect(find.text('安装运行环境'), findsNothing);
      expect(find.text('看看工作区'), findsOneWidget);
    });

    test('DeepSeek sign-in without the runtime fails at once', () async {
      final container = ProviderContainer(
        overrides: [
          localRuntimeProvider.overrideWith(
            () => RecordingLocalRuntime(const LocalRuntimeState(loaded: true, status: missingStatus)),
          ),
          accountEngineStarterProvider.overrideWithValue(() async => fail('must not start')),
          accountBrowserProvider.overrideWithValue(FakeBrowser()),
          localConnectionProvider.overrideWith(NoConnection.new),
          onboardingPrefsProvider.overrideWith(FakeOnboardingPrefs.new),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
      );
      addTearDown(container.dispose);
      container.listen(accountProvider, (_, _) {});
      // The app's root keeps the runtime's state alive from launch.
      container.listen(localRuntimeProvider, (_, _) {});
      final result = await container.read(accountProvider.notifier).signIn().timeout(const Duration(seconds: 2));
      expect(result, SignInResult.failed);
      expect(container.read(accountProvider).failure?.kind, SignInFailureKind.noRuntime);
      expect(container.read(accountProvider).failure?.title, '需要本机运行环境');
    });
  });
}
