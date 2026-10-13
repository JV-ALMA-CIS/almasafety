import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../activities/data/activity_admin_service.dart';
import '../../activities/data/activity_repository.dart';
import '../../activities/domain/activity.dart';
import '../../authentication/domain/app_role.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
import '../../safety_requirements/data/safety_requirement_repository.dart';
import '../../safety_requirements/domain/safety_requirement.dart';
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
    this.activityAdminService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final WorkerLearningRepository? workerLearningRepository;
  final SafetyLearningRepository? safetyLearningRepository;
  final WorkerLearningService? workerLearningService;

  /// Injected in tests. Backs `getSiteActivities` — a Foreman/Worker's
  /// `firestore.rules` grant on `activities` does not cover LIST queries
  /// (see that rule's own doc comment), so a non-siteManager/Admin's own
  /// site-scoped activities are resolved via this callable instead of
  /// [ActivityRepository.watchBySites].
  final ActivityAdminService? activityAdminService;

  @override
  State<MySafetyLearningScreen> createState() => _MySafetyLearningScreenState();
}

class _MySafetyLearningScreenState extends State<MySafetyLearningScreen> {
  late final WorkerLearningService _workerLearningService =
      widget.workerLearningService ?? WorkerLearningService();
  late final ActivityAdminService _activityAdminService =
      widget.activityAdminService ?? ActivityAdminService();

  String? _organizationId;
  bool _requestedRequiredLearning = false;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final profile = session.profile;
    final organizationId = session.activeOrganizationId;
    final workerUid = profile?.uid;
    final membership = session.activeMembership;
    // firestore.rules grants a siteManager (and Admin) read access to every
    // site/activity in the organization, but a Foreman or Worker only to
    // ones whose own siteIds intersect their own membership — an
    // unconstrained watchAll() is refused outright for the latter (see
    // SiteRepository.watchByIds's doc comment), so this screen must query
    // by the caller's own sites instead whenever they are not a siteManager
    // or Admin.
    final isBroadlyScoped =
        profile?.isPlatformAdministrator == true ||
        membership?.role == AppRole.siteManager;
    final ownSiteIds = membership?.siteIds ?? const <String>[];

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

