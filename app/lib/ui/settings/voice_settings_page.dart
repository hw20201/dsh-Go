import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_voice_source.dart';
import '../../l10n/l10n.dart';
import '../../speech/speech_audio.dart';
import '../../speech/speech_settings.dart';
import '../../state/android_features.dart';
import '../../state/streaming_asr_model_state.dart';
import '../../state/streaming_asr_state.dart' show SystemAsrReadiness, ohosStreamingAsrReadyProvider;
import '../../state/voice_settings.dart';
import '../../state/voice_state.dart';
import '../common/app_dialog.dart';
import '../companion/companion_voice_page.dart';
import '../providers/provider_widgets.dart';
import '../speech/call/call_backdrop.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'settings_widgets.dart';

String voiceModeLabel(L10n l10n, VoiceMode mode) => switch (mode) {
  VoiceMode.auto => l10n.voiceModeAuto,
  VoiceMode.deepseek => l10n.voiceModeDeepseek,
  VoiceMode.system => l10n.voiceModeSystem,
  VoiceMode.engine => l10n.voiceModeEngine,
  VoiceMode.cloud => l10n.voiceModeCloud,
};

/// The 朗读 voice in a few words, for its row.
String speechVoiceLabel(L10n l10n, CompanionVoiceSettings? voice) => switch (voice) {
  null => '',
  CompanionVoiceSettings(source: CompanionVoiceSource.deepseek, deepseekVoice: 'tide') =>
    '${l10n.speechVoiceDeepseek} · ${l10n.speechVoiceTideShort}',
  CompanionVoiceSettings(source: CompanionVoiceSource.deepseek) =>
    '${l10n.speechVoiceDeepseek} · ${l10n.speechVoiceStellaShort}',
  CompanionVoiceSettings(source: CompanionVoiceSource.system) => l10n.companionVoiceSystem,
  CompanionVoiceSettings(source: CompanionVoiceSource.preset) => voice.presetInfo.name,
  CompanionVoiceSettings(source: CompanionVoiceSource.openai) => l10n.companionVoiceOpenai,
  CompanionVoiceSettings(source: CompanionVoiceSource.custom) => l10n.companionVoiceCustom,
};

const _modelCardPadding = EdgeInsets.fromLTRB(SettingsMetrics.inset, 14, SettingsMetrics.inset, SettingsMetrics.inset);

String _modelMegabytes(int bytes) => '${(bytes / 1000000).round()} MB';

class VoiceSettingsTile extends ConsumerWidget {
  const VoiceSettingsTile({super.key, this.tint = 0});
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsTile(
    key: const ValueKey('settings-voice'),
    icon: AppIcons.voice,
    tint: tint,
    spot: SettingsIndex.entry(SettingsPageId.voice),
    value: Text(voiceModeLabel(context.l10n, wordsForIos ? VoiceMode.system : ref.watch(voiceSettingsProvider))),
    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceSettingsPage())),
  );
}

class VoiceSettingsPage extends ConsumerStatefulWidget {
  const VoiceSettingsPage({super.key});

  @override
  ConsumerState<VoiceSettingsPage> createState() => _VoiceSettingsPageState();
}

