import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/choice_list.dart';
import '../../../core/widgets/feature_header.dart';
import '../domain/incident.dart';
import '../domain/incident_reporting.dart';

/// "Reporting deadlines" on an incident — the Safety Plan's Section 8: the
/// reporting level, then each step it needs with its deadline, shown as
/// done, due (with time left) or OVERDUE. A Site Manager/Admin ([canEdit])
/// sets the level and ticks steps off.
class IncidentReportingSection extends StatelessWidget {
  const IncidentReportingSection({
    super.key,
    required this.incident,
    required this.canEdit,
    required this.busy,
    required this.onChooseLevel,
    required this.onStep,
    this.now,
  });

  final Incident incident;
  final bool canEdit;
  final bool busy;
  final VoidCallback onChooseLevel;

  /// Tick ([done] true) or un-tick a step.
  final void Function(ReportingStep step, bool done) onStep;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final level = incident.reportingLevel;
    final current = (now ?? DateTime.now)();
    final editable = canEdit && !incident.isClosed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FeatureSectionTitle(
          title: 'Reporting deadlines',
          icon: Icons.timer_outlined,
          color: AppColors.stop,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (level == null)
          _Box(
            color: AppColors.stop,
            icon: Icons.priority_high,
            title: 'Reporting level not set',
            detail: editable
                ? 'Choose how serious it is to see who must be told and by '
                      'when. The COR must be told as soon as it happens.'
                : 'A Site Manager sets this. The COR must be told as soon as '
                      'it happens.',
          )
        else
          _Box(
            color: AppColors.analytics,
            icon: Icons.rule,
            title: level.label,
            detail: level.description,
          ),
        if (editable) ...[
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onChooseLevel,
              icon: const Icon(Icons.tune),
              label: Text(
                level == null ? 'Set reporting level' : 'Change level',
              ),
            ),
          ),
        ],
        for (final step in incident.reportingSteps) ...[
          const SizedBox(height: AppSpacing.sm),
          _StepRow(
            step: step,
            now: current,
            canEdit: editable,
            busy: busy,
            onTick: (done) => onStep(step, done),
          ),
        ],
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({
    required this.color,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm + 4),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.10),
          Theme.of(context).colorScheme.surface,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.bodyLarge.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(detail, style: AppTextStyles.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.now,
    required this.canEdit,
    required this.busy,
    required this.onTick,
  });

  final ReportingStep step;
  final DateTime now;
  final bool canEdit;
  final bool busy;
  final ValueChanged<bool> onTick;

  @override
  Widget build(BuildContext context) {
    final overdue = step.isOverdue(now);
    final color = step.isDone
        ? AppColors.go
        : overdue
        ? AppColors.stop
        : AppColors.warning;
    final String status;
    if (step.isDone) {
      status =
          'Done ${formatReportingTime(step.doneAt!)}'
          '${step.doneByName == null ? '' : ' by ${step.doneByName}'}'
          '${step.note == null ? '' : ' — ${step.note}'}';
    } else if (_immediateSteps.contains(step.id)) {
      status = 'Due immediately — not done yet';
    } else if (overdue) {
      status =
          'OVERDUE — was due ${formatReportingTime(step.dueAt)} '
          '(${relativeTime(step.dueAt, now)})';
    } else {
      status =
          'Due ${formatReportingTime(step.dueAt)} '
          '(${relativeTime(step.dueAt, now)})';
    }
    return ChoiceTile(
      multi: true,
      title: step.label,
      subtitle: status,
      icon: step.isDone
          ? Icons.check_circle
          : overdue
          ? Icons.error
          : Icons.timer_outlined,
      color: color,
      selected: step.isDone,
      trailingLabel: canEdit ? (step.isDone ? 'Undo' : 'Mark done') : null,
      onTap: canEdit && !busy ? () => onTick(!step.isDone) : null,
    );
  }
}

/// Steps due the moment the incident happens.
const _immediateSteps = {'notifyCor', 'immediatePhone', 'sealSite'};

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// e.g. "Tue 13 Oct 14:30".
String formatReportingTime(DateTime time) {
  final local = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${_weekdays[local.weekday - 1]} ${local.day} '
      '${_months[local.month - 1]} ${two(local.hour)}:${two(local.minute)}';
}

/// Picks the reporting level — a bottom sheet of the plan's levels, each
/// with when it applies. Returns the chosen level, or null.
Future<IncidentReportingLevel?> pickReportingLevel(
  BuildContext context, {
  IncidentReportingLevel? current,
}) {
  return showModalBottomSheet<IncidentReportingLevel>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: ChoiceList<IncidentReportingLevel>(
          label: 'How serious is it for reporting?',
          items: [
            for (final level in IncidentReportingLevel.values)
              ChoiceItem(
                value: level,
                title: level.label,
                subtitle: level.description,
                icon: switch (level) {
                  IncidentReportingLevel.immediate => Icons.crisis_alert,
                  IncidentReportingLevel.lostTime => Icons.event_busy,
                  IncidentReportingLevel.medical => Icons.local_hospital,
                  IncidentReportingLevel.minorDamage => Icons.broken_image,
                  IncidentReportingLevel.firstAid => Icons.healing,
                },
                color: switch (level) {
                  IncidentReportingLevel.immediate => AppColors.stop,
                  IncidentReportingLevel.lostTime => AppColors.hazards,
                  IncidentReportingLevel.medical => AppColors.warning,
                  IncidentReportingLevel.minorDamage => AppColors.projects,
                  IncidentReportingLevel.firstAid => AppColors.go,
                },
              ),
          ],
          selected: current,
          allowDeselect: false,
          onChanged: (value) => Navigator.of(context).pop(value),
        ),
      ),
    ),
  );
}
