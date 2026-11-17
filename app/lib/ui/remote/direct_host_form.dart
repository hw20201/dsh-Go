import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/direct/direct_link.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../common/discard_guard.dart';
import '../common/smooth_size.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/credential_recovery_dialog.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'link_progress.dart';

/// Add or edit a direct DSH host (server address + launch token, the way DSH
/// Mobile connects), with a "测试连接" that runs the real connect flow and
/// shows each step.
class DirectHostFormPage extends ConsumerStatefulWidget {
  const DirectHostFormPage({super.key, this.existing, this.initialStatus});

  /// Null to add a new host.
  final DirectHostConfig? existing;

  /// Pre-filled test progress (goldens).
  @visibleForTesting
  final HostLinkStatus? initialStatus;

  @override
  ConsumerState<DirectHostFormPage> createState() => _DirectHostFormPageState();
}

class _DirectHostFormPageState extends ConsumerState<DirectHostFormPage> {
  late final String _id = widget.existing?.id ?? DirectHostConfig.newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _serverUrl = TextEditingController(text: widget.existing?.baseUri ?? '');
  late final _basicUser = TextEditingController(text: widget.existing?.basicAuthUser ?? '');
  final _token = TextEditingController();
  final _basicPassword = TextEditingController();
  bool _obscureToken = true;
  bool _obscurePassword = true;
  bool _saving = false;

  /// A problem that isn't about one field (saving failed).
  String? _formError;

  /// What is missing or wrong, shown under the field it is about.
  Map<_F, String> _errors = const {};

  /// To bring the first field with a problem into view.
  final _fieldKeys = {for (final f in _F.values) f: GlobalKey()};

  DirectHostLink? _test;
  StreamSubscription<HostLinkStatus>? _testSub;
  late HostLinkStatus? _testStatus = widget.initialStatus;

  bool get _editing => widget.existing != null;

  /// The form as opened (with the saved secrets once they are read).
  late String _clean;
  late final Listenable _edits = Listenable.merge([_name, _serverUrl, _basicUser, _token, _basicPassword]);

  String _signature() => jsonEncode({
    'name': _name.text,
    'serverUrl': _serverUrl.text,
    'basicUser': _basicUser.text,
    'token': _token.text,
    'basicPassword': _basicPassword.text,
  });

  @override
  void initState() {
    super.initState();
    _clean = _signature();
    if (_editing) unawaited(_loadSecrets());
  }

  Future<void> _loadSecrets() async {
    final clean = jsonDecode(_clean) as Map<String, dynamic>;
    final controllers = [_token, _basicPassword];
    final initial = {for (final controller in controllers) controller: controller.text};
    final edited = <TextEditingController>{};
    void trackEdits() {
      for (final controller in controllers) {
        if (controller.text != initial[controller]) edited.add(controller);
      }
    }

    for (final controller in controllers) {
      controller.addListener(trackEdits);
    }
    final DirectSecrets secrets;
    try {
      secrets = await ref.read(hostsProvider.notifier).loadDirectSecrets(_id);
    } finally {
      for (final controller in controllers) {
        controller.removeListener(trackEdits);
      }
    }
    if (!mounted) return;
    setState(() {
      // Text edits (including paste and an explicit clear) win over a late
      // storage read. Selection-only changes still allow the initial load.
      if (!edited.contains(_token)) _token.text = secrets.token ?? '';
      if (!edited.contains(_basicPassword)) _basicPassword.text = secrets.basicAuthPassword ?? '';
      // Hydrate only the original secret values in the clean baseline. Other
      // fields may have been edited while secure storage was being read.
      _clean = jsonEncode({
        ...clean,
        'token': secrets.token ?? '',
        'basicPassword': secrets.basicAuthPassword ?? '',
      });
    });
  }

