import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../domain/pre_start_outcome.dart';
import 'pre_start_outcome_style.dart';

/// The Foreman's crew result, chosen when completing a Daily Safety
/// Meeting.
typedef CrewOutcomeResult = ({PreStartOutcome outcome, String? note});

/// Asks the Foreman for the crew's GO / GO corrected / STOP result before a
/// meeting is completed. A note is required for anything but GO. Returns
/// null if the Foreman cancels — the meeting is then left in progress.
Future<CrewOutcomeResult?> showCrewOutcomeDialog(BuildContext context) =>
    showDialog<CrewOutcomeResult>(
      context: context,
      builder: (_) => const _CrewOutcomeDialog(),
    );

class _CrewOutcomeDialog extends StatefulWidget {
  const _CrewOutcomeDialog();

  @override
  State<_CrewOutcomeDialog> createState() => _CrewOutcomeDialogState();
}

class _CrewOutcomeDialogState extends State<_CrewOutcomeDialog> {
  PreStartOutcome? _outcome;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _needsNote => _outcome != null && _outcome != PreStartOutcome.go;

  bool get _canConfirm =>
      _outcome != null && (!_needsNote || _note.text.trim().isNotEmpty);

  static String _hint(PreStartOutcome outcome) => switch (outcome) {
    PreStartOutcome.go => 'The crew is safe to start work.',
    PreStartOutcome.goCorrected =>
      'Problems were found and fixed before work started.',
    PreStartOutcome.stop =>
      'Work must not start. Site Managers will be notified.',
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Today's crew result"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Can the crew start work safely?',
              style: AppTextStyles.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            for (final outcome in PreStartOutcome.values) ...[
              _OutcomeOption(
                outcome: outcome,
                hint: _hint(outcome),
                selected: _outcome == outcome,
                onTap: () => setState(() => _outcome = outcome),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (_needsNote)
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _outcome == PreStartOutcome.stop
                      ? 'Why is work stopped?'
                      : 'What was found and fixed?',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _canConfirm
              ? () => Navigator.of(context).pop((
                  outcome: _outcome!,
                  note: _needsNote ? _note.text.trim() : null,
                ))
              : null,
          child: const Text('Complete Meeting'),
        ),
      ],
    );
  }
}

class _OutcomeOption extends StatelessWidget {
  const _OutcomeOption({
    required this.outcome,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  final PreStartOutcome outcome;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = outcome.color;
    final foreground = selected ? AppColors.onColor(color) : null;
    return Material(
      color: selected ? color : color.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm + 4),
          child: Row(
            children: [
              Icon(outcome.icon, color: foreground ?? color, size: 28),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      outcome.label,
                      style: AppTextStyles.titleLarge.copyWith(
                        color:
                            foreground ??
                            AppColors.readable(
                              color,
                              Theme.of(context).brightness,
                            ),
                      ),
                    ),
                    Text(
                      hint,
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: foreground,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
