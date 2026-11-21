import 'package:flutter/material.dart';

import 'onboarding_scaffold.dart';
import 'runtime_choice.dart';
import 'welcome_page.dart';

enum OnboardingStep { welcome, choice }

/// First run introduces the app and connects a remote host.
class OnboardingFlow extends StatelessWidget {
  const OnboardingFlow({super.key, required this.step, required this.onWelcomeDone, required this.onRemote});

  final OnboardingStep step;
  final VoidCallback onWelcomeDone;
  final VoidCallback onRemote;

  @override
  Widget build(BuildContext context) => OnboardingSwitcher(
    child: switch (step) {
      OnboardingStep.welcome => WelcomePage(key: const ValueKey('welcome'), onStart: onWelcomeDone),
      OnboardingStep.choice => RuntimeChoiceView(key: const ValueKey('choice'), onRemote: onRemote),
    },
  );
}
