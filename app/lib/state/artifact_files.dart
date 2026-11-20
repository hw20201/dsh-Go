// Getting a chat artifact onto the phone and handing it to Android (open,
// share, save to Downloads).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import 'android_features.dart' show operatingSystemProvider;
import 'artifacts.dart';
import 'connection_state.dart';

/// Largest file fetched from a remote Host for open / share / save.
const maxRemoteArtifactBytes = 300 * 1024 * 1024;

/// Largest remote image fetched just to draw a thumbnail.
const maxThumbnailBytes = 8 * 1024 * 1024;

/// Maximum total size of completed remote artifact cache entries.
const maxArtifactCacheBytes = 512 * 1024 * 1024;

/// Why an artifact action could not run (beyond Host and platform errors).
class ArtifactError implements Exception {
  const ArtifactError(this.code);

  /// `missing`, `offline`, `unsupported`.
  final String code;

  @override
  String toString() => 'ArtifactError($code)';
}

/// A sentence for a failed artifact action.
String artifactErrorText(Object error) {
  final code = switch (error) {
    ArtifactError(:final code) => code,
    PlatformException(:final code) => code,
    DshRemoteException(:final code) => code,
    DshTransportException() || DshCarrierLostException() || DshClosedException() => 'offline',
    _ => '',
  };
  return switch (code) {
    'missing' || 'workspace-file/not-found' => appL10n.stateFileMissing,
    'no_app' => appL10n.stateFileNoApp,
    'permission' => appL10n.stateStoragePermission,
    'workspace-file/too-large' => appL10n.stateFileConnectionLimit,
    'unsupported' || 'workspace-file/unsupported' || 'workspace-file/not-allowed' => appL10n.stateFileReadUnsupported,
    'offline' => appL10n.commonEngineUnreachable,
    _ => appL10n.commonFailedTryAgain,
  };
}

/// Artifact files of the active connection.
///
/// The local engine's files are already on the phone (inside the Linux
/// environment, or in shared storage): Android gets them in place. A remote
/// Host's file is downloaded once into the app cache (`artifacts/`), keyed by
/// Host, session and path, and fetched again when the Host reports a new
/// version. HarmonyOS logical workspace files use the same Session-aware
/// byte service because their logical paths are not platform file paths.
class ArtifactFiles {
  ArtifactFiles({
    required this.connection,
    required this.channel,
    Future<void> Function(ShareParams params)? share,
    Future<Directory> Function()? cacheRoot,
    String? operatingSystem,
    int maxCacheBytes = maxArtifactCacheBytes,
  }) : _share = share ?? _systemShare,
       _cacheRoot = cacheRoot ?? getTemporaryDirectory,
       _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       // The public parameter name intentionally differs from the private field.
       // ignore: prefer_initializing_formals
       _maxCacheBytes = maxCacheBytes;

  final HostConnection? connection;
  final FilesChannel channel;
  final Future<void> Function(ShareParams params) _share;
  final Future<Directory> Function() _cacheRoot;
  final String _operatingSystem;
  final int _maxCacheBytes;

  static Future<void> _systemShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  static final _trimQueues = <String, Future<void>>{};
  static final _cacheLeases = <String, int>{};

  bool get isLocal => connection?.isLocal ?? false;

  /// Whether open / share / save can get at the file at all.
  bool get canFetch {
    final conn = connection;
    return conn != null && (conn.isLocal || conn.client.canReadFileBytes);
  }

  /// Whether the Host can turn Office files into PDFs for a preview.
  bool get canConvertOffice => connection?.client.supportsEndpoint('officeToPdf/render') ?? false;

