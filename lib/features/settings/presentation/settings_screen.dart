import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/offline/outbox.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/push_notification_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/services/theme_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/choice_list.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../authentication/domain/app_role.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';

/// Everything about the signed-in person and this device in one place,
/// reached from the menu ("Settings") on every screen size — the top bar
/// carries only notifications:
///
/// - Account: who they are, their role and work (worker type, trade,
///   assigned sites), and Change password (Firebase emails a reset link).
/// - Appearance: light/dark and text size, for this device.
/// - Notifications on this device.
/// - Saved on this phone: entries waiting for signal, with Send now.
/// - Help & about, then Sign out.
///
/// Stores nothing new: appearance and text size are [ThemeController]'s
/// per-device choices, notifications use [PushNotificationService], saved
/// entries are the [Outbox], and signing out is [SessionController.signOut].
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    this.pushService,
    this.isIosBrowser,
    this.authService,
    this.outbox,
    this.siteRepository,
  });

  /// Injected in tests.
  final PushNotificationService? pushService;
  final bool? isIosBrowser;
  final AuthService? authService;
  final Outbox? outbox;
  final SiteRepository? siteRepository;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final profile = session.profile;
    final membership = session.activeMembership;
    final role = (profile?.isPlatformAdministrator ?? false)
        ? AppRole.admin
        : membership?.role ?? profile?.platformRole;
    final organizationId = session.activeOrganizationId;
    final siteIds = membership?.siteIds ?? const <String>[];
    final email = profile?.email ?? '';
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        FeatureHeader(
          title: 'Settings',
          subtitle: 'Your account, how the app looks, and this device.',
          icon: Icons.settings,
          color: AppColors.primaryBright,
        ),
        const SizedBox(height: AppSpacing.lg),
        const _SectionTitle('Account'),
        _Group(
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(
                (profile?.name.trim().isNotEmpty ?? false)
                    ? profile!.name
                    : 'Unnamed account',
              ),
              subtitle: Text(email),
            ),
            if (profile?.phone?.trim().isNotEmpty ?? false)
              ListTile(
                leading: const Icon(Icons.phone_outlined),
                title: Text(profile!.phone!),
              ),
            if (role != null)
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(role.label),
                subtitle: Text(
                  [
                    ?membership?.workerType?.label,
                    if (membership?.trade?.trim().isNotEmpty ?? false)
                      membership!.trade!,
                    'JV ALMA CIS',
                  ].join(' · '),
                ),
              ),
            if (organizationId != null && siteIds.isNotEmpty)
              _SitesTile(
                repository:
                    siteRepository ??
                    SiteRepository(
                      firestoreService: FirestoreService(),
                      organizationId: organizationId,
                    ),
                siteIds: siteIds,
              ),
            const Divider(height: 1),
            _ChangePasswordTile(
              email: email,
              authService: authService ?? context.read<AuthService>(),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const _SectionTitle('Appearance'),
        const _AppearanceChoice(),
        const SizedBox(height: AppSpacing.md),
        Text('Text size', style: AppTextStyles.label),
        const SizedBox(height: AppSpacing.xs),
        const _TextSizeChoice(),
        const SizedBox(height: AppSpacing.lg),
        const _SectionTitle('Notifications'),
        _NotificationsTile(
          service: pushService ?? PushNotificationService(),
          isIosBrowser:
              isIosBrowser ??
              (kIsWeb && defaultTargetPlatform == TargetPlatform.iOS),
        ),
        const SizedBox(height: AppSpacing.lg),
        const _SectionTitle('Saved on this phone'),
        _OutboxTile(outbox: outbox ?? Outbox.instance),
        const SizedBox(height: AppSpacing.lg),
        const _SectionTitle('Help & about'),
        const _Group(
          children: [
            ListTile(
              leading: Icon(Icons.help_outline),
              title: Text('Need help with your account or access?'),
              subtitle: Text(
                'Ask your Site Manager or Foreman — they can approve '
                'accounts, assign sites and reset what you can see.',
              ),
            ),
            ListTile(
              leading: Icon(Icons.health_and_safety_outlined),
              title: Text(AppConstants.appName),
              subtitle: Text('Safety management for JV ALMA CIS'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.danger,
            side: const BorderSide(color: AppColors.danger),
            minimumSize: const Size.fromHeight(AppSpacing.minTouchTarget),
          ),
          onPressed: () => _confirmSignOut(context, session),
          icon: const Icon(Icons.logout_outlined),
          label: const Text('Sign Out'),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  static Future<void> _confirmSignOut(
    BuildContext context,
    SessionController session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'You will need your email and password to sign in again. Entries '
          'saved on this phone and not yet sent stay on this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed == true) await session.signOut();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(text, style: AppTextStyles.titleLarge),
    );
  }
}

/// A card of settings rows.
class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// The sites the person is assigned to, by name.
class _SitesTile extends StatelessWidget {
  const _SitesTile({required this.repository, required this.siteIds});

  final SiteRepository repository;
  final List<String> siteIds;

  @override
  Widget build(BuildContext context) {
    return LiveStreamBuilder<List<Site>>(
      streamKey: siteIds.join(','),
      stream: () => repository.watchByIds(siteIds),
      builder: (context, snapshot) {
        final sites = snapshot.data;
        final String text;
        if (sites != null) {
          text = sites.isEmpty
              ? 'No sites'
              : sites.map((site) => site.name).join(', ');
        } else if (snapshot.hasError) {
          text = 'Couldn\'t load your sites.';
        } else {
          text = 'Loading…';
        }
        return ListTile(
          leading: const Icon(Icons.location_on_outlined),
          title: Text(siteIds.length == 1 ? 'Your site' : 'Your sites'),
          subtitle: Text(text),
        );
      },
    );
  }
}

/// Change password: Firebase emails the person a link to choose a new one.
class _ChangePasswordTile extends StatefulWidget {
  const _ChangePasswordTile({required this.email, required this.authService});

  final String email;
  final AuthService authService;

  @override
  State<_ChangePasswordTile> createState() => _ChangePasswordTileState();
}

class _ChangePasswordTileState extends State<_ChangePasswordTile> {
  bool _sending = false;
  String? _sentTo;
  String? _error;

  Future<void> _send() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Change password?'),
        content: Text(
          'We\'ll email a link to ${widget.email}. Open it to choose a new '
          'password — your current one keeps working until you do.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Send link'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.authService.sendPasswordResetEmail(widget.email);
      if (mounted) setState(() => _sentTo = widget.email);
    } on AppException catch (e) {
      debugPrint('Settings: could not send the password email: ${e.message}');
      if (mounted) setState(() => _error = e.message);
    } on Object catch (e) {
      debugPrint('Settings: could not send the password email: $e');
      if (mounted) {
        setState(() => _error = 'Could not send the email. Try again.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sentTo = _sentTo;
    return ListTile(
      leading: const Icon(Icons.lock_reset_outlined),
      title: const Text('Change password'),
      subtitle: Text(
        _error ??
            (sentTo != null
                ? 'Link sent to $sentTo — check your inbox (and spam).'
                : 'We\'ll email you a link to choose a new one.'),
        style: _error != null
            ? AppTextStyles.bodyMedium.copyWith(color: AppColors.danger)
            : null,
      ),
      trailing: _sending
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
      enabled: !_sending && widget.email.isNotEmpty,
      onTap: _send,
    );
  }
}

/// System / Light / Dark for this device — see [ThemeController].
class _AppearanceChoice extends StatelessWidget {
  const _AppearanceChoice();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    return ChoiceList<ThemeMode>(
      allowDeselect: false,
      selected: controller.mode,
      onChanged: (mode) {
        if (mode != null) controller.setMode(mode);
      },
      items: const [
        ChoiceItem(
          value: ThemeMode.system,
          title: 'Same as this device',
          icon: Icons.brightness_auto_outlined,
          color: AppColors.primaryBright,
        ),
        ChoiceItem(
          value: ThemeMode.light,
          title: 'Light',
          icon: Icons.light_mode_outlined,
          color: AppColors.secondary,
        ),
        ChoiceItem(
          value: ThemeMode.dark,
          title: 'Dark',
          icon: Icons.dark_mode_outlined,
          color: AppColors.administration,
        ),
      ],
    );
  }
}

/// Normal / Large text for this device — see [AppTextSize].
class _TextSizeChoice extends StatelessWidget {
  const _TextSizeChoice();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    return ChoiceList<AppTextSize>(
      allowDeselect: false,
      selected: controller.textSize,
      onChanged: (size) {
        if (size != null) controller.setTextSize(size);
      },
      items: const [
        ChoiceItem(
          value: AppTextSize.normal,
          title: 'Normal',
          icon: Icons.text_fields,
          color: AppColors.primaryBright,
        ),
        ChoiceItem(
          value: AppTextSize.large,
          title: 'Large',
          subtitle: 'Easier to read outdoors',
          icon: Icons.format_size,
          color: AppColors.people,
        ),
      ],
    );
  }
}

/// Whether this device gets notifications, with a way to turn them on.
class _NotificationsTile extends StatefulWidget {
  const _NotificationsTile({required this.service, required this.isIosBrowser});

  final PushNotificationService service;
  final bool isIosBrowser;

  @override
  State<_NotificationsTile> createState() => _NotificationsTileState();
}

class _NotificationsTileState extends State<_NotificationsTile> {
  PushPermission? _permission;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    widget.service.permission().then((permission) {
      if (mounted) setState(() => _permission = permission);
    });
  }

  Future<void> _turnOn() async {
    setState(() => _asking = true);
    final permission = await widget.service.enable();
    if (mounted) {
      setState(() {
        _permission = permission;
        _asking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final permission = _permission;
    final (IconData icon, String title, String? detail) = switch (permission) {
      null => (Icons.notifications_none, 'Checking…', null),
      PushPermission.allowed => (
        Icons.notifications_active,
        'On for this device',
        null,
      ),
      PushPermission.notAsked => (
        Icons.notifications_off_outlined,
        'Off for this device',
        'Turn them on so safety alerts reach you even when the app is closed.',
      ),
      PushPermission.blocked => (
        Icons.notifications_off_outlined,
        'Blocked for this device',
        'Allow notifications for this site in your browser or phone '
            'settings, then come back.',
      ),
      PushPermission.unsupported => (
        Icons.notifications_off_outlined,
        'Not available here',
        widget.isIosBrowser
            ? 'On an iPhone, add ${AppConstants.appName} to your Home Screen '
                  '(Share → Add to Home Screen) and open it from there.'
            : 'This browser can\'t show notifications.',
      ),
    };
    return _Group(
      children: [
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: detail == null ? null : Text(detail),
        ),
        if (permission == PushPermission.notAsked)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(AppSpacing.minTouchTarget),
              ),
              onPressed: _asking ? null : _turnOn,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Turn on notifications'),
            ),
          ),
      ],
    );
  }
}

