import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/meeting_attendance_service.dart';
import '../domain/crew_readiness.dart';

/// A Foreman's focused crew-readiness summary for today's Daily Safety
/// Meeting at one of their own sites: "N workers · X Ready · Y Need
/// attention", with the specific attendance-gating learning blocking each
/// worker who needs attention. Never the learning catalogue — only learning
/// that would actually stop a worker being marked Present.
///
/// Two server sources, both resolved with the SAME attendance-gating
/// resolver `recordMeetingAttendance` enforces with:
///  - Before the meeting is started ([meetingId] null):
///    [MeetingAttendanceService.getSiteCrewReadiness], scoped to the site's
///    active activities.
///  - Once it exists: [MeetingAttendanceService
///    .getMeetingAttendeeLearningStatus], scoped to the meeting's own
///    activities, unchanged. That callable returns no workers at all when
///    nothing gates attendance for the meeting, so in that case this card
///    says so rather than showing a count it cannot know.
///
/// One callable per load; all per-worker reads happen server-side.
class CrewReadinessCard extends StatefulWidget {
  const CrewReadinessCard({
    super.key,
    required this.organizationId,
    required this.siteId,
    required this.meetingId,
    required this.attendanceService,
    required this.workerNames,
  });

  final String organizationId;
  final String siteId;

  /// Today's meeting at [siteId], or null when it has not been started.
  final String? meetingId;
  final MeetingAttendanceService attendanceService;

  /// Display names by uid; a uid missing here is shown as-is.
  final Future<Map<String, String>> workerNames;

  @override
  State<CrewReadinessCard> createState() => _CrewReadinessCardState();
}

class _CrewReadinessCardState extends State<CrewReadinessCard> {
  late Future<CrewReadiness> _future = _load();

  Future<CrewReadiness> _load() async {
    final meetingId = widget.meetingId;
    if (meetingId == null) {
      return widget.attendanceService.getSiteCrewReadiness(
        organizationId: widget.organizationId,
        siteId: widget.siteId,
      );
    }
    final outstanding = await widget.attendanceService
        .getMeetingAttendeeLearningStatus(
          organizationId: widget.organizationId,
          meetingId: meetingId,
        );
    return CrewReadiness(outstandingByWorker: outstanding);
  }

  void _reload() => setState(() {
    _future = _load();
  });

  @override
  void didUpdateWidget(CrewReadinessCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.meetingId != widget.meetingId ||
        oldWidget.siteId != widget.siteId ||
        oldWidget.organizationId != widget.organizationId) {
      _future = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CrewReadiness>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.error_outline, color: AppColors.danger),
              title: const Text('Could not load crew readiness.'),
              trailing: TextButton(
                onPressed: _reload,
                child: const Text('Retry'),
              ),
            ),
          );
        }
        final readiness = snapshot.data;
        if (readiness == null) {
          return const Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        return FutureBuilder<Map<String, String>>(
          future: widget.workerNames,
          builder: (context, namesSnapshot) =>
              _content(readiness, namesSnapshot.data ?? const {}),
        );
      },
    );
  }

  Widget _content(CrewReadiness readiness, Map<String, String> names) {
    final isPreMeeting = widget.meetingId == null;
    final heading = isPreMeeting
        ? "Before today's meeting"
        : "Today's Safety Meeting";

    final Widget body;
    if (readiness.workerCount == 0) {
      body = Text(
        isPreMeeting
            ? 'No workers are assigned to active activities at this site.'
            : 'No learning blocks attendance for this meeting.',
        style: AppTextStyles.bodyMedium,
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${readiness.workerCount} '
            '${readiness.workerCount == 1 ? 'worker' : 'workers'}',
            style: AppTextStyles.bodyLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              StatusBadge(
                label: '${readiness.readyCount} Ready',
                color: AppColors.success,
              ),
              StatusBadge(
                label: '${readiness.needAttentionCount} Need attention',
                color: readiness.needAttentionCount > 0
                    ? AppColors.danger
                    : AppColors.textSecondary,
              ),
            ],
          ),
          for (final entry in readiness.needingAttention) ...[
            const SizedBox(height: AppSpacing.sm),
            _WorkerNeedingAttention(
              name: names[entry.key] ?? entry.key,
              outstanding: entry.value,
            ),
          ],
        ],
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(heading, style: AppTextStyles.titleLarge)),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (readiness.activityNames.isNotEmpty)
              Text(
                readiness.activityNames.join(', '),
                style: AppTextStyles.bodyMedium,
              ),
            const SizedBox(height: AppSpacing.sm),
            body,
          ],
        ),
      ),
    );
  }
}

class _WorkerNeedingAttention extends StatelessWidget {
  const _WorkerNeedingAttention({
    required this.name,
    required this.outstanding,
  });

  final String name;
  final List<String> outstanding;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.block_outlined, size: 18, color: AppColors.danger),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: AppTextStyles.bodyLarge),
              Text(
                'Must complete: ${outstanding.join(', ')}',
                style: AppTextStyles.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