  /// A PDF of an Office file, converted by the Host (as the official Web
  /// client previews them) and kept in the cache until the file changes.
  Future<File> officePdf(String sessionId, Artifact artifact) async {
    final conn = connection;
    if (conn == null) throw const ArtifactError('offline');
    if (!canConvertOffice) throw const ArtifactError('unsupported');
    final client = conn.client;
    final stat = await client.statFile(sessionId, artifact.path);
    final root = await _cacheRoot();
    final key = _fnv(_pdfCacheKey(conn, sessionId, artifact));
    final dir = Directory('${root.path}/artifacts/$key');
    // 纪要.docx → 纪要.pdf: swapping the extension keeps a name the phone could
    // already store within its 255-byte limit (appending .pdf might not).
    final base = _safeName(artifact.name);
    final dot = base.lastIndexOf('.');
    final pdfName = '${dot > 0 ? base.substring(0, dot) : base}.pdf';
    final target = File('${dir.path}/$pdfName');
    final marker = File('${dir.path}/.version');
    if (target.existsSync() && marker.existsSync() && marker.readAsStringSync() == stat.version) {
      return target;
    }
    final rendered = await client.renderOfficePdf(sessionId, artifact.path);
    if (rendered.pdf.isEmpty) throw const ArtifactError('unsupported');
    await dir.create(recursive: true);
    final staging = await dir.createTemp('.part-');
    final part = File('${staging.path}/$pdfName');
    try {
      await part.writeAsBytes(rendered.pdf, flush: true);
      part.renameSync(target.path);
      marker.writeAsStringSync(stat.version);
      await _trimArtifactCache(root, dir, _maxCacheBytes);
      return target;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  /// An Android file holding [artifact]; [onProgress] gets 0–1 (null while
  /// the size is unknown) during a download.
  Future<File> materialize(
    String sessionId,
    Artifact artifact, {
    void Function(double? progress)? onProgress,
    int maxBytes = maxRemoteArtifactBytes,
  }) => _materialize(sessionId, artifact, onProgress: onProgress, maxBytes: maxBytes);

  Future<File> _materialize(
    String sessionId,
    Artifact artifact, {
    void Function(double? progress)? onProgress,
    required int maxBytes,
    Directory? rootOverride,
  }) async {
    final conn = connection;
    if (conn == null) throw const ArtifactError('offline');
    // This prefix selects a transport, not authority. The existing Session
    // file service still resolves the path and checks its workspace grant.
    final sessionCopy = conn.isLocal && _operatingSystem == 'ohos' && artifact.path.startsWith('/workspaces/');
    if (conn.isLocal && !sessionCopy) {
      final host = await channel.resolveGuest(artifact.path);
      if (host == null) throw const ArtifactError('missing');
      return File(host);
    }
    final client = conn.client;
    if (!client.canReadFileBytes) throw const ArtifactError('unsupported');
    final stat = await client.statFile(sessionId, artifact.path);
    if (stat.bytes != null && stat.bytes! > maxBytes) throw const ArtifactError('workspace-file/too-large');
    final root = rootOverride ?? await _cacheRoot();
    final key = _fnv(_artifactCacheKey(conn, sessionId, artifact));
    final dir = Directory('${root.path}/artifacts/$key');
    final target = File('${dir.path}/${_safeName(artifact.name)}');
    final marker = File('${dir.path}/.version');
    if (target.existsSync() && marker.existsSync() && marker.readAsStringSync() == stat.version) {
      if (await target.length() > maxBytes) throw const ArtifactError('workspace-file/too-large');
      return target;
    }
    await dir.create(recursive: true);
    // A thumbnail and its preview can download together. Each owns its
    // temporary directory, including cleanup after a failed read.
    final staging = await dir.createTemp('.part-');
    final part = File('${staging.path}/${_safeName(artifact.name)}');
    var received = 0;
    try {
      final sink = await part.open(mode: FileMode.write);
      try {
        await client.readFile(
          sessionId,
          artifact.path,
          maxBytes: maxBytes,
          onChunk: (chunk) async {
            received += chunk.length;
            if (received > maxBytes) throw const ArtifactError('workspace-file/too-large');
            await sink.writeFrom(chunk);
          },
          onProgress: onProgress == null
              ? null
              : (received, total) => onProgress(total == null || total == 0 ? null : received / total),
        );
        if (sessionCopy) await sink.flush();
      } finally {
        await sink.close();
      }
      // Publish the file and its version without an await between them, so
      // another completed download cannot pair this version with its bytes.
      part.renameSync(target.path);
      marker.writeAsStringSync(stat.version);
      await _trimArtifactCache(root, dir, _maxCacheBytes);
      return target;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  /// Opens [artifact] in the app Android picks for its type ([chooser]: the
  /// person picks).
  Future<void> open(
    String sessionId,
    Artifact artifact, {
    bool chooser = false,
    void Function(double?)? onProgress,
  }) async {
    final lease = await _leaseArtifactCache(sessionId, artifact);
    try {
      final file = await _materialize(
        sessionId,
        artifact,
        onProgress: onProgress,
        maxBytes: maxRemoteArtifactBytes,
        rootOverride: lease?.root,
      );
      await channel.open(file.path, name: artifact.name, mime: artifact.mimeType, chooser: chooser);
    } finally {
      await lease?.release();
    }
  }

  /// The system share sheet with the file.
  Future<void> share(String sessionId, Artifact artifact, {void Function(double?)? onProgress}) async {
    final lease = await _leaseArtifactCache(sessionId, artifact);
    try {
      final file = await _materialize(
        sessionId,
        artifact,
        onProgress: onProgress,
        maxBytes: maxRemoteArtifactBytes,
        rootOverride: lease?.root,
      );
      await _share(
        ShareParams(
          files: [XFile(file.path, mimeType: artifact.mimeType, name: artifact.name)],
          fileNameOverrides: [artifact.name],
        ),
      );
    } finally {
      await lease?.release();
    }
  }

  /// Copies the file into the phone's public Downloads; returns where.
  Future<String> saveToDownloads(String sessionId, Artifact artifact, {void Function(double?)? onProgress}) async {
    final lease = await _leaseArtifactCache(sessionId, artifact);
    try {
      final file = await _materialize(
        sessionId,
        artifact,
        onProgress: onProgress,
        maxBytes: maxRemoteArtifactBytes,
        rootOverride: lease?.root,
      );
      return await channel.saveToDownloads(file.path, name: artifact.name, mime: artifact.mimeType);
    } finally {
      await lease?.release();
    }
  }

  Future<_ArtifactCacheLease?> _leaseArtifactCache(String sessionId, Artifact artifact) async {
    final conn = connection;
    if (conn == null) return null;
    final sessionCopy = conn.isLocal && _operatingSystem == 'ohos' && artifact.path.startsWith('/workspaces/');
    if (conn.isLocal && !sessionCopy) return null;
    final root = await _cacheRoot();
    final directory = Directory('${root.path}/artifacts/${_fnv(_artifactCacheKey(conn, sessionId, artifact))}');
    await _withCacheQueue(root.path, () async {
      _cacheLeases.update(directory.path, (count) => count + 1, ifAbsent: () => 1);
    });
    return _ArtifactCacheLease(root, directory);
  }

  /// A small image of [artifact] for its card; null when it is not an image
  /// Flutter can draw, or too big to fetch just for this.
  Future<ImageProvider?> thumbnail(String sessionId, String path) async {
    final artifact = Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0);
    if (artifact.kind != ArtifactKind.image || path.toLowerCase().endsWith('.svg')) {
      return null;
    }
    final conn = connection;
    if (conn == null) return null;
    if (!conn.isLocal) {
      final stat = await conn.client.statFile(sessionId, artifact.path);
      if ((stat.bytes ?? maxThumbnailBytes + 1) > maxThumbnailBytes) {
        return null;
      }
    }
    final file = await materialize(sessionId, artifact, maxBytes: maxThumbnailBytes);
    if (await file.length() > maxThumbnailBytes) return null;
    return FileImage(file);
  }
}

Future<void> _trimArtifactCache(Directory root, Directory keep, int limit) async {
  if (limit < 0) return;
  await _withCacheQueue(root.path, () async {
    final cache = Directory('${root.path}/artifacts');
    try {
      if (!await cache.exists()) return;
      final entries = <({Directory directory, int bytes, DateTime modified})>[];
      var total = 0;
      await for (final entity in cache.list(followLinks: false)) {
        if (entity is! Directory) continue;
        var active = false;
        var bytes = 0;
        try {
          await for (final child in entity.list(recursive: true, followLinks: false)) {
            if (child is Directory && child.path.split(Platform.pathSeparator).last.startsWith('.part-')) {
              active = true;
            } else if (child is File) {
              bytes += await child.length();
            }
          }
          if (entity.path == keep.path || active || ArtifactFiles._cacheLeases.containsKey(entity.path)) {
            total += bytes;
            continue;
          }
          final modified = (await entity.stat()).modified;
          total += bytes;
          entries.add((directory: entity, bytes: bytes, modified: modified));
        } on FileSystemException {
          // Another process may remove an entry between listing and inspection.
        }
      }
      if (total <= limit) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (total <= limit) break;
        try {
          await entry.directory.delete(recursive: true);
          total -= entry.bytes;
        } on FileSystemException {
          // A concurrent reader or writer may have removed or replaced it.
        }
      }
    } on FileSystemException {
      // The cache root itself can disappear while the scan is in progress.
    }
  });
}

Future<T> _withCacheQueue<T>(String root, Future<T> Function() action) {
  final previous = ArtifactFiles._trimQueues[root] ?? Future<void>.value();
  final done = Completer<void>();
  ArtifactFiles._trimQueues[root] = done.future;
  return () async {
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
      if (identical(ArtifactFiles._trimQueues[root], done.future)) {
        ArtifactFiles._trimQueues.remove(root);
      }
    }
  }();
}

class _ArtifactCacheLease {
  _ArtifactCacheLease(this.root, this.directory);

