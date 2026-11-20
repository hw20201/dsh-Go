import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../common/app_sheet.dart';
import '../theme/app_icons.dart';
import 'log_view.dart';

/// Glass sheet with the live runtime log (setup and engine screens).
Future<void> showRuntimeLogSheet(BuildContext context, {String? title}) {
  return showAppSheet<void>(
    context,
    heightFactor: 0.72,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final logs = ref.watch(localRuntimeLogsProvider);
        return Column(
          children: [
            SheetHeader(
              title ?? context.l10n.shellEngineLogs,
              actions: [
                IconButton(
                  tooltip: context.l10n.commonCopy,
                  icon: const Icon(AppIcons.copy, size: 20),
                  onPressed: logs.isEmpty ? null : () => LogActions.copy(context, logs),
                ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
                child: LogView(lines: logs),
              ),
            ),
          ],
        );
      },
    ),
  );
}
