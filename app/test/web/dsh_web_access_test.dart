import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/web/dsh_web_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SelectedHost extends ActiveHostController {
  _SelectedHost(this.host);
  final HostRef host;
  @override
  HostRef build() => host;
}

void main() {
  test('the old local sentinel never creates a local Web target', () {
    final container = ProviderContainer(overrides: [
      activeHostProvider.overrideWith(() => _SelectedHost(HostRef.local)),
    ]);
    addTearDown(container.dispose);
    expect(container.read(dshWebAccessProvider), isA<NoDshWeb>());
  });

  test('SSH and direct launch URLs preserve token encoding and authority', () {
    for (final base in ['http://127.0.0.1:41234/base', 'https://host.example:443/base?old=value']) {
      final uri = localWebUri(base, 'fixture token+/&');
      expect(uri.authority, Uri.parse(base).authority);
      expect(uri.path, '/');
      expect(uri.queryParameters, {'token': 'fixture token+/&'});
    }
  });
}
