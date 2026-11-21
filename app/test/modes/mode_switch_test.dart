import 'package:dsh_app/state/app_mode_state.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/modes/mode_switch.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Widget _app(Widget home) => ProviderScope(
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: home,
  ),
);

void main() {
  testWidgets('a legacy Tavern startup choice falls back to 工作 without opening a route', (tester) async {
    SharedPreferences.setMockInitialValues({AppModeController.key: 'tavern'});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.byType(ModeLaunch)));
    expect(container.read(appModeProvider).loaded, isTrue);
    expect(container.read(appModeProvider).startup, AppMode.work);
    expect(find.text('工作首页'), findsOneWidget);
    expect(tester.state<NavigatorState>(find.byType(Navigator)).canPop(), isFalse);
  });

  testWidgets('工作 as the startup mode shows the home and opens nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
    await tester.pumpAndSettle();

    expect(find.text('工作首页'), findsOneWidget);
    expect(tester.state<NavigatorState>(find.byType(Navigator)).canPop(), isFalse);
  });

  test('伙伴 remains a startup mode with its own native page', () async {
    SharedPreferences.setMockInitialValues({AppModeController.key: 'companion'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(appModeProvider);
    await pumpEventQueue();

    expect(AppMode.values, [AppMode.work, AppMode.companion]);
    expect(container.read(appModeProvider).loaded, isTrue);
    expect(container.read(appModeProvider).startup, AppMode.companion);
    expect(appModePage(AppMode.companion), isA<CompanionPage>());
    expect(() => appModePage(AppMode.work), throwsArgumentError);
  });

  testWidgets('the 模式 sheet opens 伙伴 and keeps the startup choice without removed entries', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppMode? opened;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ModeSheet(current: AppMode.work, onOpen: (mode) => opened = mode),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('工作'), findsWidgets);
    expect(find.text('伙伴小屋'), findsOneWidget);
    expect(find.text('酒馆'), findsNothing);
    expect(find.byKey(const ValueKey('mode-row-tavern')), findsNothing);
    expect(find.byKey(const ValueKey('mode-row-work')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mode-row-companion')));
    expect(opened, AppMode.companion);

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('mode-startup')), matching: find.text('伙伴')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppModeController.key), 'companion');
  });
}
