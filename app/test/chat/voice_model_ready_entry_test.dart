// Remote speech capabilities drive the already-open composer. Keep the real
// ChatScreen/Composer/controller; only native and RPC IO is fake.
import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

class _Host extends Notifier<HostConnection?> {
  _Host(this.initial);
  final HostConnection initial;

  @override
  HostConnection? build() => initial;

  void use(HostConnection connection) => state = connection;
}

final _hostProvider = NotifierProvider<_Host, HostConnection?>(() => throw UnimplementedError());

class _Carrier extends FakeRpcCarrier {
  _Carrier({this.phase = 'unprepared'}) : super({});
  final String phase;
  Future<Object?>? pendingCatalog;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint != 'speech/catalog') return super.call(endpoint, args, timeout: timeout);
    calls.add((endpoint, args));
    final pending = pendingCatalog;
    pendingCatalog = null;
    return RpcOk(pending == null ? readySpeechCatalog(phase: phase) : await pending);
  }

  int get probes => argsOf('speech/catalog').length;
}

class _Rig {
  _Rig({bool system = false, String phase = 'unprepared'})
    : bridge = FakeVoiceBridge(caps: VoiceCapabilities(recognizer: system, recorder: true)),
      carrier = _Carrier(phase: phase) {
    client = DshClient.withCarrier(carrier);
    host = _Host(HostConnection(client: client, isLocal: false));
  }

  final FakeVoiceBridge bridge;
  final _Carrier carrier;
  late final DshClient client;
  late final _Host host;

  Future<void> pump(WidgetTester tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      await client.close();
    });
    final harness = ChatHarness(session: 'first-chat');
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          _hostProvider.overrideWith(() => host),
          activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_hostProvider))),
          // Replace the harness's first override (its fixed connection).
          ...harness.overrides.skip(1),
          voiceBridgeProvider.overrideWithValue(bridge),
        ],
      ),
    );
    await pumpFrames(tester);
  }

  VoiceInputController voice(WidgetTester tester) => tester.widget<Composer>(find.byType(Composer)).voice!;
}

Finder get _mic => find.byIcon(AppIcons.voice);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final ready in [false, true]) {
    testWidgets('remote catalog readiness controls the existing composer (ready: $ready)', (tester) async {
      final rig = _Rig(phase: ready ? 'standby' : 'unprepared');
      await rig.pump(tester);

      expect(rig.voice(tester).available, ready);
      expect(_mic, ready ? findsOneWidget : findsNothing);
      expect(rig.carrier.probes, 1);
    });
  }

  testWidgets('a remote catalog reply exposes the microphone without reopening chat', (tester) async {
    final pending = Completer<Object?>();
    final rig = _Rig();
    rig.carrier.pendingCatalog = pending.future;
    await rig.pump(tester);
    expect(_mic, findsNothing);
    expect(rig.carrier.probes, 1);

    pending.complete(readySpeechCatalog());
    await pumpFrames(tester);

    expect(rig.voice(tester).available, isTrue);
    expect(_mic, findsOneWidget);
    expect(rig.carrier.probes, 1);
  });

  for (final ready in [false, true]) {
    testWidgets('switching remote hosts uses the replacement catalog (ready: $ready)', (tester) async {
      final rig = _Rig(phase: ready ? 'unprepared' : 'standby');
      await rig.pump(tester);
      expect(rig.voice(tester).available, !ready);

      final replacement = _Carrier(phase: ready ? 'standby' : 'unprepared');
      final replacementClient = DshClient.withCarrier(replacement);
      addTearDown(replacementClient.close);
      rig.host.use(HostConnection(client: replacementClient, isLocal: false));
      await pumpFrames(tester);

      expect(rig.voice(tester).available, ready);
      expect(_mic, ready ? findsOneWidget : findsNothing);
      expect(rig.carrier.probes, 1);
      expect(replacement.probes, 1);
    });
  }

  testWidgets('a stale ready catalog cannot enable voice on a replacement remote host', (tester) async {
    final pending = Completer<Object?>();
    final rig = _Rig();
    rig.carrier.pendingCatalog = pending.future;
    await rig.pump(tester);

    final replacement = _Carrier();
    final replacementClient = DshClient.withCarrier(replacement);
    addTearDown(replacementClient.close);
    rig.host.use(HostConnection(client: replacementClient, isLocal: false));
    await tester.pump();
    pending.complete(readySpeechCatalog());
    await pumpFrames(tester);

    expect(rig.voice(tester).available, isFalse);
    expect(_mic, findsNothing);
    expect(rig.carrier.probes, 1);
    expect(replacement.probes, 1);
  });

  testWidgets('a system microphone stays available without an eager remote speech query', (tester) async {
    final rig = _Rig(system: true);
    await rig.pump(tester);

    expect(rig.voice(tester).available, isTrue);
    expect(_mic, findsOneWidget);
    expect(rig.carrier.probes, 0);
  });

  testWidgets('disposing chat retires a pending remote catalog probe', (tester) async {
    final pending = Completer<Object?>();
    final rig = _Rig();
    rig.carrier.pendingCatalog = pending.future;
    await rig.pump(tester);
    expect(rig.carrier.probes, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(readySpeechCatalog());
    await pumpFrames(tester);

    expect(rig.carrier.probes, 1);
    expect(find.byType(Composer), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
