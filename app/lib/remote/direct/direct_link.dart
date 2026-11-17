import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'direct_host_config.dart';

/// Logs in to the `dsh web` at the saved server address.
typedef DirectClientConnector = Future<DshClient> Function({
  required Uri baseUri,
  required String token,
  DshBasicAuth? basicAuth,
});

Future<DshClient> _defaultConnector({required Uri baseUri, required String token, DshBasicAuth? basicAuth}) =>
    DshClient.connect(baseUri: baseUri, token: token, basicAuth: basicAuth, backgroundLists: true, startMux: false);

/// A direct DSH host: plain HTTP/WebSocket to the server, the way DSH Mobile
/// connects (no SSH, no relay). The server's launch token logs in; an nginx
/// `auth_basic` in front of it is sent as HTTP Basic Auth.
///
/// Lists parse on a worker ([DshClient.backgroundLists]), so a reconnect
/// after the app comes back does not parse JSON on the UI thread.
class DirectHostLink implements HostLink {
  DirectHostLink({
    required DirectHostConfig config,
    required Future<DirectSecrets> Function() loadSecrets,
    DirectClientConnector? connectClient,
    Stream<void>? kicks,
    Backoff? backoff,
    this.retryFirstOpen = true,
  }) : _config = config,
       _loadSecrets = loadSecrets,
       _connectClient = connectClient ?? _defaultConnector,
       _backoff = backoff ?? Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  DirectHostConfig _config;
  final Future<DirectSecrets> Function() _loadSecrets;
  final DirectClientConnector _connectClient;
  final Backoff _backoff;

  /// False for "测试连接": report the first failure instead of retrying.
  final bool retryFirstOpen;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;
  StreamSubscription<DshConnectionState>? _muxSub;
  HostLinkStatus _status = HostLinkStatus.idle;
  DshClient? _client;
  Future<DshClient>? _opening;
  bool _closed = false;
  bool _recovering = false;

  DirectHostConfig get config => _config;

  /// The server address + the token this link connected with (for the island
  /// launch URL); null while not connected. In memory only, like the SSH
  /// link's endpoint token.
  (String baseUri, String token)? get islandTarget => _token == null ? null : (_config.baseUri, _token!);

  String? _token;

  /// Takes a rename (or a Basic Auth user) without touching the connection;
  /// a new address needs a new link (the provider watches [DirectHostConfig.connectionKey]).
  void updateConfig(DirectHostConfig next) {
    _config = _config.copyWith(name: next.name, basicAuthUser: () => next.basicAuthUser);
  }

  @override
  HostLinkStatus get status => _status;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  void _emit(HostLinkStatus next) {
    if (_closed && next.phase != HostLinkPhase.idle) return;
    _status = next;
    _statuses.add(next);
  }

