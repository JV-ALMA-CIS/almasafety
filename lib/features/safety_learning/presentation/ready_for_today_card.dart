import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/worker_learning_repository.dart';
import '../data/worker_learning_service.dart';
import '../domain/todays_safety_readiness.dart';
import '../domain/worker_learning_record.dart';
import '../domain/worker_learning_status.dart';
import 'todays_safety_readiness_screen.dart';

/// The worker dashboard's primary card: today's project/site/activity,
/// meeting status, and how many "before meeting" / "before work" items
/// remain — never the whole learning inventory. "Continue Learning" opens
/// [TodaysSafetyReadinessScreen].
///
/// Counts drop live as the worker completes items (filtered through
/// [WorkerLearningRepository.watchMine]); the server answer is re-fetched
/// when the worker returns from the readiness screen.
class ReadyForTodayCard extends StatefulWidget {
  const ReadyForTodayCard({
    super.key,
    required this.organizationId,
    required this.workerUid,
    required this.workerLearningService,
    required this.workerLearningRepository,
    this.onContinue,
  });

  final String organizationId;
  final String workerUid;
  final WorkerLearningService workerLearningService;
  final WorkerLearningRepository workerLearningRepository;

  /// Opens the full readiness view. Defaults to pushing
  /// [TodaysSafetyReadinessScreen]; injectable for tests.
  final Future<void> Function(BuildContext context)? onContinue;

  @override
  State<ReadyForTodayCard> createState() => _ReadyForTodayCardState();
}

class _ReadyForTodayCardState extends State<ReadyForTodayCard> {
  late Future<TodaysSafetyReadiness> _future = _load();
  late final Stream<List<WorkerLearningRecord>> _records = widget
      .workerLearningRepository
      .watchMine(widget.workerUid);

  Future<TodaysSafetyReadiness> _load() => loadTodaysSafetyReadiness(
    widget.workerLearningService,
    widget.organizationId,
  );

  void _reload() => setState(() {
    _future = _load();
  });

  Future<void> _continue() async {
    final onContinue = widget.onContinue;
    if (onContinue != null) {
      await onContinue(context);
    } else {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => TodaysSafetyReadinessScreen(
            organizationId: widget.organizationId,
            workerUid: widget.workerUid,
            workerLearningService: widget.workerLearningService,
            workerLearningRepository: widget.workerLearningRepository,
          ),
        ),
      );
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TodaysSafetyReadiness>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.error_outline, color: AppColors.danger),
              title: const Text("Could not load today's readiness."),
              trailing: TextButton(
                onPressed: _reload,
                child: const Text('Retry'),
              ),
            ),
          );
        }
        final fetched = snapshot.data;
        if (fetched == null) {
          return const Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        return StreamBuilder<List<WorkerLearningRecord>>(
          stream: _records,
          builder: (context, recordSnapshot) {
            final readiness = fetched.withoutCompleted({
              for (final record
                  in recordSnapshot.data ?? const <WorkerLearningRecord>[])
                if (record.status == WorkerLearningStatus.completed)
                  record.learningId,
            });
            return _ReadinessCard(readiness: readiness, onContinue: _continue);
          },
        );
      },
    );
  }
}

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard({required this.readiness, required this.onContinue});

  final TodaysSafetyReadiness readiness;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final ready = readiness.isReady;
    // Required learning that is neither "needed today" nor "before work"
    // (the requirement left both off) — still required, so it is always
    // counted here rather than hidden behind "You're ready for today".
    final otherRequired = readiness.additional.length;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ReadinessScopeSummary(readiness: readiness),
            const SizedBox(height: AppSpacing.md),
            if (ready) ...[
              Row(
                children: [
                  const Icon(Icons.verified_outlined, color: AppColors.success),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      otherRequired == 0
                          ? "You're ready for today"
                          : "You're ready for today's meeting and work",
                      style: AppTextStyles.bodyLarge,
                    ),
                  ),
                ],
              ),
              if (otherRequired > 0) ...[
                const SizedBox(height: AppSpacing.sm),
                _CountRow(
                  label: 'Other required learning',
                  count: otherRequired,
                  color: AppColors.learning,
                ),
              ],
            ] else ...[
              _CountRow(
                label: 'Needed today',
                count: readiness.beforeMeeting.length,
                color: AppColors.danger,
              ),
              const SizedBox(height: AppSpacing.xs),
              _CountRow(
                label: 'Before work',
                count: readiness.beforeWork.length,
                color: AppColors.warning,
              ),
              if (otherRequired > 0) ...[
                const SizedBox(height: AppSpacing.xs),
                _CountRow(
                  label: 'Other required learning',
                  count: otherRequired,
                  color: AppColors.learning,
                ),
              ],
            ],
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: ready && otherRequired == 0
                  ? OutlinedButton(
                      onPressed: onContinue,
                      child: const Text("View today's learning"),
                    )
                  : ElevatedButton(
                      onPressed: onContinue,
                      child: const Text('Continue Learning'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow({
    required this.label,
    required this.count,
    required this.color,
  });

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final done = count == 0;
    return Row(
      children: [
        Icon(
          done ? Icons.check_circle_outline : Icons.radio_button_unchecked,
          color: done ? AppColors.success : color,
          size: 20,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(label, style: AppTextStyles.bodyLarge)),
        Text(
          done ? 'Done' : '$count ${count == 1 ? 'item' : 'items'} remaining',
          style: AppTextStyles.bodyMedium,
        ),
      ],
    );
  }
}
