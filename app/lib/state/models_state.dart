import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'hosts_state.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';
import 'settings_state.dart';

/// `session/modelCatalog` of the active host (null while disconnected).
///
/// The catalog is cached (10-minute TTL, [ReadListCache]): a (re)connection
/// or a credential confirmation does not re-read it. Only a real model
/// change does — the adapters changing (`llm/adapters-updated`), or a model
/// edit in the app (the pi-ai section, or the default-model setting). A
/// manual refresh invalidates the provider, which clears the cache below.
/// DSH 0.2.1 lists no models until a provider credential exists; the app
/// pushes the key to DSH asynchronously, and the adapters change when the
/// credential lands, so `llm/adapters-updated` covers the first read too.
final modelCatalogProvider = FutureProvider<ModelCatalog?>((ref) async {
  final conn = ref.watch(readListLiveConnectionProvider);
  if (conn == null) return null;
  final identity = ref.watch(readListIdentityProvider);
  final cache = ref.read(readListCacheProvider);
  ref.watch(settingsProvider.select((s) => s.apiKey));
  final sub = conn.client.hostEvents.listen((event) {
    final refresh = switch (event) {
      SettingsUpdatedEvent(:final namespace) => namespace == piAiSettingsNs || namespace == defaultModelSettingsNs,
      UnknownHostEvent(:final event) => event == 'llm/adapters-updated',
      _ => false,
    };
    if (refresh && ref.mounted) {
      // A real model change: drop the cached catalog so the rebuild below
      // reads fresh instead of serving the TTL copy.
      cache.invalidate(readListKey(identity, ReadListKind.models));
      ref.invalidateSelf();
    }
  });
  ref.onDispose(() => unawaited(sub.cancel()));
  // Within the cache TTL, serve the last catalog instead of re-reading:
  // reconnects and credential confirmations must not re-fetch the directory.
  // But only when the cached catalog belongs to this client: a different
  // host (a newly constructed client) always reads fresh.
  final cached = cache.get<CachedModels>(readListKey(identity, ReadListKind.models));
  if (cached != null && cache.current(cached.value, identity, conn.client)) return cached.value;
  final catalog = await conn.client.listModels();
  if (ref.mounted) {
    cache.stamp(catalog, identity, conn.client);
    cache.put(readListKey(identity, ReadListKind.models), catalog, () => CachedModels(catalog));
    // The display copy loses the catalog's origin: stamp the copy too, so
    // a later read can tell which client it came from (a different host
    // must read fresh; the same client's reconnect serves the cache).
    final stored = cache.get<CachedModels>(readListKey(identity, ReadListKind.models));
    if (stored != null) cache.stamp(stored.value, identity, conn.client);
  }
  return catalog;
});

/// A stale catalog is for browsing only; model selection still needs the
/// current provider's successful authoritative response.
final modelListViewProvider = Provider.autoDispose<ReadListView<ModelCatalog>>((ref) {
  final source = ref.watch(modelCatalogProvider);
  final identity = ref.watch(readListIdentityProvider);
  final connection = ref.watch(readListLiveConnectionProvider);
  final cache = ref.watch(readListCacheProvider);
  ref.watch(readListCacheChangesProvider);
  final raw = source.value;
  final status = source.hasError
      ? ReadListStatus.failed
      : connection == null
      ? ReadListStatus.offline
      : ReadListStatus.updating;
  if (raw != null && cache.current(raw, identity, connection?.client)) {
    final ready = !source.isLoading && !source.hasError;
    return ReadListView(value: raw, readOnly: !ready, status: ready ? ReadListStatus.current : status);
  }
  return ReadListView(
    value: cache.get<CachedModels>(readListKey(identity, ReadListKind.models))?.value,
    readOnly: true,
    status: status,
  );
});

const defaultModelSettingsNs = 'agent-default-model';

/// A picker belongs to one host/connection lifetime, including same-client
/// reconnects and A -> B -> A. It must not acquire a new destination later.
/// A mux reconnect does not end the lifetime (same host, same connection),
/// so it must not invalidate the scope: that would rebuild every picker
/// and re-read the model catalog on every reconnect.
final modelSelectionScopeProvider = Provider<Object>((ref) {
  ref.watch(activeHostProvider);
  ref.watch(activeConnectionProvider);
  ref.watch(readListLiveConnectionProvider);
  return Object();
});

/// Only a current response can supply the new-chat chip's effective default;
/// cached or retained catalogs are for browsing, not a claim about defaults.
final currentModelCatalogProvider = Provider<ModelCatalog?>((ref) {
  final view = ref.watch(modelListViewProvider);
  return view.readOnly ? null : view.value;
});

/// Model picked on the new-chat screen before a session exists. Applied to the
/// session right after it is created, then cleared; never carried to a host
/// selected later or a new connection generation.
class PendingModelController extends Notifier<ModelSelection?> {
  @override
  ModelSelection? build() {
    ref.watch(modelSelectionScopeProvider);
    return null;
  }

  void select(ModelSelection? selection) => state = selection;
}

final pendingModelProvider = NotifierProvider<PendingModelController, ModelSelection?>(PendingModelController.new);

/// Catalog entry for the exact provider/model route in [selection].
/// A same-named model on another provider is not the active selection.
ModelInfo? findModel(ModelCatalog? catalog, ModelSelection? selection) {
  if (catalog == null || selection == null) return null;
  for (final model in catalog.models) {
    if (model.provider == selection.provider && model.id == selection.model) {
      return model;
    }
  }
  return null;
}

/// Selection validation must use the fresh route and effort list together.
/// A retained current selection can outlive an adapter's effort edits.
bool isValidModelSelection(ModelCatalog? catalog, ModelSelection? selection) {
  final model = findModel(catalog, selection);
  if (model == null) return false;
  final effort = selection?.reasoningEffort;
  return effort == null || model.efforts.any((entry) => entry.id == effort);
}

/// The effort [model] starts at when it is picked: the engine's own default
/// when the model names one (DeepSeek: 高), else 中, else its lowest level
/// that thinks, else the first. A custom provider's models name no default
/// (the adapter only knows a route-wide one), and the engine runs a selection
/// without an effort as not thinking: so picking one must say which.
String? startingEffort(ModelInfo model) {
  final ids = [for (final e in model.efforts) e.id];
  if (ids.isEmpty) return null;
  if (model.defaultEffort case final effort? when ids.contains(effort)) return effort;
  if (ids.contains('medium')) return 'medium';
  for (final id in ids) {
    if (id != 'off' && id != 'none') return id;
  }
  return ids.first;
}
