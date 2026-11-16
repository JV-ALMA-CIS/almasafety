import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../activities/data/activity_assignment_repository.dart';
import '../../activities/data/activity_repository.dart';
import '../../activities/domain/activity.dart';
import '../../activities/domain/activity_assignment.dart';
import '../../authentication/domain/organization_user.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/dashboard_header.dart';
import '../../../core/widgets/feature_header.dart';
import '../../pre_start_checks/presentation/pre_start_visuals.dart';
import '../../../core/widgets/mobile_title.dart';

/// Shows one worker's name, email, role, assigned sites and assigned
/// activities.
///
/// Reached via a normal [Navigator.push] from `ActivityWorkersScreen`'s
/// assigned-worker list — there is no reason for this to be a top-level
/// go_router route, since it is only ever opened from within that
/// already-gated admin flow.
///
/// Takes the already-loaded [worker] projection directly (from
/// `listOrganizationUsers` via [AccountApprovalService.listUsers]) rather
/// than re-fetching by uid: the caller already has it from the list it was
/// tapped from, and there is no single-user lookup callable to prefer over
/// that — see `ActivityWorkersScreen`'s doc comment for why a new one was
/// not added.
class WorkerDetailScreen extends StatelessWidget {
  const WorkerDetailScreen({
    required this.worker,
    required this.organizationId,
    super.key,
    this.siteRepository,
    this.assignmentRepository,
    this.activityRepository,
  });

  final OrganizationUser worker;
  final String organizationId;

  /// Injected in tests.
  final SiteRepository? siteRepository;
  final ActivityAssignmentRepository? assignmentRepository;
  final ActivityRepository? activityRepository;

  @override
  Widget build(BuildContext context) {
    final sites =
        siteRepository ??
        SiteRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    final assignments =
        assignmentRepository ??
        ActivityAssignmentRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    final activities =
        activityRepository ??
        ActivityRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );

    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Worker Details')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            eyebrow: 'Worker profile',
            title: worker.email,
            icon: Icons.person,
            color: worker.role != null
                ? DashboardHeader.roleColor(worker.role!)
                : AppColors.people,
            chips: [
              if (worker.role != null)
                FeatureChip(icon: Icons.badge, label: worker.role!.label),
              if (worker.trade != null)
                FeatureChip(icon: Icons.handyman, label: worker.trade!),
              if (worker.workerType != null)
                FeatureChip(
                  icon: Icons.business_center,
                  label: worker.workerType!.label,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const FeatureSectionTitle(
            title: 'Assigned Sites',
            icon: Icons.location_city,
            color: AppColors.analytics,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (worker.siteIds.isEmpty)
            const Text('No sites assigned.', style: AppTextStyles.bodyMedium)
          else
            FutureBuilder<List<Site?>>(
              future: Future.wait(worker.siteIds.map(sites.getById)),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final resolved = snapshot.data!.whereType<Site>().toList();
                if (resolved.isEmpty) {
                  return const Text(
                    'No sites assigned.',
                    style: AppTextStyles.bodyMedium,
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final site in resolved)
                      _ChipRow(
                        color: AppColors.analytics,
                        leading: const Icon(
                          Icons.location_city,
                          color: AppColors.analytics,
                        ),
                        text: '${site.name} (${site.code})',
                      ),
                  ],
                );
              },
            ),
          const SizedBox(height: AppSpacing.lg),
          const FeatureSectionTitle(
            title: 'Assigned Activities',
            icon: Icons.engineering,
            color: AppColors.projects,
          ),
          const SizedBox(height: AppSpacing.sm),
          LiveStreamBuilder<List<ActivityAssignment>>(
            streamKey: (organizationId, worker.uid),
            stream: () => assignments.watchAssignmentsForWorker(
              organizationId,
              worker.uid,
            ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final list = snapshot.data ?? const [];
              if (list.isEmpty) {
                return const Text(
                  'No activities assigned.',
                  style: AppTextStyles.bodyMedium,
                );
              }
              return FutureBuilder<List<Activity?>>(
                future: Future.wait(
                  list.map(
                    (assignment) => activities.getById(assignment.activityId),
                  ),
                ),
                builder: (context, activitySnapshot) {
                  if (!activitySnapshot.hasData) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final resolvedActivities = activitySnapshot.data!;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < list.length; i++)
                        _ChipRow(
                          color: AppColors.projects,
                          leading: Text(
                            hazardEmojiFor(resolvedActivities[i]?.name ?? ''),
                            style: const TextStyle(fontSize: 20),
                          ),
                          text:
                              resolvedActivities[i]?.name ??
                              'Activity ${list[i].activityId}',
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

/// One assigned site or activity on the worker profile: a tinted row with
/// a leading icon or picture.
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.color,
    required this.leading,
    required this.text,
  });

  final Color color;
  final Widget leading;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