  @override
  void dispose() {
    unawaited(_testSub?.cancel());
    unawaited(_test?.close());
    for (final c in [_name, _serverUrl, _basicUser, _token, _basicPassword]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The server address as the client dials it (a missing scheme means
  /// https), or null when it is not an http(s) address at all.
  static Uri? _parseServerUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
    return uri;
  }

  DirectHostConfig? _draft() {
    final url = _parseServerUrl(_serverUrl.text);
    final errors = <_F, String>{
      if (url == null) _F.serverUrl: context.l10n.remoteDirectBadUrl,
      if (_token.text.trim().isEmpty) _F.token: context.l10n.remoteErrDirectTokenMissing,
    };
    setState(() {
      _errors = errors;
      _formError = null;
    });
    if (errors.isNotEmpty) {
      final first = _F.values.firstWhere(errors.containsKey);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _fieldKeys[first]!.currentContext;
        if (target == null || !target.mounted) return;
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0.3,
            duration: AppMotion.of(context, AppMotion.emphasized),
            curve: AppMotion.glide,
          ),
        );
      });
      return null;
    }
    final name = _name.text.trim();
    return DirectHostConfig(
      id: _id,
      name: name.isEmpty ? url!.host : name,
      baseUri: url.toString(),
      basicAuthUser: _basicUser.text.trim().isEmpty ? null : _basicUser.text.trim(),
    );
  }

  /// Typing in a field clears its error.
  void _edited(_F field) {
    if (_errors.containsKey(field)) setState(() => _errors = {..._errors}..remove(field));
  }

  DirectSecrets get _secrets =>
      DirectSecrets(token: _token.text.trim(), basicAuthPassword: _basicPassword.text);

  Future<void> _runTest() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final config = _draft();
    if (config == null) return;
    await _testSub?.cancel();
    await _test?.close();
    final link = DirectHostLink(
      config: config,
      loadSecrets: () async => _secrets,
      retryFirstOpen: false,
    );
    _test = link;
    setState(() => _testStatus = const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    _testSub = link.statuses.listen((s) {
      if (mounted && s.phase != HostLinkPhase.idle) setState(() => _testStatus = s);
    });
    try {
      await link.open();
    } catch (_) {
      // Shown in the progress card.
    } finally {
      await _testSub?.cancel();
      _testSub = null;
      if (identical(_test, link)) {
        _test = null;
        // The terminal status may have painted before async cleanup finished.
        if (mounted) setState(() {});
      }
      // The real connection is a separate link; only our test session closes.
      await link.close();
    }
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final config = _draft();
    if (config == null) return;
    setState(() => _saving = true);
    try {
      final saved = await ref.read(hostsProvider.notifier).saveDirect(config, secrets: _secrets);
      if (!mounted) return;
      if (!saved) {
        setState(() => _formError = context.l10n.commonSaveFailed);
        return;
      }
      Navigator.of(context).pop(config);
    } catch (e) {
      if (mounted) {
        setState(() => _formError = context.l10n.commonSaveFailed);
        // Cleared or not, nothing was saved: the form stays filled in.
        await offerCredentialRecovery(context, ref, e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final name = widget.existing!.name;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.remoteDeleteHostTitle(name)),
        content: Text(context.l10n.remoteDeleteHostBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(hostsProvider.notifier).removeDirect(_id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final testing = _test != null;
    final mono = AppType.mono(size: 15, color: scheme.onSurface, height: 1.4);

    final page = AppPage.list(
      title: _editing ? l10n.remoteDirectEdit : l10n.remoteDirectAdd,
      subtitle: _editing ? null : Text(l10n.remoteDirectHostsIntro),
      // One column, not a lazy list: every field stays built so the first one
      // with a problem can be scrolled into view.
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.remoteHostBasicInfo,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.commonName,
                      child: TextField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(hintText: l10n.remoteHostNameHint),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.serverUrl],
                      error: _errors[_F.serverUrl],
                      label: l10n.remoteDirectServerUrl,
                      helper: l10n.remoteDirectServerUrlHint,
                      child: TextField(
                        controller: _serverUrl,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        style: mono,
                        onChanged: (_) => _edited(_F.serverUrl),
                        decoration: InputDecoration(
                          error: _errors[_F.serverUrl] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: 'DSH',
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      key: _fieldKeys[_F.token],
                      error: _errors[_F.token],
                      label: l10n.remoteDirectToken,
                      helper: l10n.remoteDirectTokenHint,
                      child: TextField(
                        controller: _token,
                        obscureText: _obscureToken,
                        obscuringCharacter: '•',
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        keyboardType: TextInputType.visiblePassword,
                        onChanged: (_) => _edited(_F.token),
                        decoration: InputDecoration(
                          error: _errors[_F.token] == null ? null : const SizedBox.shrink(),
                          suffixIcon: IconButton(
                            tooltip: _obscureToken ? l10n.remoteShow : l10n.commonHide,
                            icon: Icon(_obscureToken ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                            onPressed: () => setState(() => _obscureToken = !_obscureToken),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.remoteDirectBasicAuth,
              footer: Text(l10n.remoteDirectBasicAuthHint),
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.remoteDirectBasicAuthUser,
                      child: TextField(
                        controller: _basicUser,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        style: mono,
                      ),
                    ),
                    FormFieldBlock(
                      label: l10n.remoteDirectBasicAuthPassword,
                      child: TextField(
                        controller: _basicPassword,
                        obscureText: _obscurePassword,
                        obscuringCharacter: '•',
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        keyboardType: TextInputType.visiblePassword,
                        decoration: InputDecoration(
                          suffixIcon: IconButton(
                            tooltip: _obscurePassword ? l10n.remoteShow : l10n.commonHide,
                            icon: Icon(_obscurePassword ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            _Reveal(
              child: _testStatus == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: LinkProgressCard(status: _testStatus!, onRetry: testing ? null : _runTest),
                    ),
            ),
            if (_formError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
              ),
            if (_editing)
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: _delete,
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.remoteDeleteHost),
                ),
              ),
            const SizedBox(height: _FormBar.height),
          ],
        ),
      ],
    );

    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: _FormBar(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: testing || _saving ? null : _runTest,
                    icon: testing
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.testConnection, size: 19),
                    label: Text(testing ? l10n.remoteTesting : l10n.remoteTestConnection),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(onPressed: _saving ? null : _save, child: Text(l10n.commonSave)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The fields of a form page.
enum _F { serverUrl, token }

/// The form page's bottom bar: the actions stay put above the page (and above
/// the keyboard), over a soft fade of the page background.
class _FormBar extends StatelessWidget {
  const _FormBar({required this.children});

  final List<Widget> children;

  /// Room to leave at the end of the page so nothing hides under the bar.
  static const height = 88.0;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom > 0 ? 0.0 : MediaQuery.viewPaddingOf(context).bottom;
    final base = DshSurfaces.of(context).backdropBottom;
    // The page fades out above the keys; under them the bar is solid, so
    // nothing scrolls through a tonal or disabled fill.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [base.withValues(alpha: 0), base],
            ),
          ),
          child: const SizedBox(height: 24),
        ),
        ColoredBox(
          color: base,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottom),
            child: Row(children: children),
          ),
        ),
      ],
    );
  }
}

/// [AnimatedSize] unless animations are off (a zero-duration AnimatedSize
/// re-dirties itself during layout).
class _Reveal extends StatelessWidget {
  const _Reveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) return child;
    return SmoothSize(duration: duration, curve: AppMotion.std, alignment: Alignment.topCenter, child: child);
  }
}
