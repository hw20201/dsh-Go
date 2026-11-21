// Session log upload is honoured by the host itself. Client-only web
// preferences are no longer exposed by the native app.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'namespace_copy.dart';
import 'schema_form.dart';

SchemaFieldSpec _field(String ns, String key) => SchemaFieldSpec(ns, [key], copy: copyOf(ns, [key]));

class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({super.key});

  static const namespaces = ['session-log-deepseek'];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EngineFormScaffold(
      title: l10n.engineGeneralTitle,
      namespaces: namespaces,
      missingTitle: l10n.engineGeneralMissing,
      missingBody: l10n.engineSettingsVersionRequired,
      builder: (context, settings) => schemaFormGroups([
        if (settings.served('session-log-deepseek'))
          SchemaFormSection(title: l10n.engineGeneralData, fields: [_field('session-log-deepseek', 'enabled')]),
      ], settings: settings),
    );
  }
}
