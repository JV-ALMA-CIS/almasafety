import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../activities/data/activity_assignment_repository.dart';
import '../../activities/data/activity_repository.dart';
import '../../activities/domain/activity.dart';
import '../../activities/domain/activity_assignment.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/data/corrective_action_service.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
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
import 'daily_safety_meeting_history_screen.dart';

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
    this.meetingRepository,
    this.meetingService,
    this.activityRepository,
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
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in foreman's
  /// organization.
  final DailySafetyMeetingRepository? meetingRepository;
  final DailySafetyMeetingService? meetingService;
  final ActivityRepository? activityRepository;
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

  DailySafetyMeetingRepository? _meetingRepository;
  ActivityRepository? _activityRepository;
  SafetyMeetingPointRepository? _meetingPointRepository;
  SiteRepository? _siteRepository;
  ActivityAssignmentRepository? _activityAssignmentRepository;
  CorrectiveActionRepository? _correctiveActionRepository;

  String? _errorMessage;
  bool _isSaving = false;
  bool _isStartingMeeting = false;

  DailySafetyMeetingRepository _meetingRepositoryFor(String organizationId) {
    final existing = _meetingRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = widget.meetingRepository ??
        DailySafetyMeetingRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _meetingRepository = created;
    return created;
  }

  ActivityRepository _activityRepositoryFor(String organizationId) {
    final existing = _activityRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = widget.activityRepository ??
        ActivityRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _activityRepository = created;
    return created;
  }

  SafetyMeetingPointRepository _meetingPointRepositoryFor(
    String organizationId,
  ) {
    final existing = _meetingPointRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = widget.meetingPointRepository ??
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
    final created = widget.siteRepository ??
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
    final created = widget.activityAssignmentRepository ??
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
    final created = widget.correctiveActionRepository ??
        CorrectiveActionRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _correctiveActionRepository = created;
    return created;
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

    final date = _today();

    return StreamBuilder<List<DailySafetyMeeting>>(
      stream: _meetingRepositoryFor(organizationId).watchForForemanSiteAndDate(
        foremanId: profile!.uid,
        siteId: siteId,
        date: date,
      ),
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
            siteId: siteId,
            currentUid: profile.uid,
            meetingService: _meetingService,
            attendanceService: _attendanceService,
            concernService: _concernService,
            correctiveActionService: _correctiveActionService,
            activityRepository: _activityRepositoryFor(organizationId),
            meetingPointRepository: _meetingPointRepositoryFor(
              organizationId,
            ),
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
            isSaving: _isSaving,
            errorMessage: _errorMessage,
            onSave: _save,
          );
        }

        return _StartMeetingView(
          organizationId: organizationId,
          siteId: siteId,
          siteRepository: _siteRepositoryFor(organizationId),
          activityRepository: _activityRepositoryFor(organizationId),
          meetingPointRepository: _meetingPointRepositoryFor(organizationId),
          isStarting: _isStartingMeeting,
          errorMessage: _errorMessage,
          onStart: _startMeeting,
        );
      },
    );
  }
}

/// Step 1-2: resolves today's site activities and the recommended meeting
/// points (those whose `applicableActivities` overlaps today's activities,
/// or which apply universally), and lets the foreman start the meeting.
///
/// The actual accept/remove/add step happens in [_MeetingWorkspace] after
/// the meeting is created — the recommendation set here is only what the
/// meeting is SEEDED with; nothing is final until the foreman edits and
/// completes it.
class _StartMeetingView extends StatelessWidget {
  const _StartMeetingView({
    required this.organizationId,
    required this.siteId,
    required this.siteRepository,
    required this.activityRepository,
    required this.meetingPointRepository,
    required this.isStarting,
    required this.errorMessage,
    required this.onStart,
  });

