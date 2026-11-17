import 'dart:async';

import 'package:flutter/services.dart' show MethodChannel, MissingPluginException;

/// Lifecycle of the on-device Linux runtime and the local DSH server.
enum RuntimePhase {
  notInstalled,
  installing,
  installed,
  starting,
  running,
  stopping,
  error;

  static RuntimePhase parse(Object? wire) =>
      RuntimePhase.values.firstWhere((p) => p.name == wire, orElse: () => RuntimePhase.error);

  bool get isBusy => this == installing || this == starting || this == stopping;
}

/// Which profile the local DSH boots: the user's `web`, or the rescue profile.
enum EngineMode {
  normal,
  safe;

  static EngineMode parse(Object? wire) => wire == 'safe' ? safe : normal;
}

/// Where the safe-mode state machine stands (Kotlin `SafeState`).
enum SafeModeState {
  /// Normal starts.
  off,

  /// Starts use the rescue profile until the user asks for normal mode.
  on,

  /// Back in normal mode on trial: a counted failure within two minutes returns to [on].
  probation;

  static SafeModeState parse(Object? wire) => switch (wire) {
    'on' => on,
    'probation' => probation,
    _ => off,
  };
}

/// How a run that nobody asked to stop ended (Kotlin `FailureKind`).
enum FailureKind {
  /// The shell could not execute DSH before its login line.
  launchFailed,

  /// DSH printed a fatal error before its login line.
  startupFailed,

  /// DSH printed a fatal error within two minutes of its login line.
  crashedEarly,

  /// DSH printed a fatal error after running longer than that.
  crashedLate,

  /// The process went away without a DSH fatal error (low memory, battery saver, ...).
  killed,

  /// The output mentions a full disk.
  noSpace;

  static FailureKind? parse(Object? wire) => FailureKind.values.where((k) => k.name == wire).firstOrNull;

  /// Counts toward the two consecutive failures that switch to safe mode.
  bool get counts => this == startupFailed || this == crashedEarly;

  /// A plugin or configuration problem (DSH itself reported it).
  bool get isFatal => this == startupFailed || this == crashedEarly || this == crashedLate;
}

/// The last unexpected exit of the local DSH, classified natively.
class RuntimeFailure {
  const RuntimeFailure({
    required this.kind,
    required this.at,
    this.exitCode = 0,
    this.safeMode = false,
    this.summary,
    this.requiredRows = const [],
    this.suspects = const [],
    this.recent = const [],
    this.diagnostics,
    this.upSeconds,
    this.causeUnknown = false,
  });

  static RuntimeFailure? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final kind = FailureKind.parse(raw['kind']);
    if (kind == null) return null;
    List<String> strings(Object? v) => v is List
        ? [
            for (final e in v)
              if (e is String && e.isNotEmpty) e,
          ]
        : const [];
    return RuntimeFailure(
      kind: kind,
      at: DateTime.fromMillisecondsSinceEpoch((raw['at'] as num?)?.toInt() ?? 0),
      exitCode: (raw['exitCode'] as num?)?.toInt() ?? 0,
      safeMode: raw['safeMode'] == true,
      summary: raw['summary'] as String?,
      requiredRows: strings(raw['requiredRows']),
      suspects: strings(raw['suspects']),
      recent: strings(raw['recent']),
      diagnostics: raw['diagnostics'] as String?,
      upSeconds: (raw['upSeconds'] as num?)?.toInt(),
      causeUnknown: raw['causeUnknown'] == true,
    );
  }

  final FailureKind kind;
  final DateTime at;
  final int exitCode;

  /// The failed run was itself a safe-mode run.
  final bool safeMode;

  /// First fatal line (English, from DSH).
  final String? summary;

  /// Built-in rows the startup audit names; broken, not necessarily the culprit.
  final List<String> requiredRows;

  /// Packages named by the crash output.
  final List<String> suspects;

  /// Bundles enabled or upgraded since the last good run.
  final List<String> recent;

  /// Guest path of DSH's startup diagnostics file.
  final String? diagnostics;
  final int? upSeconds;

  /// The native side only knows the run didn't end cleanly (HarmonyOS, where
  /// the engine shares the app's process: the system or the person ending the
  /// app looks the same as a crash), so nothing may name a cause.
  final bool causeUnknown;

  /// Crash-output suspects first, then recent changes.
  List<String> get culprits => {...suspects, ...recent}.toList();
}