class _VoiceSettingsPageState extends ConsumerState<VoiceSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final harmonyLocal = ref.watch(harmonyLocalVoiceProvider);
    final stored = ref.watch(voiceSettingsProvider);
    final selected = harmonyLocal ? voiceModeOnHarmonyLocal(stored) : stored;
    final ohos = ref.watch(operatingSystemProvider) == 'ohos';
    final languages = ohos ? ref.watch(voiceCapabilitiesProvider).value?.languages : null;
    final chineseOnly = languages != null && languages.isNotEmpty && languages.every((l) => l.startsWith('zh'));
    final call = ref.watch(callSettingsProvider);
    final calls = ref.read(callSettingsProvider.notifier);
    return AppPage.list(
      title: l10n.voiceSettingsTitle,
      children: [
        SettingsSection(
          title: l10n.speechReadSection,
          footer: Text(l10n.speechReadFooter),
          children: [
            SettingsTile(
              key: const ValueKey('speech-voice'),
              icon: AppIcons.readAloud,
              tinted: false,
              spot: SettingsIndex.entry(SettingsPageId.voiceReading),
              value: Text(speechVoiceLabel(l10n, ref.watch(speechVoiceSettingsProvider))),
              onTap: () =>
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const CompanionVoicePage(shared: true))),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.voiceModeSection,
          footer: harmonyLocal ? Text(l10n.harmonyVoiceLocalLine, key: const ValueKey('voice-local-line')) : null,
          children: [
            if (wordsForIos)
              SettingsTile(title: voiceModeLabel(l10n, VoiceMode.system), subtitle: l10n.iosVoiceSystemHint),
            if (!wordsForIos)
              for (final mode in VoiceMode.values)
                if (!harmonyLocal || mode != VoiceMode.engine)
                  Semantics(
                    checked: selected == mode,
                    inMutuallyExclusiveGroup: true,
                    child: SettingsTile(
                      key: ValueKey('voice-mode-${mode.name}'),
                      title: voiceModeLabel(l10n, mode),
                      subtitle: switch (mode) {
                        VoiceMode.auto => harmonyLocal ? l10n.harmonyVoiceAutoHint : l10n.voiceModeAutoHint,
                        VoiceMode.deepseek => l10n.voiceModeDeepseekHint,
                        VoiceMode.system =>
                          !ohos
                              ? l10n.voiceModeSystemHint
                              : chineseOnly
                              ? l10n.harmonyVoiceSystemHintChinese
                              : l10n.harmonyVoiceSystemHint,
                        VoiceMode.engine => l10n.voiceModeEngineHint,
                        VoiceMode.cloud => l10n.voiceModeCloudHint,
                      },
                      trailing: SizedBox.square(
                        dimension: 32,
                        child: Icon(selected == mode ? AppIcons.radioOn : AppIcons.radioOff, size: 24),
                      ),
                      onTap: () => unawaited(ref.read(voiceSettingsProvider.notifier).setMode(mode)),
                    ),
                  ),
          ],
        ),
        if (!wordsForIos && selected == VoiceMode.cloud) const _CloudAsrForm(),
        if (!wordsForIos)
          SettingsSection(
            title: l10n.speechLiveSection,
            footer: Text(ohos ? l10n.speechLiveSystemFooter : l10n.speechLiveFooter),
            // HarmonyOS captions use its own recognizer: nothing to download.
            children: [ohos ? const SystemAsrCard() : const StreamingAsrModelCard()],
          ),
        SettingsSection(
          title: l10n.speechCallSection,
          footer: Text(l10n.speechCallFooter),
          children: [
            SettingsTile(
              key: const ValueKey('speech-call-backdrop'),
              title: l10n.speechBackdropTitle,
              value: Text(switch (call.backdrop) {
                CallBackdrop.sea => l10n.speechBackdropSea,
                CallBackdrop.image => l10n.speechBackdropImage,
                CallBackdrop.companion => l10n.speechBackdropCompanion,
              }),
              onTap: () => unawaited(showCallBackdropSheet(context)),
            ),
            SettingsSwitchTile(
              key: const ValueKey('speech-call-barge-in'),
              title: l10n.speechCallBargeIn,
              subtitle: l10n.speechCallBargeInHint,
              value: call.bargeIn,
              onChanged: (on) => unawaited(calls.edit((saved) => saved.copyWith(bargeIn: on))),
            ),
            SettingsSegmentTile<CallPause>(
              key: const ValueKey('speech-call-pause'),
              title: l10n.speechCallPause,
              subtitle: l10n.speechCallPauseHint,
              segments: callPauseSegments(l10n),
              selected: call.pause,
              onChanged: (pause) => unawaited(calls.edit((saved) => saved.copyWith(pause: pause))),
            ),
            SettingsSwitchTile(
              key: const ValueKey('speech-call-spoken'),
              title: l10n.speechCallSpoken,
              subtitle: l10n.speechCallSpokenHint,
              value: call.spoken,
              onChanged: (on) => unawaited(calls.edit((saved) => saved.copyWith(spoken: on))),
            ),
            SettingsSwitchTile(
              key: const ValueKey('speech-call-speaker'),
              title: l10n.speechCallSpeaker,
              subtitle: l10n.speechCallSpeakerHint,
              value: call.speaker,
              onChanged: (on) => unawaited(calls.edit((saved) => saved.copyWith(speaker: on))),
            ),
            SettingsSwitchTile(
              key: const ValueKey('speech-call-cue'),
              title: l10n.speechCallCue,
              subtitle: l10n.speechCallCueHint,
              value: call.cue,
              onChanged: (on) => unawaited(calls.edit((saved) => saved.copyWith(cue: on))),
            ),
          ],
        ),
      ],
    );
  }
}