  final String organizationId;
  final String siteId;
  final SiteRepository siteRepository;
  final ActivityRepository activityRepository;
  final SafetyMeetingPointRepository meetingPointRepository;
  final bool isStarting;
  final String? errorMessage;
  final Future<void> Function({
    required String organizationId,
    required String projectId,
    required String siteId,
    required List<Activity> todaysActivities,
    required List<SafetyMeetingPoint> recommendedPoints,
  }) onStart;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Site?>(
      stream: siteRepository.watchById(siteId),
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

        return StreamBuilder<List<Activity>>(
          stream: activityRepository.watchBySite(siteId),
          builder: (context, activitySnapshot) {
            final activities = (activitySnapshot.data ?? const <Activity>[])
                .where((a) => a.status.id == 'active')
                .toList();

            return StreamBuilder<List<SafetyMeetingPoint>>(
              stream: meetingPointRepository.watchActive(),
              builder: (context, pointSnapshot) {
                final allPoints =
                    pointSnapshot.data ?? const <SafetyMeetingPoint>[];
                final activityIds = activities.map((a) => a.id).toSet();
                final recommended = allPoints.where((point) {
                  return point.applicableActivities.isEmpty ||
                      point.applicableActivities.any(activityIds.contains);
                }).toList();

                return ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    Text("Today's Meeting", style: AppTextStyles.headlineMedium),
                    const SizedBox(height: AppSpacing.xs),
                    Text(site.name, style: AppTextStyles.bodyMedium),
                    const SizedBox(height: AppSpacing.md),
                    if (errorMessage != null) ...[
                      AuthErrorBanner(message: errorMessage!),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    Text(
                      "Today's Activities (${activities.length})",
                      style: AppTextStyles.titleLarge,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (activities.isEmpty)
                      const Text(
                        'No active activities are recorded at this site.',
                        style: AppTextStyles.bodyMedium,
                      ),
                    for (final activity in activities)
                      _ListRow(icon: Icons.engineering_outlined, label: activity.name),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      'Recommended Meeting Points (${recommended.length})',
                      style: AppTextStyles.titleLarge,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (recommended.isEmpty)
                      const Text(
                        'No recommended meeting points for these '
                        'activities yet.',
                        style: AppTextStyles.bodyMedium,
                      ),
                    for (final point in recommended)
                      _ListRow(
                        icon: Icons.list_alt_outlined,
                        label: point.title,
                      ),
                    const SizedBox(height: AppSpacing.lg),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: AppSpacing.minTouchTarget,
                      ),
                      child: ElevatedButton.icon(
                        onPressed: isStarting || activities.isEmpty
                            ? null
                            : () => onStart(
                                  organizationId: organizationId,
                                  projectId: site.projectId,
                                  siteId: siteId,
                                  todaysActivities: activities,
                                  recommendedPoints: recommended,
                                ),
                        icon: const Icon(Icons.play_arrow_outlined),
                        label: Text(
                          isStarting ? 'Starting…' : "Start Today's Meeting",
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
                    const SizedBox(height: AppSpacing.lg),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: AppSpacing.minTouchTarget,
                      ),
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => DailySafetyMeetingHistoryScreen(
                              organizationId: organizationId,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.history_outlined),
                        label: const Text('View Meeting History'),
                      ),
                    ),
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
    required this.activityRepository,
    required this.meetingPointRepository,
    required this.activityAssignmentRepository,
    required this.attendanceRepository,
    required this.concernRepository,
    required this.correctiveActionRepository,
    required this.pointNoteRepository,
    required this.evidenceRepository,
    required this.imagePicker,
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
  final ActivityRepository activityRepository;
  final SafetyMeetingPointRepository meetingPointRepository;
  final ActivityAssignmentRepository activityAssignmentRepository;
  final MeetingAttendanceRepository attendanceRepository;
  final MeetingConcernRepository concernRepository;
  final CorrectiveActionRepository correctiveActionRepository;
  final MeetingPointNoteRepository pointNoteRepository;
  final MeetingEvidenceRepository evidenceRepository;
  final ImagePicker imagePicker;
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

  Future<void> _addConcern(String description, MeetingConcernCategory category) {
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

  Future<void> _recordAttendance(String workerId, MeetingAttendanceStatus status) {
    return widget.onSave(
      () => widget.attendanceService.recordMeetingAttendance(
        organizationId: widget.organizationId,
        meetingId: widget.meeting.id,
        workerId: workerId,
        status: status.id,
      ),
    );
  }

  Future<void> _complete() => widget.onSave(
    () => widget.meetingService.completeDailySafetyMeeting(
      widget.organizationId,
      widget.meeting.id,
    ),
  );

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
      final photo = await widget.imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        imageQuality: 85,
      );
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
        () => _evidenceError = 'Could not capture evidence. Please try '
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
    final canEdit = !meeting.isCompleted;

    return StreamBuilder<List<Activity>>(
      stream: widget.activityRepository.watchBySite(widget.siteId),
      builder: (context, activitySnapshot) {
        final siteActivities = (activitySnapshot.data ?? const <Activity>[])
            .where((a) => a.status.id == 'active')
            .toList();

        return StreamBuilder<List<SafetyMeetingPoint>>(
          stream: widget.meetingPointRepository.watchActive(),
          builder: (context, pointSnapshot) {
            final allPoints =
                pointSnapshot.data ?? const <SafetyMeetingPoint>[];

            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        meeting.isCompleted
                            ? "Today's Meeting — Completed"
                            : "Today's Meeting — In Progress",
                        style: AppTextStyles.headlineMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                if (widget.errorMessage != null) ...[
                  AuthErrorBanner(message: widget.errorMessage!),
                  const SizedBox(height: AppSpacing.md),
                ],
                Text('Activities Discussed', style: AppTextStyles.titleLarge),
                const SizedBox(height: AppSpacing.sm),
                for (final activity in siteActivities)
                  CheckboxListTile(
                    value: meeting.activityIds.contains(activity.id),
                    onChanged: canEdit && !widget.isSaving
                        ? (_) => _toggleActivity(activity)
                        : null,
                    title: Text(activity.name),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Safety Meeting Points',
                        style: AppTextStyles.titleLarge,
                      ),
                    ),
                    if (canEdit)
                      TextButton.icon(
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
                  ],
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
                StreamBuilder<List<MeetingPointNote>>(
                  stream: widget.pointNoteRepository.watchAll(),
                  builder: (context, noteSnapshot) {
                    final notesByPointId = {
                      for (final n
                          in noteSnapshot.data ?? const <MeetingPointNote>[])
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
                                  .firstWhere((_) => true, orElse: () => null);
                              if (point == null) return const SizedBox.shrink();
                              return _MeetingPointTile(
                                point: point,
                                note: notesByPointId[pointId]?.note,
                                canEdit: canEdit,
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
                Text('Attendance', style: AppTextStyles.titleLarge),
                const SizedBox(height: AppSpacing.sm),
                _AttendanceSection(
                  meeting: meeting,
                  currentUid: widget.currentUid,
                  canEdit: canEdit,
                  isSaving: widget.isSaving,
                  activityAssignmentRepository:
                      widget.activityAssignmentRepository,
                  attendanceRepository: widget.attendanceRepository,
                  onRecordAttendance: _recordAttendance,
                ),
                const SizedBox(height: AppSpacing.md),
                Text('Concerns', style: AppTextStyles.titleLarge),
                const SizedBox(height: AppSpacing.sm),
                _ConcernsSection(
                  concernRepository: widget.concernRepository,
                  correctiveActionRepository: widget.correctiveActionRepository,
                  activityAssignmentRepository:
                      widget.activityAssignmentRepository,
                  meeting: meeting,
                  currentUid: widget.currentUid,
                  canEdit: canEdit,
                  isSaving: widget.isSaving,
                  onAdd: _addConcern,
                  onEdit: _editConcern,
                  onRemove: _removeConcern,
                  onCreateCorrectiveAction: _createCorrectiveAction,
                ),
                const SizedBox(height: AppSpacing.md),
                Text('Evidence', style: AppTextStyles.titleLarge),
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
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: AppSpacing.minTouchTarget,
                    ),
                    child: ElevatedButton.icon(
                      onPressed: widget.isSaving ||
                              meeting.activityIds.isEmpty ||
                              meeting.meetingPointIds.isEmpty
                          ? null
                          : _complete,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Complete Meeting'),
                    ),
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
                const SizedBox(height: AppSpacing.lg),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DailySafetyMeetingHistoryScreen(
                          organizationId: widget.organizationId,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.history_outlined),
                    label: const Text('View Meeting History'),
                  ),
                ),
              ],
            );
          },
        );
      },
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
    required this.isSaving,
    required this.onRemovePoint,
    required this.onSetNote,
    required this.onRemoveNote,
  });

  final SafetyMeetingPoint point;

  /// The point's current discussion note, or null if none has been
  /// recorded — optional, matching every other field on this workspace.
  final String? note;
  final bool canEdit;
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
      if (widget.note != null) widget.onRemoveNote();
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
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CheckboxListTile(
              value: true,
              onChanged: widget.canEdit && !widget.isSaving
                  ? (_) => widget.onRemovePoint()
                  : null,
              title: Text(widget.point.title),
              subtitle: Text(widget.point.category),
              secondary: widget.canEdit
                  ? IconButton(
                      tooltip: 'Remove',
                      onPressed:
                          widget.isSaving ? null : widget.onRemovePoint,
                      icon: const Icon(Icons.close),
                    )
                  : null,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
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
                        hintText: 'e.g. Reminded workers to maintain three '
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
                        onTap: widget.canEdit && !widget.isSaving
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
                            if (widget.canEdit)
                              const Icon(Icons.edit_outlined, size: 16),
                          ],
                        ),
                      )
                    : (widget.canEdit
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
    return StreamBuilder<List<MeetingEvidence>>(
      stream: evidenceRepository.watchAll(),
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
                      onPressed:
                          isCapturing ? null : () => onCapture(type),
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
                  errorBuilder: (context, error, stackTrace) => const Icon(
                    Icons.broken_image_outlined,
                    size: 56,
                  ),
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

class _ListRow extends StatelessWidget {
  const _ListRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(label, style: AppTextStyles.bodyMedium)),
        ],
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

class _MeetingPointPickerDialogState
    extends State<_MeetingPointPickerDialog> {
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
                    return ListTile(
                      title: Text(point.title),
                      subtitle: Text(point.category),
                      onTap: () => Navigator.of(context).pop(point),
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
    required this.currentUid,
    required this.canEdit,
    required this.isSaving,
    required this.activityAssignmentRepository,
    required this.attendanceRepository,
    required this.onRecordAttendance,
  });

  final DailySafetyMeeting meeting;
  final String currentUid;
  final bool canEdit;
  final bool isSaving;
  final ActivityAssignmentRepository activityAssignmentRepository;
  final MeetingAttendanceRepository attendanceRepository;
  final Future<void> Function(String workerId, MeetingAttendanceStatus status)
  onRecordAttendance;

  @override
  State<_AttendanceSection> createState() => _AttendanceSectionState();
}

class _AttendanceSectionState extends State<_AttendanceSection> {
  final _searchController = TextEditingController();
  String _search = '';

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

