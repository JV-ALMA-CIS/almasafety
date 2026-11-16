import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/feature_header.dart';
import '../../hazards/domain/hazard_kind.dart';
import '../../hazards/presentation/report_hazard_screen.dart';
import '../../incidents/presentation/report_incident_screen.dart';
import '../../../core/widgets/mobile_title.dart';

/// The single way in for anyone reporting something on site: **⚠️ Report
/// a Safety Issue**. Instead of making a worker know the difference between
/// a "hazard" and an "incident" at the worst moment, it asks one plain
/// question and opens the right form:
///
/// - ⚠️ Something COULD happen → hazard report,
/// - 😮 Something NEARLY happened → hazard report of kind near-miss,
/// - 🤕 Something ACTUALLY happened → incident report.
///
/// Each report still lands in its own history (Hazards or Incidents).
/// Shown full-screen when opened from a button, or [embedded] as the
/// "Report a Safety Issue" menu page inside the app shell.
class ReportSafetyIssueScreen extends StatelessWidget {
  const ReportSafetyIssueScreen({
    super.key,
    this.embedded = false,
    this.organizationId,
  });

  /// True when shown as a menu page inside the app shell (which has its
  /// own top bar), false when opened full-screen from a button.
  final bool embedded;

  /// For a System Administrator reporting an incident in a chosen
  /// organization — see [ReportIncidentScreen.organizationId].
  final String? organizationId;

  void _open(BuildContext context, Widget form) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = MaterialPageRoute<void>(builder: (_) => form);
    // Opened from a button: replace the chooser, so "back" from the form
    // returns to where the person started. As a menu page: open on top.
    if (embedded) {
      navigator.push(route);
    } else {
      navigator.pushReplacement(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        const FeatureHeader(
          title: 'Report a Safety Issue',
          subtitle: 'What are you reporting? Pick the one that fits best.',
          icon: Icons.campaign,
          color: AppColors.stop,
        ),
        const SizedBox(height: AppSpacing.md),
        _IssueChoice(
          emoji: '⚠️',
          title: 'Something COULD happen',
          examples:
              'e.g. missing guard rail, exposed wire, oil on the floor, '
              'someone without a hard hat',
          color: AppColors.hazards,
          onTap: () => _open(context, const ReportHazardScreen()),
        ),
        const SizedBox(height: AppSpacing.sm),
        _IssueChoice(
          emoji: '😮',
          title: 'Something NEARLY happened',
          examples:
              'Nobody hurt, nothing damaged — e.g. a tool fell and just '
              'missed someone',
          color: AppColors.learning,
          onTap: () => _open(
            context,
            const ReportHazardScreen(initialKind: HazardKind.nearMiss),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _IssueChoice(
          emoji: '🤕',
          title: 'Something ACTUALLY happened',
          examples: 'Someone hurt, or something damaged, spilled or on fire',
          color: AppColors.stop,
          onTap: () => _open(
            context,
            ReportIncidentScreen(organizationId: organizationId),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Not sure? Pick the closest one — a supervisor reviews every '
          'report. If someone is hurt, get help first.',
          style: AppTextStyles.bodyMedium.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
    if (embedded) return content;
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Report a Safety Issue')),
      body: content,
    );
  }
}

/// One of the three big choices: picture, plain-language title, examples.
class _IssueChoice extends StatelessWidget {
  const _IssueChoice({
    required this.emoji,
    required this.title,
    required this.examples,
    required this.color,
    required this.onTap,
  });

  final String emoji;
  final String title;
  final String examples;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Material(
      color: color.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color, width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 30)),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.titleLarge.copyWith(
                        color: AppColors.readable(color, brightness),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(examples, style: AppTextStyles.bodyMedium),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

/// The big **⚠️ Report a Safety Issue** button used on dashboards — opens
/// [ReportSafetyIssueScreen]. Worded as an action ("report a safety issue")
/// so it is never mistaken for the Reports (generated documents) page.
class ReportSafetyIssueButton extends StatelessWidget {
  const ReportSafetyIssueButton({super.key});

  @override
  Widget build(BuildContext context) {
    const color = AppColors.stop;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(
            builder: (_) => const ReportSafetyIssueScreen(),
          ),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md - 2,
          ),
          child: Row(
            children: [
              Text('⚠️', style: TextStyle(fontSize: 30)),
              SizedBox(width: AppSpacing.sm + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Report a Safety Issue',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Something wrong, nearly happened, or happened',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}
