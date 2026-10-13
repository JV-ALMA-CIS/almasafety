import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/daily_safety_meeting_repository.dart';
import '../data/meeting_attendance_repository.dart';
import '../domain/daily_safety_meeting.dart';
import '../domain/meeting_attendance.dart';
import '../domain/meeting_attendance_status.dart';

/// Resolves and shows a Worker's own site's Daily Safety Meeting for today,
/// plus their own attendance status within it, once found.
///
/// Shared by [WorkerDashboardScreen]'s "Today's Meeting" card and
/// [DailySafetyMeetingScreen]'s Worker-facing branch — a Worker has no
/// operational workspace of their own (they don't run or attend the meeting
/// IN the app; the physical toolbox talk happens on site, per
/// `DailySafetyMeetingScreen`'s own header doc comment), but they should see
/// the same real meeting/attendance data wherever they look for it, not a
/// static placeholder on one screen and the real thing on another.
///
/// A Worker has no foreman uid to query by — only their own `siteIds` — and
/// (per `firestore.rules`'s Phase 2 grant) may read a meeting whose own
/// `siteId` is in their own `siteIds`, so this queries
/// [DailySafetyMeetingRepository.watchForSiteAndDate] once per assigned site
/// rather than [DailySafetyMeetingRepository.watchForForemanSiteAndDate]
/// (the Foreman-only, foreman-scoped equivalent `ForemanDashboardScreen`
/// uses instead). Once a meeting is found, [MeetingAttendanceRepository
/// .getByWorker] looks up this worker's own attendance record within it —
/// present, absent, or not yet recorded.
class WorkerTodaysMeetingCard extends StatefulWidget {
  const WorkerTodaysMeetingCard({
    super.key,
    required this.meetingRepository,
    required this.attendanceRepositoryFor,
    required this.siteIds,
    required this.workerUid,
  });

  final DailySafetyMeetingRepository meetingRepository;
  final MeetingAttendanceRepository Function(String meetingId)
  attendanceRepositoryFor;
  final List<String> siteIds;
  final String workerUid;

  @override
  State<WorkerTodaysMeetingCard> createState() =>
      _WorkerTodaysMeetingCardState();
}

class _WorkerTodaysMeetingCardState extends State<WorkerTodaysMeetingCard> {
  static String _today() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.siteIds.isEmpty) {
      return const _MeetingMessageCard(
        message: 'You are not yet assigned to a site.',
      );
    }

    final today = _today();
    return LiveStreamBuilder<List<List<DailySafetyMeeting>>>(
      streamKey: today,
      stream: () => _combined(today),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _LoadingCard();
        }
        final meetings = [
          for (final batch in snapshot.data ?? const []) ...batch,
        ];
        if (meetings.isEmpty) {
          return const _MeetingMessageCard(
            message: 'No meeting recorded at your site today.',
          );
        }
        final meeting = meetings.first;
        return FutureBuilder<MeetingAttendance?>(
          future: widget
              .attendanceRepositoryFor(meeting.id)
              .getByWorker(widget.workerUid),
          builder: (context, attendanceSnapshot) {
            final attendance = attendanceSnapshot.data;
            return _MeetingCard(meeting: meeting, attendance: attendance);
          },
        );
      },
    );
  }

  Stream<List<List<DailySafetyMeeting>>> _combined(String today) {
    final streams = [
      for (final siteId in widget.siteIds)
        widget.meetingRepository.watchForSiteAndDate(
          siteId: siteId,
          date: today,
        ),
    ];
    if (streams.length == 1) {
      return streams.single.map((meetings) => [meetings]);
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

class _MeetingMessageCard extends StatelessWidget {
  const _MeetingMessageCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            const Icon(
              Icons.fact_check_outlined,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(message, style: AppTextStyles.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

class _MeetingCard extends StatelessWidget {
  const _MeetingCard({required this.meeting, required this.attendance});

  final DailySafetyMeeting meeting;
  final MeetingAttendance? attendance;

  @override
  Widget build(BuildContext context) {
    final statusLabel = attendance == null
        ? "You haven't been marked present yet."
        : attendance!.status == MeetingAttendanceStatus.present
        ? "You're marked present."
        : 'You were marked absent.';
    final badgeColor = attendance == null
        ? AppColors.textSecondary
        : attendance!.status == MeetingAttendanceStatus.present
        ? AppColors.success
        : AppColors.danger;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    meeting.isCompleted
                        ? 'Meeting completed'
                        : 'Meeting in progress',
                    style: AppTextStyles.titleLarge,
                  ),
                ),
                StatusBadge(label: statusLabel, color: badgeColor),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
