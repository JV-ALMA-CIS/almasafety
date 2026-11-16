import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/daily_safety_meeting_repository.dart';
import '../data/meeting_concern_repository.dart';
import '../domain/daily_safety_meeting.dart';
import 'daily_safety_meeting_screen.dart';
import 'meeting_concern_count.dart';
import '../../pre_start_checks/presentation/pre_start_outcome_style.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/mobile_title.dart';

/// Step 6: the signed-in foreman's own Daily Safety Meeting history — most
/// recent first.
///
/// Scoped to the caller's own `foremanId`, matching
/// `MySafetyLearningScreen`'s "own records only" simplicity for a first
/// foreman-facing history view. A broader admin/compliance history view
/// (every foreman's meetings across a site or organization) is out of scope
/// for this foundation.
///
/// Unlike [AdminDailySafetyMeetingsScreen] (which a Site Manager uses and
/// which only ever shows COMPLETED meetings — an in-progress one is not yet
/// a reviewable record), this screen deliberately shows every status: a
/// Foreman needs to be able to find a meeting they forgot to complete on a
/// past day and resume it. Tapping an in-progress meeting reopens
/// [DailySafetyMeetingScreen] for that specific meeting — see
/// [DailySafetyMeetingScreen.resumeMeetingId]. Tapping a completed meeting
/// opens the same screen, which shows a completed meeting as its read-only
/// record (activities/points/attendance are frozen) with a Print button —
/// though a Foreman may still add a Concern, a corrective action from a
/// concern, or a meeting-point note to it there, matching the server's
/// deliberate post-completion exceptions.
class DailySafetyMeetingHistoryScreen extends StatefulWidget {
  const DailySafetyMeetingHistoryScreen({
    super.key,
    required this.organizationId,
    this.repository,
    this.concernRepositoryBuilder,
  });

  final String organizationId;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real repository.
  final DailySafetyMeetingRepository? repository;

  /// Injected in tests: counts an older meeting's concerns — see
  /// [MeetingConcernCountBuilder].
  final MeetingConcernRepository Function(String meetingId)?
  concernRepositoryBuilder;

  @override
  State<DailySafetyMeetingHistoryScreen> createState() =>
      _DailySafetyMeetingHistoryScreenState();
}

class _DailySafetyMeetingHistoryScreenState
    extends State<DailySafetyMeetingHistoryScreen> {
  late final DailySafetyMeetingRepository _repository =
      widget.repository ??
      DailySafetyMeetingRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organizationId,
      );

  MeetingConcernRepository _concernRepositoryFor(String meetingId) =>
      widget.concernRepositoryBuilder?.call(meetingId) ??
      MeetingConcernRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organizationId,
        meetingId: meetingId,
      );

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<SessionController>().profile;
    final foremanId = profile?.uid;

    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Meeting History')),
      body: foremanId == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  'Your account has no organization yet.',
                  style: AppTextStyles.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : LiveStreamBuilder<List<DailySafetyMeeting>>(
              streamKey: (_repository, foremanId),
              stream: () => _repository.watchHistoryForForeman(foremanId),
              builder: (context, snapshot) {
                final meetings = snapshot.data ?? const <DailySafetyMeeting>[];
                final isLoading =
                    snapshot.connectionState == ConnectionState.waiting;

                if (isLoading && meetings.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Text(
                        'Could not load meeting history. Please try again.',
                        style: AppTextStyles.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                if (meetings.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Text(
                        'No meetings recorded yet.',
                        style: AppTextStyles.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                final inProgress = meetings.where((m) => !m.isCompleted).length;
                return ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    FeatureHeader(
                      title: 'Your meetings',
                      subtitle: inProgress > 0
                          ? 'Tap an unfinished meeting to complete it.'
                          : 'Every meeting you have run.',
                      icon: Icons.history,
                      color: AppColors.meetings,
                      chips: [
                        FeatureChip(
                          icon: Icons.task_alt,
                          label: '${meetings.length - inProgress} completed',
                        ),
                        FeatureChip(
                          icon: Icons.pending,
                          label: '$inProgress in progress',
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    for (final meeting in meetings) ...[
                      _MeetingHistoryCard(
                        meeting: meeting,
                        concernRepositoryFor: _concernRepositoryFor,
                        onOpen: () =>
                            Navigator.of(context, rootNavigator: true).push(
                              MaterialPageRoute<void>(
                                // Opened full-screen, so it brings its
                                // own top bar and back arrow.
                                builder: (_) => Scaffold(
                                  appBar: AppBar(
                                    title: const MobileTitle('Meeting Details'),
                                  ),
                                  body: DailySafetyMeetingScreen(
                                    resumeMeetingId: meeting.id,
                                  ),
                                ),
                              ),
                            ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ],
                );
              },
            ),
    );
  }
}

class _MeetingHistoryCard extends StatelessWidget {
  const _MeetingHistoryCard({
    required this.meeting,
    required this.concernRepositoryFor,
    required this.onOpen,
  });

  final DailySafetyMeeting meeting;
  final MeetingConcernRepository Function(String meetingId)
  concernRepositoryFor;

  /// Opens the meeting in [DailySafetyMeetingScreen]: an in-progress one to
  /// finish and complete it, a completed one to view or print its record.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final color = meeting.isCompleted ? AppColors.success : AppColors.warning;
    return MeetingConcernCountBuilder(
      meeting: meeting,
      concernRepositoryFor: concernRepositoryFor,
      builder: (context, concernCount) => AccentCard(
        color: color,
        icon: meeting.isCompleted ? Icons.task_alt : Icons.pending_actions,
        title: meeting.date,
        onTap: onOpen,
        badges: [AccentBadge(label: meeting.status.label, color: color)],
        trailing: meeting.crewOutcome == null
            ? null
            : CrewOutcomeBadge(outcome: meeting.crewOutcome!),
        details: [
          AccentDetail(
            icon: Icons.checklist,
            text:
                '${meeting.activityIds.length} activities, '
                '${meeting.totalPointCount} meeting points, '
                '${concernCountLabel(concernCount)}',
          ),
          AccentDetail(
            icon: Icons.touch_app,
            text: meeting.isCompleted
                ? 'Tap to view or print this meeting.'
                : 'Not yet completed — tap to finish this meeting.',
          ),
        ],
      ),
    );
  }
}