    final workerLearningRepository =
        widget.workerLearningRepository ??
        WorkerLearningRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    final safetyLearningRepository =
        widget.safetyLearningRepository ??
        SafetyLearningRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );

    final requirementRepository = SafetyRequirementRepository(
      firestoreService: FirestoreService(),
      organizationId: organizationId,
    );
    final siteRepository = SiteRepository(
      firestoreService: FirestoreService(),
      organizationId: organizationId,
    );
    final activityRepository = ActivityRepository(
      firestoreService: FirestoreService(),
      organizationId: organizationId,
    );

    return LiveStreamBuilder<List<SafetyLearning>>(
      streamKey: organizationId,
      stream: () => safetyLearningRepository.watchAll(),
      builder: (context, learningSnapshot) {
        final learningById = {
          for (final item in learningSnapshot.data ?? const <SafetyLearning>[])
            item.id: item,
        };

        return LiveStreamBuilder<List<SafetyRequirement>>(
          streamKey: organizationId,
          stream: () => requirementRepository.watchAll(),
          builder: (context, requirementSnapshot) {
            final requirements = requirementSnapshot.data ?? const [];

            return LiveStreamBuilder<List<Site>>(
              streamKey: (
                organizationId,
                isBroadlyScoped,
                ownSiteIds.join(','),
              ),
              stream: () => isBroadlyScoped
                  ? siteRepository.watchAll()
                  : siteRepository.watchByIds(ownSiteIds),
              builder: (context, siteSnapshot) {
                return StreamBuilder<List<Activity>>(
                  // A Foreman/Worker's firestore.rules grant on
                  // `activities` does not cover LIST queries at all (see
                  // that rule's own doc comment) — their own site-scoped
                  // activities are fetched once via getSiteActivities per
                  // assigned site instead of ActivityRepository
                  // .watchBySites.
                  stream: isBroadlyScoped
                      ? activityRepository.watchAll()
                      : Stream.fromFuture(
                          _siteScopedActivities(organizationId, ownSiteIds),
                        ),
                  builder: (context, activitySnapshot) {
                    final siteNamesById = <String, String>{
                      for (final site in siteSnapshot.data ?? const <Site>[])
                        site.id: site.name,
                    };
                    final activityNamesById = <String, String>{
                      for (final activity
                          in activitySnapshot.data ?? const <Activity>[])
                        activity.id: activity.name,
                    };
                    final reasonsByLearningId = _reasonsByLearningId(
                      requirements,
                      siteNamesById,
                      activityNamesById,
                    );

                    return LiveStreamBuilder<List<WorkerLearningRecord>>(
                      streamKey: (organizationId, workerUid),
                      stream: () =>
                          workerLearningRepository.watchMine(workerUid),
                      builder: (context, snapshot) {
                        final records = snapshot.data ?? const [];
                        final isLoading =
                            snapshot.connectionState ==
                                ConnectionState.waiting &&
                            !snapshot.hasError;

                        if (snapshot.hasError) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.lg),
                              child: Text(
                                'Could not load your safety learning. '
                                'Please try again.',
                                style: AppTextStyles.bodyMedium,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          );
                        }

                        return ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(AppSpacing.md),
                          children: [
                            Text(
                              'My Safety Learning',
                              style: AppTextStyles.headlineMedium,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            const Text(
                              'Safety learning required of you.',
                              style: AppTextStyles.bodyMedium,
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            if (isLoading && records.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(
                                  vertical: AppSpacing.xl,
                                ),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            if (!isLoading && records.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(
                                  vertical: AppSpacing.xl,
                                ),
                                child: Text(
                                  'No safety learning is currently required '
                                  'of you.',
                                  style: AppTextStyles.bodyMedium,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            for (final record in records) ...[
                              _LearningRecordTile(
                                record: record,
                                learning: learningById[record.learningId],
                                reason: reasonsByLearningId[record.learningId],
                                onTap: () async {
                                  final learning =
                                      learningById[record.learningId];
                                  if (learning == null) return;
                                  await Navigator.of(
                                    context,
                                    rootNavigator: true,
                                  ).push(
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
              },
            );
          },
        );
      },
    );
  }

  /// Every activity across [siteIds], fetched via [ActivityAdminService
  /// .getSiteActivities] once per site and merged — the per-document-safe
  /// substitute for [ActivityRepository.watchBySites], which a Foreman/
  /// Worker's `firestore.rules` grant cannot satisfy as a LIST query. A
  /// worker typically has one or two assigned sites, so this is a small,
  /// bounded number of calls, not an org-wide fan-out.
  Future<List<Activity>> _siteScopedActivities(
    String organizationId,
    List<String> siteIds,
  ) async {
    if (siteIds.isEmpty) return const [];
    final results = await Future.wait([
      for (final siteId in siteIds)
        _activityAdminService.getSiteActivities(
          organizationId: organizationId,
          siteId: siteId,
        ),
    ]);
    return [for (final activities in results) ...activities];
  }

  /// For each required [SafetyLearning] id, why it is required: the name of
  /// the site/activity whose ACTIVE [SafetyRequirement] names it, or
  /// "Organization-wide" for an unscoped requirement. When more than one
  /// requirement names the same learning item, the first match wins — this
  /// is a display hint only, not a source of truth (the resolver, not this
  /// label, decides what is actually required).
  Map<String, String> _reasonsByLearningId(
    List<SafetyRequirement> requirements,
    Map<String, String> siteNamesById,
    Map<String, String> activityNamesById,
  ) {
    final reasons = <String, String>{};
    for (final requirement in requirements) {
      final reason = requirement.siteId != null
          ? 'Required for ${siteNamesById[requirement.siteId] ?? 'your site'}'
          : requirement.activityId != null
          ? 'Required for '
                '${activityNamesById[requirement.activityId] ?? 'your activity'}'
          : 'Required organization-wide';
      for (final learningId in requirement.requiredLearningIds) {
        reasons.putIfAbsent(learningId, () => reason);
      }
    }
    return reasons;
  }
}

class _LearningRecordTile extends StatelessWidget {
  const _LearningRecordTile({
    required this.record,
    required this.learning,
    required this.onTap,
    this.reason,
  });

  final WorkerLearningRecord record;
  final SafetyLearning? learning;

  /// Why this item is required — e.g. "Required for East Site" — shown
  /// beneath the type so the worker understands the obligation, not just
  /// its existence. Null when no requirement context could be resolved.
  final String? reason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitleParts = [?learning?.type.label, ?reason];
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text(learning?.title ?? record.learningId),
        subtitle: subtitleParts.isEmpty
            ? null
            : Text(subtitleParts.join(' · ')),
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
