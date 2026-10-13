import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/daily_safety_meeting_repository.dart';
import '../domain/daily_safety_meeting.dart';
import 'daily_safety_meeting_screen.dart';
import '../../pre_start_checks/presentation/pre_start_outcome_style.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/feature_header.dart';

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
/// [DailySafetyMeetingScreen.resumeMeetingId]. A completed meeting is not
/// tappable here: it is a closed record (activities/points/attendance are
/// frozen), reviewed via the same summary a Site Manager sees, not
/// re-entered as an editable workspace — though a Foreman may still add a
/// Concern or a meeting-point note to it from that summary, matching
/// `addMeetingConcern`/`setMeetingPointNote`'s deliberate post-completion
/// exception.
class DailySafetyMeetingHistoryScreen extends StatefulWidget {
  const DailySafetyMeetingHistoryScreen({
    super.key,
    required this.organizationId,
    this.repository,
  });

  final String organizationId;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real repository.
  final DailySafetyMeetingRepository? repository;

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

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<SessionController>().profile;
    final foremanId = profile?.uid;

    return Scaffold(
      appBar: AppBar(),
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
                        onResume: meeting.isCompleted
                            ? null
                            : () => Navigator.of(context, rootNavigator: true)
                                  .push(
                                    MaterialPageRoute<void>(
                                      // Opened full-screen, so it brings its
                                      // own top bar and back arrow.
                                      builder: (_) => Scaffold(
                                        appBar: AppBar(),
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
  const _MeetingHistoryCard({required this.meeting, required this.onResume});

  final DailySafetyMeeting meeting;

  /// Null for a completed meeting — nothing to resume, it is a closed
  /// record. Set for an in-progress one — tapping the card reopens it in
  /// [DailySafetyMeetingScreen] so the Foreman can finish and complete it.
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final color = meeting.isCompleted ? AppColors.success : AppColors.warning;
    return AccentCard(
      color: color,
      icon: meeting.isCompleted ? Icons.task_alt : Icons.pending_actions,
      title: meeting.date,
      onTap: onResume,
      badges: [AccentBadge(label: meeting.status.label, color: color)],
      trailing: meeting.crewOutcome == null
          ? null
          : CrewOutcomeBadge(outcome: meeting.crewOutcome!),
      details: [
        AccentDetail(
          icon: Icons.checklist,
          text:
              '${meeting.activityIds.length} activities, '
              '${meeting.meetingPointIds.length} meeting points, '
              '${meeting.concerns.length} concerns',
        ),
        if (onResume != null)
          const AccentDetail(
            icon: Icons.touch_app,
            text: 'Not yet completed — tap to finish this meeting.',
          ),
      ],
    );
  }
}
