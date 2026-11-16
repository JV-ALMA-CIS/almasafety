import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../data/daily_safety_meeting_repository.dart';
import '../data/meeting_concern_repository.dart';
import '../domain/meeting_concern.dart';
import '../domain/meeting_concern_status.dart';

/// How many of the Foreman's earlier meetings at the site are searched for
/// concerns still open — enough to cover the last couple of weeks of
/// working days without reading every meeting ever held.
const earlierMeetingsSearched = 10;

/// Read-only reminders for the morning briefing: concerns still open from
/// earlier meetings at this site, and corrective actions at this site not
/// yet completed (PROJECT_CONTEXT.md §6.2 "previous safety concerns" and
/// "open corrective actions").
///
/// Concerns come from the Foreman's OWN earlier meetings at the site — the
/// only meetings `firestore.rules` lets a Foreman read; another Foreman's
/// concerns at a shared site are not shown. Corrective actions cover the
/// whole site (any organization member may read them). Nothing here can be
/// changed; it is a prompt for what to raise with the crew.
class EarlierOpenItemsPanel extends StatefulWidget {
  const EarlierOpenItemsPanel({
    super.key,
    required this.siteId,
    required this.foremanId,
    required this.meetingRepository,
    required this.concernRepositoryFor,
    required this.correctiveActionRepository,
    this.currentMeetingId,
  });

  final String siteId;
  final String foremanId;

  /// Today's meeting, left out of "earlier" (null before it is started).
  final String? currentMeetingId;
  final DailySafetyMeetingRepository meetingRepository;
  final MeetingConcernRepository Function(String meetingId)
  concernRepositoryFor;
  final CorrectiveActionRepository correctiveActionRepository;

  @override
  State<EarlierOpenItemsPanel> createState() => _EarlierOpenItemsPanelState();
}

/// One open concern with the date of the meeting it was raised at.
typedef _DatedConcern = ({String date, MeetingConcern concern});

class _EarlierOpenItemsPanelState extends State<EarlierOpenItemsPanel> {
  Future<List<_DatedConcern>>? _concerns;
  String? _concernsKey;
  bool _expanded = false;

  Future<List<_DatedConcern>> _openConcerns() {
    final key = '${widget.siteId}/${widget.currentMeetingId}';
    if (_concernsKey == key && _concerns != null) return _concerns!;
    _concernsKey = key;
    return _concerns = () async {
      final meetings = await widget.meetingRepository
          .watchHistoryForForeman(widget.foremanId)
          .first;
      final earlier = [
        for (final meeting in meetings)
          if (meeting.siteId == widget.siteId &&
              meeting.id != widget.currentMeetingId)
            meeting,
      ].take(earlierMeetingsSearched);
      final lists = await Future.wait(
        earlier.map(
          (meeting) => widget
              .concernRepositoryFor(meeting.id)
              .watchAll()
              .first
              .then(
                (concerns) => [
                  for (final concern in concerns)
                    if (concern.status == MeetingConcernStatus.open)
                      (date: meeting.date, concern: concern),
                ],
              ),
        ),
      );
      return [for (final list in lists) ...list];
    }().catchError((Object _) => const <_DatedConcern>[]);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_DatedConcern>>(
      future: _openConcerns(),
      builder: (context, concernSnapshot) {
        final concerns = concernSnapshot.data ?? const <_DatedConcern>[];
        return LiveStreamBuilder<List<CorrectiveAction>>(
          streamKey: (widget.correctiveActionRepository, widget.siteId),
          stream: () =>
              widget.correctiveActionRepository.watchOpenForSite(widget.siteId),
          builder: (context, actionSnapshot) {
            final actions = actionSnapshot.data ?? const <CorrectiveAction>[];
            final total = concerns.length + actions.length;
            final loading =
                concernSnapshot.connectionState != ConnectionState.done;
            return Card(
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: AppColors.warning.withValues(alpha: 0.5),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: total == 0
                          ? null
                          : () => setState(() => _expanded = !_expanded),
                      child: FeatureSectionTitle(
                        title: loading
                            ? 'Still open from earlier…'
                            : 'Still open from earlier ($total)',
                        icon: Icons.history_toggle_off,
                        color: AppColors.warning,
                        trailing: total == 0
                            ? null
                            : Icon(
                                _expanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                              ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    if (!loading && total == 0)
                      const Text(
                        'Nothing open from earlier meetings at this site.',
                        style: AppTextStyles.bodyMedium,
                      )
                    else if (!_expanded)
                      Text(
                        '${concerns.length} open '
                        '${concerns.length == 1 ? 'concern' : 'concerns'} · '
                        '${actions.length} corrective '
                        '${actions.length == 1 ? 'action' : 'actions'} not '
                        'yet done. Tap to see them.',
                        style: AppTextStyles.bodyMedium,
                      )
                    else ...[
                      for (final item in concerns)
                        _Row(
                          icon: Icons.report_problem_outlined,
                          color: AppColors.hazards,
                          text:
                              '${item.concern.category.label}: '
                              '${item.concern.description}',
                          detail: 'Raised at your meeting on ${item.date}',
                        ),
                      for (final action in actions)
                        _Row(
                          icon: Icons.build_circle_outlined,
                          color: AppColors.correctiveActions,
                          text: action.title,
                          detail:
                              '${action.status.label} · due '
                              '${_day(action.dueDate)}'
                              '${action.assignedToName == null ? '' : ' · ${action.assignedToName}'}',
                        ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static String _day(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.text,
    required this.detail,
  });

  final IconData icon;
  final Color color;
  final String text;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: AppTextStyles.bodyMedium),
                Text(
                  detail,
                  style: AppTextStyles.label.copyWith(
                    color: AppColors.textSecondary,
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
