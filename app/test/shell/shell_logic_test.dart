// Behaviour of the startup gate, onboarding helpers and small formatters.

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/engine/engine_status.dart';
import 'package:dsh_app/ui/engine/log_view.dart';
import 'package:dsh_app/ui/onboarding/api_key_page.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/update/update_sheet.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_harness.dart';

const _v = 'r1-dsh0.2.0-rc.2-node24.22.1-ubuntu24.04.5-a45b1e8964a3';

void main() {
  group('API key helpers', () {
    test('normalize strips whitespace from pastes', () {
      expect(normalizeApiKey('  sk-abc\n def \t'), 'sk-abcdef');
    });

    test('warnings are light and non-blocking', () {
      expect(apiKeyWarning(''), isNull);
      expect(apiKeyWarning('sk-0123456789abcdef0123'), isNull);
      expect(apiKeyWarning('sk-short'), isNotNull);
      expect(apiKeyWarning('or-0123456789abcdef0123'), isNotNull);
    });

    test('mask keeps only the prefix and last four', () {
      expect(maskApiKey('sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9'), 'sk-…a3f9');
      expect(maskApiKey(''), '');
      expect(maskApiKey('abc'), '••••');
    });
  });

  group('formatters', () {
    test('sessions group by local calendar day', () {
      final now = DateTime(2026, 10, 23, 9);
      expect(sessionDayOf(DateTime(2026, 10, 23, 0, 1), now), SessionDay.today);
      expect(sessionDayOf(DateTime(2026, 10, 22, 23, 59), now), SessionDay.yesterday);
      // 23 Oct 2026 is a Friday; the week starts on Monday the 19th.
      expect(sessionDayOf(DateTime(2026, 10, 20), now), SessionDay.thisWeek);
      expect(sessionDayOf(DateTime(2026, 10, 19, 0, 1), now), SessionDay.thisWeek);
      expect(sessionDayOf(DateTime(2026, 10, 18, 23, 59), now), SessionDay.earlier);
      // On a Monday, Sunday is 昨天 and nothing is 本周 before it.
      final monday = DateTime(2026, 10, 19, 9);
      expect(sessionDayOf(DateTime(2026, 10, 18, 12), monday), SessionDay.yesterday);
      expect(sessionDayOf(DateTime(2026, 10, 17, 12), monday), SessionDay.earlier);
    });

    test('runtime version is shortened to release and hash', () {
      expect(shortRuntimeVersion(_v), 'r1 · a45b1e89');
      expect(shortRuntimeVersion(null), '—');
      expect(shortRuntimeVersion('custom'), 'custom');
    });

    test('runtime errors read as sentences', () {
      expect(humanizeRuntimeError('install failed: 存储空间不足：需要约 640 MB，当前可用 212 MB'), '存储空间不足：需要约 640 MB，当前可用 212 MB');
      expect(humanizeRuntimeError('DSH exited unexpectedly (code 137)'), '引擎意外退出了');
      expect(humanizeRuntimeError(null), isNull);
      expect(humanizeRuntimeError('install failed: raw native exception'), isNull);
      expect(humanizeRuntimeError('start failed: token=secret'), isNull);
    });

    test('ANSI colour codes are stripped from logs', () {
      expect(stripAnsi('\x1B[2m[gateway]\x1B[0m ok'), '[gateway] ok');
    });

    test('engine status labels', () {
      final installing = EngineStatusView.of(
        const LocalRuntimeState(
          status: RuntimeStatus(phase: RuntimePhase.installing),
          progress: RuntimeProgressEvent(step: 'extract', done: 46, total: 100),
        ),
      );
      expect(installing.label, '正在安装 · 46%');
      expect(EngineStatusView.of(const LocalRuntimeState(status: runningStatus)).label, '运行中');
    });
  });

  testWidgets('update notes begin 16 inside the card', (tester) async {
    usePhoneSurface(tester);
    final release = ReleaseInfo(
      version: AppVersion.tryParse('1.2.0+2')!,
      tag: 'v1.2.0',
      notes: '修复了连接恢复',
      apks: {ApkFlavor.arm64: ReleaseAsset(name: 'app.apk', url: Uri.parse('https://example.com/app.apk'), size: 1234)},
    );
    await tester.pumpWidget(
      goldenApp(
        home: const Scaffold(body: SafeArea(child: UpdateSheet())),
        brightness: Brightness.light,
        overrides: [
          appUpdateProvider.overrideWith(
            () => _FixedUpdate(
              AppUpdateState(
                loaded: true,
                current: AppVersion.tryParse('1.0.0+1')!,
                flavor: ApkFlavor.arm64,
                check: UpdateCheckPhase.available,
                latest: release,
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    final notes = tester.getRect(find.byType(MarkdownBody));
    final card = tester.getRect(find.byType(SheetGroup));
    expect(notes.left - card.left, closeTo(16, .5));
    expect(card.right - notes.right, closeTo(16, .5));
    expect(tester.takeException(), isNull);
  });

  group('small screen, large text: nothing overflows', () {
    final screens = <String, Widget Function()>{
      'welcome': () => WelcomePage(onStart: () {}),
      'api key': () => ApiKeyPage(onDone: () {}),
      'settings': () => const SettingsScreen(),
      'remote': () => const RemoteScreen(),
      'drawer': () => HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
    };
    for (final MapEntry(key: name, value: build) in screens.entries) {
      testWidgets(name, (tester) async {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(320 * 2, 568 * 2);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          goldenApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
                child: build(),
              ),
            ),
            brightness: Brightness.light,
            overrides: [
              localRuntimeProvider.overrideWith(
                () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
              ),
              localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => sampleLogs),
              settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
              sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
      });
    }
  });
}

class _FixedUpdate extends AppUpdateController {
  _FixedUpdate(this.initial);

  final AppUpdateState initial;

  @override
  AppUpdateState build() => initial;
}
