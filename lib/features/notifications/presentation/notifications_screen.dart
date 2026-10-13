import 'package:flutter/material.dart';
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

  Future<void> _markRead(
    String organizationId,
    AppNotification notification,
  ) async {
    if (notification.isRead) return;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _service.markNotificationRead(
        organizationId: organizationId,
        notificationId: notification.id,
      );
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _markAllRead(String organizationId) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _service.markAllNotificationsRead(organizationId: organizationId);
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
        final unreadCount = notifications.where((n) => !n.isRead).length;

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
                            : () => _markAllRead(organizationId),
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
              for (final notification in notifications) ...[
                _NotificationCard(
                  notification: notification,
                  isSaving: _isSaving,
                  onTap: () => _markRead(organizationId, notification),
                ),
                const SizedBox(height: AppSpacing.sm),
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
    required this.isSaving,
    required this.onTap,
  });

  final AppNotification notification;
  final bool isSaving;
  final VoidCallback onTap;

  IconData get _typeIcon => switch (notification.type) {
    AppNotificationType.safetyAlert => Icons.campaign,
    AppNotificationType.correctiveAction => Icons.build_circle,
    AppNotificationType.safetyMeeting => Icons.groups,
    AppNotificationType.safetyLearning => Icons.school,
    AppNotificationType.system => Icons.info,
  };

  /// Each notification type in its feature's own color.
  Color get _typeColor => switch (notification.type) {
    AppNotificationType.safetyAlert => AppColors.safetyAlerts,
    AppNotificationType.correctiveAction => AppColors.correctiveActions,
    AppNotificationType.safetyMeeting => AppColors.meetings,
    AppNotificationType.safetyLearning => AppColors.learning,
    AppNotificationType.system => AppColors.primaryBright,
  };

  @override
  Widget build(BuildContext context) {
    final isUnread = !notification.isRead;
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
        onTap: isUnread && !isSaving ? onTap : null,
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
                          Text(
                            '${notification.type.label} · '
                            '${_formatDate(notification.createdAt)}',
                            style: AppTextStyles.label,
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

String _formatDate(DateTime? date) {
  if (date == null) return 'recently';
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
