import 'dart:math' as math;

/// One saved direct DSH host: a server URL, reached the way DSH Mobile does
/// (plain HTTP/WebSocket to the server, no SSH, no relay). Persisted as JSON
/// in SharedPreferences (no secrets); the launch token and any Basic Auth
/// password live in the [SecretStore] under [DirectSecrets] keys.
class DirectHostConfig {
  const DirectHostConfig({required this.id, required this.name, required this.baseUri, this.basicAuthUser, this.relayHostId});

  /// Stable id (`direct-<hex>`); also the secret-store namespace.
  final String id;

  /// What the person calls it ("家里的服务器", "srv-main 直连").
  final String name;

  /// Server address, e.g. `https://example.com/dsh/` or
  /// `http://100.116.80.16:3080`. A trailing slash is trimmed.
  final String baseUri;

  /// Username for the server's HTTP Basic Auth (an nginx `auth_basic` user),
  /// if any. The password lives in the secret store; null means no Basic Auth.
  final String? basicAuthUser;

  /// The Relay host this direct entry was synced from, if any. Used to avoid
  /// fetching the same host's direct config on every reconnect.
  final String? relayHostId;

  /// The address as the client dials it (no trailing slash).
  Uri get uri {
    var text = baseUri.trim();
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return Uri.parse(text);
  }

  /// Fields that require a new connection when they change (a rename doesn't).
  String get connectionKey => [uri.toString(), basicAuthUser ?? ''].join('\u0000');

  DirectHostConfig copyWith({String? name, String? baseUri, String? Function()? basicAuthUser, String? Function()? relayHostId}) =>
      DirectHostConfig(
        id: id,
        name: name ?? this.name,
        baseUri: baseUri ?? this.baseUri,
        basicAuthUser: basicAuthUser != null ? basicAuthUser() : this.basicAuthUser,
        relayHostId: relayHostId != null ? relayHostId() : this.relayHostId,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'baseUri': baseUri,
    if (basicAuthUser != null) 'basicAuthUser': basicAuthUser,
    if (relayHostId != null) 'relayHostId': relayHostId,
  };

  static String newId([math.Random? random]) {
    final r = random ?? math.Random.secure();
    final hex = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'direct-$hex';
  }

  static DirectHostConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final baseUri = raw['baseUri'];
    if (id is! String || id.isEmpty || name is! String || baseUri is! String || baseUri.isEmpty) return null;
    final basicAuthUser = raw['basicAuthUser'];
    final relayHostId = raw['relayHostId'];
    return DirectHostConfig(
      id: id,
      name: name,
      baseUri: baseUri,
      basicAuthUser: basicAuthUser is String && basicAuthUser.isNotEmpty ? basicAuthUser : null,
      relayHostId: relayHostId is String && relayHostId.isNotEmpty ? relayHostId : null,
    );
  }
}

/// The secrets of one direct host: the DSH launch token and, when the server
/// sits behind HTTP Basic Auth, that password. Never in SharedPreferences.
class DirectSecrets {
  const DirectSecrets({this.token, this.basicAuthPassword});

  /// DSH launch token (the `?token=` the server prints on start).
  final String? token;

  /// Password for [DirectHostConfig.basicAuthUser], if any.
  final String? basicAuthPassword;

  static String tokenKey(String hostId) => 'direct.$hostId.token';
  static String basicAuthPasswordKey(String hostId) => 'direct.$hostId.basicAuthPassword';
}
