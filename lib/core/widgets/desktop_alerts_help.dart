import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// Whether the app is running in a browser on a computer (Windows, Mac,
/// Linux) — where notifications pop up like Outlook's only while the
/// browser is running, so people need the short how-to below.
bool get isDesktopBrowser =>
    kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// The steps, in order: what to do, and where.
const desktopAlertSteps = <(IconData, String, String)>[
  (
    Icons.install_desktop,
    'Install ${AppConstants.appName} as an app',
    'Edge: click the install icon at the right of the address bar, or '
        '⋯ menu → Apps → Install this site as an app.\n'
        'Chrome: click the install icon in the address bar, or ⋮ menu → '
        'Cast, save and share → Install page as app.\n'
        'It then opens in its own window with its own taskbar icon. '
        '(Already opens in its own window? Skip this step.)',
  ),
  (
    Icons.sync,
    'Let the browser run in the background',
    'So pop-ups still arrive after you close the window.\n'
        'Edge: Settings → System and performance → turn on "Continue '
        'running background extensions and apps when Microsoft Edge is '
        'closed".\n'
        'Chrome: Settings → System → turn on "Continue running background '
        'apps when Google Chrome is closed".',
  ),
  (
    Icons.notifications_active,
    'Let Windows show the pop-ups',
    'Windows Settings → System → Notifications: Notifications On, and '
        'your browser (or ${AppConstants.appName}) On. Turn off "Do not '
        'disturb" when you want alerts.\n'
        'On a Mac: System Settings → Notifications → your browser → Allow '
        'notifications.',
  ),
];

/// Opens the how-to for getting alerts on this computer.
Future<void> showDesktopAlertsHelp(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.computer, color: AppColors.primaryBright),
      title: const Text('Get alerts on this computer'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Safety alerts pop up at the corner of the screen, like new '
                'emails in Outlook — even when you are working in another '
                'program. Three settings make sure they always arrive:',
                style: AppTextStyles.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              for (final (index, (icon, title, detail))
                  in desktopAlertSteps.indexed) ...[
                _Step(
                  number: index + 1,
                  icon: icon,
                  title: title,
                  detail: detail,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              const Text(
                'If the browser is fully closed, alerts wait until it opens '
                'again — and they are always in Notifications in the app.',
                style: AppTextStyles.label,
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final int number;
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    const color = AppColors.primaryBright;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: color,
          child: Text(
            '$number',
            style: TextStyle(
              color: AppColors.onColor(color),
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: Text(title, style: AppTextStyles.titleLarge)),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(detail, style: AppTextStyles.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
