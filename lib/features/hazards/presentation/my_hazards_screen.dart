import 'package:flutter/material.dart';
import '../../corrective_actions/presentation/report_progress.dart';
import '../../safety_reporting/presentation/report_safety_issue_screen.dart';
import '../domain/hazard_category.dart';
import '../../corrective_actions/domain/corrective_action_status.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/hazard_repository.dart';
import '../domain/hazard.dart';
import '../domain/hazard_kind.dart';
import '../domain/hazard_status.dart';
import 'report_hazard_screen.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/feature_header.dart';
import 'hazard_style.dart';

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
  const MyHazardsScreen({
    super.key,
    this.hazardRepository,
    this.correctiveActionRepository,
  });

  /// Injected in tests — loads what is being done about each report.
  final CorrectiveActionRepository? correctiveActionRepository;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependency scoped to the signed-in user's
  /// organization.
  final HazardRepository? hazardRepository;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final organizationId = sessionController.activeOrganizationId;
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

    final repository =
        hazardRepository ??
        HazardRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    final actionRepository =
        correctiveActionRepository ??
        CorrectiveActionRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );

    return Scaffold(
      body: LiveStreamBuilder<List<Hazard>>(
        streamKey: (organizationId, workerUid),
        stream: () => repository.watchReportedBy(workerUid),
        builder: (context, snapshot) {
          final hazards = snapshot.data ?? const <Hazard>[];
          final isLoading = snapshot.connectionState == ConnectionState.waiting;
          final hasError = snapshot.hasError;

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              FeatureHeader(
                title: 'My Hazard Reports',
                subtitle: 'Hazards you have reported and their current status.',
                icon: Icons.warning_amber,
                color: AppColors.hazards,
                chips: [
                  FeatureChip(
                    icon: Icons.report,
                    label:
                        '${hazards.where((h) => h.status != HazardStatus.closed).length} open',
                  ),
                  FeatureChip(
                    icon: Icons.check_circle,
                    label:
                        '${hazards.where((h) => h.status == HazardStatus.closed).length} closed',
                  ),
                ],
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
                _HazardTile(hazard: hazard, actions: actionRepository),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(builder: (_) => const ReportSafetyIssueScreen()),
        ),
        icon: const Icon(Icons.campaign),
        label: const Text('Report a Safety Issue'),
      ),
    );
  }
}

class _HazardTile extends StatelessWidget {
  const _HazardTile({required this.hazard, required this.actions});

  final Hazard hazard;
  final CorrectiveActionRepository actions;

  @override
  Widget build(BuildContext context) {
    final category = hazard.category;
    final actionId = hazard.correctiveActionId;
    Widget withCard(CorrectiveAction? action) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(category, action),
        const SizedBox(height: 6),
        _HazardOutcome(hazard: hazard, actions: actions),
      ],
    );
    if (actionId == null) return withCard(null);
    // The badge follows the fix ("Being fixed", "Awaiting review"…).
    return LiveStreamBuilder<CorrectiveAction?>(
      streamKey: (actions.organizationId, actionId),
      stream: () => actions.watchById(actionId),
      builder: (context, snapshot) => withCard(snapshot.data),
    );
  }

  Widget _card(HazardCategory category, CorrectiveAction? action) {
    return AccentCard(
      color: category.color,
      icon: category.icon,
      title: category.label,
      dimmed: hazard.status == HazardStatus.closed,
      trailing: Text(category.emoji, style: const TextStyle(fontSize: 26)),
      badges: [
        if (hazard.kind == HazardKind.nearMiss)
          AccentBadge(label: hazard.kind.label, color: hazard.kind.color),
        AccentBadge(
          label: ReportProgress.forHazard(hazard, action).label,
          color: ReportProgress.forHazard(hazard, action).color,
        ),
      ],
      body: hazard.description,
      details: [
        if (hazard.location != null)
          AccentDetail(icon: Icons.place, text: hazard.location!),
        if (hazard.photoUrl != null)
          const AccentDetail(icon: Icons.photo_camera, text: 'Photo attached'),
      ],
    );
  }
}

/// What happened to the worker's report — so the person who spotted a
/// hazard sees it was taken seriously and what was done about it, and
/// keeps reporting. Shown under each of their reports:
///
/// - waiting for / seen by a supervisor,
/// - "Being fixed: [the corrective action]" with its progress,
/// - "Fixed" with the assignee's own account of the fix and their photo,
/// - or closed with no work needed.
class _HazardOutcome extends StatelessWidget {
  const _HazardOutcome({required this.hazard, required this.actions});

  final Hazard hazard;
  final CorrectiveActionRepository actions;

  @override
  Widget build(BuildContext context) {
    final actionId = hazard.correctiveActionId;
    if (actionId == null) {
      return switch (hazard.status) {
        HazardStatus.closed => const _OutcomeBox(
          icon: Icons.check_circle,
          color: AppColors.success,
          title: 'Closed',
          text:
              'A supervisor checked your report — no further work was '
              'needed. Thank you for reporting.',
        ),
        HazardStatus.acknowledged => const _OutcomeBox(
          icon: Icons.visibility,
          color: AppColors.meetings,
          title: 'Seen by a supervisor',
          text: 'They are deciding what needs to be done.',
        ),
        _ => const _OutcomeBox(
          icon: Icons.hourglass_top,
          color: AppColors.textSecondary,
          title: 'Reported',
          text: 'Waiting for a supervisor to look at it.',
        ),
      };
    }
    return LiveStreamBuilder<CorrectiveAction?>(
      streamKey: (actions.organizationId, actionId),
      stream: () => actions.watchById(actionId),
      builder: (context, snapshot) {
        final action = snapshot.data;
        if (action == null) {
          return const _OutcomeBox(
            icon: Icons.build_circle,
            color: AppColors.correctiveActions,
            title: 'Being fixed',
            text: 'A corrective action has been raised.',
          );
        }
        if (action.status == CorrectiveActionStatus.completed) {
          return _OutcomeBox(
            icon: Icons.check_circle,
            color: AppColors.success,
            title: 'Fixed: ${action.title}',
            text: [
              if (action.completionNote != null) action.completionNote!,
              'Thank you for reporting — this hazard is now closed.',
            ].join('\n'),
            photoUrl: action.evidencePhotos.firstOrNull?.downloadUrl,
          );
        }
        return _OutcomeBox(
          icon: Icons.build_circle,
          color: AppColors.correctiveActions,
          title: 'Being fixed: ${action.title}',
          text: action.status == CorrectiveActionStatus.submittedForReview
              ? 'The work is done and being checked by a supervisor.'
              : 'Assigned to ${action.assignedToName ?? 'a team member'} · '
                    'due ${_formatDate(action.dueDate)}',
        );
      },
    );
  }
}

class _OutcomeBox extends StatelessWidget {
  const _OutcomeBox({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    this.photoUrl,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      margin: const EdgeInsets.only(left: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.sm + 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.readable(color, brightness)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.bodyLarge.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.readable(color, brightness),
                  ),
                ),
                Text(text, style: AppTextStyles.bodyMedium),
              ],
            ),
          ),
          if (photoUrl != null) ...[
            const SizedBox(width: AppSpacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                photoUrl!,
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox.shrink(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatDate(DateTime date) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}