/// Snapshot of the native runtime (see docs/architecture.md, "RuntimeStatus").
/// HarmonyOS's background grant, as its native side reports it. Android has none.
class RuntimeBackgroundTask {
  const RuntimeBackgroundTask({required this.phase, required this.foreground});

  /// The phase of the long-running task: the turn goes on, with no deadline.
  static const longRunningPhase = 7;

  final int phase;

  /// The app is on screen, so a task ending now is the return, not the system's doing.
  final bool foreground;

  bool get longRunning => phase == longRunningPhase;

  static RuntimeBackgroundTask? fromMap(Object? raw) => switch (raw) {
    {'phase': final num phase, 'foreground': final bool foreground} => RuntimeBackgroundTask(
      phase: phase.toInt(),
      foreground: foreground,
    ),
    _ => null,
  };
}

class RuntimeStatus {
  const RuntimeStatus({
    required this.phase,
    this.abi,
    this.bundledVersion,
    this.installedVersion,
    this.dshVersion,
    this.nodeVersion,
    this.baseUrl,
    this.token,
    this.managedSkillGeneration,
    this.error,
    this.mode = EngineMode.normal,
    this.workspaceRecovery = false,
    this.safeState = SafeModeState.off,
    this.safeReason,
    this.strikes = 0,
    this.autoSafe = true,
    this.failure,
    this.mainFailure,
    this.healthyAt,
    this.networkBlocked = false,
    this.networkBlockedAt,
    this.directEngineEnabled = false,
    this.directEngineAvailable = false,
    this.directEngineActive = false,
    this.directEngineFallbackReason,
    this.tawcEngineEnabled = false,
    this.tawcEngineAvailable = false,
    this.tawcEngineActive = false,
    this.currentExecutionMode,
    this.launchSelectedMode,
    this.launchSpawned = false,
    this.launchFailureReason,
    this.tidyingFiles = false,
    this.resetPending = false,
    this.backgroundTask,
    this.longTaskEligible = false,
    this.continuedRun = false,
  });

  const RuntimeStatus.unknown() : this(phase: RuntimePhase.notInstalled);

  final RuntimePhase phase;

  /// Null where there's no such grant.
  final RuntimeBackgroundTask? backgroundTask;

  /// This build may ask HarmonyOS for a long-running task for a turn (debug and
  /// device builds have the permission, store builds don't). The system can still
  /// say no, or take it back.
  final bool longTaskEligible;
  final String? abi;
  final String? bundledVersion;
  final String? installedVersion;
  final String? dshVersion;
  final String? nodeVersion;
  final String? baseUrl;
  final String? token;

  /// Native grant generation for bundled-skill writes only (runtime ready and
  /// Flutter attachment). Unknown means the
  /// native transaction must reject admission; this is not general RPC authority.
  final int? managedSkillGeneration;
  final String? error;

  /// Mode of the running process, or the mode the next start will use.
  final EngineMode mode;

  /// Uses the persistent independent workspace index on this local runtime.
  /// This is a launch setting, not evidence that workspace services are ready.
  final bool workspaceRecovery;
  final SafeModeState safeState;

  /// Why safe mode is on: `manual`, `auto` (two failures in a row) or `probation` (normal mode failed again).
  final String? safeReason;

  /// Consecutive counted failures of the main profile.
  final int strikes;

  /// Switch to safe mode by itself after two consecutive failures (default on).
  final bool autoSafe;

  /// The last unexpected exit; cleared once a later run gets going.
  final RuntimeFailure? failure;

  /// The main profile's last failure: what safe mode is there to fix.
  final RuntimeFailure? mainFailure;

  /// When the current normal run will count as healthy (two minutes after its login line).
  final DateTime? healthyAt;

  /// Android reports this app's network blocked right now (e.g. a vendor background policy).
  final bool networkBlocked;

  /// When the latest such block started; kept after it lifts.
  final DateTime? networkBlockedAt;

  /// App-local launch option. Unknown/older runtimes remain on the default path.
  final bool directEngineEnabled;
  final bool directEngineAvailable;
  final bool directEngineActive;
  final String? directEngineFallbackReason;

  /// The opt-in tawcroot launch (native `TawcrootLaunch`); one of it and Direct is on at most.
  final bool tawcEngineEnabled;
  final bool tawcEngineAvailable;
  final bool tawcEngineActive;

  /// Native process observation, never inferred from the saved direct preference.
  final String? currentExecutionMode;

