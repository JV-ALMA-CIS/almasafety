import 'package:flutter/material.dart';
import 'safety_reports_card.dart';
import '../../incidents/domain/incident.dart';
import '../../incidents/data/incident_repository.dart';
import '../../safety_reporting/presentation/report_safety_issue_screen.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/dashboard_header.dart';
import '../../../core/widgets/dashboard_section.dart';
import '../../../core/widgets/kpi_card.dart';
import '../../../routing/app_routes.dart';
import '../../pre_start_checks/data/pre_start_check_service.dart';
import '../../pre_start_checks/presentation/worker_pre_start_card.dart';
import '../../authentication/domain/app_role.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import '../../daily_safety_meetings/data/meeting_attendance_repository.dart';
import '../../daily_safety_meetings/presentation/worker_todays_meeting_card.dart';
import '../../hazards/data/hazard_repository.dart';
import '../../hazards/domain/hazard.dart';
import '../../safety_learning/data/worker_learning_repository.dart';
import '../../safety_learning/data/worker_learning_service.dart';
import '../../safety_learning/domain/safety_learning.dart';
import '../../safety_learning/presentation/ready_for_today_card.dart';
import '../../safety_learning/presentation/todays_safety_readiness_screen.dart';
import '../../safety_requirements/data/safety_requirement_repository.dart';

