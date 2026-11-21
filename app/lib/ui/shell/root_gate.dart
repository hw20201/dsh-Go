import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../diagnostics/automatic_diagnostics.dart';
import '../../launch/launch_state.dart';
import '../../launch/startup_trace.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import '../../state/onboarding_state.dart';
import '../../state/settings_state.dart';
import '../onboarding/onboarding_flow.dart';
import '../remote/remote_screen.dart';
import '../theme/theme.dart';
import '../modes/mode_switch.dart';
import 'home_shell.dart';
import 'brand_mark.dart';
import 'usage_upgrade_notice.dart';

/// Saved local setup state never resumes an install or asks for a local key.
OnboardingStep? initialOnboardingStep({required OnboardingPrefs prefs}) {
  if (prefs.localDeclined || prefs.setupStep != null) return null;
  return prefs.welcomeSeen ? OnboardingStep.choice : OnboardingStep.welcome;
}

class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key, this.home});

  @visibleForTesting
  final Widget? home;

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate> {
  bool _hostRestored = false;
  bool _decided = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreHost());
  }

  Future<void> _restoreHost() async {
    await ref.read(activeHostProvider.notifier).ready;
    if (mounted) setState(() => _hostRestored = true);
  }

  bool _launchReady = false;
  bool _pickingRemote = false;
  OnboardingStep? _step;

  void _goTo(OnboardingStep? step) {
    if (mounted) setState(() => _step = step);
  }

  Future<void> _useRemote() async {
    if (_pickingRemote) return;
    _pickingRemote = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen()));
    } finally {
      _pickingRemote = false;
    }
    if (!mounted || ref.read(activeHostProvider).isLocal) return;
    await ref.read(onboardingPrefsProvider.notifier).setLocalDeclined(true);
    unawaited(ref.read(notifyChannelProvider).status().then<void>((_) {}, onError: (_) {}));
    _goTo(null);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(automaticDiagnosticsProvider);
    final settings = ref.watch(settingsProvider);
    final prefs = ref.watch(onboardingPrefsProvider);
    final host = ref.watch(activeHostProvider);
    final Widget child;
    if (!settings.loaded || !prefs.loaded || !_hostRestored) {
      StartupTrace.mark('waiting: settings ${settings.loaded}, setup ${prefs.loaded}');
      child = const _Splash();
    } else {
      if (!_decided) {
        _decided = true;
        _step = host.isLocal ? initialOnboardingStep(prefs: prefs) : null;
      }
      if (_step case final step?) {
        child = OnboardingFlow(
          step: step,
          onRemote: _useRemote,
          onWelcomeDone: () {
            unawaited(ref.read(onboardingPrefsProvider.notifier).markWelcomeSeen());
            _goTo(OnboardingStep.choice);
          },
        );
      } else {
        child = UsageUpgradeNotice(child: widget.home ?? const ModeLaunch(child: HomeShell()));
      }
    }
    if (child is! _Splash && !_launchReady) {
      _launchReady = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        StartupTrace.mark('first page');
        final launch = LaunchController.active.value;
        if (launch == null) return StartupTrace.finished();
        launch.ready(waitsForEngine: false);
      });
    }
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.page),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      child: KeyedSubtree(
        key: ValueKey(child is _Splash ? 'splash' : (_step == null ? 'home' : 'onboarding')),
        child: child,
      ),
    );
  }
}

class _Splash extends StatefulWidget {
  const _Splash();

  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> {
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(Theme.of(context).brightness),
      child: AppBackdrop(
        child: Center(
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: AppMotion.of(context, AppMotion.slow),
            child: const Column(mainAxisSize: MainAxisSize.min, children: [BrandMark(size: 64, tile: true)]),
          ),
        ),
      ),
    );
  }
}