/// The person's own cloud recognizer (OpenAI-compatible): saved as typed.
class _CloudAsrForm extends ConsumerStatefulWidget {
  const _CloudAsrForm();

  @override
  ConsumerState<_CloudAsrForm> createState() => _CloudAsrFormState();
}

class _CloudAsrFormState extends ConsumerState<_CloudAsrForm> {
  final _base = TextEditingController();
  final _key = TextEditingController();
  final _model = TextEditingController();
  late final CloudAsrController _store = ref.read(cloudAsrProvider.notifier);
  Timer? _save;
  bool _filled = false;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    unawaited(
      _store.ready().then((s) {
        if (!mounted) return;
        _base.text = s.base;
        _key.text = s.key;
        _model.text = s.model;
        setState(() => _filled = true);
      }),
    );
  }

  CloudAsrSettings get _typed =>
      CloudAsrSettings(base: _base.text.trim(), key: _key.text.trim(), model: _model.text.trim());

  @override
  void dispose() {
    final pending = _save?.isActive ?? false;
    _save?.cancel();
    if (pending) {
      final next = _typed;
      scheduleMicrotask(() => unawaited(_store.update(next)));
    }
    _base.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  void _edited() {
    if (!_filled) return;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 400), () => unawaited(_store.update(_typed)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Widget field(TextEditingController c, String hint, {bool secret = false, bool url = false}) => TextField(
      controller: c,
      // Not before the saved values are in: they would replace what was typed.
      enabled: _filled,
      onChanged: (_) => _edited(),
      obscureText: secret && _obscure,
      obscuringCharacter: '•',
      autocorrect: false,
      enableSuggestions: !secret,
      enableIMEPersonalizedLearning: !secret,
      keyboardType: secret ? TextInputType.visiblePassword : (url ? TextInputType.url : TextInputType.text),
      decoration: InputDecoration(
        hintText: hint,
        suffixIcon: secret
            ? IconButton(
                tooltip: _obscure ? l10n.engineFieldShow : l10n.commonHide,
                icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                onPressed: () => setState(() => _obscure = !_obscure),
              )
            : null,
      ),
    );
    return SettingsSection(
      key: const ValueKey('voice-cloud-form'),
      title: l10n.voiceCloudSection,
      footer: Text(l10n.voiceCloudFooter),
      children: [
        FormFieldGroup(
          children: [
            FormFieldBlock(
              label: l10n.companionVoiceBase,
              helper: l10n.voiceCloudBaseHelper,
              child: field(_base, 'https://api.siliconflow.cn/v1', url: true),
            ),
            FormFieldBlock(label: 'API Key', child: field(_key, 'sk-…', secret: true)),
            FormFieldBlock(
              label: l10n.companionVoiceModel,
              helper: l10n.voiceCloudModelHelper,
              child: field(_model, 'FunAudioLLM/SenseVoiceSmall'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The streaming recognizer for live captions: download (about 198 MB), progress, delete.
/// HarmonyOS's own recognizer for live captions: what its probe says now, and a
/// retry when it was busy or failed. It never downloads or deletes anything.
class SystemAsrCard extends ConsumerWidget {
  const SystemAsrCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final probe = ref.watch(ohosStreamingAsrReadyProvider);
    final (status, statusColor, note) = switch (probe) {
      AsyncData(value: SystemAsrReadiness.ready) => (
        l10n.voiceModelReady,
        colors.success,
        l10n.speechLiveSystemReadyNote,
      ),
      AsyncData(value: SystemAsrReadiness.busy) => (
        l10n.speechLiveSystemBusy,
        theme.colorScheme.onSurfaceVariant,
        l10n.speechLiveSystemBusyNote,
      ),
      AsyncError(:final error) => (l10n.voiceModelFailed, colors.danger, l10n.speechLiveSystemFailedNote('$error')),
      _ => ('', colors.textTertiary, null),
    };
    final retry = probe is AsyncError || probe.value == SystemAsrReadiness.busy;
    return Padding(
      key: const ValueKey('live-system-card'),
      padding: _modelCardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(child: Text(l10n.speechLiveSystemName, style: settingsTitleStyle(context))),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  status,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodyMedium?.copyWith(color: statusColor),
                ),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 6),
            Text(note, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
          ],
          if (retry) ...[
            const SizedBox(height: 14),
            OutlinedButton(
              key: const ValueKey('live-system-retry'),
              onPressed: () => ref.invalidate(ohosStreamingAsrReadyProvider),
              child: Text(l10n.commonRetry),
            ),
          ],
        ],
      ),
    );
  }
}

class StreamingAsrModelCard extends ConsumerWidget {
  const StreamingAsrModelCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final model = ref.watch(streamingAsrModelProvider);
    final controller = ref.read(streamingAsrModelProvider.notifier);
    final total = _modelMegabytes(model.totalBytes);
    final partial = model.doneBytes > 0 && model.doneBytes < model.totalBytes;
    final (status, statusColor) = switch (model.status) {
      StreamingAsrModelStatus.checking ||
      StreamingAsrModelStatus.cancelling ||
      StreamingAsrModelStatus.deleting => ('', colors.textTertiary),
      StreamingAsrModelStatus.absent => (l10n.voiceModelAbsent, theme.colorScheme.onSurfaceVariant),
      StreamingAsrModelStatus.downloading => ('${(model.fraction * 100).floor()}%', theme.colorScheme.onSurfaceVariant),
      StreamingAsrModelStatus.verifying => (l10n.voiceModelPreparing, theme.colorScheme.onSurfaceVariant),
      StreamingAsrModelStatus.ready when model.blocked => (l10n.speechLiveBlocked, colors.danger),
      StreamingAsrModelStatus.ready => (l10n.voiceModelReady, colors.success),
      StreamingAsrModelStatus.failed => (l10n.voiceModelFailed, colors.danger),
    };
    final note = switch (model.status) {
      StreamingAsrModelStatus.ready when model.blocked => l10n.speechLiveBlockedNote,
      StreamingAsrModelStatus.ready => l10n.speechLiveReadyNote(total),
      StreamingAsrModelStatus.downloading ||
      StreamingAsrModelStatus.absent when partial => l10n.voiceModelBytes(_modelMegabytes(model.doneBytes), total),
      StreamingAsrModelStatus.absent || StreamingAsrModelStatus.failed => l10n.speechLiveAbsentNote(total),
      _ => null,
    };
    final Widget? action = switch (model.status) {
      StreamingAsrModelStatus.absent || StreamingAsrModelStatus.failed => FilledButton(
        key: const ValueKey('live-model-download'),
        onPressed: () => unawaited(controller.download()),
        child: Text(partial ? l10n.voiceModelResume : l10n.voiceModelDownload),
      ),
      StreamingAsrModelStatus.downloading || StreamingAsrModelStatus.verifying => OutlinedButton(
        key: const ValueKey('live-model-cancel'),
        onPressed: () => unawaited(controller.cancel()),
        child: Text(l10n.commonCancel),
      ),
      StreamingAsrModelStatus.ready => OutlinedButton(
        key: const ValueKey('live-model-delete'),
        style: OutlinedButton.styleFrom(foregroundColor: colors.danger),
        onPressed: () => unawaited(_delete(context, controller)),
        child: Text(l10n.commonDelete),
      ),
      _ => null,
    };
    return Padding(
      key: const ValueKey('live-model-card'),
      padding: _modelCardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(child: Text(l10n.speechLiveName, style: settingsTitleStyle(context))),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  status,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodyMedium?.copyWith(color: statusColor),
                ),
              ),
            ],
          ),
          if (model.status == StreamingAsrModelStatus.downloading ||
              model.status == StreamingAsrModelStatus.verifying) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: AppShape.radiusXs,
              child: LinearProgressIndicator(
                value: model.status == StreamingAsrModelStatus.downloading ? model.fraction : null,
                minHeight: 4,
              ),
            ),
          ],
          if (note != null) ...[
            const SizedBox(height: 6),
            Text(note, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
          ],
          if (action != null) ...[const SizedBox(height: 14), action],
        ],
      ),
    );
  }

  static Future<void> _delete(BuildContext context, StreamingAsrModelController controller) async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.speechLiveDeleteTitle),
        content: Text(l10n.speechLiveDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok == true) await controller.delete();
  }
}
