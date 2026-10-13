import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../data/corrective_action_repository.dart';
import '../data/corrective_action_service.dart';
import '../domain/corrective_action.dart';
import '../domain/corrective_action_status.dart';
import 'corrective_action_status_color.dart';
import 'review_corrective_action_screen.dart';
import 'submit_corrective_action_screen.dart';

/// A worker's own corrective actions — the jobs a supervisor has asked them
/// to do to fix a safety issue (from a hazard, an incident investigation or
/// a meeting). Reviewer roles reach their own work from the org-wide
/// [CorrectiveActionsScreen] instead ("Assigned to you").
///
/// Laid out as a work list:
///
/// - **To do** — open/in progress/overdue, most urgent first, each with
///   **Complete & Submit** (and the reviewer's reason if it was sent back);
/// - **Waiting for review** — submitted, for a supervisor to check;
/// - **Done** — approved.
///
/// Tapping a card opens it: [SubmitCorrectiveActionScreen] while there is
/// work to do, otherwise the read-only details with what was submitted.
class MyCorrectiveActionsScreen extends StatefulWidget {
  const MyCorrectiveActionsScreen({super.key, this.repository, this.service});

  /// Injected in tests.
  final CorrectiveActionRepository? repository;
  final CorrectiveActionService? service;

  @override
  State<MyCorrectiveActionsScreen> createState() =>
      _MyCorrectiveActionsScreenState();
}

class _MyCorrectiveActionsScreenState extends State<MyCorrectiveActionsScreen> {
  late final CorrectiveActionService _service =
      widget.service ?? CorrectiveActionService();

  Future<void> _open(String organizationId, CorrectiveAction action) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final bool? done;
    if (_isToDo(action)) {
      done = await navigator.push<bool>(
        MaterialPageRoute(
          builder: (_) => SubmitCorrectiveActionScreen(
            organizationId: organizationId,
            action: action,
            service: _service,
          ),
        ),
      );
    } else {
      final uid = context.read<SessionController>().profile?.uid;
      done = await navigator.push<bool>(
        MaterialPageRoute(
          builder: (_) => ReviewCorrectiveActionScreen(
            organizationId: organizationId,
            action: action,
            assignedToName: 'You',
            siteName: '',
            currentUid: uid,
            service: _service,
          ),
        ),
      );
    }
    if (done == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Submitted for review.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final organizationId = session.activeOrganizationId;
    final uid = session.profile?.uid;

    if (organizationId == null || uid == null) {
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
        widget.repository ??
        CorrectiveActionRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );

    return LiveStreamBuilder<List<CorrectiveAction>>(
      streamKey: (organizationId, uid),
      stream: () => repository.watchForAssignee(uid),
      builder: (context, snapshot) {
        final actions = snapshot.data ?? const <CorrectiveAction>[];
        final isLoading =
            snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null;

        final toDo = actions.where(_isToDo).toList()
          ..sort((a, b) => a.dueDate.compareTo(b.dueDate));
        final waiting = actions
            .where((a) => a.status == CorrectiveActionStatus.submittedForReview)
            .toList();
        final done = actions.where((a) => a.isCompleted).toList()
          ..sort(
            (a, b) => (b.completedAt ?? b.dueDate).compareTo(
              a.completedAt ?? a.dueDate,
            ),
          );

        Widget section(
          String title,
          IconData icon,
          Color color,
          List<CorrectiveAction> list,
        ) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: AppSpacing.md),
            FeatureSectionTitle(
              title: title,
              icon: icon,
              color: color,
              count: list.length,
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final action in list) ...[
              _MyActionCard(
                action: action,
                onOpen: () => _open(organizationId, action),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            FeatureHeader(
              title: 'My Corrective Actions',
              subtitle: 'Jobs you have been asked to do to fix safety issues.',
              icon: Icons.build_circle,
              color: AppColors.correctiveActions,
              chips: [
                FeatureChip(
                  icon: Icons.pending_actions,
                  label: '${toDo.length} to do',
                ),
                FeatureChip(
                  icon: Icons.hourglass_top,
                  label: '${waiting.length} in review',
                ),
                FeatureChip(icon: Icons.task_alt, label: '${done.length} done'),
              ],
            ),
            if (isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (snapshot.hasError)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: EmptyState(
                  icon: Icons.cloud_off,
                  title: 'Could not load your corrective actions.',
                ),
              )
            else if (actions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: EmptyState(
                  icon: Icons.task_alt,
                  title: 'Nothing assigned to you',
                ),
              )
            else ...[
              if (toDo.isNotEmpty)
                section(
                  'To do',
                  Icons.pending_actions,
                  AppColors.correctiveActions,
                  toDo,
                ),
              if (waiting.isNotEmpty)
                section(
                  'Waiting for review',
                  Icons.hourglass_top,
                  AppColors.analytics,
                  waiting,
                ),
              if (done.isNotEmpty)
                section('Done', Icons.task_alt, AppColors.success, done),
            ],
          ],
        );
      },
    );
  }
}