/// A Worker's dashboard — the landing view after signing in. It leads with
/// "Ready for Today" ([ReadyForTodayCard]): only the learning that matters
/// before today's meeting and today's work, never the whole learning
/// inventory. Below it: Today's Meeting, All My Learning (the broader
/// [MySafetyLearningScreen] inventory, deliberately secondary), My Hazards,
/// My Corrective Actions, and a Report Hazard quick action. Every other
/// section reads from the SAME repositories/queries already backing
/// [MySafetyLearningScreen]/[MyHazardsScreen]/[MyCorrectiveActionsScreen].
class WorkerDashboardScreen extends StatelessWidget {
  const WorkerDashboardScreen({
    super.key,
    this.safetyRequirementRepository,
    this.dailySafetyMeetingRepository,
    this.incidentRepository,
    this.hazardRepository,
    this.correctiveActionRepository,
    this.meetingAttendanceRepositoryFor,
    this.workerLearningService,
    this.workerLearningRepository,
    this.onOpenAllLearning,
    this.preStartCheckService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final SafetyRequirementRepository? safetyRequirementRepository;
  final DailySafetyMeetingRepository? dailySafetyMeetingRepository;
  final IncidentRepository? incidentRepository;
  final HazardRepository? hazardRepository;
  final CorrectiveActionRepository? correctiveActionRepository;

  /// Injected in tests. Production builds pass nothing; the widget
  /// constructs a real, meeting-scoped repository per meeting encountered.
  final MeetingAttendanceRepository Function(String meetingId)?
  meetingAttendanceRepositoryFor;

  /// Injected in tests. Back the "Ready for Today" card.
  final WorkerLearningService? workerLearningService;
  final WorkerLearningRepository? workerLearningRepository;

  /// Injected in tests. Opens the full learning list; defaults to
  /// [openAllMyLearning].
  final Future<void> Function(BuildContext context)? onOpenAllLearning;

  /// Injected in tests. Backs the "Pre-Start Check" card.
  final PreStartCheckService? preStartCheckService;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final organizationId = sessionController.activeOrganizationId;
    final workerUid = profile?.uid;
    final siteIds = sessionController.activeMembership?.siteIds ?? const [];

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

    final firestoreService = FirestoreService();
    final requirementRepository =
        safetyRequirementRepository ??
        SafetyRequirementRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final meetingRepository =
        dailySafetyMeetingRepository ??
        DailySafetyMeetingRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final hazardRepo =
        hazardRepository ??
        HazardRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final incidentRepo =
        incidentRepository ??
        IncidentRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final correctiveActionRepo =
        correctiveActionRepository ??
        CorrectiveActionRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final attendanceRepositoryFor =
        meetingAttendanceRepositoryFor ??
        (meetingId) => MeetingAttendanceRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
          meetingId: meetingId,
        );

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        DashboardHeader(
          title: 'Dashboard',
          role: AppRole.worker,
          userName: profile?.name,
          icon: Icons.engineering,
        ),
        const SizedBox(height: AppSpacing.md),
        // Always within reach: one button for anything wrong on site — the
        // chooser behind it files a hazard, near-miss or incident.
        const ReportSafetyIssueButton(),
        const SizedBox(height: AppSpacing.lg),
        // First on the page: the one thing every worker does every day
        // before starting work.
        DashboardSection(
          title: 'Pre-Start Check',
          color: AppColors.go,
          icon: Icons.checklist_rtl,
          child: WorkerPreStartCard(
            key: ValueKey('pre-start-$organizationId'),
            organizationId: organizationId,
            service: preStartCheckService ?? PreStartCheckService(),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'Ready for Today',
          color: AppColors.learning,
          icon: Icons.wb_sunny_outlined,
          child: ReadyForTodayCard(
            // Keyed by organization so switching organizations re-fetches.
            key: ValueKey('ready-for-today-$organizationId'),
            organizationId: organizationId,
            workerUid: workerUid,
            workerLearningService:
                workerLearningService ?? WorkerLearningService(),
            workerLearningRepository:
                workerLearningRepository ??
                WorkerLearningRepository(
                  firestoreService: firestoreService,
                  organizationId: organizationId,
                ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: "Today's Meeting",
          color: AppColors.meetings,
          icon: Icons.fact_check_outlined,
          child: WorkerTodaysMeetingCard(
            meetingRepository: meetingRepository,
            attendanceRepositoryFor: attendanceRepositoryFor,
            siteIds: siteIds,
            workerUid: workerUid,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'All My Learning',
          color: AppColors.learning,
          icon: Icons.school_outlined,
          trailing: TextButton(
            onPressed: () => (onOpenAllLearning ?? openAllMyLearning)(context),
            child: const Text('See all'),
          ),
          child: LiveStreamBuilder<List<SafetyLearning>>(
            streamKey: (organizationId, workerUid),
            stream: () =>
                requirementRepository.watchResolvedRequiredLearning(workerUid),
            builder: (context, snapshot) {
              final items = snapshot.data;
              if (snapshot.connectionState == ConnectionState.waiting &&
                  items == null) {
                return const _LoadingCard();
              }
              final count = items?.length ?? 0;
              // The learning accent, not a warning/success status colour:
              // this is the broader inventory, not today's task list —
              // "Ready for Today" above carries the urgency.
              return KpiCard(
                color: AppColors.learning,
                value: '$count',
                label: count == 1
                    ? 'learning item in total'
                    : 'learning items in total',
                icon: Icons.school_outlined,
                onTap: () => (onOpenAllLearning ?? openAllMyLearning)(context),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'My Safety Reports',
          color: AppColors.stop,
          icon: Icons.campaign_outlined,
          child: LiveStreamBuilder<List<Hazard>>(
            streamKey: (organizationId, workerUid),
            stream: () => hazardRepo.watchReportedBy(workerUid),
            builder: (context, hazardSnapshot) {
              if (hazardSnapshot.connectionState == ConnectionState.waiting &&
                  hazardSnapshot.data == null) {
                return const _LoadingCard();
              }
              return LiveStreamBuilder<List<Incident>>(
                streamKey: (organizationId, workerUid),
                stream: () => incidentRepo.watchReportedBy(workerUid),
                builder: (context, incidentSnapshot) => SafetyReportsCard(
                  hazards: hazardSnapshot.data ?? const <Hazard>[],
                  incidents: incidentSnapshot.data ?? const <Incident>[],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'My Corrective Actions',
          color: AppColors.correctiveActions,
          icon: Icons.build_outlined,
          trailing: TextButton(
            onPressed: () => context.go(AppRoutes.correctiveActions),
            child: const Text('See all'),
          ),
          child: LiveStreamBuilder<List<CorrectiveAction>>(
            streamKey: (organizationId, workerUid),
            stream: () => correctiveActionRepo.watchForAssignee(workerUid),
            builder: (context, snapshot) {
              final actions = snapshot.data;
              if (snapshot.connectionState == ConnectionState.waiting &&
                  actions == null) {
                return const _LoadingCard();
              }
              final list = actions ?? const <CorrectiveAction>[];
              final openCount = list.where((a) => !a.isCompleted).length;
              return KpiCard(
                value: '$openCount',
                label: openCount == 1 ? 'action open' : 'actions open',
                icon: Icons.build_outlined,
                color: openCount > 0 ? AppColors.warning : AppColors.success,
                onTap: () => context.go(AppRoutes.correctiveActions),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
