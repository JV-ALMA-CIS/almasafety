import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/pre_start_check_service.dart';
import '../domain/pre_start_answer.dart';
import '../domain/pre_start_check.dart';
import '../domain/pre_start_outcome.dart';
import 'pre_start_outcome_style.dart';

/// A Foreman's view of today's Pre-Start Checks at one site: counts of GO /
/// GO corrected / STOP / not done, then each worker who needs attention —
/// STOP first, with their "No" answers and notes, then GO corrected, then
/// anyone who has not done their check yet.
///
/// Warns only: nothing here blocks attendance (see
/// `pre_start_check_callable.ts`'s header note).
class CrewPreStartCard extends StatefulWidget {
  const CrewPreStartCard({
    super.key,
    required this.organizationId,
    required this.siteId,
    required this.service,
  });

  final String organizationId;
  final String siteId;
  final PreStartCheckService service;

  @override
  State<CrewPreStartCard> createState() => _CrewPreStartCardState();
}

class _CrewPreStartCardState extends State<CrewPreStartCard> {
  late Future<List<CrewPreStartRow>> _future = _load();

  Future<List<CrewPreStartRow>> _load() =>
      widget.service.getSiteCrewPreStartChecks(
        organizationId: widget.organizationId,
        siteId: widget.siteId,
      );

  void _reload() => setState(() {
    _future = _load();
  });

  @override
  void didUpdateWidget(CrewPreStartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.siteId != widget.siteId ||
        oldWidget.organizationId != widget.organizationId) {
      _future = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<CrewPreStartRow>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.error_outline, color: AppColors.danger),
              title: const Text('Could not load Pre-Start Checks.'),
              trailing: TextButton(
                onPressed: _reload,
                child: const Text('Retry'),
              ),
            ),
          );
        }
        final rows = snapshot.data;
        if (rows == null) {
          return const Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        return _content(rows);
      },
    );
  }

  Widget _content(List<CrewPreStartRow> rows) {
    int count(PreStartOutcome? outcome) =>
        rows.where((row) => row.outcome == outcome).length;
    final stops = count(PreStartOutcome.stop);
    final notDone = count(null);

    int rank(CrewPreStartRow row) => switch (row.outcome) {
      PreStartOutcome.stop => 0,
      PreStartOutcome.goCorrected => 1,
      null => 2,
      PreStartOutcome.go => 3,
    };
    final needingAttention =
        rows.where((row) => row.outcome != PreStartOutcome.go).toList()
          ..sort((a, b) => rank(a).compareTo(rank(b)));

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: stops > 0
              ? AppColors.stop
              : AppColors.primaryBright.withValues(alpha: 0.18),
          width: stops > 0 ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    rows.isEmpty
                        ? 'No workers are assigned to active activities at '
                              'this site.'
                        : '${rows.length - notDone} of ${rows.length} '
                              'checked in',
                    style: AppTextStyles.bodyLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (rows.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final outcome in PreStartOutcome.values)
                    StatusBadge(
                      label: '${count(outcome)} ${outcome.label}',
                      color: outcome.color,
                    ),
                  StatusBadge(
                    label: '$notDone Not done',
                    color: notDone > 0
                        ? AppColors.warning
                        : AppColors.textSecondary,
                  ),
                ],
              ),
            ],
            for (final row in needingAttention) ...[
              const SizedBox(height: AppSpacing.sm),
              _CrewRow(row: row),
            ],
          ],
        ),
      ),
    );
  }
}

class _CrewRow extends StatelessWidget {
  const _CrewRow({required this.row});

  final CrewPreStartRow row;

  @override
  Widget build(BuildContext context) {
    final outcome = row.outcome;
    final color = outcome?.color ?? AppColors.warning;
    final name = row.workerName.isEmpty ? row.workerId : row.workerName;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(outcome?.icon ?? Icons.schedule, size: 20, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$name — ${outcome?.label ?? 'Not done yet'}',
                style: AppTextStyles.bodyLarge.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final issue in row.issues)
                Text(
                  '${issue.answer == PreStartAnswer.fixed ? 'Fixed' : 'Not fixed'}: '
                  '${issue.prompt}'
                  '${issue.note == null ? '' : ' — ${issue.note}'}',
                  style: AppTextStyles.bodyMedium,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