  /// Latest attempt, including attempts that failed before spawning a process.
  final String? launchSelectedMode;
  final bool launchSpawned;
  final String? launchFailureReason;

  /// The start in progress has been turning PRoot's fake hard links into real
  /// files for more than a moment (once per install, before Direct launch).
  final bool tidyingFiles;

  /// A reset was committed and hasn't finished (HarmonyOS): it finishes as the
  /// app opens, and nothing starts until it has.
  final bool resetPending;

  /// iOS: the system is letting the engine keep running while the app is away.
  final bool continuedRun;

  Map<String, Object?> get launchDiagnostics => {
    'directEngineEnabled': directEngineEnabled,
    'directEngineAvailable': directEngineAvailable,
    'directEngineActive': directEngineActive,
    'directEngineFallbackReason': directEngineFallbackReason,
    'tawcEngineEnabled': tawcEngineEnabled,
    'tawcEngineAvailable': tawcEngineAvailable,
    'tawcEngineActive': tawcEngineActive,
    'currentExecutionMode': currentExecutionMode,
    'launchSelectedMode': launchSelectedMode,
    'launchSpawned': launchSpawned,
    'launchFailureReason': launchFailureReason,
  };

  bool get isRunning => phase == RuntimePhase.running && baseUrl != null && token != null;

  /// The install stopped because what a reset kept could not go back (Kotlin
  /// `KeepFailed`); `install(dropKept: true)` gives it up and carries on.
  bool get keepFailed => phase == RuntimePhase.error && (error?.startsWith('install failed: keep: ') ?? false);

  /// The engine is (or will next start) in safe mode.
  bool get inSafeMode => mode == EngineMode.safe;

  /// Normal mode on trial after leaving safe mode.
  bool get onProbation => safeState == SafeModeState.probation;

  factory RuntimeStatus.fromMap(Map<Object?, Object?> map) => RuntimeStatus(
    phase: RuntimePhase.parse(map['phase']),
    backgroundTask: RuntimeBackgroundTask.fromMap(map['transientTask']),
    longTaskEligible: map['longTaskEligible'] == true,
    abi: map['abi'] as String?,
    bundledVersion: map['bundledVersion'] as String?,
    installedVersion: map['installedVersion'] as String?,
    dshVersion: map['dshVersion'] as String?,
    nodeVersion: map['nodeVersion'] as String?,
    baseUrl: map['baseUrl'] as String?,
    token: map['token'] as String?,
    managedSkillGeneration: switch (map['managedSkillGeneration']) {
      final int value when value > 0 => value,
      _ => null,
    },
    error: map['error'] as String?,
    mode: EngineMode.parse(map['mode']),
    workspaceRecovery: map['workspaceRecovery'] == true,
    safeState: SafeModeState.parse(map['safeState']),
    safeReason: map['safeReason'] as String?,
    strikes: (map['strikes'] as num?)?.toInt() ?? 0,
    autoSafe: map['autoSafe'] != false,
    failure: RuntimeFailure.fromMap(map['failure']),
    mainFailure: RuntimeFailure.fromMap(map['mainFailure']),
    healthyAt: switch (map['healthyAt']) {
      final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
      _ => null,
    },
    networkBlocked: map['networkBlocked'] == true,
    networkBlockedAt: switch (map['networkBlockedAt']) {
      final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
      _ => null,
    },
    directEngineEnabled: map['directEngineEnabled'] == true,
    directEngineAvailable: map['directEngineAvailable'] == true,
    directEngineActive: map['directEngineActive'] == true,
    directEngineFallbackReason: map['directEngineFallbackReason'] as String?,
    tawcEngineEnabled: map['tawcEngineEnabled'] == true,
    tawcEngineAvailable: map['tawcEngineAvailable'] == true,
    tawcEngineActive: map['tawcEngineActive'] == true,
    currentExecutionMode: map['currentExecutionMode'] as String?,
    launchSelectedMode: map['launchSelectedMode'] as String?,
    launchSpawned: map['launchSpawned'] == true,
    launchFailureReason: map['launchFailureReason'] as String?,
    tidyingFiles: map['tidyingFiles'] == true,
    resetPending: map['resetPending'] == true,
    continuedRun: map['continuedRun'] == true,
  );
}

/// What "恢复上次正常的配置" would change in the main profile.
class LastKnownGood {
  const LastKnownGood({
    required this.available,
    this.at,
    this.disable = const [],
    this.enable = const [],
    this.changed = const [],
    this.patchChanged = false,
    this.empty = true,
  });

