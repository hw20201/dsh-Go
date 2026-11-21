import 'package:dsh_app/ui/plugins/islands/island_assets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shipped island assets retain the shared navigation bridge', () async {
    final assets = IslandAssets();
    expect(await assets.openBridge, contains('window.__dshAppOpen'));
    expect(await assets.runtime, contains('__dshGoIsland'));
    expect(await assets.css, contains('@font-face'));
    expect((await assets.recipes).slots, isNotEmpty);
  });
}