  @override
  Widget build(BuildContext context) {
    final activityIds = widget.meeting.activityIds;
    if (activityIds.isEmpty) {
      return const Text(
        'Add at least one activity above to build the worker roster.',
        style: AppTextStyles.bodyMedium,
      );
    }

    return StreamBuilder<List<List<ActivityAssignment>>>(
      stream: _combineAssignmentStreams(activityIds),
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

        return StreamBuilder<List<MeetingAttendance>>(
          stream: widget.attendanceRepository.watchAll(),
          builder: (context, attendanceSnapshot) {
            final attendanceByWorker = {
              for (final record in attendanceSnapshot.data ?? const [])
                record.workerId: record.status,
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
                    status: attendanceByWorker[workerId],
                    canEdit: widget.canEdit,
                    isSaving: widget.isSaving,
                    onRecord: (status) =>
                        widget.onRecordAttendance(workerId, status),
                  ),
              ],
            );
          },
        );
      },
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
        _streams[i].listen(
          (value) {
            latest[index] = value;
            hasValue[index] = true;
            emitIfReady();
          },
          onError: controller.addError,
        ),
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
  });

  final String workerId;
  final MeetingAttendanceStatus? status;
  final bool canEdit;
  final bool isSaving;
  final void Function(MeetingAttendanceStatus status) onRecord;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(workerId, style: AppTextStyles.bodyMedium),
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
/// **Once the meeting is completed, this section becomes read-only.**
/// `addMeetingConcern`/`updateMeetingConcern`/`removeMeetingConcern` all
/// refuse server-side once the meeting's own `status` is no longer
/// `inProgress` — [canEdit] (derived from that same status one level up in
/// [_MeetingWorkspace]) only mirrors that refusal in the UI so a foreman
/// never sees a control that would fail anyway; it grants no capability of
/// its own.
class _ConcernsSection extends StatefulWidget {
  const _ConcernsSection({
    required this.concernRepository,
    required this.correctiveActionRepository,
    required this.activityAssignmentRepository,
    required this.meeting,
    required this.currentUid,
    required this.canEdit,
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
  final bool canEdit;
  final bool isSaving;
  final Future<void> Function(String description, MeetingConcernCategory category)
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
    final result = await showDialog<_CorrectiveActionFormResult>(
      context: context,
      builder: (_) => _CorrectiveActionFormDialog(candidateAssignees: workerIds),
    );
    if (result == null) return;
    await widget.onCreateCorrectiveAction(
      concernId: concern.id,
      title: result.title,
      description: result.description,
      assignedTo: result.assignedTo,
      dueDate: result.dueDate,
      evidenceRequired: result.evidenceRequired,
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
        (id) => widget.activityAssignmentRepository.watchAssignedWorkers(id).first,
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
    return StreamBuilder<List<MeetingConcern>>(
      stream: widget.concernRepository.watchAll(),
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
            if (widget.canEdit) ...[
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
            StreamBuilder<List<CorrectiveAction>>(
              stream: correctiveActionRepository.watchForConcern(concern.id),
              builder: (context, snapshot) {
                final actions =
                    snapshot.data ?? const <CorrectiveAction>[];
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
  });

  final String title;
  final String description;
  final String assignedTo;
  final DateTime dueDate;
  final bool evidenceRequired;
}

/// A dialog for creating a corrective action from a concern: title,
/// description, assigned person (picked from the same worker roster
/// [_AttendanceSection] draws from), a due date, and whether completing it
/// will require evidence — a flag only, since evidence upload itself is
/// explicitly out of scope for this stage (see [CorrectiveAction]'s doc
/// comment).
class _CorrectiveActionFormDialog extends StatefulWidget {
  const _CorrectiveActionFormDialog({required this.candidateAssignees});

  final List<String> candidateAssignees;

  @override
  State<_CorrectiveActionFormDialog> createState() =>
      _CorrectiveActionFormDialogState();
}

class _CorrectiveActionFormDialogState
    extends State<_CorrectiveActionFormDialog> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  String? _assignedTo;
  DateTime? _dueDate;
  bool _evidenceRequired = false;

  @override
  void initState() {
    super.initState();
    _assignedTo = widget.candidateAssignees.firstOrNull;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
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
        evidenceRequired: _evidenceRequired,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = widget.candidateAssignees.isNotEmpty;

    return AlertDialog(
      title: const Text('Create Corrective Action'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!canSubmit)
                const Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Text(
                    'No eligible workers to assign. A worker must already '
                    'be assigned to one of this meeting\'s activities.',
                    style: AppTextStyles.bodyMedium,
                  ),
                ),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Title'),
                autofocus: true,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: AppSpacing.sm),
              if (canSubmit)
                DropdownButtonFormField<String>(
                  initialValue: _assignedTo,
                  decoration: const InputDecoration(
                    labelText: 'Assigned person',
                  ),
                  items: [
                    for (final workerId in widget.candidateAssignees)
                      DropdownMenuItem(
                        value: workerId,
                        child: Text(workerId),
                      ),
                  ],
                  onChanged: (value) => setState(() => _assignedTo = value),
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
              CheckboxListTile(
                value: _evidenceRequired,
                onChanged: (value) =>
                    setState(() => _evidenceRequired = value ?? false),
                title: const Text('Evidence required to complete'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: canSubmit ? _submit : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
