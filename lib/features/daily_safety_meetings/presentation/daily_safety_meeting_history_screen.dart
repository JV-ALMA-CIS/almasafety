import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/daily_safety_meeting_repository.dart';
import '../domain/daily_safety_meeting.dart';

/// Step 6: the signed-in foreman's own Daily Safety Meeting history —
/// read-only, most recent first.
///
/// Scoped to the caller's own `foremanId`, matching
/// `MySafetyLearningScreen`'s "own records only" simplicity for a first
/// foreman-facing history view. A broader admin/compliance history view
/// (every foreman's meetings across a site or organization) is out of scope
/// for this foundation.
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
      appBar: AppBar(title: const Text('Meeting History')),
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
          : StreamBuilder<List<DailySafetyMeeting>>(
              stream: _repository.watchHistoryForForeman(foremanId),
              builder: (context, snapshot) {
                final meetings =
                    snapshot.data ?? const <DailySafetyMeeting>[];
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

                return ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    for (final meeting in meetings) ...[
                      _MeetingHistoryCard(meeting: meeting),
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
  const _MeetingHistoryCard({required this.meeting});

  final DailySafetyMeeting meeting;

  @override
  Widget build(BuildContext context) {
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
                  child: Text(meeting.date, style: AppTextStyles.titleLarge),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: (meeting.isCompleted
                            ? AppColors.success
                            : AppColors.textSecondary)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppSpacing.sm),
                  ),
                  child: Text(
                    meeting.status.label,
                    style: AppTextStyles.label.copyWith(
                      color: meeting.isCompleted
                          ? AppColors.success
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${meeting.activityIds.length} activities, '
              '${meeting.meetingPointIds.length} meeting points, '
              '${meeting.concerns.length} concerns',
              style: AppTextStyles.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
