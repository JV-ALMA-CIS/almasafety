import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/push_notification_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'desktop_alerts_help.dart';

/// A floating card at the top of the dashboard asking to turn on
/// notifications — safety notifications must reach people even when the
/// app is closed, like a messaging app. Never blocks the dashboard.
///
/// - Shown only while this device does not have notifications allowed.
/// - "Turn on notifications" brings up the device's own Allow prompt (no app
///   can switch them on without it); the card then disappears.
/// - ✕ closes it for the rest of this session.
/// - Once allowed it never shows again on that device, and the device is
///   quietly kept registered. Still not allowed at the next session? It
///   asks again.
/// - Blocked: a short how-to instead; an iPhone browser: the Home Screen
///   tip (notifications only work from the Home Screen app there).
/// - On a computer, once allowed: "Get alerts on this computer" — how to
///   make pop-ups arrive like Outlook's ([showDesktopAlertsHelp]). "Got it"
///   or "Show me how" hides it on that computer for good; ✕ for the
///   session. The same how-to stays in Settings → Notifications.
class NotificationPrompt extends StatefulWidget {
  const NotificationPrompt({
    super.key,
    required this.child,
    this.service,
    this.isIosBrowser,
    this.isDesktop,
  });

  final Widget child;

  /// Injected in tests.
  final PushNotificationService? service;
  final bool? isIosBrowser;

  /// Running in a browser on a computer — injected in tests.
  final bool? isDesktop;

  /// Saved on this device once the computer how-to has been seen.
  static const desktopTipSeenKey = 'desktop_alerts_tip_seen';

  /// Closed (or answered) in this session — kept across visits to the
  /// dashboard until the app is reloaded.
  static bool closedThisSession = false;

  @override
  State<NotificationPrompt> createState() => _NotificationPromptState();
}

class _NotificationPromptState extends State<NotificationPrompt> {
  late final PushNotificationService _service =
      widget.service ?? PushNotificationService();
  PushPermission? _permission;

  /// Whether this computer has already seen the how-to (null: not loaded).
  bool? _desktopTipSeen;

  bool get _isDesktop => widget.isDesktop ?? isDesktopBrowser;

  bool get _isIosBrowser =>
      widget.isIosBrowser ??
      (kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _service.permission().then((permission) {
      if (!mounted) return;
      setState(() => _permission = permission);
      if (permission == PushPermission.allowed) _service.registerIfAllowed();
    });
    if (_isDesktop) _loadDesktopTipSeen();
  }

  Future<void> _loadDesktopTipSeen() async {
    var seen = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      seen = preferences.getBool(NotificationPrompt.desktopTipSeenKey) ?? false;
    } on Object {
      // Cannot remember it here — better not to nag on every visit.
    }
    if (mounted) setState(() => _desktopTipSeen = seen);
  }

  /// The how-to was seen ("Got it" / "Show me how") — not shown again on
  /// this computer.
  Future<void> _desktopTipDone({required bool showHow}) async {
    setState(() => _desktopTipSeen = true);
    if (showHow) unawaited(showDesktopAlertsHelp(context));
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(NotificationPrompt.desktopTipSeenKey, true);
    } on Object {
      // Not remembered — it may show once more next time.
    }
  }

  /// The computer how-to is what the card shows now.
  bool get _showingDesktopTip =>
      _permission == PushPermission.allowed &&
      _isDesktop &&
      _desktopTipSeen == false;

  /// The card goes away at once and the device's Allow prompt opens
  /// straight away. Only "blocked" brings it back, with the how-to.
  Future<void> _turnOn() async {
    setState(() => NotificationPrompt.closedThisSession = true);
    final result = await _service.enable();
    if (!mounted) return;
    setState(() {
      _permission = result;
      if (result == PushPermission.blocked) {
        NotificationPrompt.closedThisSession = false;
      }
    });
  }

  void _close() => setState(() => NotificationPrompt.closedThisSession = true);

  bool get _visible {
    if (NotificationPrompt.closedThisSession) return false;
    return switch (_permission) {
      null => false,
      PushPermission.allowed => _showingDesktopTip,
      PushPermission.unsupported => _isIosBrowser,
      PushPermission.notAsked || PushPermission.blocked => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        Positioned(
          top: AppSpacing.sm,
          left: AppSpacing.sm,
          right: AppSpacing.sm,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: AnimatedSlide(
                offset: visible ? Offset.zero : const Offset(0, -1.5),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: visible
                      ? _showingDesktopTip
                            ? _DesktopTipCard(
                                onShowHow: () => _desktopTipDone(showHow: true),
                                onGotIt: () => _desktopTipDone(showHow: false),
                                onClose: _close,
                              )
                            : _PromptCard(
                                permission: _permission!,
                                onTurnOn: _turnOn,
                                onClose: _close,
                              )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.permission,
    required this.onTurnOn,
    required this.onClose,
  });

  final PushPermission permission;
  final VoidCallback onTurnOn;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    const color = AppColors.primaryBright;
    final text = switch (permission) {
      PushPermission.blocked =>
        'Notifications are blocked on this device. Allow them for this app '
            'in your browser or phone settings so safety alerts reach you.',
      PushPermission.unsupported =>
        'To get notifications on this iPhone, add the app to your Home '
            'Screen: tap Share, then Add to Home Screen, and open it from '
            'there.',
      _ =>
        'Turn on notifications so incidents, actions assigned to you and '
            'sign-offs reach you even when the app is closed.',
    };
    return Material(
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(14),
      color: Theme.of(context).colorScheme.surface,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.xs,
          AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.notifications_active, color: color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(text, style: AppTextStyles.bodyMedium),
                  if (permission == PushPermission.notAsked) ...[
                    const SizedBox(height: AppSpacing.xs),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: color,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 40),
                      ),
                      onPressed: onTurnOn,
                      icon: const Icon(Icons.notifications_active, size: 18),
                      label: const Text('Turn on notifications'),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Get alerts on this computer" — a computer that already allows
/// notifications, until the how-to has been seen.
class _DesktopTipCard extends StatelessWidget {
  const _DesktopTipCard({
    required this.onShowHow,
    required this.onGotIt,
    required this.onClose,
  });

  final VoidCallback onShowHow;
  final VoidCallback onGotIt;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    const color = AppColors.primaryBright;
    return Material(
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(14),
      color: Theme.of(context).colorScheme.surface,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.xs,
          AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
        ),
        child: Row(
          children: [
            const Icon(Icons.computer, color: color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Get alerts on this computer',
                    style: AppTextStyles.titleLarge,
                  ),
                  const Text(
                    'Pop-ups like new emails in Outlook, even when you are '
                    'in another program — three quick settings.',
                    style: AppTextStyles.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: color,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 40),
                        ),
                        onPressed: onShowHow,
                        icon: const Icon(Icons.help_outline, size: 18),
                        label: const Text('Show me how'),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 40),
                        ),
                        onPressed: onGotIt,
                        child: const Text('Got it'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}