  const LastKnownGood.none() : this(available: false);

  factory LastKnownGood.fromMap(Map<Object?, Object?> map) {
    List<String> strings(Object? v) => v is List
        ? [
            for (final e in v)
              if (e is String) e,
          ]
        : const [];
    return LastKnownGood(
      available: map['available'] == true,
      at: switch (map['at']) {
        final num ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
        _ => null,
      },
      disable: strings(map['disable']),
      enable: strings(map['enable']),
      changed: strings(map['changed']),
      patchChanged: map['patchChanged'] == true,
      empty: map['empty'] != false,
    );
  }

  /// A snapshot exists and the main profile exists.
  final bool available;
  final DateTime? at;

  /// Bundles that would be turned off (added or upgraded since).
  final List<String> disable;

  /// Bundles that would be turned back on.
  final List<String> enable;

  /// Of [disable]: upgraded in place since (can only be turned off, not downgraded).
  final List<String> changed;

  /// The settings layer (`cordis.patch.yml`) would go back to the snapshot's.
  final bool patchChanged;

  /// Restoring would change nothing.
  final bool empty;

  /// Restoring is possible and would change something.
  bool get useful => available && !empty;
}

/// A home-level file that applies to every profile, the safe one included.
class SafeHazard {
  const SafeHazard({required this.path, required this.kind, required this.detail});

  factory SafeHazard.fromMap(Map<Object?, Object?> map) => SafeHazard(
    path: map['path'] as String? ?? '',
    kind: map['kind'] as String? ?? '',
    detail: map['detail'] as String? ?? '',
  );

  /// Guest path, e.g. `/root/.dsh/.env`.
  final String path;

  /// `homePatch`, `homeEnv` or `cwdEnv`.
  final String kind;

  /// One Chinese sentence.
  final String detail;
}

/// Whether the Linux environment can see the phone's shared storage.
class StorageAccess {
  const StorageAccess({
    required this.granted,
    required this.permission,
    required this.legacy,
    this.guestPath = '/sdcard',
  });

  factory StorageAccess.fromMap(Map<Object?, Object?> map) => StorageAccess(
    granted: map['granted'] == true,
    permission: map['permission'] == true,
    legacy: map['legacy'] == true,
    guestPath: map['guestPath'] as String? ?? '/sdcard',
  );

  final bool granted;

  /// The runtime permission is granted (may still need "All files access" when not [legacy]).
  final bool permission;
  final bool legacy;
  final String guestPath;
}

sealed class RuntimeEvent {
  const RuntimeEvent();
}

class RuntimeStatusEvent extends RuntimeEvent {
  const RuntimeStatusEvent(this.status);
  final RuntimeStatus status;
}

class RuntimeProgressEvent extends RuntimeEvent {
  const RuntimeProgressEvent({required this.step, required this.done, required this.total});
  final String step;
  final int done;
  final int total;

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0, 1).toDouble();
}

class RuntimeLogEntry {
  const RuntimeLogEntry(this.seq, this.line, this.stream);

  factory RuntimeLogEntry.fromMap(Map<Object?, Object?> raw) =>
      RuntimeLogEntry(raw['seq'] as int, raw['line'] as String, raw['stream'] as String);

  final int seq;
  final String line;
  final String stream;
}

class RuntimeLogsEvent extends RuntimeEvent {
  const RuntimeLogsEvent(this.entries);
  final List<RuntimeLogEntry> entries;
}

class RuntimeLogSnapshot {
  const RuntimeLogSnapshot(this.entries, this.throughSeq);
  final List<RuntimeLogEntry> entries;
  final int throughSeq;
}

/// One-off message from the native side, e.g. "已用安全模式启动".
class RuntimeNoticeEvent extends RuntimeEvent {
  const RuntimeNoticeEvent(this.text);
  final String text;
}

/// See [RuntimeBridge.backgroundSettings].
class BackgroundSettingsInfo {
  const BackgroundSettingsInfo({this.vendor, this.label});
  final String? vendor;
  final String? label;
}

/// What 「重置运行环境」 keeps of the old /root (Kotlin `ResetKeep`); the next
/// install puts it back.
class ResetKeep {
  const ResetKeep({this.uiAndSkills = false, this.pluginsAndSettings = false});

  /// `$DSH_HOME/dsh-go` (ui.json) and the user's skills.
  final bool uiAndSkills;

  /// Installed plugins with their settings, `cordis.patch.yml` and `.env`.
  final bool pluginsAndSettings;