/// Open, in progress or overdue — work the assignee still has to do.
bool _isToDo(CorrectiveAction action) =>
    action.status == CorrectiveActionStatus.open ||
    action.status == CorrectiveActionStatus.inProgress ||
    action.status == CorrectiveActionStatus.overdue;

class _MyActionCard extends StatelessWidget {
  const _MyActionCard({required this.action, required this.onOpen});

  final CorrectiveAction action;
  final VoidCallback onOpen;

  bool get _canSubmit =>
      action.status == CorrectiveActionStatus.open ||
      action.status == CorrectiveActionStatus.inProgress;

  @override
  Widget build(BuildContext context) {
    final color = correctiveActionStatusColor(action.status);
    final today = DateUtils.dateOnly(DateTime.now());
    final isLate =
        !action.isCompleted &&
        action.status != CorrectiveActionStatus.submittedForReview &&
        DateUtils.dateOnly(action.dueDate).isBefore(today);
    final sentBack = _canSubmit && action.reviewFeedback != null;

    return AccentCard(
      color: color,
      icon: correctiveActionStatusIcon(action.status),
      title: action.title,
      onTap: onOpen,
      dimmed: action.isCompleted,
      badges: [
        AccentBadge(label: action.status.label, color: color),
        if (sentBack)
          const AccentBadge(label: 'Sent back', color: AppColors.hazards),
        if (isLate) const AccentBadge(label: 'Late', color: AppColors.danger),
      ],
      body: action.description,
      details: [
        AccentDetail(
          icon: action.incidentId != null
              ? Icons.personal_injury_outlined
              : action.hazardId != null
              ? Icons.warning_amber_outlined
              : Icons.groups_outlined,
          text: action.incidentId != null
              ? 'From an incident investigation'
              : action.hazardId != null
              ? 'From a reported hazard'
              : 'From a daily safety meeting',
        ),
        AccentDetail(
          icon: Icons.event,
          text: action.isCompleted
              ? 'Completed ${_formatDate(action.completedAt ?? action.dueDate)}'
              : 'Due ${_formatDate(action.dueDate)}',
        ),
        AccentDetail(
          icon: Icons.person_outline,
          text: 'Asked by ${action.assignedByName ?? 'a supervisor'}',
        ),
        if (action.requiredEvidence.isNotEmpty && !action.isCompleted)
          AccentDetail(
            icon: Icons.verified,
            text:
                'Evidence: '
                '${action.requiredEvidence.map((k) => k.label).join(' + ')}',
          ),
        if (sentBack)
          AccentDetail(
            icon: Icons.reply,
            text: 'Reviewer: ${action.reviewFeedback}',
          ),
        if (action.status == CorrectiveActionStatus.submittedForReview)
          const AccentDetail(
            icon: Icons.hourglass_top,
            text: 'Submitted — waiting for a supervisor to check it.',
          ),
        if (action.status == CorrectiveActionStatus.overdue)
          const AccentDetail(
            icon: Icons.info_outline,
            text: 'Marked overdue — ask your supervisor to reopen it.',
          ),
      ],
      actions: [
        if (_canSubmit)
          AccentButton(
            label: 'Complete & Submit',
            icon: Icons.task_alt,
            color: AppColors.correctiveActions,
            onPressed: onOpen,
          ),
      ],
    );
  }
}

String _formatDate(DateTime date) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}
