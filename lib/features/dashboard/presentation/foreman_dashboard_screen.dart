import '../../../core/widgets/push_opt_in_card.dart';
import 'package:flutter/material.dart';
import '../../../core/widgets/dashboard_grid.dart';
import '../../corrective_actions/domain/corrective_action_status.dart';
import 'safety_reports_card.dart';
import 'whats_due_card.dart';
import '../../organizations/presentation/site_emergency_contacts.dart';

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
import '../../pre_start_checks/presentation/crew_pre_start_card.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/domain/organization_user.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import '../../daily_safety_meetings/data/meeting_attendance_service.dart';
import '../../daily_safety_meetings/domain/daily_safety_meeting.dart';
import '../../daily_safety_meetings/presentation/crew_readiness_card.dart';
import '../../hazards/data/hazard_repository.dart';
import '../../hazards/domain/hazard.dart';
import '../../organizations/data/site_repository.dart';
import '../../safety_learning/data/worker_learning_repository.dart';
import '../../safety_learning/data/worker_learning_service.dart';
import '../../safety_learning/presentation/ready_for_today_card.dart';
import '../../safety_learning_compliance/data/safety_compliance_repository.dart';

/// A Foreman's dashboard: Today's Meeting, Site workers, Learning
/// readiness, Open hazards, Corrective actions, and quick actions —
/// everything scoped to the Foreman's own assigned site(s)
/// ([SessionController.activeMembership]'s `siteIds`), matching
/// [MyWorkersScreen]'s existing "a Foreman only reads their own sites, not
/// the whole organization" boundary (`firestore.rules` refuses an
/// unconstrained listing to a non-org-wide role — see [SiteRepository
/// .watchByIds]'s own doc comment).
///
/// Every section composes EXISTING repositories — no new backend.
/// Corrective Actions has no site-scoped query ([CorrectiveActionRepository]
/// has no `watchForSite`), so this filters [CorrectiveActionRepository
/// .watchForOrganization]'s stream client-side by `siteId` instead of
/// introducing one.
///
/// **Crew readiness comes from ONE server callable, not client fan-out.**
/// [CrewReadinessCard] shows today's attendance-gating readiness via
/// `getSiteCrewReadiness` (before the meeting) or
/// `getMeetingAttendeeLearningStatus` (once started) — a single call whose
/// per-worker reads all happen server-side. The FULL compliance view is
/// still deliberately NOT computed here:
/// [SafetyComplianceRepository.buildSiteCompliance] fans out one
/// `watchResolvedRequiredLearning` query per worker at a site — exactly the
/// same per-worker query pattern that, when [AnalyticsRepository.build]
/// auto-fired it for every worker in the organization from this dashboard,
/// broke Firestore's read budget in production (see [AnalyticsRepository
/// .build]'s own `includeSafetyLearning` doc comment). Calling
/// [SafetyComplianceRepository.buildSiteCompliance] automatically here for
/// every assigned site, on every dashboard visit, is the same risk at a
/// smaller (but still unbounded) scale — a Foreman with a large crew would
/// eventually hit the same failure. [SafetyLearningComplianceScreen]
/// already computes this safely, ON DEMAND, for exactly one site the user
/// picks — this screen links there instead of recomputing it.
class ForemanDashboardScreen extends StatefulWidget {
  const ForemanDashboardScreen({
    super.key,
    this.siteRepository,
    this.dailySafetyMeetingRepository,
    this.incidentRepository,
    this.hazardRepository,
    this.correctiveActionRepository,
    this.safetyComplianceRepository,
    this.approvalService,
    this.meetingAttendanceService,
    this.workerLearningService,
    this.workerLearningRepository,
    this.preStartCheckService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final SiteRepository? siteRepository;
  final DailySafetyMeetingRepository? dailySafetyMeetingRepository;
  final IncidentRepository? incidentRepository;
  final HazardRepository? hazardRepository;
  final CorrectiveActionRepository? correctiveActionRepository;
  final SafetyComplianceRepository? safetyComplianceRepository;
  final AccountApprovalService? approvalService;
  final MeetingAttendanceService? meetingAttendanceService;

  /// Injected in tests. Back the Foreman's own "My Readiness" card.
  final WorkerLearningService? workerLearningService;
  final WorkerLearningRepository? workerLearningRepository;

  /// Injected in tests. Backs the "Crew Pre-Start Checks" card.
  final PreStartCheckService? preStartCheckService;

  @override
  State<ForemanDashboardScreen> createState() => _ForemanDashboardScreenState();
}

class _ForemanDashboardScreenState extends State<ForemanDashboardScreen> {
  static String _today() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  late final MeetingAttendanceService _attendanceService =
      widget.meetingAttendanceService ?? MeetingAttendanceService();
  late final PreStartCheckService _preStartService =
      widget.preStartCheckService ?? PreStartCheckService();

  String? _usersOrganizationId;
  Future<List<OrganizationUser>>? _usersFuture;
  Future<Map<String, String>>? _workerNames;

  /// Active users of [organizationId], fetched once per organization (not
  /// once per rebuild) and shared by Site Workers and crew readiness names.
  Future<List<OrganizationUser>> _users(
    AccountApprovalService service,
    String organizationId,
  ) {
    if (_usersFuture == null || _usersOrganizationId != organizationId) {
      _usersOrganizationId = organizationId;
      final users = service.listUsers(
        status: AccountStatus.active,
        organizationId: organizationId,
      );
      _usersFuture = users;
      _workerNames = users.then(
        (list) => {for (final user in list) user.uid: user.name},
      );
    }
    return _usersFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final organizationId = sessionController.activeOrganizationId;
    final foremanUid = profile?.uid;
    final siteIds = sessionController.activeMembership?.siteIds ?? const [];

    if (organizationId == null || foremanUid == null) {
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
    if (siteIds.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You have not been assigned to a site yet.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final firestoreService = FirestoreService();
    final meetingRepository =
        widget.dailySafetyMeetingRepository ??
        DailySafetyMeetingRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final hazardRepo =
        widget.hazardRepository ??
        HazardRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final incidentRepo =
        widget.incidentRepository ??
        IncidentRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final correctiveActionRepo =
        widget.correctiveActionRepository ??
        CorrectiveActionRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final approvalService = widget.approvalService ?? AccountApprovalService();
    final usersFuture = _users(approvalService, organizationId);
    final workerNames = _workerNames!;
    final todaysMeetings = meetingRepository.watchForForemanSiteAndDate(
      foremanId: foremanUid,
      siteId: siteIds.first,
      date: _today(),
    );

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        DashboardHeader(
          title: 'Dashboard',
          role: AppRole.foreman,
          userName: profile?.name,
          icon: Icons.groups,
        ),
        const SizedBox(height: AppSpacing.md),
        const ReportSafetyIssueButton(),
        const SizedBox(height: AppSpacing.md),
        const PushOptInCard(),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: "What's Due",
          color: AppColors.warning,
          icon: Icons.event_available,
          child: WhatsDueCard(
            organizationId: organizationId,
            uid: foremanUid,
            isManager: false,
            siteIds: siteIds,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        for (final siteId in siteIds) ...[
          SiteEmergencyContacts(
            organizationId: organizationId,
            siteId: siteId,
            siteRepository: widget.siteRepository,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        DashboardSection(
          title: "Today's Meeting",
          color: AppColors.meetings,
          icon: Icons.fact_check_outlined,
          child: LiveStreamBuilder<List<DailySafetyMeeting>>(
            streamKey: (organizationId, foremanUid, siteIds.first, _today()),
            stream: () => todaysMeetings,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _LoadingCard();
              }
              final meetings = snapshot.data ?? const <DailySafetyMeeting>[];
              final meeting = meetings.firstOrNull;
              final icon = meeting == null
                  ? Icons.fact_check_outlined
                  : meeting.isCompleted
                  ? Icons.check_circle_outline
                  : Icons.pending_outlined;
              final iconColor = meeting == null
                  ? AppColors.meetings
                  : meeting.isCompleted
                  ? AppColors.success
                  : AppColors.warning;
              return Card(
                margin: EdgeInsets.zero,
                color: Color.alphaBlend(
                  iconColor.withValues(alpha: 0.10),
                  Theme.of(context).colorScheme.surface,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: iconColor.withValues(alpha: 0.45)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: iconColor,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(icon, color: AppColors.onColor(iconColor)),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          meeting == null
                              ? 'No meeting started today.'
                              : meeting.isCompleted
                              ? "Today's meeting is complete."
                              : "Today's meeting is in progress.",
                          style: AppTextStyles.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: ElevatedButton(
                          onPressed: () =>
                              context.go(AppRoutes.dailySafetyMeetings),
                          child: Text(
                            meeting == null
                                ? 'Start'
                                : meeting.isCompleted
                                ? 'View'
                                : 'Resume',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'My Readiness',
          color: AppColors.learning,
          icon: Icons.school_outlined,
          // The Foreman's OWN learning: what must be done before
          // `createDailySafetyMeeting` will let them start today's meeting.
          child: ReadyForTodayCard(
            key: ValueKey('my-readiness-$organizationId'),
            organizationId: organizationId,
            workerUid: foremanUid,
            workerLearningService:
                widget.workerLearningService ?? WorkerLearningService(),
            workerLearningRepository:
                widget.workerLearningRepository ??
                WorkerLearningRepository(
                  firestoreService: firestoreService,
                  organizationId: organizationId,
                ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'Crew Readiness',
          color: AppColors.compliance,
          icon: Icons.verified_user_outlined,
          trailing: TextButton(
            onPressed: () => context.go(AppRoutes.safetyLearningCompliance),
            child: const Text('Full compliance'),
          ),
          child: LiveStreamBuilder<List<DailySafetyMeeting>>(
            streamKey: (organizationId, foremanUid, siteIds.first, _today()),
            stream: () => todaysMeetings,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _LoadingCard();
              }
              final meeting =
                  (snapshot.data ?? const <DailySafetyMeeting>[]).firstOrNull;
              return CrewReadinessCard(
                organizationId: organizationId,
                siteId: siteIds.first,
                meetingId: meeting?.id,
                attendanceService: _attendanceService,
                workerNames: workerNames,
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'Crew Pre-Start Checks',
          color: AppColors.go,
          icon: Icons.checklist_rtl,
          child: CrewPreStartCard(
            key: ValueKey('crew-pre-start-$organizationId-${siteIds.first}'),
            organizationId: organizationId,
            siteId: siteIds.first,
            service: _preStartService,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'Site Workers',
          color: AppColors.people,
          icon: Icons.groups_outlined,
          trailing: TextButton(
            onPressed: () => context.go(AppRoutes.workers),
            child: const Text('See all'),
          ),
          child: FutureBuilder<List<OrganizationUser>>(
            future: usersFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _LoadingCard();
              }
              final users = snapshot.data ?? const <OrganizationUser>[];
              final workerCount = users
                  .where(
                    (u) =>
                        u.role == AppRole.worker &&
                        u.siteIds.any(siteIds.contains),
                  )
                  .length;
              return KpiCard(
                value: '$workerCount',
                label: workerCount == 1 ? 'worker' : 'workers',
                icon: Icons.groups_outlined,
                color: AppColors.people,
                onTap: () => context.go(AppRoutes.workers),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'Safety Reports',
          color: AppColors.stop,
          icon: Icons.campaign_outlined,
          child: LiveStreamBuilder<List<List<Hazard>>>(
            streamKey: (organizationId, siteIds.join(',')),
            stream: () => _combineHazardStreams(hazardRepo, siteIds),
            builder: (context, hazardSnapshot) {
              if (hazardSnapshot.connectionState == ConnectionState.waiting &&
                  !hazardSnapshot.hasData) {
                return const _LoadingCard();
              }
              final hazards = <Hazard>[
                for (final batch
                    in hazardSnapshot.data ?? const <List<Hazard>>[])
                  ...batch,
              ];
              return LiveStreamBuilder<List<Incident>>(
                streamKey: organizationId,
                stream: () => incidentRepo.watchForOrganization(),
                builder: (context, incidentSnapshot) {
                  // A Foreman's own sites only, like every other count here.
                  final incidents = [
                    for (final incident
                        in incidentSnapshot.data ?? const <Incident>[])
                      if (siteIds.contains(incident.siteId)) incident,
                  ];
                  return SafetyReportsCard(
                    hazards: hazards,
                    incidents: incidents,
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'Corrective Actions',
          color: AppColors.correctiveActions,
          icon: Icons.build_outlined,
          trailing: TextButton(
            onPressed: () => context.go(AppRoutes.correctiveActions),
            child: const Text('See all'),
          ),
          child: LiveStreamBuilder<List<CorrectiveAction>>(
            streamKey: organizationId,
            stream: () => correctiveActionRepo.watchForOrganization(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _LoadingCard();
              }
              final actions = (snapshot.data ?? const <CorrectiveAction>[])
                  .where((a) => siteIds.contains(a.siteId))
                  .toList(growable: false);
              final openCount = actions.where((a) => !a.isCompleted).length;
              // The Foreman's own work: actions assigned to them (by their
              // Site Manager, e.g. from an incident) still to do.
              final mineCount = (snapshot.data ?? const <CorrectiveAction>[])
                  .where(
                    (a) =>
                        a.assignedTo == foremanUid &&
                        (a.status == CorrectiveActionStatus.open ||
                            a.status == CorrectiveActionStatus.inProgress),
                  )
                  .length;
              return DashboardGrid(
                children: [
                  KpiCard(
                    value: '$mineCount',
                    label: 'assigned to you',
                    icon: Icons.assignment_ind_outlined,
                    color: mineCount > 0
                        ? AppColors.correctiveActions
                        : AppColors.success,
                    onTap: () => context.go(AppRoutes.correctiveActions),
                  ),
                  KpiCard(
                    value: '$openCount',
                    label: 'open on your sites',
                    icon: Icons.build_outlined,
                    color: openCount > 0
                        ? AppColors.warning
                        : AppColors.success,
                    onTap: () => context.go(AppRoutes.correctiveActions),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DashboardSection(
          title: 'Quick Actions',
          icon: Icons.bolt,
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              ElevatedButton.icon(
                style: _quickActionStyle(AppColors.meetings),
                onPressed: () => context.go(AppRoutes.dailySafetyMeetings),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text("Today's Meeting"),
              ),
              ElevatedButton.icon(
                style: _quickActionStyle(AppColors.people),
                onPressed: () => context.go(AppRoutes.workers),
                icon: const Icon(Icons.groups_outlined),
                label: const Text('My Workers'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A Quick Action button filled in its feature's color.
  ButtonStyle _quickActionStyle(Color color) => ElevatedButton.styleFrom(
    backgroundColor: color,
    foregroundColor: AppColors.onColor(color),
    minimumSize: const Size(0, AppSpacing.minTouchTarget),
  );

  Stream<List<List<Hazard>>> _combineHazardStreams(
    HazardRepository repository,
    List<String> siteIds,
  ) {
    final streams = [
      for (final siteId in siteIds) repository.watchForSite(siteId),
    ];
    if (streams.length == 1) {
      return streams.single.map((hazards) => [hazards]);
    }
    return Stream.fromFuture(Future.wait(streams.map((s) => s.first)));
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

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
