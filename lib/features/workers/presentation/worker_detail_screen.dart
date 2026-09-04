import 'package:flutter/material.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../activities/data/activity_assignment_repository.dart';
import '../../activities/domain/activity_assignment.dart';
import '../../authentication/domain/organization_user.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';

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
  });

  final OrganizationUser worker;
  final String organizationId;

  /// Injected in tests.
  final SiteRepository? siteRepository;
  final ActivityAssignmentRepository? assignmentRepository;

  @override
  Widget build(BuildContext context) {
    final sites = siteRepository ??
        SiteRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    final assignments = assignmentRepository ??
        ActivityAssignmentRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );

    return Scaffold(
      appBar: AppBar(title: Text(worker.name)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Text(worker.email, style: AppTextStyles.bodyMedium),
          if (worker.role != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(worker.role!.label, style: AppTextStyles.bodyMedium),
          ],
          const SizedBox(height: AppSpacing.lg),
          Text('Assigned Sites', style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          if (worker.siteIds.isEmpty)
            const Text(
              'No sites assigned.',
              style: AppTextStyles.bodyMedium,
            )
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
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: Text(
                          '${site.name} (${site.code})',
                          style: AppTextStyles.bodyMedium,
                        ),
                      ),
                  ],
                );
              },
            ),
          const SizedBox(height: AppSpacing.lg),
          Text('Assigned Activities', style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          StreamBuilder<List<ActivityAssignment>>(
            stream: assignments.watchAssignmentsForWorker(
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
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final assignment in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: Text(
                        'Activity ${assignment.activityId} '
                        '(site ${assignment.siteId})',
                        style: AppTextStyles.bodyMedium,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
