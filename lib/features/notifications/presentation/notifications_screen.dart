import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../routing/app_routes.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/notification_repository.dart';
import '../data/notification_service.dart';
import '../domain/app_notification.dart';
import '../domain/notification_type.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/status_badge.dart';

/// The signed-in user's own notification list.
///
/// **User-specific, not organization-wide.** Every notification shown here
/// belongs to the caller alone — `firestore.rules` independently confirms
/// `recipientUid == request.auth.uid` for every document this screen reads,
/// so there is no client-side filtering step that actually matters for
/// isolation; [NotificationRepository.watchForRecipient] narrows the query
/// for efficiency, not for security.
///
/// Mobile-friendly by construction: a single scrolling list, large tap
/// targets on each row (mark-as-read is the whole row, not a small icon),
/// and one "Mark all read" action rather than a per-row menu.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, this.repository, this.service});

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final NotificationRepository? repository;
  final NotificationService? service;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late final NotificationService _service =
      widget.service ?? NotificationService();

  NotificationRepository? _repository;
  String? _errorMessage;
  bool _isSaving = false;

  /// Marked read here but not yet confirmed by the server — shown as read
  /// straight away so tapping a notification never waits on the network.
  final Set<String> _readLocally = {};

  NotificationRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.repository ??
        NotificationRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _repository = created;
    return created;
  }

  /// Marks [notification] read (if it isn't) and opens the page it is
  /// about, when there is one.
  /// Opens the page [notification] is about at once, and marks it read in
  /// the background — the server call never holds up the tap.
  void _open(String organizationId, AppNotification notification) {
    _markRead(organizationId, notification);
    final route = routeForNotification(notification);
    if (route != null) context.go(route);
  }

  /// Shows [notification] as read immediately and tells the server in the
  /// background; if that fails it shows as unread again, with the error.
  Future<void> _markRead(
    String organizationId,
    AppNotification notification,
  ) async {
    if (notification.isRead || _readLocally.contains(notification.id)) return;
    setState(() {
      _readLocally.add(notification.id);
      _errorMessage = null;
    });
    try {
      await _service.markNotificationRead(
        organizationId: organizationId,
        notificationId: notification.id,
      );
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() {
        _readLocally.remove(notification.id);
        _errorMessage = e.message;
      });
    }
  }

  /// Shows every one of [unread] as read at once and tells the server in
  /// the background; if that fails they show as unread again, with the
  /// error.
  Future<void> _markAllRead(
    String organizationId,
    List<AppNotification> unread,
  ) async {
    final ids = unread.map((n) => n.id).toSet();
    setState(() {
      _isSaving = true;
      _errorMessage = null;
      _readLocally.addAll(ids);
    });
    try {
      await _service.markAllNotificationsRead(organizationId: organizationId);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() {
        _readLocally.removeAll(ids);
        _errorMessage = e.message;
      });
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Only unread notifications are listed.
  bool _unreadOnly = false;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final organizationId = sessionController.activeOrganizationId;
    final uid = profile?.uid;

    if (organizationId == null || uid == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Notifications are available once your account has an '
            'organization.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return LiveStreamBuilder<List<AppNotification>>(
      streamKey: (_repositoryFor(organizationId), uid),
      stream: () => _repositoryFor(organizationId).watchForRecipient(uid),
      builder: (context, snapshot) {
        final notifications = snapshot.data ?? const <AppNotification>[];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        bool isRead(AppNotification n) =>
            n.isRead || _readLocally.contains(n.id);
        final unread = notifications.where((n) => !isRead(n)).toList();
        final unreadCount = unread.length;
        final shown = _unreadOnly ? unread : notifications;
        final now = DateTime.now();
        final days = groupNotificationsByDay(shown, now);

        return Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              FeatureHeader(
                title: 'Notifications',
                subtitle: unreadCount > 0
                    ? '$unreadCount unread'
                    : 'All caught up',
                icon: unreadCount > 0
                    ? Icons.notifications_active
                    : Icons.notifications_none,
                color: AppColors.primaryBright,
                footer: unreadCount == 0
                    ? null
                    : ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.primaryBright,
                          minimumSize: const Size(0, AppSpacing.minTouchTarget),
                        ),
                        onPressed: _isSaving
                            ? null
                            : () => _markAllRead(organizationId, unread),
                        icon: const Icon(Icons.done_all),
                        label: const Text('Mark all read'),
                      ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (_errorMessage != null) ...[
                AuthErrorBanner(message: _errorMessage!),
                const SizedBox(height: AppSpacing.md),
              ],
              if (isLoading && notifications.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (!isLoading && notifications.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Column(
                    children: [
                      Icon(
                        Icons.notifications_none_outlined,
                        size: 48,
                        color: AppColors.textSecondary,
                      ),
                      SizedBox(height: AppSpacing.sm),
                      Text(
                        'No notifications yet.',
                        style: AppTextStyles.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              if (notifications.isNotEmpty) ...[
                ColorChoiceChips<bool>(
                  choices: [
                    ColorChoice(
                      value: false,
                      label: 'All (${notifications.length})',
                      color: AppColors.primaryBright,
                      icon: Icons.inbox,
                    ),
                    ColorChoice(
                      value: true,
                      label: 'Unread ($unreadCount)',
                      color: AppColors.safetyAlerts,
                      icon: Icons.mark_email_unread,
                    ),
                  ],
                  selected: _unreadOnly,
                  onSelected: (value) => setState(() => _unreadOnly = value),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              if (_unreadOnly && notifications.isNotEmpty && unread.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Text(
                    'No unread notifications — you are all caught up.',
                    style: AppTextStyles.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final day in days) ...[
                _DayHeader(
                  label: day.label,
                  unread: day.notifications.where((n) => !isRead(n)).length,
                ),
                for (final notification in day.notifications) ...[
                  _NotificationCard(
                    notification: notification,
                    isRead: isRead(notification),
                    isSaving: _isSaving,
                    onTap: () => _open(organizationId, notification),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.isRead,
    required this.isSaving,
    required this.onTap,
  });

  final AppNotification notification;
  final bool isRead;
  final bool isSaving;
  final VoidCallback onTap;

  IconData get _typeIcon => switch (notification.type) {
    AppNotificationType.safetyAlert => Icons.campaign,
    AppNotificationType.correctiveAction => Icons.build_circle,
    AppNotificationType.safetyMeeting => Icons.groups,
    AppNotificationType.safetyLearning => Icons.school,
    AppNotificationType.hazard => Icons.warning_amber,
    AppNotificationType.incident => Icons.personal_injury,
    AppNotificationType.inspection => Icons.fact_check,
    AppNotificationType.riskAssessment => Icons.assignment_late,
    AppNotificationType.system => Icons.info,
  };

  /// Each notification type in its feature's own color.
  Color get _typeColor => switch (notification.type) {
    AppNotificationType.safetyAlert => AppColors.safetyAlerts,
    AppNotificationType.correctiveAction => AppColors.correctiveActions,
    AppNotificationType.safetyMeeting => AppColors.meetings,
    AppNotificationType.safetyLearning => AppColors.learning,
    AppNotificationType.hazard => AppColors.hazards,
    AppNotificationType.incident => AppColors.stop,
    AppNotificationType.inspection => AppColors.inspections,
    AppNotificationType.riskAssessment => AppColors.riskAssessments,
    AppNotificationType.system => AppColors.primaryBright,
  };

  @override
  Widget build(BuildContext context) {
    final isUnread = !isRead;
    final color = _typeColor;
    final surface = Theme.of(context).colorScheme.surface;

    return Card(
      margin: EdgeInsets.zero,
      color: isUnread
          ? Color.alphaBlend(color.withValues(alpha: 0.09), surface)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: color.withValues(alpha: isUnread ? 0.7 : 0.25),
          width: isUnread ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap:
            isSaving ||
                (!isUnread && routeForNotification(notification) == null)
            ? null
            : onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: AppSpacing.minTouchTarget,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: isUnread
                      ? color
                      : color.withValues(alpha: 0.15),
                  child: Icon(
                    _typeIcon,
                    size: 20,
                    color: isUnread ? AppColors.onColor(color) : color,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              notification.title,
                              style: isUnread
                                  ? AppTextStyles.titleLarge
                                  : AppTextStyles.bodyLarge,
                            ),
                          ),
                          if (isUnread) StatusBadge(label: 'New', color: color),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        notification.message,
                        style: AppTextStyles.bodyMedium,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        children: [
                          Icon(Icons.schedule, size: 14, color: color),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${notification.type.label} · '
                              '${notificationTime(notification.createdAt)}',
                              style: AppTextStyles.label,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A day's heading in the list — "Today", with how many are still unread.
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.unread});

  final String label;
  final int unread;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
      child: Row(
        children: [
          Text(
            label,
            style: AppTextStyles.titleLarge.copyWith(
              color: AppColors.readable(
                AppColors.primaryBright,
                Theme.of(context).brightness,
              ),
            ),
          ),
          if (unread > 0) ...[
            const SizedBox(width: AppSpacing.sm),
            StatusBadge(label: '$unread new', color: AppColors.safetyAlerts),
          ],
          const SizedBox(width: AppSpacing.sm),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// One day's notifications, newest first, under its [label].
class NotificationDay {
  const NotificationDay(this.label, this.notifications);

  final String label;
  final List<AppNotification> notifications;
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// How the day of [date] reads from [now], the way a messaging app labels
/// its chats: "Today", "Yesterday", the weekday within the last week, then
/// "Mon 3 Nov" (with the year when it is not this year). A notification
/// the server has not stamped yet ([date] null) is today's.
String notificationDayLabel(DateTime? date, DateTime now) {
  if (date == null) return 'Today';
  final local = date.toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final daysAgo = (today.difference(day).inHours / 24).round();
  if (daysAgo <= 0) return 'Today';
  if (daysAgo == 1) return 'Yesterday';
  if (daysAgo < 7) return _weekdays[local.weekday - 1];
  final short =
      '${_weekdays[local.weekday - 1].substring(0, 3)} '
      '${local.day} ${_months[local.month - 1]}';
  return local.year == now.year ? short : '$short ${local.year}';
}

/// "14:05" for [date], local time; "now" when not stamped yet.
String notificationTime(DateTime? date) {
  if (date == null) return 'now';
  final local = date.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// [notifications] (newest first) split into days, keeping their order.
List<NotificationDay> groupNotificationsByDay(
  List<AppNotification> notifications,
  DateTime now,
) {
  final days = <NotificationDay>[];
  for (final notification in notifications) {
    final label = notificationDayLabel(notification.createdAt, now);
    if (days.isEmpty || days.last.label != label) {
      days.add(NotificationDay(label, [notification]));
    } else {
      days.last.notifications.add(notification);
    }
  }
  return days;
}

/// The page a notification is about, from what it relates to; null when
/// it relates to nothing that has a page.
String? routeForNotification(AppNotification notification) =>
    switch (notification.relatedEntityType) {
      'correctiveAction' => AppRoutes.correctiveActions,
      'hazard' => AppRoutes.hazards,
      'incident' => AppRoutes.incidents,
      'inspection' => AppRoutes.inspections,
      'riskAssessment' => AppRoutes.riskAssessments,
      'dailySafetyMeeting' => AppRoutes.dailySafetyMeetings,
      'safetyAlert' => AppRoutes.safetyAlerts,
      _ => null,
    };
