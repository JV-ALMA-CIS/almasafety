import 'dart:async';
import '../../../core/widgets/photo_capture.dart';
import '../../corrective_actions/presentation/evidence_requirement_picker.dart';
import '../../corrective_actions/domain/corrective_action_evidence.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/widgets/choice_list.dart';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../routing/app_routes.dart';
import '../../activities/data/activity_admin_service.dart';
import '../../activities/data/activity_assignment_repository.dart';
import '../../activities/domain/activity.dart';
import '../../activities/domain/activity_assignment.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/domain/organization_user.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/data/corrective_action_service.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
import '../../safety_learning/data/worker_learning_repository.dart';
import '../../safety_learning/domain/worker_learning_record.dart';
import '../../safety_learning/domain/worker_learning_status.dart';
import '../../safety_meeting_points/data/safety_meeting_point_repository.dart';
import '../../safety_meeting_points/domain/safety_meeting_point.dart';
import '../data/daily_safety_meeting_repository.dart';
import '../data/daily_safety_meeting_service.dart';
import '../data/meeting_attendance_repository.dart';
import '../data/meeting_attendance_service.dart';
import '../data/meeting_concern_repository.dart';
import '../data/meeting_concern_service.dart';
import '../data/meeting_evidence_repository.dart';
import '../data/meeting_point_note_repository.dart';
import '../domain/daily_safety_meeting.dart';
import '../domain/meeting_attendance.dart';
import '../domain/meeting_attendance_status.dart';
import '../domain/meeting_concern.dart';
import '../domain/meeting_concern_category.dart';
import '../domain/meeting_evidence.dart';
import '../domain/meeting_evidence_type.dart';
import '../domain/meeting_point_note.dart';
import '../../../core/widgets/status_badge.dart';
import '../../pre_start_checks/presentation/crew_outcome_dialog.dart';
import '../../pre_start_checks/presentation/pre_start_outcome_style.dart';
import '../../pre_start_checks/presentation/pre_start_visuals.dart';
import '../../risk_assessments/data/risk_assessment_repository.dart';
import '../../risk_assessments/domain/risk_assessment.dart';
import '../../risk_assessments/presentation/risk_assessments_screen.dart';
import 'daily_safety_meeting_history_screen.dart';
import 'worker_todays_meeting_card.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/person_picker.dart';

String _today() {
  final now = DateTime.now();
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  return '${now.year}-$month-$day';
}

/// The foreman's Daily Safety Meeting flow for their assigned site, today.
///
/// **Record-keeping only.** This screen never records audio, transcribes
/// speech or requires a particular language — see
/// `DailySafetyMeetingService`'s doc comment. It is a structured form: pick
/// which activities and (recommended) meeting points the physical toolbox
/// talk covered, note any concerns as plain text, and mark it complete.
///
/// Reachable only by an active `foreman` with at least one assigned site
/// (`profile.siteIds`, granted by `assignWorkerToSite` — see
/// [SessionController.profile]'s doc comment). A foreman with more than one
/// assigned site sees the first; multi-site selection is out of scope for
/// this foundation. This is UX only — `createDailySafetyMeeting` re-verifies
/// site access server-side regardless.
///
/// Flow:
///  1. Resolve today's meeting for this foreman+site (resume if one already
///     exists; otherwise this screen starts one, seeded with today's site
///     activities and the meeting points whose `applicableActivities`
///     overlap them — the "recommended" set).
///  2. The foreman accepts/removes/adds activities and meeting points.
///  3. The foreman records concerns as free text.
///  4. The foreman completes the meeting.
class DailySafetyMeetingScreen extends StatefulWidget {
  const DailySafetyMeetingScreen({
    super.key,
    this.resumeMeetingId,
    this.meetingRepository,
    this.meetingService,
    this.meetingPointRepository,
    this.siteRepository,
    this.activityAssignmentRepository,
    this.attendanceService,
    this.attendanceRepositoryBuilder,
    this.concernService,
    this.concernRepositoryBuilder,
    this.correctiveActionService,
    this.correctiveActionRepository,
    this.pointNoteRepositoryBuilder,
    this.evidenceRepositoryBuilder,
    this.imagePicker,
    this.workerLearningRepository,
    this.riskAssessmentRepository,
    this.approvalService,
    this.activityAdminService,
  });

  /// When given, this screen resumes that SPECIFIC meeting instead of
  /// resolving "today's meeting" for the signed-in foreman's site — how a
  /// Foreman reopens a past, forgotten in-progress meeting from
  /// [DailySafetyMeetingHistoryScreen] to finish and complete it days
  /// later. Server-side authorization is unaffected either way: every
  /// callable this screen calls independently re-verifies the caller is
  /// that specific meeting's own foreman.
  final String? resumeMeetingId;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in foreman's
  /// organization.
  final DailySafetyMeetingRepository? meetingRepository;
  final DailySafetyMeetingService? meetingService;
  final SafetyMeetingPointRepository? meetingPointRepository;
  final SiteRepository? siteRepository;
  final ActivityAssignmentRepository? activityAssignmentRepository;
  final MeetingAttendanceService? attendanceService;

  /// Injected in tests: builds a [MeetingAttendanceRepository] for a given
  /// meeting id, since that repository is scoped per-meeting rather than
  /// per-organization.
  final MeetingAttendanceRepository Function(String meetingId)?
  attendanceRepositoryBuilder;

  final MeetingConcernService? concernService;

  /// Injected in tests: builds a [MeetingConcernRepository] for a given
  /// meeting id, mirroring [attendanceRepositoryBuilder].
  final MeetingConcernRepository Function(String meetingId)?
  concernRepositoryBuilder;

  final CorrectiveActionService? correctiveActionService;

  /// Injected in tests. Unlike the meeting/attendance/concern repositories,
  /// this one is scoped to the organization only (not to one meeting) since
  /// corrective actions are stored flat — see
  /// [CorrectiveActionRepository]'s doc comment.
  final CorrectiveActionRepository? correctiveActionRepository;

  /// Injected in tests: builds a [MeetingPointNoteRepository] for a given
  /// meeting id, mirroring [attendanceRepositoryBuilder]/
  /// [concernRepositoryBuilder].
  final MeetingPointNoteRepository Function(String meetingId)?
  pointNoteRepositoryBuilder;

  /// Injected in tests: builds a [MeetingEvidenceRepository] for a given
  /// meeting id, mirroring [pointNoteRepositoryBuilder].
  final MeetingEvidenceRepository Function(String meetingId)?
  evidenceRepositoryBuilder;

  /// Injected in tests to avoid touching the platform camera/gallery,
  /// mirroring [ReportHazardScreen]'s own injection.
  final ImagePicker? imagePicker;

  /// Injected in tests. Backs `getSiteActivities` — a Foreman's
  /// `firestore.rules` grant on `activities` does not cover LIST queries
  /// at all (see that rule's own doc comment), so today's site activities
  /// are resolved via this callable instead of [ActivityRepository
  /// .watchBySite].
  final ActivityAdminService? activityAdminService;

  /// Injected in tests: lets the Safety Learning gate preview drop lessons
  /// the moment they are completed — see [_LearningGateBanner].
  final WorkerLearningRepository? workerLearningRepository;

  /// Injected in tests: the site's risk assessments (AHAs) the Foreman
  /// covers with the crew.
  final RiskAssessmentRepository? riskAssessmentRepository;

  /// Injected in tests: resolves an attendee's uid to a display name for
  /// [_AttendanceSection] — see [AdminDailySafetyMeetingsScreen]'s matching
  /// `_nameFor` pattern.
  final AccountApprovalService? approvalService;

  @override
  State<DailySafetyMeetingScreen> createState() =>
      _DailySafetyMeetingScreenState();
}

class _DailySafetyMeetingScreenState extends State<DailySafetyMeetingScreen> {
  late final DailySafetyMeetingService _meetingService =
      widget.meetingService ?? DailySafetyMeetingService();
  late final MeetingAttendanceService _attendanceService =
      widget.attendanceService ?? MeetingAttendanceService();
  late final MeetingConcernService _concernService =
      widget.concernService ?? MeetingConcernService();
  late final CorrectiveActionService _correctiveActionService =
      widget.correctiveActionService ?? CorrectiveActionService();
  late final ImagePicker _imagePicker = widget.imagePicker ?? ImagePicker();
  late final AccountApprovalService _approvalService =
      widget.approvalService ?? AccountApprovalService();
  late final ActivityAdminService _activityAdminService =
      widget.activityAdminService ?? ActivityAdminService();

  /// The organization's active members, loaded once — resolves an
  /// attendee's uid to a display name, matching
  /// [AdminDailySafetyMeetingsScreen]'s established `_nameFor` pattern.
  List<OrganizationUser> _members = const [];
  String? _membersLoadedForOrganizationId;

  DailySafetyMeetingRepository? _meetingRepository;
  SafetyMeetingPointRepository? _meetingPointRepository;
  SiteRepository? _siteRepository;
  ActivityAssignmentRepository? _activityAssignmentRepository;
  CorrectiveActionRepository? _correctiveActionRepository;
  WorkerLearningRepository? _workerLearningRepository;
  RiskAssessmentRepository? _riskAssessmentRepository;

  String? _errorMessage;
  bool _isSaving = false;
  bool _isStartingMeeting = false;

  DailySafetyMeetingRepository _meetingRepositoryFor(String organizationId) {
    final existing = _meetingRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.meetingRepository ??
        DailySafetyMeetingRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _meetingRepository = created;
    return created;
  }

  SafetyMeetingPointRepository _meetingPointRepositoryFor(
    String organizationId,
  ) {
    final existing = _meetingPointRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.meetingPointRepository ??
        SafetyMeetingPointRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _meetingPointRepository = created;
    return created;
  }

  SiteRepository _siteRepositoryFor(String organizationId) {
    final existing = _siteRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.siteRepository ??
        SiteRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _siteRepository = created;
    return created;
  }

  ActivityAssignmentRepository _activityAssignmentRepositoryFor(
    String organizationId,
  ) {
    final existing = _activityAssignmentRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.activityAssignmentRepository ??
        ActivityAssignmentRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _activityAssignmentRepository = created;
    return created;
  }

  MeetingAttendanceRepository _attendanceRepositoryFor(
    String organizationId,
    String meetingId,
  ) {
    if (widget.attendanceRepositoryBuilder != null) {
      return widget.attendanceRepositoryBuilder!(meetingId);
    }
    return MeetingAttendanceRepository(
      firestoreService: FirestoreService(),
      organizationId: organizationId,
      meetingId: meetingId,
    );
  }

  MeetingConcernRepository _concernRepositoryFor(
    String organizationId,
    String meetingId,
  ) {
    if (widget.concernRepositoryBuilder != null) {
      return widget.concernRepositoryBuilder!(meetingId);
    }
    return MeetingConcernRepository(
      firestoreService: FirestoreService(),
      organizationId: organizationId,
      meetingId: meetingId,
    );
  }

  MeetingPointNoteRepository _pointNoteRepositoryFor(
    String organizationId,
    String meetingId,
  ) {
    if (widget.pointNoteRepositoryBuilder != null) {
      return widget.pointNoteRepositoryBuilder!(meetingId);
    }
    return MeetingPointNoteRepository(
      firestoreService: FirestoreService(),
      organizationId: organizationId,
      meetingId: meetingId,
    );
  }

  MeetingEvidenceRepository _evidenceRepositoryFor(
    String organizationId,
    String meetingId,
  ) {
    if (widget.evidenceRepositoryBuilder != null) {
      return widget.evidenceRepositoryBuilder!(meetingId);
    }
    return MeetingEvidenceRepository(
      firestoreService: FirestoreService(),
      organizationId: organizationId,
      meetingId: meetingId,
    );
  }

  CorrectiveActionRepository _correctiveActionRepositoryFor(
    String organizationId,
  ) {
    final existing = _correctiveActionRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.correctiveActionRepository ??
        CorrectiveActionRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _correctiveActionRepository = created;
    return created;
  }

  WorkerLearningRepository _workerLearningRepositoryFor(String organizationId) {
    final existing = _workerLearningRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.workerLearningRepository ??
        WorkerLearningRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _workerLearningRepository = created;
    return created;
  }