  void _checkOpen() {
    if (_closed) throw StateError('link closed');
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('link closed'));
    final client = _client;
    if (client != null && _status.isConnected) return Future.value(client);
    return _opening ??= _openFirst().whenComplete(() => _opening = null);
  }

  Future<DshClient> _openFirst() async {
    _backoff.reset();
    _emit(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    try {
      return await _connectOnce();
    } on HostLinkError catch (e) {
      if (!e.retryable || !retryFirstOpen) {
        _fail(e);
        rethrow;
      }
      return _recover(e);
    } catch (e) {
      final error = HostLinkError(
        HostLinkErrorKind.other,
        appL10n.commonConnectionFailed,
        detail: '$e',
        retryable: true,
      );
      if (!retryFirstOpen) {
        _fail(error);
        throw error;
      }
      return _recover(error);
    }
  }

  void _fail(HostLinkError error) {
    _emit(HostLinkStatus(HostLinkPhase.failed, step: _status.step, completed: _status.completed, error: error));
  }

  /// One full attempt: log in with the saved token (and Basic Auth, if the
  /// server sits behind one).
  Future<DshClient> _connectOnce() async {
    final secrets = await _loadSecrets();
    _checkOpen();
    final token = secrets.token?.trim();
    if (token == null || token.isEmpty) {
      throw HostLinkError(HostLinkErrorKind.loginFailed, appL10n.remoteErrDirectTokenMissing, retryable: false);
    }
    _token = token;
    final user = _config.basicAuthUser;
    final basicAuth = user == null || user.isEmpty
        ? null
        : (username: user, password: secrets.basicAuthPassword ?? '');
    final DshClient client;
    try {
      client = await _connectClient(baseUri: _config.uri, token: token, basicAuth: basicAuth);
    } on DshHttpException catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.loginFailed,
        e.statusCode == 401 ? appL10n.remoteErrDshTokenRejected : appL10n.remoteErrDshSignIn,
        detail: e.statusCode == 401 ? null : '$e',
        retryable: false,
      );
    } on DshException catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrDirectUnreachable,
        detail: '$e',
        retryable: true,
      );
    }
    if (_closed) {
      await client.close().catchError((_) {});
      throw StateError('link closed');
    }
    final existing = _client;
    _client = client;
    _watchMux(client);
    if (existing != null) {
      _clients.add(client);
      unawaited(existing.close().catchError((_) {}));
    }
    _emit(
      HostLinkStatus(
        HostLinkPhase.connected,
        completed: HostLinkStep.values.toSet(),
        detail: _config.baseUri,
      ),
    );
    return client;
  }

  void _watchMux(DshClient client) {
    unawaited(_muxSub?.cancel());
    _muxSub = client.mux.states.listen((state) {
      if (state == DshConnectionState.unauthorized && identical(client, _client)) {
        _lost(HostLinkError(HostLinkErrorKind.loginFailed, appL10n.remoteErrDshSignInExpired, retryable: true));
      }
    });
  }

  void _lost(HostLinkError reason) {
    if (_closed || _recovering || _status.phase == HostLinkPhase.failed) return;
    if (_status.phase != HostLinkPhase.connected) return;
    unawaited(_recover(reason).then((_) {}, onError: (_) {}));
  }

  /// Reconnect loop with backoff. Resolves with the (possibly new) client.
  Future<DshClient> _recover(HostLinkError reason) async {
    _recovering = true;
    var last = reason;
    try {
      while (!_closed) {
        if (_backoff.exhausted) {
          final error = HostLinkError(
            last.kind,
            last.message,
            detail: [if (last.detail != null) last.detail!, appL10n.remoteRetryCount(_backoff.attempt)].join('\n'),
            retryable: true,
            diagnosticCode: last.diagnosticCode,
          );
          _fail(error);
          throw error;
        }
        final delay = _backoff.next();
        _emit(
          HostLinkStatus(
            HostLinkPhase.reconnecting,
            attempt: _backoff.attempt,
            error: last,
            nextRetryAt: DateTime.now().add(delay),
          ),
        );
        await _delay.wait(delay);
        if (_closed) break;
        try {
          final client = await _connectOnce();
          _backoff.reset();
          return client;
        } on HostLinkError catch (e) {
          if (_closed) break;
          if (!e.retryable) {
            _fail(e);
            rethrow;
          }
          last = e;
        } catch (e) {
          if (_closed) break;
          last = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, detail: '$e', retryable: true);
        }
      }
      throw StateError('link closed');
    } finally {
      _recovering = false;
    }
  }

  @override
  void kick() {
    if (_closed) return;
    switch (_status.phase) {
      case HostLinkPhase.connected:
        // The mux heals a dropped socket by itself; a kick only matters when
        // it is already waiting (a network change under a reconnecting mux).
        break;
      case HostLinkPhase.reconnecting:
        _backoff.reset();
        _delay.skip();
      case HostLinkPhase.failed:
        if (_status.error?.retryable ?? false) retry();
      case HostLinkPhase.idle || HostLinkPhase.connecting:
        break;
    }
  }

  @override
  void retry() {
    if (_closed || _status.isBusy && _status.phase != HostLinkPhase.reconnecting) return;
    if (_status.phase == HostLinkPhase.reconnecting) {
      _backoff.reset();
      _delay.skip();
      return;
    }
    if (_status.phase == HostLinkPhase.failed || _status.phase == HostLinkPhase.idle) {
      unawaited(open().then((_) {}, onError: (_) {}));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _emit(HostLinkStatus.idle);
    _closed = true;
    _delay.cancel();
    await _kickSub?.cancel();
    await _muxSub?.cancel();
    final client = _client;
    _client = null;
    if (client != null) await client.close().catchError((_) {});
    await _statuses.close();
    await _clients.close();
  }
}
