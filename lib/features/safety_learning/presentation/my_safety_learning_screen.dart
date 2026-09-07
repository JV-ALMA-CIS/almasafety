import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/safety_learning_repository.dart';
import '../data/worker_learning_repository.dart';
import '../data/worker_learning_service.dart';
import '../domain/safety_learning.dart';
import '../domain/worker_learning_record.dart';
import '../domain/worker_learning_status.dart';
import 'learning_detail_screen.dart';

/// The signed-in worker's own required-learning list — the first genuinely
/// worker-facing screen in this codebase beyond auth/pending screens.
///
/// Kept extremely simple, per this feature's scope: a flat list with a
/// status badge per item, tapping through to [LearningDetailScreen]. On
/// first build it calls `getMyRequiredLearning` so the merged
/// required-learning view (real [WorkerLearningRecord] documents,
/// materialized lazily server-side) exists before the list stream is read —
/// see [WorkerLearningService.getMyRequiredLearning]'s doc comment.
class MySafetyLearningScreen extends StatefulWidget {
  const MySafetyLearningScreen({
    super.key,
    this.workerLearningRepository,
    this.safetyLearningRepository,
    this.workerLearningService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final WorkerLearningRepository? workerLearningRepository;
  final SafetyLearningRepository? safetyLearningRepository;
  final WorkerLearningService? workerLearningService;

  @override
  State<MySafetyLearningScreen> createState() =>
      _MySafetyLearningScreenState();
}

class _MySafetyLearningScreenState extends State<MySafetyLearningScreen> {
  late final WorkerLearningService _workerLearningService =
      widget.workerLearningService ?? WorkerLearningService();

  String? _organizationId;
  bool _requestedRequiredLearning = false;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final profile = session.profile;
    final organizationId = session.activeOrganizationId;
    final workerUid = profile?.uid;

    if (organizationId == null || workerUid == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Your account is not yet assigned to an organization.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Ensure required learning is materialized for this organization once
    // per screen instance (not once per build) — see this class's doc
    // comment for why this call happens before the list stream is read.
    if (!_requestedRequiredLearning || _organizationId != organizationId) {
      _requestedRequiredLearning = true;
      _organizationId = organizationId;
      // Fire-and-forget: a failure here just means the list may be missing
      // a newly-required item until the next successful call; the screen
      // still renders whatever records already exist.
      unawaited(
        _workerLearningService.getMyRequiredLearning(
          organizationId: organizationId,
        ),
      );
    }

    final workerLearningRepository = widget.workerLearningRepository ??
        WorkerLearningRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    final safetyLearningRepository = widget.safetyLearningRepository ??
        SafetyLearningRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );

    return StreamBuilder<List<SafetyLearning>>(
      stream: safetyLearningRepository.watchAll(),
      builder: (context, learningSnapshot) {
        final learningById = {
          for (final item in learningSnapshot.data ?? const <SafetyLearning>[])
            item.id: item,
        };

        return StreamBuilder<List<WorkerLearningRecord>>(
          stream: workerLearningRepository.watchMine(workerUid),
          builder: (context, snapshot) {
            final records = snapshot.data ?? const [];
            final isLoading =
                snapshot.connectionState == ConnectionState.waiting;

            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                Text('My Safety Learning', style: AppTextStyles.headlineMedium),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  'Safety learning required of you.',
                  style: AppTextStyles.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.lg),
                if (isLoading && records.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (!isLoading && records.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Text(
                      'No safety learning is currently required of you.',
                      style: AppTextStyles.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final record in records) ...[
                  _LearningRecordTile(
                    record: record,
                    learning: learningById[record.learningId],
                    onTap: () async {
                      final learning = learningById[record.learningId];
                      if (learning == null) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => LearningDetailScreen(
                            organizationId: organizationId,
                            learning: learning,
                            record: record,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _LearningRecordTile extends StatelessWidget {
  const _LearningRecordTile({
    required this.record,
    required this.learning,
    required this.onTap,
  });

  final WorkerLearningRecord record;
  final SafetyLearning? learning;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text(learning?.title ?? record.learningId),
        subtitle: learning != null ? Text(learning!.type.label) : null,
        trailing: _StatusBadge(status: record.status),
        onTap: onTap,
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final WorkerLearningStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      WorkerLearningStatus.assigned => AppColors.textSecondary,
      WorkerLearningStatus.inProgress => AppColors.warning,
      WorkerLearningStatus.completed => AppColors.success,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Text(
        status.label,
        style: AppTextStyles.label.copyWith(color: color),
      ),
    );
  }
}

/// Deliberately-ignored future, matching this codebase's existing
/// fire-and-forget style for best-effort background calls.
void unawaited(Future<void> future) {
  future.ignore();
}