  RiskAssessmentRepository _riskAssessmentRepositoryFor(String organizationId) {
    final existing = _riskAssessmentRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.riskAssessmentRepository ??
        RiskAssessmentRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _riskAssessmentRepository = created;
    return created;
  }

  String? _siteActivitiesKey;
  Future<List<Activity>>? _siteActivitiesFuture;

  /// The site's active activities, fetched once per (organization, site)
  /// pair and cached across rebuilds — `getSiteActivities` is a Cloud
  /// Functions call, not a live Firestore stream, so without this cache a
  /// fresh call (and its own brief empty-then-populated flash) would fire
  /// on every rebuild this screen goes through (e.g. every keystroke or
  /// unrelated `setState`, since this widget is otherwise built entirely
  /// from nested `StreamBuilder`s). See this screen's own flicker fix —
  /// caching the future is what lets `_StartMeetingView` and
  /// `_MeetingWorkspace` settle once instead of re-flashing on every
  /// rebuild.
  Future<List<Activity>> _siteActivitiesFor(
    String organizationId,
    String siteId,
  ) {
    final key = '$organizationId/$siteId';
    if (_siteActivitiesKey == key && _siteActivitiesFuture != null) {
      return _siteActivitiesFuture!;
    }
    _siteActivitiesKey = key;
    final future = _activityAdminService.getSiteActivities(
      organizationId: organizationId,
      siteId: siteId,
    );
    _siteActivitiesFuture = future;
    return future;
  }

  Future<void> _startMeeting({
    required String organizationId,
    required String projectId,
    required String siteId,
    required List<Activity> todaysActivities,
    required List<SafetyMeetingPoint> recommendedPoints,
  }) async {
    setState(() {
      _isStartingMeeting = true;
      _errorMessage = null;
    });
    try {
      await _meetingService.createDailySafetyMeeting(
        organizationId: organizationId,
        projectId: projectId,
        siteId: siteId,
        activityIds: todaysActivities.map((a) => a.id).toList(),
        meetingPointIds: recommendedPoints.map((p) => p.id).toList(),
      );
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isStartingMeeting = false);
    }
  }

  Future<void> _save(Future<void> Function() action) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await action();
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _loadMembers(String organizationId) async {
    try {
      final users = await _approvalService.listUsers(
        status: AccountStatus.active,
        organizationId: organizationId,
      );
      if (!mounted) return;
      setState(() => _members = users);
    } catch (_) {
      // A failed name lookup degrades to showing uids in the attendance
      // list rather than blocking the whole workspace — mirrors
      // AdminDailySafetyMeetingsScreen's own _loadMembers.
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final membership = sessionController.activeMembership;
    final organizationId = sessionController.activeOrganizationId;
    final isForeman = membership?.role == AppRole.foreman;
    final siteId = membership?.siteIds.isNotEmpty == true
        ? membership!.siteIds.first
        : null;

    // A Worker reaching here (via DailySafetyMeetingsRouterScreen's
    // fallthrough — see that screen's doc comment) has no operational
    // workspace of their own on this screen: they never run or attend the
    // meeting IN the app, only the physical toolbox talk on site (see this
    // class's own header doc comment). They should still see the real
    // thing, though — today's meeting for their site and their own
    // present/absent status — rather than a static pointer to ask their
    // foreman, reusing exactly the query [WorkerDashboardScreen]'s "Today's
    // Meeting" card already uses, so both surfaces agree.
    if (membership?.role == AppRole.worker && organizationId != null) {
      final workerSiteIds = membership?.siteIds ?? const [];
      final workerUid = profile?.uid;
      if (workerUid == null) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Text(
              'Your account could not be loaded.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const FeatureHeader(
              title: "Today's Meeting",
              icon: Icons.groups,
              color: AppColors.meetings,
            ),
            const SizedBox(height: AppSpacing.md),
            const Text(
              'Daily Safety Meetings are run by your foreman as an '
              'in-person briefing — this shows what was recorded for your '
              'site today.',
              style: AppTextStyles.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            WorkerTodaysMeetingCard(
              meetingRepository: _meetingRepositoryFor(organizationId),
              attendanceRepositoryFor: (meetingId) =>
                  _attendanceRepositoryFor(organizationId, meetingId),
              siteIds: workerSiteIds,
              workerUid: workerUid,
            ),
          ],
        ),
      );
    }

    if (!isForeman || organizationId == null || siteId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Daily Safety Meetings are available to a foreman assigned to '
            'a site.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_membersLoadedForOrganizationId != organizationId) {
      _membersLoadedForOrganizationId = organizationId;
      unawaited(_loadMembers(organizationId));
    }

    final date = _today();
    final resumeMeetingId = widget.resumeMeetingId;

    // Resuming a specific past meeting (from history) reads that one
    // document directly rather than the "today's meeting" query — see
    // [DailySafetyMeetingScreen.resumeMeetingId]'s doc comment. Wrapped to
    // the same List<DailySafetyMeeting> shape the rest of this build()
    // already expects, so the branch below is unchanged either way.
    final uid = profile!.uid;
    final meetingStream = resumeMeetingId != null
        ? _meetingRepositoryFor(organizationId)
              .watchById(resumeMeetingId)
              .map((m) => m == null ? const <DailySafetyMeeting>[] : [m])
        : _meetingRepositoryFor(organizationId).watchForForemanSiteAndDate(
            foremanId: uid,
            siteId: siteId,
            date: date,
          );

    return LiveStreamBuilder<List<DailySafetyMeeting>>(
      streamKey: (organizationId, resumeMeetingId, uid, siteId, date),
      stream: () => meetingStream,
      builder: (context, meetingSnapshot) {
        if (meetingSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (meetingSnapshot.hasError) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text(
                "Could not load today's meeting. Please try again.",
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final existing = meetingSnapshot.data?.firstOrNull;
        if (existing != null) {
          return _MeetingWorkspace(
            meeting: existing,
            organizationId: organizationId,
            // The MEETING's own site, not the foreman's current one — they
            // can differ when resuming a past meeting after a reassignment.
            siteId: existing.siteId,
            currentUid: uid,
            meetingService: _meetingService,
            attendanceService: _attendanceService,
            concernService: _concernService,
            correctiveActionService: _correctiveActionService,
            siteActivitiesFuture: _siteActivitiesFor,
            meetingPointRepository: _meetingPointRepositoryFor(organizationId),
            activityAssignmentRepository: _activityAssignmentRepositoryFor(
              organizationId,
            ),
            attendanceRepository: _attendanceRepositoryFor(
              organizationId,
              existing.id,
            ),
            concernRepository: _concernRepositoryFor(
              organizationId,
              existing.id,
            ),
            correctiveActionRepository: _correctiveActionRepositoryFor(
              organizationId,
            ),
            pointNoteRepository: _pointNoteRepositoryFor(
              organizationId,
              existing.id,
            ),
            evidenceRepository: _evidenceRepositoryFor(
              organizationId,
              existing.id,
            ),
            imagePicker: _imagePicker,
            workerLearningRepository: _workerLearningRepositoryFor(
              organizationId,
            ),
            riskAssessmentRepository: _riskAssessmentRepositoryFor(
              organizationId,
            ),
            members: _members,
            isSaving: _isSaving,
            errorMessage: _errorMessage,
            onSave: _save,
          );
        }

        if (resumeMeetingId != null) {
          // A specific meeting was requested (resuming from history) but no
          // longer exists/resolves — an error, not "start a new one".
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'That meeting could not be found.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return _StartMeetingView(
          organizationId: organizationId,
          siteId: siteId,
          currentUid: uid,
          siteRepository: _siteRepositoryFor(organizationId),
          siteActivitiesFuture: _siteActivitiesFor,
          meetingPointRepository: _meetingPointRepositoryFor(organizationId),
          meetingService: _meetingService,
          workerLearningRepository: _workerLearningRepositoryFor(
            organizationId,
          ),
          isStarting: _isStartingMeeting,
          errorMessage: _errorMessage,
          onStart: _startMeeting,
        );
      },
    );
  }
}

/// Step 1-2: resolves today's site activities and the CANDIDATE meeting
/// points (those whose `applicableActivities` overlaps today's activities,
/// or which apply universally), and lets the foreman pick which of those
/// candidates actually apply this morning before starting the meeting.
///
/// **Candidates are NOT pre-selected.** A Site Manager's meeting point
/// library is typically built up once to cover every activity a site ever
/// runs, not re-authored daily — on any given morning only a subset is
/// actually relevant, so this screen makes the foreman actively check the
/// ones covered today rather than starting with everything pre-checked and
/// having to individually remove what doesn't apply. See this widget's
/// state class for the selection mechanics.
///
/// The actual accept/remove/add step still happens in [_MeetingWorkspace]
/// after the meeting is created — the selection here is only what the
/// meeting is SEEDED with; nothing is final until the foreman edits and
/// completes it.
class _StartMeetingView extends StatefulWidget {
  const _StartMeetingView({
    required this.organizationId,
    required this.siteId,
    required this.currentUid,
    required this.siteRepository,
    required this.siteActivitiesFuture,
    required this.meetingPointRepository,
    required this.meetingService,
    required this.workerLearningRepository,
    required this.isStarting,
    required this.errorMessage,
    required this.onStart,
  });

  final String organizationId;
  final String siteId;
  final String currentUid;
  final SiteRepository siteRepository;

  /// Resolves and caches today's site activities across rebuilds — see
  /// [_DailySafetyMeetingScreenState._siteActivitiesFor]'s doc comment for
  /// why this must not be a fresh `Stream.fromFuture` per build.
  final Future<List<Activity>> Function(String organizationId, String siteId)
  siteActivitiesFuture;
  final SafetyMeetingPointRepository meetingPointRepository;
  final DailySafetyMeetingService meetingService;
  final WorkerLearningRepository workerLearningRepository;
  final bool isStarting;
  final String? errorMessage;
  final Future<void> Function({
    required String organizationId,
    required String projectId,
    required String siteId,
    required List<Activity> todaysActivities,
    required List<SafetyMeetingPoint> recommendedPoints,
  })
  onStart;

  @override
  State<_StartMeetingView> createState() => _StartMeetingViewState();
}

class _StartMeetingViewState extends State<_StartMeetingView> {
  /// The candidate meeting point ids the foreman has checked as covered
  /// today. Reset whenever the candidate set itself changes (e.g. today's
  /// activities load in) so a stale selection from a different candidate
  /// list is never silently carried over — see [_syncSelection].
  final Set<String> _selectedPointIds = {};
  List<String>? _lastCandidateIds;

