import 'dart:async';

import 'package:dsh_app/remote/direct/direct_link.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_relay.dart';

const _url = 'https://host.example/dsh';
const _direct = DirectHostConfig(
  id: 'direct-sync',
  name: 'Server',
  baseUri: _url,
  basicAuthUser: 'owner',
  relayHostId: 'mac',
  relayServerUrl: defaultRelayServer,
);

class _ConfigBackend extends FakeRelayBackend implements RelayDirectConfigBackend {
  _ConfigBackend() : super(user: sampleRelayUser);
  int queries = 0;
  DirectConnectionCredentials? credentials = const DirectConnectionCredentials(url: _url, token: 'new-token');
  Completer<DirectConnectionCredentials?>? pending;
  Object? failure;

  bool refreshAllowed = true;

  @override
  bool canRefreshDirectConfig(String hostId) => refreshAllowed;

  @override
  Future<DirectConnectionCredentials?> readDirectConfig(DshClient client) async {
    queries++;
    if (failure case final error?) throw error;
    return pending == null ? credentials : await pending!.future;
  }
}

DshClient _client() => DshClient(DshConnection(Uri.parse(_url)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('direct login', () {
    test('401 fetches once, retries direct with new token and preserves Basic Auth', () async {
      final attempts = <String>[];
      final passwords = <String?>[];
      var refreshes = 0;
      final link = DirectHostLink(
        config: _direct,
        loadSecrets: () async => const DirectSecrets(token: 'old-token', basicAuthPassword: 'password'),
        refreshToken: (rejected) async {
          expect(rejected, 'old-token');
          refreshes++;
          return 'new-token';
        },
        connectClient: ({required baseUri, required token, basicAuth}) async {
          attempts.add(token);
          passwords.add(basicAuth?.password);
          if (token == 'old-token') throw const DshHttpException(401, 'rejected');
          return _client();
        },
      );
      addTearDown(link.close);
      await Future.wait([link.open(), link.open()]);
      expect(attempts, ['old-token', 'new-token']);
      expect(passwords, ['password', 'password']);
      expect(refreshes, 1);
      expect(link.status.isConnected, isTrue);
      expect(link.islandTarget, (_url, 'new-token'));
    });

    for (final refreshed in <String?>[null, '', 'old-token', 'new-token']) {
      test('failed refresh $refreshed never loops or publishes rejected credentials', () async {
        var attempts = 0;
        var refreshes = 0;
        final link = DirectHostLink(
          config: _direct,
          loadSecrets: () async => const DirectSecrets(token: 'old-token'),
          refreshToken: (_) async {
            refreshes++;
            return refreshed;
          },
          connectClient: ({required baseUri, required token, basicAuth}) async {
            attempts++;
            throw const DshHttpException(401, 'rejected');
          },
        );
        addTearDown(link.close);
        await expectLater(link.open(), throwsA(isA<HostLinkError>().having((e) => e.retryable, 'retryable', false)));
        expect(attempts, refreshed == 'new-token' ? 2 : 1);
        expect(refreshes, 1);
        expect(link.islandTarget, isNull);
      });
    }

    test('403 does not request credentials', () async {
      var refreshes = 0;
      final link = DirectHostLink(
        config: _direct,
        loadSecrets: () async => const DirectSecrets(token: 'old-token'),
        refreshToken: (_) async {
          refreshes++;
          return 'new-token';
        },
        connectClient: ({required baseUri, required token, basicAuth}) async =>
            throw const DshHttpException(403, 'denied'),
      );
      addTearDown(link.close);
      await expectLater(link.open(), throwsA(isA<HostLinkError>()));
      expect(refreshes, 0);
    });

    test('retryable Remote errors do not start another credential refresh', () async {
      var refreshes = 0;
      final link = DirectHostLink(
        config: _direct,
        loadSecrets: () async => const DirectSecrets(token: 'old-token'),
        refreshToken: (_) async {
          refreshes++;
          throw const HostLinkError(HostLinkErrorKind.unreachable, 'offline', retryable: true);
        },
        connectClient: ({required baseUri, required token, basicAuth}) async =>
            throw const DshHttpException(401, 'rejected'),
      );
      addTearDown(link.close);
      await expectLater(link.open(), throwsA(isA<HostLinkError>().having((e) => e.retryable, 'retryable', false)));
      expect(refreshes, 1);
    });

    test('closing while refreshing prevents a late retry', () async {
      final refreshing = Completer<void>();
      final token = Completer<String?>();
      var attempts = 0;
      final link = DirectHostLink(
        config: _direct,
        loadSecrets: () async => const DirectSecrets(token: 'old-token'),
        refreshToken: (_) {
          refreshing.complete();
          return token.future;
        },
        connectClient: ({required baseUri, required token, basicAuth}) async {
          attempts++;
          throw const DshHttpException(401, 'rejected');
        },
      );
      final opening = link.open();
      final expectation = expectLater(opening, throwsA(isA<StateError>()));
      await refreshing.future;
      await link.close();
      token.complete('new-token');
      await expectation;
      expect(attempts, 1);
    });
  });

  group('associated Host refresh', () {
    late MemorySecretStore secrets;
    late _ConfigBackend backend;
    late ProviderContainer container;
    late List<String> attempts;

    setUp(() async {
      attempts = [];
      secrets = MemorySecretStore();
      backend = _ConfigBackend();
      container = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          relayBackendProvider.overrideWithValue(backend),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          directClientConnectorProvider.overrideWithValue(({required baseUri, required token, basicAuth}) async {
            attempts.add(token);
            expect(basicAuth?.password, 'password');
            if (token == 'old-token') throw const DshHttpException(401, 'rejected');
            return _client();
          }),
        ],
      );
      await container.read(hostsProvider.notifier).ready;
      await container
          .read(hostsProvider.notifier)
          .saveDirect(
            _direct,
            secrets: const DirectSecrets(token: 'old-token', basicAuthPassword: 'password'),
          );
    });
    tearDown(() => container.dispose());

    Future<String?> refresh() => container.read(directTokenRefresherProvider(_direct.id))('old-token');

    test('provider wiring recovers direct 401 through its associated Host', () async {
      final keep = container.listen(hostLinkProvider(const HostRef.direct('direct-sync')), (_, _) {});
      addTearDown(keep.close);
      await keep.read()!.open();
      expect(attempts, ['old-token', 'new-token']);
      expect(backend.queries, 1);
      expect(backend.connected, ['mac']);
      expect((await container.read(hostsProvider.notifier).loadDirectSecrets(_direct.id)).token, 'new-token');
    });

    test('first discovery creates a scoped entry but never activates it', () async {
      await container.read(hostsProvider.notifier).removeDirect(_direct.id);
      final keep = container.listen(hostLinkProvider(const HostRef.relay('mac')), (_, _) {});
      addTearDown(keep.close);
      await keep.read()!.open();
      await pumpEventQueue();
      final discovered = container.read(hostsProvider).direct.single;
      expect(discovered.relayServerUrl, defaultRelayServer);
      expect(discovered.relayHostId, 'mac');
      expect(container.read(activeHostProvider), HostRef.local);
      expect((await container.read(hostsProvider.notifier).loadDirectSecrets(discovered.id)).token, 'new-token');
    });

    test('updates token without touching password, host selection or route policy', () async {
      container.read(activeHostProvider.notifier).select(const HostRef.direct('direct-sync'));
      final policy = container.read(remoteTransportPolicyProvider);
      final keep = container.listen(directTokenRefresherProvider(_direct.id), (_, _) {});
      addTearDown(keep.close);
      expect(await refresh(), 'new-token');
      expect(backend.queries, 1);
      expect(backend.connected, ['mac']);
      final saved = await container.read(hostsProvider.notifier).loadDirectSecrets(_direct.id);
      expect(saved.token, 'new-token');
      expect(saved.basicAuthPassword, 'password');
      expect(container.read(activeHostProvider), const HostRef.direct('direct-sync'));
      expect(container.read(remoteTransportPolicyProvider), policy);
    });

    test('reuses the existing associated Remote client', () async {
      final keep = container.listen(hostLinkProvider(const HostRef.relay('mac')), (_, _) {});
      addTearDown(keep.close);
      await keep.read()!.open();
      expect(await refresh(), 'new-token');
      expect(backend.connected, ['mac']);
    });

    test('a different server or different active Remote host is not contacted', () async {
      await container
          .read(hostsProvider.notifier)
          .saveDirect(_direct.copyWith(relayServerUrl: () => 'https://other.example'));
      expect(await refresh(), isNull);
      expect(backend.connected, isEmpty);
      await container.read(hostsProvider.notifier).saveDirect(_direct);
      container.read(activeHostProvider.notifier).select(const HostRef.relay('nas'));
      expect(await refresh(), isNull);
      expect(backend.connected, isEmpty);
    });

    test('a changed endpoint cannot receive a refreshed token', () async {
      backend.credentials = const DirectConnectionCredentials(url: 'https://changed.example', token: 'new-token');
      expect(await refresh(), isNull);
      expect((await container.read(hostsProvider.notifier).loadDirectSecrets(_direct.id)).token, 'old-token');
    });

    test('deleted or edited hosts reject a late response', () async {
      backend.pending = Completer<DirectConnectionCredentials?>();
      final pending = refresh();
      await pumpEventQueue();
      await container.read(hostsProvider.notifier).removeDirect(_direct.id);
      backend.pending!.complete(backend.credentials);
      expect(await pending, isNull);
      expect(secrets.values.containsKey(DirectSecrets.tokenKey(_direct.id)), isFalse);
      expect(container.read(hostsProvider).directById(_direct.id), isNull);
    });

    test('legacy associations refresh only the matching endpoint', () async {
      await container.read(hostsProvider.notifier).saveDirect(_direct.copyWith(relayServerUrl: () => null));
      expect(await refresh(), 'new-token');
    });

    test('another live Host is never displaced by a credential request', () async {
      backend.refreshAllowed = false;
      expect(await refresh(), isNull);
      expect(backend.connected, isEmpty);
    });

    test('logout while a Host response is pending discards its credentials', () async {
      backend.pending = Completer<DirectConnectionCredentials?>();
      final pending = refresh();
      await pumpEventQueue();
      await container.read(relayAccountProvider.notifier).logout();
      backend.pending!.complete(backend.credentials);
      expect(await pending, isNull);
      expect((await container.read(hostsProvider.notifier).loadDirectSecrets(_direct.id)).token, 'old-token');
    });

    test('disabled or unsupported sync preserves existing credentials', () async {
      backend.credentials = null;
      expect(await refresh(), isNull);
      expect((await container.read(hostsProvider.notifier).loadDirectSecrets(_direct.id)).token, 'old-token');
    });
  });

  test('untrusted credential responses require a safe token-free URL', () {
    for (final url in [
      'http://public.example',
      'https://user:pass@host.example',
      'https://host.example/?token=secret',
      'file:///tmp/x',
      'https://host.example/#secret',
    ]) {
      expect(DirectConnectionCredentials.tryParse({'url': url, 'token': 'sample'}), isNull, reason: url);
    }
    expect(DirectConnectionCredentials.tryParse({'url': _url, 'token': 'sample'}), isNotNull);
    expect(DirectConnectionCredentials.tryParse({'url': '$_url/', 'token': 'sample'})?.url, _url);
    expect(DirectConnectionCredentials.tryParse({'url': 'ftp://host.example', 'token': 'sample'}), isNull);
    expect(DirectConnectionCredentials.tryParse({'url': _url, 'token': '   '}), isNull);
    final scoped = DirectHostConfig.fromJson(_direct.toJson())!;
    expect(scoped.relayServerUrl, defaultRelayServer);
    expect(scoped.relayHostId, 'mac');
    expect(scoped.toJson().containsKey('token'), isFalse);
  });
}
