import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/push_notification_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// "Get notifications on this device" — asks to turn on push notifications
/// until the person decides. Shows nothing once they are allowed (and then
/// quietly keeps this device registered), a short how-to when they were
/// blocked, and the Home Screen tip on an iPhone browser that cannot
/// receive them yet.
class PushOptInCard extends StatefulWidget {
  const PushOptInCard({super.key, this.service, this.isIosBrowser});

  /// Injected in tests.
  final PushNotificationService? service;
  final bool? isIosBrowser;

  @override
  State<PushOptInCard> createState() => _PushOptInCardState();
}

class _PushOptInCardState extends State<PushOptInCard> {
  late final PushNotificationService _service =
      widget.service ?? PushNotificationService();
  PushPermission? _permission;
  bool _busy = false;

  bool get _isIosBrowser =>
      widget.isIosBrowser ??
      (kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _service.permission().then((value) {
      if (!mounted) return;
      setState(() => _permission = value);
      if (value == PushPermission.allowed) _service.registerIfAllowed();
    });
  }

  Future<void> _enable() async {
    setState(() => _busy = true);
    final result = await _service.enable();
    if (mounted) {
      setState(() {
        _permission = result;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final permission = _permission;
    final String text;
    Widget? action;
    switch (permission) {
      case null:
      case PushPermission.allowed:
        return const SizedBox.shrink();
      case PushPermission.unsupported:
        if (!_isIosBrowser) return const SizedBox.shrink();
        text =
            'To get notifications on this iPhone, add the app to your Home '
            'Screen (Share → Add to Home Screen) and open it from there.';
      case PushPermission.blocked:
        text =
            'Notifications are blocked on this device. To get them, allow '
            'notifications for this app in your browser or phone settings.';
      case PushPermission.notAsked:
        text =
            'Get safety notifications on this device — incidents, actions '
            'assigned to you, sign-offs — even when the app is closed.';
        action = FilledButton.icon(
          onPressed: _busy ? null : _enable,
          icon: const Icon(Icons.notifications_active),
          label: const Text('Turn on notifications'),
        );
    }
    const color = AppColors.primaryBright;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm + 4),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.08),
          Theme.of(context).colorScheme.surface,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.notifications_outlined, color: color),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(text, style: AppTextStyles.bodyMedium)),
            ],
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(alignment: Alignment.centerLeft, child: action),
          ],
        ],
      ),
    );
  }
}