  /// Keeps [_selectedPointIds] valid as the candidate set loads/changes:
  /// drops any selected id no longer in [candidateIds] (e.g. a point was
  /// deactivated), and otherwise leaves the foreman's choices untouched —
  /// selection is deliberately NOT reset just because the stream re-emits
  /// the same set.
  void _syncSelection(List<String> candidateIds) {
    final last = _lastCandidateIds;
    if (last != null &&
        last.length == candidateIds.length &&
        last.toSet().containsAll(candidateIds)) {
      return;
    }
    // A momentarily EMPTY candidate list is never trusted enough to prune an
    // existing selection against — nested Firestore listeners (activities,
    // then meeting points) can each re-subscribe and briefly re-emit an
    // empty snapshot before their real data arrives, especially right after
    // an unrelated setState elsewhere in this widget triggers a rebuild.
    // Treating that transient emission as authoritative would silently wipe
    // whatever the foreman had already checked. Only a genuinely non-empty,
    // settled candidate list is allowed to prune selections that have
    // fallen out of it (e.g. a point was deactivated).
    if (candidateIds.isEmpty) return;
    _lastCandidateIds = candidateIds;
    _selectedPointIds.removeWhere((id) => !candidateIds.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final organizationId = widget.organizationId;
    final siteId = widget.siteId;
    final siteRepository = widget.siteRepository;
    final meetingPointRepository = widget.meetingPointRepository;
    final isStarting = widget.isStarting;
    final errorMessage = widget.errorMessage;
    final onStart = widget.onStart;
    return LiveStreamBuilder<Site?>(
      streamKey: (siteRepository, siteId),
      stream: () => siteRepository.watchById(siteId),
      builder: (context, siteSnapshot) {
        final site = siteSnapshot.data;
        if (siteSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (site == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'Your assigned site could not be loaded.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return FutureBuilder<List<Activity>>(
          // A Foreman's firestore.rules grant on `activities` does not
          // cover LIST queries at all (see that rule's own doc comment)
          // — this fetches once via the getSiteActivities callable
          // instead of a live ActivityRepository.watchBySite stream. The
          // future itself is cached by the parent screen (not recreated
          // per build) so this settles once instead of re-flashing on
          // every unrelated rebuild — see [siteActivitiesFuture]'s doc
          // comment.
          future: widget.siteActivitiesFuture(organizationId, siteId),
          builder: (context, activitySnapshot) {
            final activities = (activitySnapshot.data ?? const <Activity>[])
                .where((a) => a.status.id == 'active')
                .toList();

            return LiveStreamBuilder<List<SafetyMeetingPoint>>(
              streamKey: meetingPointRepository,
              stream: () => meetingPointRepository.watchActive(),
              builder: (context, pointSnapshot) {
                final allPoints =
                    pointSnapshot.data ?? const <SafetyMeetingPoint>[];
                final activityIds = activities.map((a) => a.id).toSet();
                final candidates = allPoints.where((point) {
                  return point.applicableActivities.isEmpty ||
                      point.applicableActivities.any(activityIds.contains);
                }).toList();
                _syncSelection(candidates.map((p) => p.id).toList());
                final selectedPoints = candidates
                    .where((p) => _selectedPointIds.contains(p.id))
                    .toList();

                return _LearningGateBanner(
                  meetingService: widget.meetingService,
                  workerLearningRepository: widget.workerLearningRepository,
                  organizationId: organizationId,
                  foremanUid: widget.currentUid,
                  meetingId: null,
                  siteId: siteId,
                  activityIds: activities.map((a) => a.id).toList(),
                  builder: (context, outstandingTitles) {
                    final isForemanReady =
                        outstandingTitles != null && outstandingTitles.isEmpty;
                    return ListView(
                      // Remembers the scroll position, so ticking a point
                      // never sends the foreman back to the top.
                      key: const PageStorageKey('meeting-start'),
                      padding: const EdgeInsets.all(AppSpacing.md),
                      children: [
                        FeatureHeader(
                          eyebrow: 'Not started yet',
                          title: "Today's Meeting",
                          subtitle: site.name,
                          icon: Icons.groups,
                          color: AppColors.meetings,
                          chips: [
                            FeatureChip(
                              icon: Icons.handyman,
                              label:
                                  '${activities.length} '
                                  '${activities.length == 1 ? 'activity' : 'activities'}',
                            ),
                            FeatureChip(
                              icon: Icons.checklist,
                              label:
                                  '${_selectedPointIds.length} meeting '
                                  '${_selectedPointIds.length == 1 ? 'point' : 'points'}',
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        if (errorMessage != null) ...[
                          AuthErrorBanner(message: errorMessage),
                          const SizedBox(height: AppSpacing.md),
                        ],
                        _ForemanReadinessBanner(
                          outstandingTitles: outstandingTitles,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        FeatureSectionTitle(
                          title: "Today's Activities (${activities.length})",
                          icon: Icons.handyman,
                          color: AppColors.projects,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (activities.isEmpty)
                          const Text(
                            'No active activities are recorded at this site.',
                            style: AppTextStyles.bodyMedium,
                          ),
                        for (final activity in activities)
                          _ActivityChipRow(name: activity.name),
                        const SizedBox(height: AppSpacing.lg),
                        FeatureSectionTitle(
                          title:
                              'Safety Meeting Points '
                              '(${_selectedPointIds.length}/${candidates.length} '
                              'selected)',
                          icon: Icons.checklist,
                          color: AppColors.meetings,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        const Text(
                          "Check the points you'll actually cover this "
                          "morning — the library covers every activity this "
                          "site runs, not just today's.",
                          style: AppTextStyles.bodyMedium,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (candidates.isEmpty)
                          const Text(
                            'No meeting points apply to these activities yet.',
                            style: AppTextStyles.bodyMedium,
                          ),
                        for (final point in candidates)
                          _ColorCheckTile(
                            checked: _selectedPointIds.contains(point.id),
                            emoji: hazardEmojiFor(
                              '${point.title} ${point.category}',
                            ),
                            title: point.title,
                            category: point.category,
                            onChanged: (checked) => setState(() {
                              if (checked) {
                                _selectedPointIds.add(point.id);
                              } else {
                                _selectedPointIds.remove(point.id);
                              }
                            }),
                          ),
                        const SizedBox(height: AppSpacing.lg),
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: AppSpacing.minTouchTarget,
                          ),
                          child: ElevatedButton.icon(
                            onPressed:
                                isStarting ||
                                    activities.isEmpty ||
                                    !isForemanReady
                                ? null
                                : () => onStart(
                                    organizationId: organizationId,
                                    projectId: site.projectId,
                                    siteId: siteId,
                                    todaysActivities: activities,
                                    recommendedPoints: selectedPoints,
                                  ),
                            icon: const Icon(Icons.play_arrow_outlined),
                            label: Text(
                              isStarting
                                  ? 'Starting…'
                                  : "Start Today's Meeting",
                            ),
                          ),
                        ),
                        if (activities.isEmpty) ...[
                          const SizedBox(height: AppSpacing.sm),
                          const Text(
                            'At least one active activity is required to start '
                            'a meeting.',
                            style: AppTextStyles.bodyMedium,
                          ),
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
  }
}

/// Steps 3-5: an in-progress meeting's accept/remove/add editing, concern
/// recording, and completion — or a read-only summary once completed.
class _MeetingWorkspace extends StatefulWidget {
  const _MeetingWorkspace({
    required this.meeting,
    required this.organizationId,
    required this.siteId,
    required this.currentUid,
    required this.meetingService,
    required this.attendanceService,
    required this.concernService,
    required this.correctiveActionService,
    required this.siteActivitiesFuture,
    required this.meetingPointRepository,
    required this.activityAssignmentRepository,
    required this.attendanceRepository,
    required this.concernRepository,
    required this.correctiveActionRepository,
    required this.pointNoteRepository,
    required this.evidenceRepository,
    required this.imagePicker,
    required this.workerLearningRepository,
    required this.riskAssessmentRepository,
    required this.members,
    required this.isSaving,
    required this.errorMessage,
    required this.onSave,
  });

  final DailySafetyMeeting meeting;
  final String organizationId;
  final String siteId;
  final String currentUid;
  final DailySafetyMeetingService meetingService;
  final MeetingAttendanceService attendanceService;
  final MeetingConcernService concernService;
  final CorrectiveActionService correctiveActionService;

  /// See [_StartMeetingView.siteActivitiesFuture]'s doc comment.
  final Future<List<Activity>> Function(String organizationId, String siteId)
  siteActivitiesFuture;
  final SafetyMeetingPointRepository meetingPointRepository;
  final ActivityAssignmentRepository activityAssignmentRepository;
  final MeetingAttendanceRepository attendanceRepository;
  final MeetingConcernRepository concernRepository;
  final CorrectiveActionRepository correctiveActionRepository;
  final MeetingPointNoteRepository pointNoteRepository;
  final MeetingEvidenceRepository evidenceRepository;
  final ImagePicker imagePicker;
  final WorkerLearningRepository workerLearningRepository;
  final RiskAssessmentRepository riskAssessmentRepository;

  /// The organization's active members — resolves an attendee's uid to a
  /// display name. See [_DailySafetyMeetingScreenState._loadMembers].
  final List<OrganizationUser> members;
  final bool isSaving;
  final String? errorMessage;
  final Future<void> Function(Future<void> Function()) onSave;

  @override
  State<_MeetingWorkspace> createState() => _MeetingWorkspaceState();
}

class _MeetingWorkspaceState extends State<_MeetingWorkspace> {
  Future<void> _toggleActivity(Activity activity) {
    final ids = {...widget.meeting.activityIds};
    if (!ids.remove(activity.id)) ids.add(activity.id);
    return widget.onSave(
      () => widget.meetingService.updateDailySafetyMeeting(
        widget.organizationId,
        widget.meeting.id,
        activityIds: ids.toList(),
      ),
    );
  }

  /// Ticks / unticks an accepted risk assessment (AHA) as covered with the
  /// crew at this meeting.
  Future<void> _toggleAha(RiskAssessment aha) {
    final ids = {...widget.meeting.ahaIds};
    if (!ids.remove(aha.id)) ids.add(aha.id);
    return widget.onSave(
      () => widget.meetingService.updateDailySafetyMeeting(
        widget.organizationId,
        widget.meeting.id,
        ahaIds: ids.toList(),
      ),
    );
  }

  void _openAha(String id) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => RiskAssessmentDetailScreen(
          organizationId: widget.organizationId,
          id: id,
          repository: widget.riskAssessmentRepository,
        ),
      ),
    );
  }

  Future<void> _removePoint(SafetyMeetingPoint point) {
    final ids = {...widget.meeting.meetingPointIds}..remove(point.id);
    return widget.onSave(() async {
      await widget.meetingService.updateDailySafetyMeeting(
        widget.organizationId,
        widget.meeting.id,
        meetingPointIds: ids.toList(),
      );
      // A note is meaningless once its point is no longer on the meeting —
      // removed alongside it rather than left orphaned. Succeeds even if
      // there was never a note to remove — see
      // DailySafetyMeetingService.removeMeetingPointNote's doc comment.
      await widget.meetingService.removeMeetingPointNote(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        meetingPointId: point.id,
      );
    });
  }

  Future<void> _setNote(SafetyMeetingPoint point, String note) {
    return widget.onSave(
      () => widget.meetingService.setMeetingPointNote(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        meetingPointId: point.id,
        note: note,
      ),
    );
  }

  Future<void> _removeNote(SafetyMeetingPoint point) {
    return widget.onSave(
      () => widget.meetingService.removeMeetingPointNote(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        meetingPointId: point.id,
      ),
    );
  }

  Future<void> _addPoint(SafetyMeetingPoint point) {
    final ids = {...widget.meeting.meetingPointIds, point.id};
    return widget.onSave(
      () => widget.meetingService.updateDailySafetyMeeting(
        widget.organizationId,
        widget.meeting.id,
        meetingPointIds: ids.toList(),
      ),
    );
  }

  Future<void> _openAddPointPicker(List<SafetyMeetingPoint> candidates) async {
    final selected = await showDialog<SafetyMeetingPoint>(
      context: context,
      builder: (_) => _MeetingPointPickerDialog(candidates: candidates),
    );
    if (selected == null) return;
    await _addPoint(selected);
  }

  Future<void> _addConcern(
    String description,
    MeetingConcernCategory category,
  ) {
    return widget.onSave(
      () => widget.concernService.addMeetingConcern(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        description: description,
        category: category.id,
      ),
    );
  }

  Future<void> _editConcern(
    MeetingConcern concern,
    String description,
    MeetingConcernCategory category,
  ) {
    return widget.onSave(
      () => widget.concernService.updateMeetingConcern(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        concernId: concern.id,
        description: description,
        category: category.id,
      ),
    );
  }

  Future<void> _createCorrectiveAction({
    String? concernId,
    required String title,
    required String description,
    required String assignedTo,
    required DateTime dueDate,
    required bool evidenceRequired,
    List<CorrectiveActionEvidenceKind> evidenceKinds = const [],
    String? evidenceInstructions,
  }) {
    return widget.onSave(
      () => widget.correctiveActionService.createCorrectiveAction(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        concernId: concernId,
        title: title,
        description: description,
        assignedTo: assignedTo,
        dueDate: dueDate,
        evidenceRequired: evidenceRequired,
        evidenceKinds: evidenceKinds,
        evidenceInstructions: evidenceInstructions,
      ),
    );
  }

  Future<void> _removeConcern(MeetingConcern concern) {
    return widget.onSave(
      () => widget.concernService.removeMeetingConcern(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        concernId: concern.id,
      ),
    );
  }

  Future<void> _recordAttendance(
    String workerId,
    MeetingAttendanceStatus status, {
    bool briefedInPerson = false,
  }) {
    return widget.onSave(
      () => widget.attendanceService.recordMeetingAttendance(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        workerId: workerId,
        status: status.id,
        briefedInPerson: briefedInPerson,
      ),
    );
  }

  /// Asks for the crew's GO / GO corrected / STOP result first; cancelling
  /// that dialog leaves the meeting in progress.
  Future<void> _complete() async {
    final result = await showCrewOutcomeDialog(context);
    if (result == null || !mounted) return;
    await widget.onSave(
      () => widget.meetingService.completeDailySafetyMeeting(
        widget.organizationId,
        widget.meeting.id,
        crewOutcome: result.outcome,
        crewOutcomeNote: result.note,
      ),
    );
  }

  bool _isCapturingEvidence = false;
  String? _evidenceError;

  /// Captures a photo and uploads it as evidence of the given [type] —
  /// deliberately reachable REGARDLESS of [canEdit] (unlike every other
  /// action on this screen): evidence may still be added after the meeting
  /// is completed, see [MeetingEvidence]'s doc comment. Camera-only for
  /// this stage (matching [ReportHazardScreen]'s existing pattern) — a
  /// general document picker is a larger dependency this pass does not
  /// need, since a photo covers the handwritten-book/sign-in-sheet/
  /// briefing-photo cases named in the design.
  Future<void> _captureEvidence(MeetingEvidenceType type) async {
    setState(() {
      _isCapturingEvidence = true;
      _evidenceError = null;
    });
    try {
      final photo = await takePhoto(context, picker: widget.imagePicker);
      if (photo == null) return;
      final bytes = await photo.readAsBytes();
      await widget.meetingService.uploadMeetingEvidence(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        fileName: photo.name,
        bytes: bytes,
        fileType: photo.mimeType ?? 'image/jpeg',
        evidenceType: type,
      );
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _evidenceError = e.message);
    } on Object catch (_) {
      if (!mounted) return;
      setState(
        () => _evidenceError =
            'Could not capture evidence. Please try '
            'again.',
      );
    } finally {
      if (mounted) setState(() => _isCapturingEvidence = false);
    }
  }

  Future<void> _removeEvidence(MeetingEvidence evidence) {
    return widget.onSave(
      () => widget.meetingService.removeMeetingEvidence(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        evidenceId: evidence.id,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final meeting = widget.meeting;

    return PopScope(
      // Only intercept navigating away while the meeting is genuinely
      // unfinished — a completed meeting has nothing left to lose by
      // leaving, so this never interrupts the common case.
      canPop: meeting.isCompleted,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldLeave = await _confirmLeaveIncomplete(context);
        if (shouldLeave && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: _buildWorkspaceBody(context),
    );
  }

  /// Prompts before leaving an INCOMPLETE meeting — a foreman closing the
  /// tab, tapping back, or navigating elsewhere mid-toolbox-talk should be
  /// warned, not silently leave a half-recorded meeting stuck `inProgress`
  /// indefinitely (nothing is lost either way — it can always be resumed
  /// from [DailySafetyMeetingHistoryScreen] — but a deliberate choice beats
  /// an accidental one). Returns true if the foreman confirms leaving
  /// anyway.
  Future<bool> _confirmLeaveIncomplete(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Meeting not completed'),
        content: const Text(
          "This meeting hasn't been marked complete yet. You can finish "
          'it later from Meeting History, but the toolbox talk record '
          "isn't final until you tap Complete Meeting.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Stay and finish'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Leave anyway'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _buildWorkspaceBody(BuildContext context) {
    final meeting = widget.meeting;
    // Activities/points/attendance freeze hard at completion. Concerns and
    // meeting-point discussion notes are a deliberate exception — a
    // foreman may still ADD (not edit/remove) either after completion; see
    // `functions/src/daily_safety_meeting_callable.ts`'s header note. This
    // is UI convenience only, matching every other canEdit gate on this
    // screen: the real enforcement is server-side in the callables.
    final canEdit = !meeting.isCompleted;
    const canAddConcernOrNote = true;

    return FutureBuilder<List<Activity>>(
      // See _StartMeetingView's own matching comment: a Foreman's
      // firestore.rules grant on `activities` does not cover LIST
      // queries, so this fetches once via getSiteActivities instead — and
      // the future is cached by the parent screen so it settles once
      // instead of re-flashing on every rebuild.
      future: widget.siteActivitiesFuture(widget.organizationId, widget.siteId),
      builder: (context, activitySnapshot) {
        final siteActivities = (activitySnapshot.data ?? const <Activity>[])
            .where((a) => a.status.id == 'active')
            .toList();

        return LiveStreamBuilder<List<SafetyMeetingPoint>>(
          streamKey: widget.meetingPointRepository,
          stream: () => widget.meetingPointRepository.watchActive(),
          builder: (context, pointSnapshot) {
            final allPoints =
                pointSnapshot.data ?? const <SafetyMeetingPoint>[];

            return LiveStreamBuilder<List<RiskAssessment>>(
              streamKey: widget.riskAssessmentRepository,
              stream: () => widget.riskAssessmentRepository.watchAll(),
              builder: (context, ahaSnapshot) {
                // The site's accepted AHAs — the Safety Plan: Foremen cover the
                // activity hazard analysis with the crew before work begins.
                final siteAhas = [
                  for (final aha
                      in ahaSnapshot.data ?? const <RiskAssessment>[])
                    if (aha.siteId == widget.siteId &&
                        aha.status == RiskAssessmentStatus.accepted)
                      aha,
                ];
                // Only the AHAs for the activities worked today (or covering
                // the whole site) are offered; each of today's activities
                // with one needs one covered.
                final todaysAhas = [
                  for (final aha in siteAhas)
                    if (aha.activityIds.isEmpty ||
                        aha.activityIds.any(meeting.activityIds.contains) ||
                        meeting.ahaIds.contains(aha.id))
                      aha,
                ];
                final activityNames = {
                  for (final a in siteActivities) a.id: a.name,
                };
                final needingAha = [
                  for (final id in activitiesNeedingAha(
                    siteAhas: siteAhas,
                    activityIds: meeting.activityIds,
                    coveredIds: meeting.ahaIds,
                  ))
                    activityNames[id] ?? 'an activity',
                ];
                final needsAha = needingAha.isNotEmpty;

                return ListView(
                  // Remembers the scroll position across rebuilds — see
                  // 'meeting-start' above.
                  key: const PageStorageKey('meeting-workspace'),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    FeatureHeader(
                      title: meeting.isCompleted
                          ? "Today's Meeting — Completed"
                          : "Today's Meeting — In Progress",
                      icon: meeting.isCompleted ? Icons.task_alt : Icons.groups,
                      color: meeting.isCompleted
                          ? AppColors.success
                          : AppColors.meetings,
                      chips: [
                        FeatureChip(icon: Icons.event, label: meeting.date),
                        FeatureChip(
                          icon: Icons.handyman,
                          label:
                              '${meeting.activityIds.length} '
                              '${meeting.activityIds.length == 1 ? 'activity' : 'activities'}',
                        ),
                        FeatureChip(
                          icon: Icons.checklist,
                          label:
                              '${meeting.meetingPointIds.length} meeting '
                              '${meeting.meetingPointIds.length == 1 ? 'point' : 'points'}',
                        ),
                        if (meeting.ahaIds.isNotEmpty)
                          FeatureChip(
                            icon: Icons.assignment_late,
                            label:
                                '${meeting.ahaIds.length} AHA'
                                '${meeting.ahaIds.length == 1 ? '' : 's'} covered',
                          ),
                      ],
                      trailing: meeting.crewOutcome == null
                          ? null
                          : CrewOutcomeBadge(outcome: meeting.crewOutcome!),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    if (widget.errorMessage != null) ...[
                      AuthErrorBanner(message: widget.errorMessage!),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    const FeatureSectionTitle(
                      title: 'Activities Discussed',
                      icon: Icons.handyman,
                      color: AppColors.projects,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    for (final activity in siteActivities)
                      _ColorCheckTile(
                        checked: meeting.activityIds.contains(activity.id),
                        emoji: hazardEmojiFor(activity.name),
                        title: activity.name,
                        onChanged: canEdit && !widget.isSaving
                            ? (_) => _toggleActivity(activity)
                            : null,
                      ),
                    const SizedBox(height: AppSpacing.md),
                    FeatureSectionTitle(
                      title: 'Safety Meeting Points',
                      icon: Icons.checklist,
                      color: AppColors.meetings,
                      trailing: !canEdit
                          ? null
                          : TextButton.icon(
                              onPressed: widget.isSaving
                                  ? null
                                  : () => _openAddPointPicker(
                                      allPoints
                                          .where(
                                            (p) => !meeting.meetingPointIds
                                                .contains(p.id),
                                          )
                                          .toList(),
                                    ),
                              icon: const Icon(Icons.add_outlined),
                              label: const Text('Add Safety Point'),
                            ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    // "Recommended" = every point currently on this meeting,
                    // whether seeded at start or added since — checking a point
                    // marks it covered; unchecking or removing takes it off the
                    // meeting entirely. There is no separate "covered" flag: a
                    // point on the meeting IS the covered set, matching
                    // `meetingPointIds`'s single source of truth.
                    //
                    // Each point also carries an optional DISCUSSION NOTE — what
                    // was actually explained/covered about it, kept deliberately
                    // separate from Concerns (an issue record, not discussion
                    // context) — see MeetingPointNote's doc comment.
                    LiveStreamBuilder<List<MeetingPointNote>>(
                      streamKey: widget.pointNoteRepository,
                      stream: () => widget.pointNoteRepository.watchAll(),
                      builder: (context, noteSnapshot) {
                        final notesByPointId = {
                          for (final n
                              in noteSnapshot.data ??
                                  const <MeetingPointNote>[])
                            n.meetingPointId: n,
                        };

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final pointId in meeting.meetingPointIds)
                              Builder(
                                builder: (context) {
                                  final point = allPoints
                                      .where((p) => p.id == pointId)
                                      .cast<SafetyMeetingPoint?>()
                                      .firstWhere(
                                        (_) => true,
                                        orElse: () => null,
                                      );
                                  if (point == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return _MeetingPointTile(
                                    point: point,
                                    note: notesByPointId[pointId]?.note,
                                    canEdit: canEdit,
                                    canEditNote: canAddConcernOrNote,
                                    isSaving: widget.isSaving,
                                    onRemovePoint: () => _removePoint(point),
                                    onSetNote: (note) => _setNote(point, note),
                                    onRemoveNote: () => _removeNote(point),
                                  );
                                },
                              ),
                            if (meeting.meetingPointIds.isEmpty)
                              const Text(
                                'No safety meeting points recorded yet. Use '
                                '"Add Safety Point" above.',
                                style: AppTextStyles.bodyMedium,
                              ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _AhaSection(
                      meeting: meeting,
                      siteAhas: todaysAhas,
                      siteHasAhas: siteAhas.isNotEmpty,
                      canEdit: canEdit && !widget.isSaving,
                      onToggle: _toggleAha,
                      onOpen: _openAha,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const FeatureSectionTitle(
                      title: 'Attendance',
                      icon: Icons.how_to_reg,
                      color: AppColors.people,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _AttendanceSection(
                      meeting: meeting,
                      organizationId: widget.organizationId,
                      currentUid: widget.currentUid,
                      canEdit: canEdit,
                      isSaving: widget.isSaving,
                      activityAssignmentRepository:
                          widget.activityAssignmentRepository,
                      attendanceRepository: widget.attendanceRepository,
                      attendanceService: widget.attendanceService,
                      members: widget.members,
                      onRecordAttendance: _recordAttendance,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const FeatureSectionTitle(
                      title: 'Concerns',
                      icon: Icons.report_problem,
                      color: AppColors.hazards,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _ConcernsSection(
                      members: widget.members,
                      concernRepository: widget.concernRepository,
                      correctiveActionRepository:
                          widget.correctiveActionRepository,
                      activityAssignmentRepository:
                          widget.activityAssignmentRepository,
                      meeting: meeting,
                      currentUid: widget.currentUid,
                      canEdit: canEdit,
                      canAdd: canAddConcernOrNote,
                      isSaving: widget.isSaving,
                      onAdd: _addConcern,
                      onEdit: _editConcern,
                      onRemove: _removeConcern,
                      onCreateCorrectiveAction: _createCorrectiveAction,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const FeatureSectionTitle(
                      title: 'Evidence',
                      icon: Icons.photo_camera,
                      color: AppColors.analytics,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    const Text(
                      'Supporting photos — a handwritten safety-book page, a '
                      'sign-in sheet, a briefing/site photo. Can still be added '
                      'after the meeting is completed.',
                      style: AppTextStyles.bodyMedium,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _EvidenceSection(
                      evidenceRepository: widget.evidenceRepository,
                      canRemove: canEdit,
                      isCapturing: _isCapturingEvidence,
                      errorMessage: _evidenceError,
                      onCapture: _captureEvidence,
                      onRemove: _removeEvidence,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    if (canEdit)
                      _LearningGateBanner(
                        meetingService: widget.meetingService,
                        workerLearningRepository:
                            widget.workerLearningRepository,
                        organizationId: widget.organizationId,
                        foremanUid: widget.currentUid,
                        meetingId: meeting.id,
                        siteId: widget.siteId,
                        activityIds: meeting.activityIds,
                        builder: (context, outstandingTitles) {
                          final hasOutstandingLearning =
                              outstandingTitles == null ||
                              outstandingTitles.isNotEmpty;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (outstandingTitles != null &&
                                  outstandingTitles.isNotEmpty) ...[
                                _OutstandingLearningBanner(
                                  titles: outstandingTitles,
                                ),
                                const SizedBox(height: AppSpacing.md),
                              ],
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: AppSpacing.minTouchTarget,
                                ),
                                child: ElevatedButton.icon(
                                  onPressed:
                                      widget.isSaving ||
                                          meeting.activityIds.isEmpty ||
                                          meeting.meetingPointIds.isEmpty ||
                                          needsAha ||
                                          hasOutstandingLearning
                                      ? null
                                      : _complete,
                                  icon: const Icon(Icons.check_circle_outline),
                                  label: const Text('Complete Meeting'),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    if (canEdit &&
                        (meeting.activityIds.isEmpty ||
                            meeting.meetingPointIds.isEmpty)) ...[
                      const SizedBox(height: AppSpacing.sm),
                      const Text(
                        'At least one activity and one meeting point must be '
                        'recorded before completing.',
                        style: AppTextStyles.bodyMedium,
                      ),
                    ],
                    if (canEdit && needsAha) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Cover the risk assessment (AHA) with the crew and '
                        'tick it above before completing, for: '
                        '${needingAha.join(', ')}.',
                        style: AppTextStyles.bodyMedium,
                      ),
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

/// The site's accepted risk assessments (AHAs) — the Safety Plan's
/// "Foremen cover the activity hazard analysis before work begins". While
/// the meeting is in progress the Foreman ticks each one covered with the
/// crew (and can open it to read through); once completed, it shows what
/// was covered, by name and revision as recorded at the time.
class _AhaSection extends StatelessWidget {
  const _AhaSection({
    required this.meeting,
    required this.siteAhas,
    required this.siteHasAhas,
    required this.canEdit,
    required this.onToggle,
    required this.onOpen,
  });

  final DailySafetyMeeting meeting;

  /// The site's accepted AHAs for today's activities.
  final List<RiskAssessment> siteAhas;

  /// Whether the site has any accepted AHA at all (for any activity).
  final bool siteHasAhas;
  final bool canEdit;
  final ValueChanged<RiskAssessment> onToggle;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (meeting.isCompleted) {
      for (final covered in meeting.ahasCovered) {
        children.add(
          _AhaRow(
            title: covered.featureOfWork,
            subtitle: 'Revision ${covered.revision} · covered with the crew',
            covered: true,
            onTap: null,
            onRead: () => onOpen(covered.id),
          ),
        );
      }
      if (meeting.ahasCovered.isEmpty) {
        children.add(
          const Text(
            'No risk assessment was recorded for this meeting.',
            style: AppTextStyles.bodyMedium,
          ),
        );
      }
    } else {
      for (final aha in siteAhas) {
        final covered = meeting.ahaIds.contains(aha.id);
        children.add(
          _AhaRow(
            title: aha.featureOfWork,
            subtitle:
                'Revision ${aha.revision} · ${aha.steps.length} steps · '
                '${covered ? 'covered with the crew' : 'tap when covered'}',
            covered: covered,
            onTap: canEdit ? () => onToggle(aha) : null,
            onRead: () => onOpen(aha.id),
          ),
        );
      }
      if (siteAhas.isEmpty) {
        children.add(
          Text(
            siteHasAhas
                ? meeting.activityIds.isEmpty
                      ? "Tick today's activities above to see their risk "
                            'assessments.'
                      : "None of today's activities has a risk assessment."
                : 'This site has no accepted risk assessment yet.',
            style: AppTextStyles.bodyMedium,
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FeatureSectionTitle(
          title: 'Risk Assessments (AHA)',
          icon: Icons.assignment_late,
          color: AppColors.riskAssessments,
        ),
        if (!meeting.isCompleted && siteAhas.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          const Text(
            "Go through the hazards and controls for today's work with the "
            'crew, then tick each one you covered.',
            style: AppTextStyles.bodyMedium,
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        ...children,
      ],
    );
  }
}

class _AhaRow extends StatelessWidget {
  const _AhaRow({
    required this.title,
    required this.subtitle,
    required this.covered,
    required this.onTap,
    required this.onRead,
  });

  final String title;
  final String subtitle;
  final bool covered;
  final VoidCallback? onTap;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceTile(
            multi: true,
            title: title,
            subtitle: subtitle,
            icon: Icons.assignment_late,
            color: AppColors.riskAssessments,
            selected: covered,
            onTap: onTap,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onRead,
              icon: const Icon(Icons.menu_book_outlined),
              label: Text('Read "$title"'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Foreman's own outstanding "Needed today" lessons for this meeting —
/// fetched from `getMyMeetingLearningGate`, i.e. exactly what
/// `createDailySafetyMeeting`/`completeDailySafetyMeeting` will check
/// server-side, so the Foreman finds out before tapping Start/Complete
/// rather than only from the refusal after. Lessons drop off live (via
/// [WorkerLearningRepository.watchMine]) as the Foreman completes them.
///
/// Calls [builder] with the outstanding titles, or `null` while still
/// loading — the caller never enables Start/Complete on `null`. If the
/// lookup itself fails (e.g. no signal) the banner shows nothing and lets
/// the Foreman try: the server still enforces the rule on Start/Complete.
class _LearningGateBanner extends StatefulWidget {
  const _LearningGateBanner({
    required this.meetingService,
    required this.workerLearningRepository,
    required this.organizationId,
    required this.foremanUid,
    required this.meetingId,
    required this.siteId,
    required this.activityIds,
    required this.builder,
  });

  final DailySafetyMeetingService meetingService;
  final WorkerLearningRepository workerLearningRepository;
  final String organizationId;
  final String foremanUid;

  /// Null before the meeting has been started.
  final String? meetingId;
  final String siteId;
  final List<String> activityIds;
  final Widget Function(BuildContext context, List<String>? outstandingTitles)
  builder;

  @override
  State<_LearningGateBanner> createState() => _LearningGateBannerState();
}

class _LearningGateBannerState extends State<_LearningGateBanner> {
  late Future<List<({String learningId, String title})>> _outstanding = _load();
  late final Stream<List<WorkerLearningRecord>> _records = widget
      .workerLearningRepository
      .watchMine(widget.foremanUid);

  Future<List<({String learningId, String title})>> _load() async {
    try {
      return await widget.meetingService.getMyMeetingLearningGate(
        organizationId: widget.organizationId,
        siteId: widget.siteId,
        activityIds: widget.activityIds,
        meetingId: widget.meetingId,
      );
    } on AppException {
      return const [];
    }
  }

  @override
  void didUpdateWidget(_LearningGateBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.siteId != widget.siteId ||
        oldWidget.meetingId != widget.meetingId ||
        oldWidget.activityIds.join(',') != widget.activityIds.join(',');
    if (changed) _outstanding = _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<({String learningId, String title})>>(
      future: _outstanding,
      builder: (context, outstandingSnapshot) {
        final outstanding = outstandingSnapshot.data;
        if (outstanding == null) return widget.builder(context, null);
        if (outstanding.isEmpty) return widget.builder(context, const []);

        return StreamBuilder<List<WorkerLearningRecord>>(
          stream: _records,
          builder: (context, recordSnapshot) {
            final records = recordSnapshot.data;
            if (records == null) return widget.builder(context, null);
            final completedIds = {
              for (final record in records)
                if (record.status == WorkerLearningStatus.completed)
                  record.learningId,
            };
            return widget.builder(context, [
              for (final lesson in outstanding)
                if (!completedIds.contains(lesson.learningId)) lesson.title,
            ]);
          },
        );
      },
    );
  }
}

/// The Foreman's own pre-meeting readiness summary, shown in
/// [_StartMeetingView] before "Start Today's Meeting" is even tappable —
/// reuses [_LearningGateBanner]'s same server-authorized, ATTENDANCE-GATING
/// resolution ([SafetyRequirementRepository
/// .watchAttendanceGatingLearningForScope] + [WorkerLearningRepository
/// .watchMine], the exact scope `createDailySafetyMeeting`'s own
/// `requireForemanLearningComplete` gate checks) so the foreman finds out
/// BEFORE tapping Start, not only from the refusal after. Purely
/// informational: `createDailySafetyMeeting` remains the sole authority,
/// re-deriving and enforcing this same check server-side regardless of what
/// this banner shows.
///
/// [outstandingTitles] null means "not yet resolved" — renders nothing
/// (never claims Ready before the read has actually completed), matching
/// [_LearningGateBanner]'s own "never fail-open" convention.
class _ForemanReadinessBanner extends StatelessWidget {
  const _ForemanReadinessBanner({required this.outstandingTitles});

  final List<String>? outstandingTitles;

  @override
  Widget build(BuildContext context) {
    final titles = outstandingTitles;
    if (titles == null) return const SizedBox.shrink();
    if (titles.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppSpacing.sm),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: AppColors.success),
            const SizedBox(width: AppSpacing.sm),
            Text(
              'Your safety learning — Ready',
              style: AppTextStyles.bodyMedium.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: _OutstandingLearningBanner(
        titles: titles,
        message:
            'Complete the following before you can start today\'s '
            'meeting',
      ),
    );
  }
}

/// The warning shown when [_LearningGateBanner] finds the acting foreman
/// has not completed all learning this meeting requires of them — lists
/// what's outstanding and links to [MySafetyLearningScreen] so the foreman
/// can act on it without leaving to find that screen on their own. Shared
/// by [_ForemanReadinessBanner] (pre-creation) and the in-workspace
/// pre-completion check, via [message].
class _OutstandingLearningBanner extends StatelessWidget {
  const _OutstandingLearningBanner({
    required this.titles,
    this.message =
        'Complete your required safety learning before you can '
        'complete this meeting',
  });

  final List<String> titles;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.school_outlined, color: AppColors.warning),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: AppTextStyles.bodyMedium.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          for (final title in titles)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 2),
              child: Text('• $title', style: AppTextStyles.bodyMedium),
            ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => context.go(AppRoutes.safetyLearning),
              icon: const Icon(Icons.arrow_forward_outlined, size: 18),
              label: const Text('Go to My Safety Learning'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One covered meeting point: the checkbox/remove row (unchanged shape),
/// plus an inline "Add note"/"Edit note" affordance for its DISCUSSION
/// CONTEXT — what was actually explained/covered, kept deliberately
/// separate from Concerns. Sized and laid out for field use (large touch
/// targets, no separate dialog to open), matching the inline text field
/// already established for Concerns in [_ConcernsSection].
class _MeetingPointTile extends StatefulWidget {
  const _MeetingPointTile({
    required this.point,
    required this.note,
    required this.canEdit,
    required this.canEditNote,
    required this.isSaving,
    required this.onRemovePoint,
    required this.onSetNote,
    required this.onRemoveNote,
  });

  final SafetyMeetingPoint point;

  /// The point's current discussion note, or null if none has been
  /// recorded — optional, matching every other field on this workspace.
  final String? note;

  /// Whether the point itself (checkbox/remove) can still be edited — false
  /// once the meeting is completed, since that record is frozen.
  final bool canEdit;

  /// Whether the discussion note can still be SET — true even once the
  /// meeting is completed, matching `setMeetingPointNote`'s deliberate
  /// post-completion exception (a foreman may remember something worth
  /// recording later). Clearing an existing note to empty still calls
  /// `onRemoveNote`, which stays gated by [canEdit] server-side
  /// (`removeMeetingPointNote` is `inProgress`-only) — see [_submitNote].
  final bool canEditNote;
  final bool isSaving;
  final VoidCallback onRemovePoint;
  final ValueChanged<String> onSetNote;
  final VoidCallback onRemoveNote;

  @override
  State<_MeetingPointTile> createState() => _MeetingPointTileState();
}

class _MeetingPointTileState extends State<_MeetingPointTile> {
  bool _isEditingNote = false;
  late final _noteController = TextEditingController(text: widget.note);

  @override
  void didUpdateWidget(covariant _MeetingPointTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the field in sync with a note change that came from elsewhere
    // (e.g. another device) while this tile isn't mid-edit — avoids
    // clobbering text the foreman is actively typing.
    if (!_isEditingNote && widget.note != oldWidget.note) {
      _noteController.text = widget.note ?? '';
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _submitNote() {
    final text = _noteController.text.trim();
    if (text.isEmpty) {
      // Clearing to empty is a REMOVAL, which stays inProgress-only
      // server-side — see [_MeetingPointTile.canEditNote]'s doc comment.
      // If the meeting has already completed, silently keep the existing
      // note rather than attempting (and failing) a call the UI already
      // should not have offered.
      if (widget.note != null && widget.canEdit) widget.onRemoveNote();
    } else {
      widget.onSetNote(text);
    }
    setState(() => _isEditingNote = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasNote = widget.note != null && widget.note!.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      color: Color.alphaBlend(
        AppColors.meetings.withValues(alpha: 0.07),
        Theme.of(context).colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.meetings.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Row(
                children: [
                  Expanded(
                    // Ticked = on today's meeting; tapping it unticks
                    // (removes) the point, exactly like the ✕ beside it.
                    child: ChoiceTile(
                      multi: true,
                      selected: true,
                      title: widget.point.title,
                      subtitle: widget.point.category,
                      badge: hazardEmojiFor(
                        '${widget.point.title} ${widget.point.category}',
                      ),
                      color: AppColors.forLabel(widget.point.category),
                      onTap: widget.canEdit && !widget.isSaving
                          ? widget.onRemovePoint
                          : null,
                    ),
                  ),
                  if (widget.canEdit)
                    IconButton(
                      tooltip: 'Remove',
                      onPressed: widget.isSaving ? null : widget.onRemovePoint,
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
            if (_isEditingNote)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _noteController,
                      decoration: const InputDecoration(
                        labelText: 'What was discussed',
                        hintText:
                            'e.g. Reminded workers to maintain three '
                            'points of contact; team confirmed '
                            'understanding.',
                      ),
                      enabled: !widget.isSaving,
                      minLines: 1,
                      maxLines: 4,
                      autofocus: true,
                      onSubmitted: (_) => _submitNote(),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: widget.isSaving
                              ? null
                              : () => setState(() {
                                  _noteController.text = widget.note ?? '';
                                  _isEditingNote = false;
                                }),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        FilledButton(
                          onPressed: widget.isSaving ? null : _submitNote,
                          child: const Text('Save note'),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.sm,
                ),
                child: hasNote
                    ? InkWell(
                        onTap: widget.canEditNote && !widget.isSaving
                            ? () => setState(() => _isEditingNote = true)
                            : null,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.notes_outlined,
                              size: 16,
                              color: AppColors.textSecondary,
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(
                              child: Text(
                                widget.note!,
                                style: AppTextStyles.bodyMedium,
                              ),
                            ),
                            if (widget.canEditNote)
                              const Icon(Icons.edit_outlined, size: 16),
                          ],
                        ),
                      )
                    : (widget.canEditNote
                          ? TextButton.icon(
                              onPressed: widget.isSaving
                                  ? null
                                  : () => setState(() => _isEditingNote = true),
                              icon: const Icon(Icons.notes_outlined, size: 16),
                              label: const Text('Add note'),
                            )
                          : const SizedBox.shrink()),
              ),
          ],
        ),
      ),
    );
  }
}

/// The Evidence step of the meeting flow: a "Capture" button per
/// [MeetingEvidenceType], a list of what's already uploaded, and — while
/// the meeting is still `inProgress` — a Remove control per item.
///
/// **Capture buttons are ALWAYS enabled, regardless of [canEdit]** — unlike
/// every other section on this workspace. Evidence may still be added
/// after the meeting is completed (a foreman may not have the physical
/// safety book on hand at the exact moment they complete the meeting), so
/// this section deliberately does not gate its add path on the meeting's
/// own completion status — see [MeetingEvidence]'s doc comment. Only
/// REMOVAL stays gated on `inProgress`, mirroring
/// `corrective_actions`' "no delete once permanent" rule.
class _EvidenceSection extends StatelessWidget {
  const _EvidenceSection({
    required this.evidenceRepository,
    required this.canRemove,
    required this.isCapturing,
    required this.errorMessage,
    required this.onCapture,
    required this.onRemove,
  });

  final MeetingEvidenceRepository evidenceRepository;

  /// Whether the meeting is still `inProgress` — Remove is only offered
  /// then, matching `removeMeetingEvidence`'s own server-side gate. Add
  /// (via [onCapture]) is offered unconditionally regardless of this flag
  /// — see this class's own doc comment.
  final bool canRemove;
  final bool isCapturing;
  final String? errorMessage;
  final ValueChanged<MeetingEvidenceType> onCapture;
  final ValueChanged<MeetingEvidence> onRemove;

  @override
  Widget build(BuildContext context) {
    return LiveStreamBuilder<List<MeetingEvidence>>(
      streamKey: evidenceRepository,
      stream: () => evidenceRepository.watchAll(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <MeetingEvidence>[];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text(
                  'No evidence attached yet.',
                  style: AppTextStyles.bodyMedium,
                ),
              )
            else
              for (final item in items)
                _EvidenceCard(
                  evidence: item,
                  onRemove: canRemove ? () => onRemove(item) : null,
                ),
            if (errorMessage != null) ...[
              AuthErrorBanner(message: errorMessage!),
              const SizedBox(height: AppSpacing.sm),
            ],
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final type in MeetingEvidenceType.values)
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: AppSpacing.minTouchTarget,
                    ),
                    child: OutlinedButton.icon(
                      onPressed: isCapturing ? null : () => onCapture(type),
                      icon: const Icon(Icons.camera_alt_outlined, size: 18),
                      label: Text(type.label),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _EvidenceCard extends StatelessWidget {
  const _EvidenceCard({required this.evidence, required this.onRemove});

  final MeetingEvidence evidence;

  /// Null when the meeting is no longer `inProgress` — evidence may still
  /// be added then, but never removed, so the Remove control simply does
  /// not render rather than showing disabled.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (evidence.isImage)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  evidence.downloadUrl,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const Icon(Icons.broken_image_outlined, size: 56),
                ),
              )
            else
              const Icon(Icons.description_outlined, size: 56),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    evidence.evidenceType.label,
                    style: AppTextStyles.bodyMedium,
                  ),
                  if (evidence.description != null)
                    Text(
                      evidence.description!,
                      style: AppTextStyles.label.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: 'Remove',
                onPressed: onRemove,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
    );
  }
}

/// One of today's activities on the start view: a colored card with a
/// hazard picture matched from its name.
class _ActivityChipRow extends StatelessWidget {
  const _ActivityChipRow({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.projects.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.projects.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.projects.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              hazardEmojiFor(name),
              style: const TextStyle(fontSize: 22),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              name,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Icon(Icons.engineering, color: AppColors.projects),
        ],
      ),
    );
  }
}

/// A tick-box row: the app's shared [ChoiceTile] with a hazard picture in
/// its badge, a bold title and the optional category underneath. Each row
/// gets its own colour; ticked rows turn solid. Tap again to untick.
class _ColorCheckTile extends StatelessWidget {
  const _ColorCheckTile({
    required this.checked,
    required this.emoji,
    required this.title,
    required this.onChanged,
    this.category,
  });

  final bool checked;
  final String emoji;
  final String title;
  final String? category;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    // Each row its own colour (by category, or by name when there is
    // none), so a long list of points or activities is easy to scan.
    final rowColor = AppColors.forLabel(category ?? title);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ChoiceTile(
        multi: true,
        title: title,
        subtitle: category,
        badge: emoji,
        color: rowColor,
        selected: checked,
        onTap: onChanged == null ? null : () => onChanged!(!checked),
      ),
    );
  }
}

/// Lets the foreman pick an additional Safety Meeting Point from the
/// organization's library — [_MeetingWorkspaceState.candidates] is already
/// narrowed to active points not yet on the meeting. Adding a point beyond
/// the auto-recommended set is "site-specific" in the sense the library
/// already supports: the org's Safety Meeting Point Library
/// (`safety_meeting_points`) is the single source of every point a meeting
/// can ever reference — see `updateDailySafetyMeeting`'s
/// `requireActiveMeetingPoints`, which refuses any id not already a real,
/// active library document. There is deliberately no free-text point here:
/// doing so would need a backend change this task's scope excludes.
class _MeetingPointPickerDialog extends StatefulWidget {
  const _MeetingPointPickerDialog({required this.candidates});

  final List<SafetyMeetingPoint> candidates;

  @override
  State<_MeetingPointPickerDialog> createState() =>
      _MeetingPointPickerDialogState();
}

class _MeetingPointPickerDialogState extends State<_MeetingPointPickerDialog> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final query = _search.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.candidates
        : widget.candidates
              .where((p) => p.title.toLowerCase().contains(query))
              .toList(growable: false);

    return AlertDialog(
      title: const Text('Add Safety Point'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.candidates.isNotEmpty)
              TextField(
                decoration: const InputDecoration(hintText: 'Search...'),
                onChanged: (value) => setState(() => _search = value),
              ),
            if (widget.candidates.isNotEmpty)
              const SizedBox(height: AppSpacing.sm),
            if (widget.candidates.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text(
                  'Every active safety meeting point is already on this '
                  'meeting.',
                  style: AppTextStyles.bodyMedium,
                ),
              )
            else if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text(
                  'No points match that search.',
                  style: AppTextStyles.bodyMedium,
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final point = filtered[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: ChoiceTile(
                        title: point.title,
                        subtitle: point.category,
                        badge: hazardEmojiFor(
                          '${point.title} ${point.category}',
                        ),
                        color: AppColors.forLabel(point.category),
                        selected: false,
                        onTap: () => Navigator.of(context).pop(point),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// The Attendance step of the meeting flow: lets the foreman mark each
/// worker assigned to the meeting's activities present or absent, and
/// review/change their choice before completing the meeting.
///
/// The roster is the union of workers assigned (via `assignWorkerToActivity`)
/// to every activity currently on [DailySafetyMeeting.activityIds] — the
/// same "workers assigned to the relevant site/activity" set
/// `ActivityWorkersScreen` shows, re-used here rather than re-derived. There
/// is deliberately no name lookup: `listOrganizationUsers` is restricted to
/// reviewer roles a foreman does not hold, so — exactly like
/// `ActivityWorkersScreen`'s own worker rows — each entry is shown by its
/// uid.
///
/// A worker never appears able to mark themselves: [currentUid] is excluded
/// from the roster outright, mirroring the server's own refusal in
/// `recordMeetingAttendance` (a foreman cannot record their own attendance
/// either, since the caller and the meeting's own foreman are the same
/// person here).
class _AttendanceSection extends StatefulWidget {
  const _AttendanceSection({
    required this.meeting,
    required this.organizationId,
    required this.currentUid,
    required this.canEdit,
    required this.isSaving,
    required this.activityAssignmentRepository,
    required this.attendanceRepository,
    required this.attendanceService,
    required this.members,
    required this.onRecordAttendance,
  });

  final DailySafetyMeeting meeting;
  final String organizationId;
  final String currentUid;
  final bool canEdit;
  final bool isSaving;
  final ActivityAssignmentRepository activityAssignmentRepository;
  final MeetingAttendanceRepository attendanceRepository;

  /// Backs the read-only attendee learning-status preview — see
  /// [_AttendanceSectionState._loadLearningStatus].
  final MeetingAttendanceService attendanceService;

  /// Resolves a worker's uid to a display name — see
  /// [_DailySafetyMeetingScreenState._loadMembers].
  final List<OrganizationUser> members;
  final Future<void> Function(
    String workerId,
    MeetingAttendanceStatus status, {
    bool briefedInPerson,
  })
  onRecordAttendance;

  @override
  State<_AttendanceSection> createState() => _AttendanceSectionState();
}

class _AttendanceSectionState extends State<_AttendanceSection> {
  final _searchController = TextEditingController();
  String _search = '';

  /// Each attendee's outstanding required-learning titles, by uid — see
  /// `MeetingAttendanceService.getMeetingAttendeeLearningStatus`'s doc
  /// comment. Null while loading (never shown as "clear" until resolved);
  /// a failed lookup degrades to showing no learning status at all rather
  /// than blocking the attendance list — this is informational only, so a
  /// failure here should never be load-bearing.
  Map<String, List<String>>? _learningStatus;
  String? _learningStatusLoadedForMeetingId;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _search = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLearningStatus() async {
    try {
      final status = await widget.attendanceService
          .getMeetingAttendeeLearningStatus(
            organizationId: widget.organizationId,
            meetingId: widget.meeting.id,
          );
      if (!mounted) return;
      setState(() => _learningStatus = status);
    } catch (_) {
      // Informational only — see this field's doc comment.
    }
  }

  @override
  Widget build(BuildContext context) {
    final activityIds = widget.meeting.activityIds;
    if (activityIds.isEmpty) {
      return const Text(
        'Add at least one activity above to build the worker roster.',
        style: AppTextStyles.bodyMedium,
      );
    }

    if (_learningStatusLoadedForMeetingId != widget.meeting.id) {
      _learningStatusLoadedForMeetingId = widget.meeting.id;
      _learningStatus = null;
      unawaited(_loadLearningStatus());
    }

    return LiveStreamBuilder<List<List<ActivityAssignment>>>(
      streamKey: activityIds.join(','),
      stream: () => _combineAssignmentStreams(activityIds),
      builder: (context, assignmentSnapshot) {
        final assignmentLists =
            assignmentSnapshot.data ?? const <List<ActivityAssignment>>[];
        final workerIds = <String>{
          for (final assignments in assignmentLists)
            for (final assignment in assignments) assignment.uid,
        }..remove(widget.currentUid);
        final sortedWorkerIds = workerIds.toList()..sort();
        final filteredWorkerIds = _search.isEmpty
            ? sortedWorkerIds
            : sortedWorkerIds
                  .where((id) => id.toLowerCase().contains(_search))
                  .toList();

        return LiveStreamBuilder<List<MeetingAttendance>>(
          streamKey: widget.attendanceRepository,
          stream: () => widget.attendanceRepository.watchAll(),
          builder: (context, attendanceSnapshot) {
            final attendanceByWorker = {
              for (final record in attendanceSnapshot.data ?? const [])
                record.workerId: record.status,
            };
            final briefedWorkers = {
              for (final record in attendanceSnapshot.data ?? const [])
                if (record.briefedInPerson) record.workerId,
            };

            if (sortedWorkerIds.isEmpty) {
              return const Text(
                'No workers are assigned to this meeting\'s activities yet.',
                style: AppTextStyles.bodyMedium,
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (sortedWorkerIds.length > 5)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        labelText: 'Search workers',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ),
                Text(
                  '${attendanceByWorker.length} of ${sortedWorkerIds.length} '
                  'recorded',
                  style: AppTextStyles.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final workerId in filteredWorkerIds)
                  _WorkerAttendanceRow(
                    workerId: workerId,
                    name: _nameFor(workerId),
                    status: attendanceByWorker[workerId],
                    briefedInPerson: briefedWorkers.contains(workerId),
                    outstandingLearning: _learningStatus?[workerId],
                    canEdit: widget.canEdit,
                    isSaving: widget.isSaving,
                    onRecord: (status) =>
                        widget.onRecordAttendance(workerId, status),
                    onBriefedInPerson: () => _confirmBriefed(
                      workerId,
                      _learningStatus?[workerId] ?? const [],
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  String? _nameFor(String uid) {
    for (final member in widget.members) {
      if (member.uid == uid) return member.name;
    }
    return null;
  }

  /// Confirms, then marks [workerId] present as "Briefed in person": the
  /// Foreman has covered today's outstanding [lessons] with them face to
  /// face. The lessons stay due, and the attendance record names them.
  Future<void> _confirmBriefed(String workerId, List<String> lessons) async {
    final name = _nameFor(workerId) ?? 'this worker';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Briefed in person?'),
        content: Text(
          'Confirm you have briefed $name in person on:\n\n'
          '${lessons.map((title) => '• $title').join('\n')}\n\n'
          'They can attend today. The lesson stays on their list until '
          'they complete it, and this record shows you briefed them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Mark present'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onRecordAttendance(
      workerId,
      MeetingAttendanceStatus.present,
      briefedInPerson: true,
    );
  }

  Stream<List<List<ActivityAssignment>>> _combineAssignmentStreams(
    List<String> activityIds,
  ) {
    final streams = activityIds
        .map(widget.activityAssignmentRepository.watchAssignedWorkers)
        .toList();
    return StreamZip(streams);
  }
}

/// Zips multiple streams into a stream of value lists, updating whenever any
/// source stream emits — hand-rolled rather than adding the `async` package
/// as a dependency purely for this one call site.
class StreamZip<T> extends Stream<List<T>> {
  StreamZip(this._streams);

  final List<Stream<T>> _streams;

  @override
  StreamSubscription<List<T>> listen(
    void Function(List<T>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<List<T>>();
    final latest = List<T?>.filled(_streams.length, null);
    final hasValue = List<bool>.filled(_streams.length, false);
    final subscriptions = <StreamSubscription<T>>[];

    void emitIfReady() {
      if (hasValue.every((v) => v)) {
        controller.add(latest.cast<T>());
      }
    }

    for (var i = 0; i < _streams.length; i++) {
      final index = i;
      subscriptions.add(
        _streams[i].listen((value) {
          latest[index] = value;
          hasValue[index] = true;
          emitIfReady();
        }, onError: controller.addError),
      );
    }

    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };

    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

/// One worker's row in the Attendance roster: a large Present/Absent toggle
/// pair sized for gloved/outdoor field use, per [AppSpacing.minTouchTarget].
class _WorkerAttendanceRow extends StatelessWidget {
  const _WorkerAttendanceRow({
    required this.workerId,
    required this.status,
    required this.canEdit,
    required this.isSaving,
    required this.onRecord,
    required this.onBriefedInPerson,
    this.name,
    this.outstandingLearning,
    this.briefedInPerson = false,
  });

  final String workerId;

  /// The worker's display name, or null if it could not be resolved — falls
  /// back to showing [workerId] itself. See [_AttendanceSection.members].
  final String? name;
  final MeetingAttendanceStatus? status;
  final bool canEdit;
  final bool isSaving;

  /// Titles of this worker's outstanding required safety learning for this
  /// meeting — null while still loading or if the lookup failed (shown as
  /// nothing, never as "clear"); an empty list means "checked, nothing
  /// outstanding." Informational only — see
  /// `MeetingAttendanceService.getMeetingAttendeeLearningStatus`'s doc
  /// comment; this never blocks marking attendance.
  final List<String>? outstandingLearning;
  final void Function(MeetingAttendanceStatus status) onRecord;

  /// The worker was marked present after an in-person briefing.
  final bool briefedInPerson;

  /// Marks the worker present as "Briefed in person" — offered only while
  /// they have lessons outstanding for today.
  final VoidCallback onBriefedInPerson;

  @override
  Widget build(BuildContext context) {
    final outstanding = outstandingLearning;
    final canBrief =
        canEdit &&
        !isSaving &&
        outstanding != null &&
        outstanding.isNotEmpty &&
        status != MeetingAttendanceStatus.present;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name ?? workerId, style: AppTextStyles.bodyMedium),
            if (outstanding != null && outstanding.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.school_outlined,
                    size: 16,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      'Outstanding: ${outstanding.join(', ')}',
                      style: AppTextStyles.label.copyWith(
                        color: AppColors.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: _AttendanceButton(
                    label: 'Present',
                    icon: Icons.check_circle_outline,
                    color: AppColors.success,
                    selected: status == MeetingAttendanceStatus.present,
                    onPressed: canEdit && !isSaving
                        ? () => onRecord(MeetingAttendanceStatus.present)
                        : null,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _AttendanceButton(
                    label: 'Absent',
                    icon: Icons.cancel_outlined,
                    color: AppColors.danger,
                    selected: status == MeetingAttendanceStatus.absent,
                    onPressed: canEdit && !isSaving
                        ? () => onRecord(MeetingAttendanceStatus.absent)
                        : null,
                  ),
                ),
              ],
            ),
            if (canBrief) ...[
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.readable(
                    AppColors.learning,
                    Theme.of(context).brightness,
                  ),
                  side: const BorderSide(color: AppColors.learning),
                ),
                onPressed: onBriefedInPerson,
                icon: const Icon(Icons.record_voice_over_outlined),
                label: const Text('Briefed in person'),
              ),
            ],
            if (briefedInPerson &&
                status == MeetingAttendanceStatus.present) ...[
              const SizedBox(height: AppSpacing.sm),
              const StatusBadge(
                label: 'Briefed in person',
                color: AppColors.learning,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AttendanceButton extends StatelessWidget {
  const _AttendanceButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.minTouchTarget),
      child: selected
          ? ElevatedButton.icon(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                foregroundColor: AppColors.textOnPrimary,
              ),
              icon: Icon(icon),
              label: Text(label),
            )
          : OutlinedButton.icon(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(foregroundColor: color),
              icon: Icon(icon),
              label: Text(label),
            ),
    );
  }
}

/// The Concerns step of the meeting flow: lets the foreman add a concern
/// (short description + a fixed category), review what has been recorded,
/// and edit/remove any of it before completing the meeting.
///
/// **Editing/removing an existing concern locks once the meeting is
/// completed; ADDING a new one does not.** `updateMeetingConcern`/
/// `removeMeetingConcern` refuse server-side once the meeting's own
/// `status` is no longer `inProgress` — [canEdit] (derived from that same
/// status one level up in [_MeetingWorkspace]) mirrors that refusal in the
/// UI. `addMeetingConcern` deliberately does NOT refuse on a completed
/// meeting — [canAdd] mirrors that exception instead, so the "Add Concern"
/// form stays available even once [canEdit] is false. Neither flag grants
/// any capability of its own; both only mirror what the callables already
/// enforce.
class _ConcernsSection extends StatefulWidget {
  const _ConcernsSection({
    required this.members,
    required this.concernRepository,
    required this.correctiveActionRepository,
    required this.activityAssignmentRepository,
    required this.meeting,
    required this.currentUid,
    required this.canEdit,
    required this.canAdd,
    required this.isSaving,
    required this.onAdd,
    required this.onEdit,
    required this.onRemove,
    required this.onCreateCorrectiveAction,
  });

  final MeetingConcernRepository concernRepository;
  final CorrectiveActionRepository correctiveActionRepository;
  final ActivityAssignmentRepository activityAssignmentRepository;
  final DailySafetyMeeting meeting;
  final String currentUid;

  /// The organization's people, to show assignees by name.
  final List<OrganizationUser> members;
  final bool canEdit;
  final bool canAdd;
  final bool isSaving;
  final Future<void> Function(
    String description,
    MeetingConcernCategory category,
  )
  onAdd;
  final Future<void> Function(
    MeetingConcern concern,
    String description,
    MeetingConcernCategory category,
  )
  onEdit;
  final Future<void> Function(MeetingConcern concern) onRemove;
  final Future<void> Function({
    String? concernId,
    required String title,
    required String description,
    required String assignedTo,
    required DateTime dueDate,
    required bool evidenceRequired,
    List<CorrectiveActionEvidenceKind> evidenceKinds,
    String? evidenceInstructions,
  })
  onCreateCorrectiveAction;

  @override
  State<_ConcernsSection> createState() => _ConcernsSectionState();
}

class _ConcernsSectionState extends State<_ConcernsSection> {
  final _descriptionController = TextEditingController();
  MeetingConcernCategory _category = MeetingConcernCategory.safety;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submitNew() async {
    final text = _descriptionController.text.trim();
    if (text.isEmpty) return;
    await widget.onAdd(text, _category);
    _descriptionController.clear();
    setState(() => _category = MeetingConcernCategory.safety);
  }

  Future<void> _openEditDialog(MeetingConcern concern) async {
    final result = await showDialog<_ConcernFormResult>(
      context: context,
      builder: (_) => _ConcernFormDialog(
        initialDescription: concern.description,
        initialCategory: concern.category,
      ),
    );
    if (result == null) return;
    await widget.onEdit(concern, result.description, result.category);
  }

  Future<void> _openCreateCorrectiveActionDialog(MeetingConcern concern) async {
    final workerIds = await _rosterFor(widget.meeting.activityIds);
    if (!mounted) return;
    final result = await Navigator.of(context, rootNavigator: true)
        .push<_CorrectiveActionFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => _CorrectiveActionFormDialog(
              candidateAssignees: workerIds,
              people: widget.members,
            ),
          ),
        );
    if (result == null) return;
    await widget.onCreateCorrectiveAction(
      concernId: concern.id,
      title: result.title,
      description: result.description,
      assignedTo: result.assignedTo,
      dueDate: result.dueDate,
      evidenceRequired: result.evidenceRequired,
      evidenceKinds: result.evidenceKinds,
      evidenceInstructions: result.evidenceInstructions,
    );
  }

  /// The candidate assignee roster: workers assigned to the meeting's own
  /// activities, excluding the caller — mirrors [_AttendanceSection]'s own
  /// roster derivation exactly (same "no name lookup available to a
  /// foreman" reasoning), since a corrective action's assignee is drawn from
  /// the same pool of workers a foreman can already see.
  Future<List<String>> _rosterFor(List<String> activityIds) async {
    if (activityIds.isEmpty) return const [];
    final lists = await Future.wait(
      activityIds.map(
        (id) =>
            widget.activityAssignmentRepository.watchAssignedWorkers(id).first,
      ),
    );
    final workerIds = <String>{
      for (final assignments in lists)
        for (final assignment in assignments) assignment.uid,
    }..remove(widget.currentUid);
    return workerIds.toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    return LiveStreamBuilder<List<MeetingConcern>>(
      streamKey: widget.concernRepository,
      stream: () => widget.concernRepository.watchAll(),
      builder: (context, snapshot) {
        final concerns = snapshot.data ?? const <MeetingConcern>[];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (concerns.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text(
                  'No concerns recorded. Add one below if anything came up '
                  'during the meeting.',
                  style: AppTextStyles.bodyMedium,
                ),
              )
            else
              for (final concern in concerns)
                _ConcernCard(
                  concern: concern,
                  correctiveActionRepository: widget.correctiveActionRepository,
                  canEdit: widget.canEdit,
                  isSaving: widget.isSaving,
                  onEdit: () => _openEditDialog(concern),
                  onRemove: () => widget.onRemove(concern),
                  onCreateCorrectiveAction: () =>
                      _openCreateCorrectiveActionDialog(concern),
                ),
            if (widget.canAdd) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final category in MeetingConcernCategory.values)
                    ChoiceChip(
                      label: Text(category.label),
                      selected: _category == category,
                      onSelected: widget.isSaving
                          ? null
                          : (_) => setState(() => _category = category),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Describe the concern',
                ),
                enabled: !widget.isSaving,
                minLines: 1,
                maxLines: 3,
                onSubmitted: (_) => _submitNew(),
              ),
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTouchTarget,
                ),
                child: ElevatedButton.icon(
                  onPressed: widget.isSaving ? null : _submitNew,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Add Concern'),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// One recorded concern's card: category, description, and — while the
/// meeting is still editable — large Edit/Remove controls.
class _ConcernCard extends StatelessWidget {
  const _ConcernCard({
    required this.concern,
    required this.correctiveActionRepository,
    required this.canEdit,
    required this.isSaving,
    required this.onEdit,
    required this.onRemove,
    required this.onCreateCorrectiveAction,
  });

  final MeetingConcern concern;
  final CorrectiveActionRepository correctiveActionRepository;
  final bool canEdit;
  final bool isSaving;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onCreateCorrectiveAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.report_problem_outlined,
                  size: 16,
                  color: AppColors.warning,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(concern.category.label, style: AppTextStyles.bodyMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(concern.description, style: AppTextStyles.bodyMedium),
            const SizedBox(height: AppSpacing.sm),
            LiveStreamBuilder<List<CorrectiveAction>>(
              streamKey: (correctiveActionRepository, concern.id),
              stream: () =>
                  correctiveActionRepository.watchForConcern(concern.id),
              builder: (context, snapshot) {
                final actions = snapshot.data ?? const <CorrectiveAction>[];
                if (actions.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final action in actions)
                        _CorrectiveActionSummaryRow(action: action),
                    ],
                  ),
                );
              },
            ),
            if (canEdit) ...[
              Row(
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: AppSpacing.minTouchTarget,
                      ),
                      child: OutlinedButton.icon(
                        onPressed: isSaving ? null : onEdit,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit'),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: AppSpacing.minTouchTarget,
                      ),
                      child: OutlinedButton.icon(
                        onPressed: isSaving ? null : onRemove,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                        ),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remove'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTouchTarget,
                ),
                child: OutlinedButton.icon(
                  onPressed: isSaving ? null : onCreateCorrectiveAction,
                  icon: const Icon(Icons.build_outlined),
                  label: const Text('Create Corrective Action'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact summary of one corrective action raised from a concern, shown
/// inline on the [_ConcernCard] it belongs to.
class _CorrectiveActionSummaryRow extends StatelessWidget {
  const _CorrectiveActionSummaryRow({required this.action});

  final CorrectiveAction action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.build_outlined, size: 16, color: AppColors.info),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(action.title, style: AppTextStyles.bodyMedium),
                Text(
                  '${action.status.label} · Assigned: ${action.assignedTo} '
                  '· Due ${_formatDate(action.dueDate)}',
                  style: AppTextStyles.label,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

class _ConcernFormResult {
  const _ConcernFormResult(this.description, this.category);

  final String description;
  final MeetingConcernCategory category;
}

/// A dialog for editing an existing concern's description/category. Adding
/// a new concern uses the inline form in [_ConcernsSection] instead — this
/// dialog exists only for the edit path, so a foreman correcting a concern
/// mid-review does not lose their place in the list.
class _ConcernFormDialog extends StatefulWidget {
  const _ConcernFormDialog({
    required this.initialDescription,
    required this.initialCategory,
  });

  final String initialDescription;
  final MeetingConcernCategory initialCategory;

  @override
  State<_ConcernFormDialog> createState() => _ConcernFormDialogState();
}

class _ConcernFormDialogState extends State<_ConcernFormDialog> {
  late final _descriptionController = TextEditingController(
    text: widget.initialDescription,
  );
  late MeetingConcernCategory _category = widget.initialCategory;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Concern'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final category in MeetingConcernCategory.values)
                  ChoiceChip(
                    label: Text(category.label),
                    selected: _category == category,
                    onSelected: (_) => setState(() => _category = category),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Describe the concern',
              ),
              minLines: 1,
              maxLines: 3,
              autofocus: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final text = _descriptionController.text.trim();
            if (text.isEmpty) return;
            Navigator.of(context).pop(_ConcernFormResult(text, _category));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _CorrectiveActionFormResult {
  const _CorrectiveActionFormResult({
    required this.title,
    required this.description,
    required this.assignedTo,
    required this.dueDate,
    required this.evidenceRequired,
    this.evidenceKinds = const [],
    this.evidenceInstructions,
  });

  final String title;
  final String description;
  final String assignedTo;
  final DateTime dueDate;
  final bool evidenceRequired;

  /// What evidence completing it needs — see [EvidenceRequirementPicker].
  final List<CorrectiveActionEvidenceKind> evidenceKinds;
  final String? evidenceInstructions;
}

/// A dialog for creating a corrective action from a concern: title,
/// description, assigned person (picked from the same worker roster
/// [_AttendanceSection] draws from), a due date, and whether completing it
/// will require evidence — a flag only, since evidence upload itself is
/// explicitly out of scope for this stage (see [CorrectiveAction]'s doc
/// comment).
class _CorrectiveActionFormDialog extends StatefulWidget {
  const _CorrectiveActionFormDialog({
    required this.candidateAssignees,
    this.people = const [],
  });

  final List<String> candidateAssignees;

  /// Who [candidateAssignees] are, to choose by name, not account id.
  final List<OrganizationUser> people;

  @override
  State<_CorrectiveActionFormDialog> createState() =>
      _CorrectiveActionFormDialogState();
}

class _CorrectiveActionFormDialogState
    extends State<_CorrectiveActionFormDialog> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _evidenceInstructionsController = TextEditingController();
  String? _assignedTo;
  DateTime? _dueDate;
  Set<CorrectiveActionEvidenceKind> _evidenceKinds = {};

  String? get _evidenceInstructions {
    final text = _evidenceInstructionsController.text.trim();
    return _evidenceKinds.isEmpty || text.isEmpty ? null : text;
  }

  @override
  void initState() {
    super.initState();
    _assignedTo = widget.candidateAssignees.firstOrNull;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _evidenceInstructionsController.dispose();
    super.dispose();
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  void _submit() {
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    final assignedTo = _assignedTo;
    final dueDate = _dueDate;
    if (title.isEmpty ||
        description.isEmpty ||
        assignedTo == null ||
        dueDate == null) {
      return;
    }
    Navigator.of(context).pop(
      _CorrectiveActionFormResult(
        title: title,
        description: description,
        assignedTo: assignedTo,
        dueDate: dueDate,
        evidenceRequired: _evidenceKinds.isNotEmpty,
        evidenceKinds: _evidenceKinds.toList(),
        evidenceInstructions: _evidenceInstructions,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = widget.candidateAssignees.isNotEmpty;

    final actions = <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: canSubmit ? _submit : null,
        child: const Text('Create'),
      ),
    ];
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FeatureHeader(
                    eyebrow: 'From a meeting concern',
                    title: _titleController.text.trim().isEmpty
                        ? 'New Corrective Action'
                        : _titleController.text.trim(),
                    icon: Icons.build_circle,
                    color: AppColors.correctiveActions,
                    chips: [
                      FeatureChip(
                        icon: Icons.event,
                        label: _dueDate == null
                            ? 'No due date yet'
                            : 'Due ${_formatDate(_dueDate!)}',
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (!canSubmit)
                    const Padding(
                      padding: EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Text(
                        'No eligible workers to assign. A worker must already '
                        'be assigned to one of this meeting\'s activities.',
                        style: AppTextStyles.bodyMedium,
                      ),
                    ),
                  FormSection(
                    title: 'What needs doing',
                    icon: Icons.edit_note,
                    color: AppColors.correctiveActions,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _titleController,
                          decoration: const InputDecoration(labelText: 'Title'),
                          autofocus: true,
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextField(
                          controller: _descriptionController,
                          decoration: const InputDecoration(
                            labelText: 'Description',
                          ),
                          minLines: 1,
                          maxLines: 3,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const SizedBox(height: AppSpacing.sm),
                  FormSection(
                    title: 'Who and when',
                    icon: Icons.event,
                    color: AppColors.meetings,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (canSubmit)
                          PersonPicker(
                            uids: widget.candidateAssignees,
                            people: widget.people,
                            selected: _assignedTo,
                            color: AppColors.correctiveActions,
                            onChanged: (uid) =>
                                setState(() => _assignedTo = uid),
                          ),
                        const SizedBox(height: AppSpacing.sm),
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: AppSpacing.minTouchTarget,
                          ),
                          child: OutlinedButton.icon(
                            onPressed: _pickDueDate,
                            icon: const Icon(Icons.event_outlined),
                            label: Text(
                              _dueDate == null
                                  ? 'Set due date'
                                  : 'Due ${_formatDate(_dueDate!)}',
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        EvidenceRequirementPicker(
                          kinds: _evidenceKinds,
                          onKindsChanged: (kinds) =>
                              setState(() => _evidenceKinds = kinds),
                          instructionsController:
                              _evidenceInstructionsController,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              for (final (index, action) in actions.indexed) ...[
                if (index > 0) const SizedBox(width: AppSpacing.sm),
                Expanded(child: action),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