  final Directory root;
  final Directory directory;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _withCacheQueue(root.path, () async {
      final count = ArtifactFiles._cacheLeases[directory.path]! - 1;
      if (count == 0) {
        ArtifactFiles._cacheLeases.remove(directory.path);
      } else {
        ArtifactFiles._cacheLeases[directory.path] = count;
      }
    });
  }
}

String _artifactCacheKey(HostConnection conn, String sessionId, Artifact artifact) =>
    '${conn.hostId ?? conn.label}\n$sessionId\n${artifact.path}';

String _pdfCacheKey(HostConnection conn, String sessionId, Artifact artifact) =>
    'pdf\n${conn.hostId ?? conn.label}\n$sessionId\n${artifact.path}';

String _safeName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\x00-\x1f/\\:*?"<>|]'), '_').trim();
  // Keep downloaded content separate from the cache's version marker.
  if (cleaned == '.version') return 'file.version';
  return cleaned.isEmpty ? 'file' : _fitName(cleaned);
}

/// Android's file systems take 255 bytes for a name, a Windows Host 255 characters: a
/// longer name (CJK is 3 bytes a character) is cut to fit, its extension kept. Each
/// artifact has its own cache directory, so a cut name can't meet another.
String _fitName(String name) {
  const max = 200;
  if (utf8.encode(name).length <= max) return name;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && name.length - dot <= 16 ? name.substring(dot) : '';
  var room = max - utf8.encode(ext).length;
  final stem = StringBuffer();
  for (final rune in (ext.isEmpty ? name : name.substring(0, dot)).runes) {
    room -= utf8.encode(String.fromCharCode(rune)).length;
    if (room < 0) break;
    stem.writeCharCode(rune);
  }
  return '$stem$ext';
}

/// FNV-1a, hex: a stable cache directory name.
String _fnv(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

final artifactFilesProvider = Provider<ArtifactFiles>(
  (ref) => ArtifactFiles(
    connection: ref.watch(activeConnectionProvider).value,
    channel: ref.watch(filesChannelProvider),
    operatingSystem: ref.watch(operatingSystemProvider),
  ),
);

/// [ArtifactFiles.thumbnail], cached per (session, path) while shown.
final artifactThumbnailProvider = FutureProvider.autoDispose.family<ImageProvider?, (String, String)>((ref, key) async {
  final (sessionId, path) = key;
  try {
    return await ref.watch(artifactFilesProvider).thumbnail(sessionId, path);
  } catch (_) {
    return null;
  }
});
