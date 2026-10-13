import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/pre_start_check_service.dart';
import '../domain/pre_start_answer.dart';
import '../domain/pre_start_check.dart';
import 'pre_start_check_screen.dart';
import 'pre_start_outcome_style.dart';

/// The worker dashboard's Pre-Start card. Before today's check: a bright
/// prompt with a "Start Check" button. After: today's GO / GO corrected /
/// STOP result, with the worker's own notes for anything they answered No.
class WorkerPreStartCard extends StatefulWidget {
  const WorkerPreStartCard({
    super.key,
    required this.organizationId,
    required this.service,
  });

  final String organizationId;
  final PreStartCheckService service;

  @override
  State<WorkerPreStartCard> createState() => _WorkerPreStartCardState();
}

class _WorkerPreStartCardState extends State<WorkerPreStartCard> {
  late Future<MyPreStartCheck> _future = _load();

  Future<MyPreStartCheck> _load() =>
      widget.service.getMyPreStartCheck(organizationId: widget.organizationId);

  void _reload() => setState(() {
    _future = _load();
  });

  Future<void> _start(MyPreStartCheck check) async {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => PreStartCheckScreen(
          organizationId: widget.organizationId,
          check: check,
          service: widget.service,
        ),
      ),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MyPreStartCheck>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.error_outline, color: AppColors.danger),
              title: Text(
                snapshot.error.toString(),
                style: AppTextStyles.bodyMedium,
              ),
              trailing: TextButton(
                onPressed: _reload,
                child: const Text('Retry'),
              ),
            ),
          );
        }
        final check = snapshot.data;
        if (check == null) {
          return const Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        final submission = check.submission;
        if (submission != null) return _done(submission);
        return _todo(check);
      },
    );
  }

  Widget _todo(MyPreStartCheck check) {
    const accent = AppColors.secondary;
    return Card(
      margin: EdgeInsets.zero,
      color: Color.alphaBlend(
        accent.withValues(alpha: 0.14),
        Theme.of(context).colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: accent, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.checklist_rtl,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                const Expanded(
                  child: Text(
                    'Do your Pre-Start Check',
                    style: AppTextStyles.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${check.questions.length} quick questions before you start '
              'work${check.siteName.isEmpty ? '' : ' at ${check.siteName}'}.',
              style: AppTextStyles.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.go,
                foregroundColor: Colors.white,
              ),
              onPressed: () => _start(check),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start Check'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _done(PreStartSubmission submission) {
    final issues = submission.issues;
    final foreground = AppColors.onColor(submission.outcome.color);
    return PreStartOutcomePanel(
      outcome: submission.outcome,
      footer: issues.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final issue in issues)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${issue.answer == PreStartAnswer.fixed ? 'Fixed' : 'Not fixed'}: '
                      '${issue.prompt}'
                      '${issue.note == null ? '' : ' — ${issue.note}'}',
                      style: TextStyle(color: foreground),
                    ),
                  ),
              ],
            ),
    );
  }
}
