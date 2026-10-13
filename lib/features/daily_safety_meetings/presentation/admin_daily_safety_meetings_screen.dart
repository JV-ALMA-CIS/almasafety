import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../organizations/presentation/site_select_list.dart';
import '../../../core/widgets/choice_list.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../activities/data/activity_repository.dart';
import '../../activities/domain/activity.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/domain/organization_user.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../organizations/data/project_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/organization.dart';
import '../../organizations/domain/project.dart';
import '../../organizations/domain/site.dart';
import '../../safety_meeting_points/data/safety_meeting_point_repository.dart';
import '../../safety_meeting_points/domain/safety_meeting_point.dart';
import '../data/daily_safety_meeting_repository.dart';
import '../data/meeting_attendance_repository.dart';
import '../data/meeting_concern_repository.dart';
import '../data/meeting_evidence_repository.dart';
import '../data/meeting_point_note_repository.dart';
import '../domain/daily_safety_meeting.dart';
import '../domain/meeting_attendance.dart';
import '../domain/meeting_attendance_status.dart';
import '../domain/meeting_concern.dart';
import '../domain/meeting_evidence.dart';
import '../domain/meeting_point_note.dart';
import '../../pre_start_checks/presentation/pre_start_outcome_style.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/feature_header.dart';

/// The administrator-facing Daily Safety Meeting review list: every meeting
/// recorded in one organization, most recent first — a read/history
/// function, not the foreman's operational meeting workspace
/// ([DailySafetyMeetingScreen]).
///
/// **Authorization**: an Admin (any organization), or any role of
/// [organization] for which [AppRole.canReviewDailySafetyMeetings] is true
/// ([AppRole.siteManager]) may view. A [AppRole.foreman] or [AppRole.worker]
/// cannot: this is a review surface,
/// not the foreman's own operational tool. There is no write path here at
/// all — an administrator can open a
/// completed or in-progress meeting's summary, but every field on
/// [DailySafetyMeeting] and its subcollections remains foreman-write-only
/// server-side (`createDailySafetyMeeting`/`updateDailySafetyMeeting`/
/// `completeDailySafetyMeeting`/`recordMeetingAttendance`/
/// `addMeetingConcern`/etc. all still require the caller to be the
/// meeting's own foreman) — this screen introduces no new backend
/// authorization, only a read surface for data an administrator's role
/// already has read access to under `firestore.rules`' existing
/// org-member-or-System-Administrator grant on `daily_safety_meetings`.
///
/// Reuses [DailySafetyMeetingRepository.watchAll] — the same org-wide read
/// [ReportsRepository.buildDailySafetyMeetingReport] already uses — rather
/// than introducing a second query path.
class AdminDailySafetyMeetingsScreen extends StatefulWidget {
  const AdminDailySafetyMeetingsScreen({
    required this.organization,
    super.key,
    this.firestoreService,
    this.meetingRepository,
    this.projectRepository,
    this.siteRepository,
    this.approvalService,
  });

  final Organization organization;

  /// Injected in tests, and threaded through to
  /// [DailySafetyMeetingSummaryScreen] when a meeting is opened, so a test's
  /// fake Firestore instance backs the whole drill-down, not just this list.
  /// Production builds pass nothing and every repository resolves the real
  /// Firebase instance lazily.
  final FirestoreService? firestoreService;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to [organization].
  final DailySafetyMeetingRepository? meetingRepository;
  final ProjectRepository? projectRepository;
  final SiteRepository? siteRepository;
  final AccountApprovalService? approvalService;

  @override
  State<AdminDailySafetyMeetingsScreen> createState() =>
      _AdminDailySafetyMeetingsScreenState();
}

