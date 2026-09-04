import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/hazard_repository.dart';
import '../domain/hazard.dart';
import '../domain/hazard_status.dart';
import 'report_hazard_screen.dart';

/// The signed-in worker's own hazard reports — "what have I reported, and
/// what happened to it" — the natural landing view after
/// [ReportHazardScreen], and where a worker returns to check status without
/// needing reviewer-level visibility into every hazard on the site.
///
/// Read-only: this screen has no acknowledge/link/close actions — those
/// belong to an authorized reviewer's own view, out of scope for this
/// worker-facing stage (mirrors [AdminDailySafetyMeetingsScreen] being a
/// separate screen from the foreman's own [DailySafetyMeetingScreen]).
class MyHazardsScreen extends StatelessWidget {
  const MyHazardsScreen({super.key, this.hazardRepository});

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependency scoped to the signed-in user's
  /// organization.
  final HazardRepository? hazardRepository;

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<SessionController>().profile;
    final organizationId = profile?.organizationId;
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

    final repository = hazardRepository ??
        HazardRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );

    return Scaffold(
      body: StreamBuilder<List<Hazard>>(
        stream: repository.watchReportedBy(workerUid),
        builder: (context, snapshot) {
          final hazards = snapshot.data ?? const <Hazard>[];
          final isLoading = snapshot.connectionState == ConnectionState.waiting;
          final hasError = snapshot.hasError;

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Text('My Hazard Reports', style: AppTextStyles.headlineMedium),
              const SizedBox(height: AppSpacing.xs),
              const Text(
                'Hazards you have reported and their current status.',
                style: AppTextStyles.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.lg),
              if (isLoading && hazards.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (hasError)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Text(
                    'Could not load your hazard reports. Please try again.',
                    style: AppTextStyles.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              if (!isLoading && !hasError && hazards.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Text(
                    "You haven't reported any hazards yet.",
                    style: AppTextStyles.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final hazard in hazards) ...[
                _HazardTile(hazard: hazard),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ReportHazardScreen()),
        ),
        icon: const Icon(Icons.add_alert_outlined),
        label: const Text('Report Hazard'),
      ),
    );
  }
}

class _HazardTile extends StatelessWidget {
  const _HazardTile({required this.hazard});

  final Hazard hazard;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: hazard.photoUrl != null
            ? const Icon(Icons.photo_outlined)
            : const Icon(Icons.warning_amber_outlined),
        title: Text(hazard.category.label),
        subtitle: Text(
          hazard.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: _StatusBadge(status: hazard.status),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final HazardStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      HazardStatus.reported => AppColors.textSecondary,
      HazardStatus.acknowledged => AppColors.info,
      HazardStatus.correctiveActionCreated => AppColors.warning,
      HazardStatus.closed => AppColors.success,
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