  /// The reset dialog's starting choice.
  static const suggested = ResetKeep(uiAndSkills: true);

  List<String> get wire => [if (uiAndSkills) 'uiAndSkills', if (pluginsAndSettings) 'pluginsAndSettings'];

  ResetKeep copyWith({bool? uiAndSkills, bool? pluginsAndSettings}) => ResetKeep(
    uiAndSkills: uiAndSkills ?? this.uiAndSkills,
    pluginsAndSettings: pluginsAndSettings ?? this.pluginsAndSettings,
  );

  @override
  bool operator ==(Object other) =>
      other is ResetKeep && other.uiAndSkills == uiAndSkills && other.pluginsAndSettings == pluginsAndSettings;

  @override
  int get hashCode => Object.hash(uiAndSkills, pluginsAndSettings);

  @override
  String toString() => 'ResetKeep(${wire.join(', ')})';
}

/// Transaction outcome plus whether its native runtime scope is still current.
class ManagedSkillInstallResponse {
  const ManagedSkillInstallResponse({this.result, this.current = false, this.reason});
  final String? result;
  final bool current;
  final String? reason;
}

/// Dart side of the `dsh/runtime` platform channels implemented in Kotlin.
///
/// The on-device engine is gone: this fork is remote-only (SSH / relay), so
/// there is no native side anymore. Every call answers as if the runtime were
/// permanently not installed. The remote paths never touch this class.
class RuntimeBridge {
  RuntimeBridge();

  Stream<RuntimeEvent> get events => const Stream<RuntimeEvent>.empty();

  Future<RuntimeStatus> status() async => throw MissingPluginException('dsh/runtime: no local runtime in this build');

  /// No guest rootfs to install a bundled skill into.
  Future<ManagedSkillInstallResponse> installManagedSkill({
    required String requestId,
    required String expectedRoot,
    required String expectedToken,
    required int? expectedGeneration,
    required String name,
    required Map<String, String> files,
  }) async => const ManagedSkillInstallResponse(reason: 'unavailable');

  Future<void> cancelManagedSkill(String requestId) async {}

  Future<void> install({bool dropKept = false}) async {}

  Future<void> start({
    Map<String, String> env = const {},
    bool phoneStorage = false,
    EngineMode? mode,
    bool visualReplies = true,
  }) async {}

  Future<LastKnownGood> lastKnownGood() async => const LastKnownGood.none();

  Future<LastKnownGood> restoreLastKnownGood() async => const LastKnownGood.none();

  Future<String?> reminderAccess() async => null;

  Future<List<SafeHazard>> safePreflight() async => const [];

  Future<List<String>> moveAside(List<String> paths) async => const [];

  Future<void> clearFailure() async {}

  Future<void> setAutoSafe(bool enabled) async {}

  Future<void> setWorkspaceRecovery(bool enabled) async {}

  Future<void> setDirectEngine(bool enabled) async {}

  Future<void> setTawcEngine(bool enabled) async {}

  Future<List<String>> failureLog() async => const [];

  Future<StorageAccess> storageStatus() async => StorageAccess.fromMap(const {});

  Future<StorageAccess> requestStorage() async => StorageAccess.fromMap(const {});

  Future<bool> openAllFilesAccess() async => false;

  Future<bool?> batteryExempt() async => null;

  Future<bool?> requestBatteryExempt() async => null;

  Future<BackgroundSettingsInfo?> backgroundSettings() async => null;

  Future<String?> openBackgroundSettings() async => null;

  Future<String?> openVendorSettings(String vendorSwitch) async => null;

  Future<bool?> networkMetered() async => null;

  Future<void> stop() async {}

  Future<void> reopenApp() async {}

  /// iOS: whether a local turn is running, which is what asks the system to let it go on.
  /// This is a shell signal, not the engine: the native side (ios/Runner/ContinuedRun.swift)
  /// still answers it, so the channel call stays. No plugin on Android: the caller swallows
  /// the MissingPluginException.
  Future<void> setTurnRunning(bool running) =>
      const MethodChannel('dsh/runtime').invokeMethod<void>('turnRunning', {'running': running});

  Future<void> reset({ResetKeep keep = const ResetKeep()}) async {}

  Future<void> resetAndReinstall({ResetKeep keep = const ResetKeep()}) async {}

  Future<List<String>> logs({int lines = 500}) async => const [];

  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) async =>
      const RuntimeLogSnapshot([], 0);
}