/// Entries saved with no signal (see [Outbox]): how many are waiting or
/// failed, and Send now.
class _OutboxTile extends StatelessWidget {
  const _OutboxTile({required this.outbox});

  final Outbox outbox;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: outbox,
      builder: (context, _) {
        final waiting = outbox.waiting.length;
        final failed = outbox.failed.length;
        final online = outbox.isOnline;
        String count(int n) => n == 1 ? '1 entry' : '$n entries';
        final String title;
        final String? detail;
        if (waiting == 0 && failed == 0) {
          title = 'Everything is sent';
          detail =
              'Reports made with no signal are kept here until they '
              'can be sent.';
        } else {
          title = [
            if (waiting > 0) '${count(waiting)} waiting to send',
            if (failed > 0) '${count(failed)} could not be sent',
          ].join(' · ');
          detail = failed > 0
              ? 'Tap the red strip at the top of the screen to see why.'
              : online
              ? null
              : 'They will send by themselves when the signal comes back.';
        }
        return _Group(
          children: [
            ListTile(
              leading: Icon(
                waiting == 0 && failed == 0
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_upload_outlined,
              ),
              title: Text(title),
              subtitle: detail == null ? null : Text(detail),
            ),
            if (waiting > 0 && online)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.sm,
                ),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(
                      AppSpacing.minTouchTarget,
                    ),
                  ),
                  onPressed: outbox.isSending ? null : outbox.flush,
                  icon: const Icon(Icons.send_outlined),
                  label: Text(outbox.isSending ? 'Sending…' : 'Send now'),
                ),
              ),
          ],
        );
      },
    );
  }
}