class _AdminDailySafetyMeetingsScreenState
    extends State<AdminDailySafetyMeetingsScreen> {
  late final FirestoreService _firestoreService =
      widget.firestoreService ?? FirestoreService();
  late final DailySafetyMeetingRepository _meetingRepository =
      widget.meetingRepository ??
      DailySafetyMeetingRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
      );
  late final ProjectRepository _projectRepository =
      widget.projectRepository ??
      ProjectRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
      );
  late final SiteRepository _siteRepository =
      widget.siteRepository ??
      SiteRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
      );
  late final AccountApprovalService _approvalService =
      widget.approvalService ?? AccountApprovalService();

  /// The organization's active members, loaded once — resolves a
  /// `foremanId`/`workerId` uid to a human-readable name, matching
  /// [SiteWorkersScreen]/[ActivityWorkersScreen]'s established pattern.
  List<OrganizationUser> _members = const [];

  /// The project this list is filtered to, or null for "All projects" (the
  /// default). An organization running several projects at once otherwise
  /// blends every project's meetings into one list with only a small text
  /// line noting which project each card belongs to — this filter lets a
  /// Site Manager pull one project's meetings (and therefore its Foremen's
  /// dailies) on their own, e.g. to review Rosslyn Ridge separately from
  /// Italian Ambassador's Residence. Client-side only: [DailySafetyMeeting]
  /// already carries its own `projectId`, so no new query/index is needed.
  String? _selectedProjectId;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final users = await _approvalService.listUsers(
        status: AccountStatus.active,
        organizationId: widget.organization.id,
      );
      if (!mounted) return;
      setState(() => _members = users);
    } catch (_) {
      // A failed name lookup degrades to showing uids for foreman/attendee
      // fields rather than blocking the whole list — the meeting records
      // themselves are the primary content here.
    }
  }

  String? _nameFor(String uid) {
    for (final member in _members) {
      if (member.uid == uid) return member.name;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    // Checked against membershipFor(widget.organization.id) SPECIFICALLY,
    // not activeMembership — see ProjectsScreen's matching comment for why.
    final membershipRole = sessionController
        .membershipFor(widget.organization.id)
        ?.role;
    final canManage =
        isPlatformAdministrator ||
        (membershipRole?.canReviewDailySafetyMeetings ?? false);

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to view daily safety meetings.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return LiveStreamBuilder<List<DailySafetyMeeting>>(
      streamKey: _meetingRepository,
      stream: () => _meetingRepository.watchCompleted(),
      builder: (context, meetingSnapshot) {
        final meetings = meetingSnapshot.data ?? const <DailySafetyMeeting>[];
        final isLoading =
            meetingSnapshot.connectionState == ConnectionState.waiting;
        final hasError = meetingSnapshot.hasError;
        if (hasError) {
          // Surfaced only via debug output — the raw exception (e.g. a
          // Firestore parse/permission failure) is not user-safe, matching
          // AuthErrorBanner's "only ever fed a user-safe message" contract.
          debugPrint(
            'AdminDailySafetyMeetingsScreen: failed to load daily safety '
            'meetings for organization ${widget.organization.id}: '
            '${meetingSnapshot.error}',
          );
        }

        return LiveStreamBuilder<List<Project>>(
          streamKey: _projectRepository,
          stream: () => _projectRepository.watchAll(),
          builder: (context, projectSnapshot) {
            final projects = projectSnapshot.data ?? const <Project>[];
            final projectsById = {for (final p in projects) p.id: p};
            final selectedProjectId = _selectedProjectId;
            final filteredMeetings = selectedProjectId == null
                ? meetings
                : meetings
                      .where((m) => m.projectId == selectedProjectId)
                      .toList();

            return LiveStreamBuilder<List<Site>>(
              streamKey: _siteRepository,
              stream: () => _siteRepository.watchAll(),
              builder: (context, siteSnapshot) {
                final sitesById = {
                  for (final s in siteSnapshot.data ?? const <Site>[]) s.id: s,
                };

                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    FeatureHeader(
                      title: 'Daily Safety Meetings',
                      subtitle: widget.organization.name,
                      icon: Icons.groups,
                      color: AppColors.meetings,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (projects.isNotEmpty)
                      ChoiceList<String>(
                        label: 'Project',
                        items: [
                          for (final project in projects)
                            projectChoice(project),
                        ],
                        selected: selectedProjectId,
                        noneLabel: 'All projects',
                        searchHint: 'Search projects',
                        onChanged: (value) =>
                            setState(() => _selectedProjectId = value),
                      ),
                    if (projects.isNotEmpty)
                      const SizedBox(height: AppSpacing.md),
                    if (isLoading && !hasError && filteredMeetings.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (hasError)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                        child: AuthErrorBanner(
                          message:
                              'Unable to load daily safety meetings. '
                              'Please try again.',
                        ),
                      ),
                    if (!isLoading && !hasError && filteredMeetings.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xl,
                        ),
                        child: Text(
                          selectedProjectId == null
                              ? 'No daily safety meetings recorded yet.'
                              : 'No daily safety meetings recorded yet for '
                                    'this project.',
                          style: AppTextStyles.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    for (final meeting in filteredMeetings) ...[
                      _AdminMeetingCard(
                        meeting: meeting,
                        siteName:
                            sitesById[meeting.siteId]?.name ?? meeting.siteId,
                        projectName:
                            projectsById[meeting.projectId]?.name ??
                            meeting.projectId,
                        foremanName: _nameFor(meeting.foremanId),
                        onTap: () =>
                            Navigator.of(context, rootNavigator: true).push(
                              MaterialPageRoute<void>(
                                builder: (_) => DailySafetyMeetingSummaryScreen(
                                  organization: widget.organization,
                                  project: projectsById[meeting.projectId],
                                  site: sitesById[meeting.siteId],
                                  meeting: meeting,
                                  members: _members,
                                  firestoreService: _firestoreService,
                                ),
                              ),
                            ),
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
  }
}

class _AdminMeetingCard extends StatelessWidget {
  const _AdminMeetingCard({
    required this.meeting,
    required this.siteName,
    required this.projectName,
    required this.foremanName,
    required this.onTap,
  });

  final DailySafetyMeeting meeting;
  final String siteName;
  final String projectName;
  final String? foremanName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AccentCard(
      color: meeting.isCompleted ? AppColors.success : AppColors.meetings,
      icon: meeting.isCompleted ? Icons.task_alt : Icons.groups,
      title: '$siteName · ${meeting.date}',
      onTap: onTap,
      badges: [
        AccentBadge(
          label: meeting.status.label,
          color: meeting.isCompleted ? AppColors.success : AppColors.meetings,
        ),
      ],
      trailing: meeting.crewOutcome == null
          ? null
          : CrewOutcomeBadge(outcome: meeting.crewOutcome!),
      details: [
        AccentDetail(
          icon: Icons.person,
          text:
              'Project: $projectName · Foreman: '
              '${foremanName ?? meeting.foremanId}',
        ),
        AccentDetail(
          icon: Icons.checklist,
          text:
              '${meeting.activityIds.length} activities · '
              '${meeting.meetingPointIds.length} safety points · '
              '${meeting.concerns.length} concerns',
        ),
        if (meeting.ahasCovered.isNotEmpty)
          AccentDetail(
            icon: Icons.assignment_late,
            text:
                'AHA covered: '
                '${meeting.ahasCovered.map((a) => a.featureOfWork).join(', ')}',
          ),
      ],
    );
  }
}

/// A single meeting's read-only structured summary — the "prove that
/// Working at Height was covered, without knowing what language was
/// spoken" record described in PROJECT_CONTEXT.md §3/§7.
///
/// Assembled entirely from already-recorded structured data
/// (`DailySafetyMeeting`, `MeetingAttendance`, `MeetingConcern`,
/// `CorrectiveAction`, `SafetyMeetingPoint`, `Activity`) — there is no
/// audio, transcript or AI-generated content anywhere in this screen. If a
/// future Gemini-assisted summary is ever added on top of this data, it
/// must only restate what these already-verified records say, never invent
/// content — matching `AiGeneratedBadge`'s existing purpose elsewhere in
/// this codebase.
class DailySafetyMeetingSummaryScreen extends StatefulWidget {
  const DailySafetyMeetingSummaryScreen({
    required this.organization,
    required this.meeting,
    required this.members,
    super.key,
    this.project,
    this.site,
    this.firestoreService,
    this.attendanceRepository,
    this.concernRepository,
    this.correctiveActionRepository,
    this.activityRepository,
    this.meetingPointRepository,
    this.pointNoteRepository,
    this.evidenceRepository,
  });

  final Organization organization;
  final Project? project;
  final Site? site;
  final DailySafetyMeeting meeting;

  /// The organization's active members — reused from the caller
  /// ([AdminDailySafetyMeetingsScreen]) rather than re-fetched, so opening a
  /// summary doesn't repeat the same `listOrganizationUsers` call.
  final List<OrganizationUser> members;

  /// Injected in tests, and by [AdminDailySafetyMeetingsScreen] when opening
  /// a summary, so a test's fake Firestore instance backs every repository
  /// below. Production builds pass nothing and every repository resolves
  /// the real Firebase instance lazily.
  final FirestoreService? firestoreService;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies.
  final MeetingAttendanceRepository? attendanceRepository;
  final MeetingConcernRepository? concernRepository;
  final CorrectiveActionRepository? correctiveActionRepository;
  final ActivityRepository? activityRepository;
  final SafetyMeetingPointRepository? meetingPointRepository;
  final MeetingPointNoteRepository? pointNoteRepository;
  final MeetingEvidenceRepository? evidenceRepository;

  @override
  State<DailySafetyMeetingSummaryScreen> createState() =>
      _DailySafetyMeetingSummaryScreenState();
}

class _DailySafetyMeetingSummaryScreenState
    extends State<DailySafetyMeetingSummaryScreen> {
  late final FirestoreService _firestoreService =
      widget.firestoreService ?? FirestoreService();
  late final MeetingAttendanceRepository _attendanceRepository =
      widget.attendanceRepository ??
      MeetingAttendanceRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
        meetingId: widget.meeting.id,
      );
  late final MeetingConcernRepository _concernRepository =
      widget.concernRepository ??
      MeetingConcernRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
        meetingId: widget.meeting.id,
      );
  late final CorrectiveActionRepository _correctiveActionRepository =
      widget.correctiveActionRepository ??
      CorrectiveActionRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
      );
  late final ActivityRepository _activityRepository =
      widget.activityRepository ??
      ActivityRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
      );
  late final SafetyMeetingPointRepository _meetingPointRepository =
      widget.meetingPointRepository ??
      SafetyMeetingPointRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
      );
  late final MeetingPointNoteRepository _pointNoteRepository =
      widget.pointNoteRepository ??
      MeetingPointNoteRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
        meetingId: widget.meeting.id,
      );
  late final MeetingEvidenceRepository _evidenceRepository =
      widget.evidenceRepository ??
      MeetingEvidenceRepository(
        firestoreService: _firestoreService,
        organizationId: widget.organization.id,
        meetingId: widget.meeting.id,
      );

  String? _nameFor(String uid) {
    for (final member in widget.members) {
      if (member.uid == uid) return member.name;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final meeting = widget.meeting;

    return Scaffold(
      appBar: AppBar(),
      body: LiveStreamBuilder<List<Activity>>(
        streamKey: (_activityRepository, meeting.siteId),
        stream: () => _activityRepository.watchBySite(meeting.siteId),
        builder: (context, activitySnapshot) {
          final activitiesById = {
            for (final a in activitySnapshot.data ?? const <Activity>[])
              a.id: a,
          };

          return LiveStreamBuilder<List<SafetyMeetingPoint>>(
            streamKey: _meetingPointRepository,
            stream: () => _meetingPointRepository.watchAll(),
            builder: (context, pointSnapshot) {
              final pointsById = {
                for (final p
                    in pointSnapshot.data ?? const <SafetyMeetingPoint>[])
                  p.id: p,
              };

              return LiveStreamBuilder<List<MeetingAttendance>>(
                streamKey: _attendanceRepository,
                stream: () => _attendanceRepository.watchAll(),
                builder: (context, attendanceSnapshot) {
                  final attendance =
                      attendanceSnapshot.data ?? const <MeetingAttendance>[];

                  return LiveStreamBuilder<List<MeetingConcern>>(
                    streamKey: _concernRepository,
                    stream: () => _concernRepository.watchAll(),
                    builder: (context, concernSnapshot) {
                      final concerns =
                          concernSnapshot.data ?? const <MeetingConcern>[];

                      return LiveStreamBuilder<List<CorrectiveAction>>(
                        streamKey: (_correctiveActionRepository, meeting.id),
                        stream: () => _correctiveActionRepository
                            .watchForMeeting(meeting.id),
                        builder: (context, actionSnapshot) {
                          final actions =
                              actionSnapshot.data ?? const <CorrectiveAction>[];

                          return LiveStreamBuilder<List<MeetingPointNote>>(
                            streamKey: _pointNoteRepository,
                            stream: () => _pointNoteRepository.watchAll(),
                            builder: (context, noteSnapshot) {
                              final notesByPointId = {
                                for (final n
                                    in noteSnapshot.data ??
                                        const <MeetingPointNote>[])
                                  n.meetingPointId: n,
                              };

                              return LiveStreamBuilder<List<MeetingEvidence>>(
                                streamKey: _evidenceRepository,
                                stream: () => _evidenceRepository.watchAll(),
                                builder: (context, evidenceSnapshot) {
                                  final evidence =
                                      evidenceSnapshot.data ??
                                      const <MeetingEvidence>[];

                                  return ListView(
                                    padding: const EdgeInsets.all(
                                      AppSpacing.md,
                                    ),
                                    children: [
                                      FeatureHeader(
                                        eyebrow: 'Daily Safety Meeting',
                                        title:
                                            '${widget.site?.name ?? meeting.siteId}'
                                            ' — ${meeting.status.label}',
                                        icon: meeting.isCompleted
                                            ? Icons.task_alt
                                            : Icons.groups,
                                        color: meeting.isCompleted
                                            ? AppColors.success
                                            : AppColors.meetings,
                                        chips: [
                                          FeatureChip(
                                            icon: Icons.handyman,
                                            label:
                                                '${meeting.activityIds.length} '
                                                'activities',
                                          ),
                                          FeatureChip(
                                            icon: Icons.checklist,
                                            label:
                                                '${meeting.meetingPointIds.length} '
                                                'safety points',
                                          ),
                                          FeatureChip(
                                            icon: Icons.report_problem,
                                            label:
                                                '${meeting.concerns.length} '
                                                'concerns',
                                          ),
                                        ],
                                        trailing: meeting.crewOutcome == null
                                            ? null
                                            : CrewOutcomeBadge(
                                                outcome: meeting.crewOutcome!,
                                              ),
                                      ),
                                      const SizedBox(height: AppSpacing.md),
                                      _SummarySection(
                                        title: 'Meeting Information',
                                        children: [
                                          _InfoRow(
                                            'Organization',
                                            widget.organization.name,
                                          ),
                                          _InfoRow(
                                            'Project',
                                            widget.project?.name ??
                                                meeting.projectId,
                                          ),
                                          _InfoRow(
                                            'Site',
                                            widget.site?.name ?? meeting.siteId,
                                          ),
                                          _InfoRow('Date', meeting.date),
                                          _InfoRow(
                                            'Foreman',
                                            _nameFor(meeting.foremanId) ??
                                                meeting.foremanId,
                                          ),
                                          _InfoRow(
                                            'Status',
                                            meeting.status.label,
                                          ),
                                          if (meeting.crewOutcome != null)
                                            _InfoRow(
                                              'Crew result',
                                              [
                                                meeting.crewOutcome!.label,
                                                ?meeting.crewOutcomeNote,
                                              ].join(' — '),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: AppSpacing.lg),
                                      _SummarySection(
                                        title: 'Activities Discussed',
                                        children: meeting.activityIds.isEmpty
                                            ? [
                                                const Text(
                                                  'No activities recorded.',
                                                  style:
                                                      AppTextStyles.bodyMedium,
                                                ),
                                              ]
                                            : [
                                                for (final id
                                                    in meeting.activityIds)
                                                  _BulletRow(
                                                    activitiesById[id]?.name ??
                                                        id,
                                                  ),
                                              ],
                                      ),
                                      const SizedBox(height: AppSpacing.lg),
                                      _SummarySection(
                                        title: 'Risk Assessments (AHA) Covered',
                                        children: meeting.ahasCovered.isEmpty
                                            ? [
                                                const Text(
                                                  'No risk assessment '
                                                  'recorded.',
                                                  style:
                                                      AppTextStyles.bodyMedium,
                                                ),
                                              ]
                                            : [
                                                for (final aha
                                                    in meeting.ahasCovered)
                                                  _BulletRow(
                                                    aha.featureOfWork,
                                                    subtitle:
                                                        'Revision '
                                                        '${aha.revision}',
                                                  ),
                                              ],
                                      ),
                                      const SizedBox(height: AppSpacing.lg),
                                      _SummarySection(
                                        title: 'Safety Points Covered',
                                        children:
                                            meeting.meetingPointIds.isEmpty
                                            ? [
                                                const Text(
                                                  'No safety points recorded.',
                                                  style:
                                                      AppTextStyles.bodyMedium,
                                                ),
                                              ]
                                            : [
                                                for (final id
                                                    in meeting.meetingPointIds)
                                                  _BulletRow(
                                                    pointsById[id]?.title ?? id,
                                                    subtitle: notesByPointId[id]
                                                        ?.note,
                                                  ),
                                              ],
                                      ),
                                      const SizedBox(height: AppSpacing.lg),
                                      _SummarySection(
                                        title:
                                            'Attendance '
                                            '(${attendance.where((a) => a.status == MeetingAttendanceStatus.present).length}/'
                                            '${attendance.length})',
                                        children: attendance.isEmpty
                                            ? [
                                                const Text(
                                                  'No attendance recorded.',
                                                  style:
                                                      AppTextStyles.bodyMedium,
                                                ),
                                              ]
                                            : [
                                                for (final record in attendance)
                                                  _BulletRow(
                                                    '${_nameFor(record.workerId) ?? record.workerId} '
                                                    '— ${record.status.label}',
                                                  ),
                                              ],
                                      ),
                                      const SizedBox(height: AppSpacing.lg),
                                      _SummarySection(
                                        title: 'Concerns',
                                        children: concerns.isEmpty
                                            ? [
                                                const Text(
                                                  'No concerns recorded.',
                                                  style:
                                                      AppTextStyles.bodyMedium,
                                                ),
                                              ]
                                            : [
                                                for (final concern in concerns)
                                                  _BulletRow(
                                                    '${concern.category.label}: '
                                                    '${concern.description}',
                                                  ),
                                              ],
                                      ),
                                      const SizedBox(height: AppSpacing.lg),
                                      _SummarySection(
                                        title: 'Corrective Actions',
                                        children: actions.isEmpty
                                            ? [
                                                const Text(
                                                  'No corrective actions recorded.',
                                                  style:
                                                      AppTextStyles.bodyMedium,
                                                ),
                                              ]
                                            : [
                                                for (final action in actions)
                                                  _BulletRow(
                                                    '${action.title} — '
                                                    '${action.status.label} '
                                                    '(assigned: '
                                                    '${_nameFor(action.assignedTo) ?? action.assignedTo})',
                                                  ),
                                              ],
                                      ),
                                      const SizedBox(height: AppSpacing.lg),
                                      _EvidenceSummarySection(
                                        evidence: evidence,
                                      ),
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
            },
          );
        },
      ),
    );
  }
}

/// One section of the meeting summary: its own colored card, so meeting
/// information, activities, safety points, attendance, concerns, actions
/// and evidence are clearly separated.
class _SummarySection extends StatelessWidget {
  const _SummarySection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  (Color, IconData) get _style {
    final lower = title.toLowerCase();
    if (lower.startsWith('meeting information')) {
      return (AppColors.meetings, Icons.info);
    }
    if (lower.startsWith('activities')) {
      return (AppColors.projects, Icons.handyman);
    }
    if (lower.startsWith('safety points')) {
      return (AppColors.meetings, Icons.checklist);
    }
    if (lower.startsWith('attendance')) {
      return (AppColors.people, Icons.how_to_reg);
    }
    if (lower.startsWith('concerns')) {
      return (AppColors.hazards, Icons.report_problem);
    }
    if (lower.startsWith('corrective')) {
      return (AppColors.correctiveActions, Icons.build_circle);
    }
    if (lower.startsWith('evidence')) {
      return (AppColors.analytics, Icons.photo_camera);
    }
    return (AppColors.primaryBright, Icons.article);
  }

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _style;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FeatureSectionTitle(title: title, icon: icon, color: color),
            const SizedBox(height: AppSpacing.sm),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 96, child: Text(label, style: AppTextStyles.label)),
          Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

/// The read-only "Evidence" section of a completed meeting's summary —
/// supporting photos/documents (a handwritten safety-book photo, a sign-in
/// sheet, a briefing/site photo). Shows a placeholder when empty rather
/// than omitting the section, so a Site Manager reviewing the record can
/// tell "no evidence attached" apart from "this screen doesn't show
/// evidence at all" — the absence itself is signal worth surfacing.
class _EvidenceSummarySection extends StatelessWidget {
  const _EvidenceSummarySection({required this.evidence});

  final List<MeetingEvidence> evidence;

  @override
  Widget build(BuildContext context) {
    return _SummarySection(
      title: 'Evidence',
      children: evidence.isEmpty
          ? const [
              Text('No evidence attached.', style: AppTextStyles.bodyMedium),
            ]
          : [
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final item in evidence) _EvidenceThumbnail(item: item),
                ],
              ),
            ],
    );
  }
}

class _EvidenceThumbnail extends StatelessWidget {
  const _EvidenceThumbnail({required this.item});

  final MeetingEvidence item;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: item.isImage
              ? InteractiveViewer(child: Image.network(item.downloadUrl))
              : Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    item.description ?? item.evidenceType.label,
                    style: AppTextStyles.bodyMedium,
                  ),
                ),
        ),
      ),
      child: SizedBox(
        width: 96,
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: item.isImage
                  ? Image.network(
                      item.downloadUrl,
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          const Icon(Icons.broken_image_outlined, size: 96),
                    )
                  : Container(
                      width: 96,
                      height: 96,
                      color: AppColors.textSecondary.withValues(alpha: 0.08),
                      child: const Icon(Icons.description_outlined, size: 40),
                    ),
            ),
            const SizedBox(height: 2),
            Text(
              item.evidenceType.label,
              style: AppTextStyles.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _BulletRow extends StatelessWidget {
  const _BulletRow(this.text, {this.subtitle});

  final String text;

  /// An optional secondary line shown under [text] — used for a covered
  /// meeting point's DISCUSSION CONTEXT note (what was actually explained,
  /// kept deliberately separate from Concerns; see [MeetingPointNote]'s doc
  /// comment). Null for every other use of this row.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check, size: 16, color: AppColors.success),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: AppTextStyles.bodyMedium),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: AppTextStyles.label.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
