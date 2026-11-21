import 'dart:async';

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine_settings/support.dart';
import 'support.dart';

const _package = '@acme/dsh-weather';

class _DelayedConfig extends MemoryPluginConfigApi {
  _DelayedConfig(super.entries);

  Completer<void> pending = Completer<void>();
  bool fail = false;

  void release() => pending.complete();

  @override
  Future<PluginConfigCatalog> describe() async {
    await pending.future;
    if (fail) throw StateError('fixture configuration read failed');
    return super.describe();
  }
}

Finder _settingsRow() => find.descendant(
  of: find.byType(BundleSheet),
  matching: find.byWidgetPredicate((w) => w is ListPageRow && w.icon == AppIcons.configure),
);

Future<ProviderContainer> _open(WidgetTester tester, PluginConfigApi? api) async {
  final host = FakeSettingsHost()..bundles = [configBundles()[2]];
  final client = DshClient.withCarrier(host);
  addTearDown(client.close);
  final bundle = PluginBundle.fromJson(host.bundles.single);
  await pumpPage(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(onPressed: () => showBundleSheet(context, bundle), child: const Text('open')),
      ),
    ),
    overrides: [
      ...engineOverrides(client),
      pluginConfigApiProvider.overrideWithValue(api),
      seatInventoryProvider.overrideWithValue(
        const SeatInventory(
          tier: ClientInventoryTier.bridge,
          routeGuard: true,
          webReachable: true,
          packages: {
            _package: PluginClientInfo(
              package: _package,
              hasClient: true,
              installed: true,
              enabled: true,
              rowIds: ['weather'],
            ),
          },
          occupancy: {
            Slots.bundleConfig: [SlotOccupant(slot: Slots.bundleConfig, package: _package, cell: _package)],
          },
        ),
      ),
      islandBudgetProvider.overrideWithValue(const NoIslandBudget()),
    ],
  );
  await tester.tap(find.text('open'));
  await flush(tester);
  return ProviderScope.containerOf(tester.element(find.byType(BundleSheet)));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a pending configuration cannot send an early settings tap to DSH Web', (tester) async {
    final api = _DelayedConfig([weatherEntry()]);
    final container = await _open(tester, api);
    expect(container.read(pluginConfigProvider).isLoading, isTrue);
    expect(container.read(pluginConfigProvider).hasValue, isFalse);
    final pending = tester.widget<ListPageRow>(_settingsRow());
    await tester.tap(_settingsRow());

    api.release();
    await flush(tester);
    expect(container.read(pluginConfigProvider).value!.isPlugin('weather'), isTrue);
    await tester.tap(_settingsRow());
    await flush(tester);
    expect(find.byType(PluginConfigPage), findsOneWidget);
    expect(pending.onTap, isNull);
    expect(pending.meta, '正在加载');
  });

  testWidgets('a confirmed catalog without fields disables the unavailable settings entry', (tester) async {
    final api = _DelayedConfig([]);
    await _open(tester, api);
    api.release();
    await flush(tester);
    expect(tester.widget<ListPageRow>(_settingsRow()).meta, '暂不可用');
    await tester.tap(_settingsRow());
  });

  testWidgets('a failed first read disables the unavailable settings fallback', (tester) async {
    final api = _DelayedConfig([])..fail = true;
    final container = await _open(tester, api);
    api.release();
    await flush(tester);
    expect(container.read(pluginConfigProvider).hasError, isTrue);
    expect(tester.widget<ListPageRow>(_settingsRow()).meta, '暂不可用');
    await tester.tap(_settingsRow());
  });

  testWidgets('an unavailable configuration source disables the unavailable settings fallback', (tester) async {
    final container = await _open(tester, null);
    expect(container.read(pluginConfigProvider).isLoading, isFalse);
    expect(container.read(pluginConfigProvider).hasValue, isTrue);
    expect(container.read(pluginConfigProvider).value, isNull);
    expect(tester.widget<ListPageRow>(_settingsRow()).meta, '暂不可用');
    await tester.tap(_settingsRow());
  });

  for (final hasFields in [true, false]) {
    testWidgets('a refresh keeps a known ${hasFields ? 'native' : 'unavailable'} settings entry usable', (
      tester,
    ) async {
      final api = _DelayedConfig(hasFields ? [weatherEntry()] : [])..release();
      final container = await _open(tester, api);
      api.pending = Completer<void>();
      container.invalidate(pluginConfigProvider);
      await flush(tester);
      expect(container.read(pluginConfigProvider).isLoading, isTrue);
      expect(container.read(pluginConfigProvider).hasValue, isTrue);
      final refreshing = tester.widget<ListPageRow>(_settingsRow());
      await tester.tap(_settingsRow());
      await flush(tester);
      expect(refreshing.onTap, hasFields ? isNotNull : isNull);
      if (hasFields) {
        expect(find.byType(PluginConfigPage), findsOneWidget);
        expect(refreshing.meta, isNull);
      } else {
        expect(refreshing.meta, '暂不可用');
      }
      api.release();
      await flush(tester);
    });
  }
}
