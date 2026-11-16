import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../data/meeting_concern_repository.dart';
import '../domain/daily_safety_meeting.dart';

/// Builds with how many concerns [meeting] has.
///
/// Uses the server-kept [DailySafetyMeeting.concernCount] when the meeting
/// has one. A meeting started before that count existed (and not touched
/// since) has none, so its `concerns` subcollection is counted live
/// instead — never the legacy `concerns` text list, which is no longer
/// written and would always read 0. [builder] gets null while that count
/// is loading.
class MeetingConcernCountBuilder extends StatelessWidget {
  const MeetingConcernCountBuilder({
    super.key,
    required this.meeting,
    required this.concernRepositoryFor,
    required this.builder,
  });

  final DailySafetyMeeting meeting;
  final MeetingConcernRepository Function(String meetingId)
  concernRepositoryFor;
  final Widget Function(BuildContext context, int? count) builder;

  @override
  Widget build(BuildContext context) {
    final stored = meeting.concernCount;
    if (stored != null) return builder(context, stored);
    return LiveStreamBuilder<int>(
      streamKey: meeting.id,
      stream: () => concernRepositoryFor(
        meeting.id,
      ).watchAll().map((concerns) => concerns.length),
      builder: (context, snapshot) => builder(context, snapshot.data),
    );
  }
}

/// "3 concerns" / "1 concern", or "… concerns" while still counting.
String concernCountLabel(int? count) {
  if (count == null) return '… concerns';
  return '$count ${count == 1 ? 'concern' : 'concerns'}';
}
