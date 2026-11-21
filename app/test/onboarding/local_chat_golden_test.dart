import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';
import 'local_optional_support.dart';

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  for (final status in [missingStatus, stoppedStatus]) {
    testWidgets('chat has no local setup action (${status.phase})', (tester) async {
      usePhoneView(tester);
      final runtime = RecordingLocalRuntime(LocalRuntimeState(loaded: true, status: status));
      final harness = ChatHarness(connected: false, runtime: () => runtime);
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
      await pumpFrames(tester);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.textContaining('安装引擎'), findsNothing);
      expect(find.text('启动引擎'), findsNothing);
      expect(runtime.calls, isEmpty);
    });
  }

  testWidgets('a loaded conversation stays on screen without starting a local engine', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {'s1': conversationState()},
      connected: false,
      runtime: () => RecordingLocalRuntime(const LocalRuntimeState(loaded: true, status: stoppedStatus)),
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    expect(find.text('启动引擎'), findsNothing);
    final runtime = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)))
        .read(localRuntimeProvider.notifier);
    expect((runtime as RecordingLocalRuntime).calls, isEmpty);
  });
}
