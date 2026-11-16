import 'safety_meeting_pdf.dart';
import '../../../core/reports/report_context.dart';
import '../../../core/reports/print_report_button.dart';
import '../../../core/reports/pdf_report.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../authentication/domain/app_role.dart';
import '../../organizations/data/site_repository.dart';
import '../data/safety_meeting_repository.dart';
import '../data/safety_meeting_service.dart';
import '../domain/safety_meeting.dart';
import 'record_safety_meeting_screen.dart';
import 'safety_meeting_style.dart';
import '../../../core/widgets/mobile_title.dart';

/// The "Weekly & Monthly Meetings" page — the Safety Plan's weekly employee
/// safety meeting (Thursday 08:00) and monthly supervisory safety meeting
/// (Thursday 08:30), separate from the Foreman's Daily Safety Meeting.
///
/// Shows whether each has been held this week / this month, lets the
/// facilitator record one, and lists past meetings. A Foreman records the
/// weekly meeting for their own sites and sees those; Site Managers/Admins
/// record both, for any site.
class SafetyMeetingsScreen extends StatefulWidget {
  const SafetyMeetingsScreen({
    super.key,
    this.repository,
    this.service,
    this.siteRepository,
    this.loadPeople,
    this.now,
  });

  /// Injected in tests.
  final SafetyMeetingRepository? repository;
  final SafetyMeetingService? service;
  final SiteRepository? siteRepository;
  final PeopleLoader? loadPeople;
  final DateTime Function()? now;

  @override
  State<SafetyMeetingsScreen> createState() => _SafetyMeetingsScreenState();
}

class _SafetyMeetingsScreenState extends State<SafetyMeetingsScreen> {
  SafetyMeetingRepository? _repository;

  /// null = both kinds.
  SafetyMeetingKind? _filter;

  SafetyMeetingRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    return _repository =
        widget.repository ??
        SafetyMeetingRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
  }

  Future<void> _record(String organizationId, SafetyMeetingKind kind) async {
    final recorded = await Navigator.of(context, rootNavigator: true)
        .push<bool>(
          MaterialPageRoute(
            builder: (_) => RecordSafetyMeetingScreen(
              organizationId: organizationId,
              kind: kind,
              service: widget.service,
              siteRepository: widget.siteRepository,
              loadPeople: widget.loadPeople,
              now: widget.now,
            ),
          ),
        );
    if (recorded == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${kind.label} recorded.')));
    }
  }

  void _open(SafetyMeeting meeting) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => SafetyMeetingDetailScreen(meeting: meeting),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final organizationId = session.activeOrganizationId;
    final role = session.activeMembership?.role;
    final isManager =
        (session.profile?.isPlatformAdministrator ?? false) ||
        role == AppRole.admin ||
        role == AppRole.siteManager;
    final isForeman = role == AppRole.foreman;
    final mySiteIds = session.activeMembership?.siteIds ?? const <String>[];

    if (organizationId == null || !(isManager || isForeman)) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Weekly and monthly safety meetings are recorded by Foremen and '
            'Site Managers.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final now = (widget.now ?? DateTime.now)();
    final repository = _repositoryFor(organizationId);
    return LiveStreamBuilder<List<SafetyMeeting>>(
      streamKey: organizationId,
      stream: () => repository.watchMeetings(),
      builder: (context, snapshot) {
        final visible = [
          for (final meeting in snapshot.data ?? const <SafetyMeeting>[])
            if (isManager ||
                meeting.siteId == null ||
                mySiteIds.contains(meeting.siteId))
              meeting,
        ];
        final shown = [
          for (final meeting in visible)
            if (_filter == null || meeting.kind == _filter) meeting,
        ];
        final loading =
            snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null;

        return ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            const FeatureHeader(
              title: 'Weekly & Monthly Meetings',
              subtitle:
                  "The Safety Plan's weekly employee safety meeting and "
                  'monthly supervisory meeting. Record each one after it '
                  'is held.',
              icon: Icons.groups,
              color: AppColors.teamMeetings,
            ),
            if (snapshot.hasError) ...[
              const SizedBox(height: AppSpacing.md),
              const Text(
                'Could not load the meetings. Please try again.',
                style: AppTextStyles.bodyMedium,
              ),
            ],
            for (final kind in SafetyMeetingKind.values) ...[
              const SizedBox(height: AppSpacing.md),
              _PeriodCard(
                kind: kind,
                held: [
                  for (final meeting in visible)
                    if (meeting.kind == kind && isInCurrentPeriod(meeting, now))
                      meeting,
                ],
                loading: loading,
                canRecord:
                    kind == SafetyMeetingKind.weeklyEmployee || isManager,
                onRecord: () => _record(organizationId, kind),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            FeatureSectionTitle(
              title: 'Past meetings',
              icon: Icons.history,
              color: AppColors.teamMeetings,
              count: shown.length,
            ),
            const SizedBox(height: AppSpacing.sm),
            ColorChoiceChips<SafetyMeetingKind?>(
              selected: _filter,
              onSelected: (value) => setState(() => _filter = value),
              choices: [
                const ColorChoice(
                  value: null,
                  label: 'All',
                  color: AppColors.textSecondary,
                  icon: Icons.all_inclusive,
                ),
                for (final kind in SafetyMeetingKind.values)
                  ColorChoice(
                    value: kind,
                    label: kind == SafetyMeetingKind.weeklyEmployee
                        ? 'Weekly'
                        : 'Monthly',
                    color: kind.color,
                    icon: kind.icon,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (!loading && shown.isEmpty)
              const Text(
                'No meetings recorded yet.',
                style: AppTextStyles.bodyMedium,
              ),
            for (final meeting in shown) ...[
              SafetyMeetingCard(meeting: meeting, onTap: () => _open(meeting)),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );
      },
    );
  }
}

/// This week's (weekly) or this month's (monthly) status for one meeting
/// type, with the button to record one.
class _PeriodCard extends StatelessWidget {
  const _PeriodCard({
    required this.kind,
    required this.held,
    required this.loading,
    required this.canRecord,
    required this.onRecord,
  });

  final SafetyMeetingKind kind;
  final List<SafetyMeeting> held;
  final bool loading;
  final bool canRecord;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final period = kind == SafetyMeetingKind.weeklyEmployee
        ? 'this week'
        : 'this month';
    final done = held.isNotEmpty;
    return AccentCard(
      color: kind.color,
      icon: kind.icon,
      title: kind.label,
      badges: [
        if (!loading)
          AccentBadge(
            label: done ? 'Held $period' : 'Not recorded $period',
            color: done ? AppColors.go : AppColors.warning,
          ),
      ],
      details: [
        AccentDetail(icon: Icons.schedule, text: kind.schedule),
        AccentDetail(icon: Icons.groups_outlined, text: kind.audience),
        for (final meeting in held)
          AccentDetail(
            icon: Icons.check_circle_outline,
            text:
                '${meeting.siteName ?? 'All sites'} · '
                '${_dayText(meeting)} · ${meeting.attendeeCount} attended',
          ),
      ],
      actions: [
        if (canRecord)
          AccentButton(
            label: 'Record meeting',
            icon: Icons.add,
            color: kind.color,
            onPressed: onRecord,
          ),
      ],
    );
  }
}

String _dayText(SafetyMeeting meeting) {
  final day = meeting.day;
  return day == null ? meeting.date : formatMeetingDay(day);
}

/// One recorded meeting in a list.
class SafetyMeetingCard extends StatelessWidget {
  const SafetyMeetingCard({super.key, required this.meeting, this.onTap});

  final SafetyMeeting meeting;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AccentCard(
      color: meeting.kind.color,
      icon: meeting.kind.icon,
      title: meeting.kind.label,
      onTap: onTap,
      badges: [
        AccentBadge(label: _dayText(meeting), color: meeting.kind.color),
        if (meeting.concerns.isNotEmpty)
          AccentBadge(
            label:
                '${meeting.concerns.length} '
                'concern${meeting.concerns.length == 1 ? '' : 's'}',
            color: AppColors.hazards,
          ),
      ],
      details: [
        AccentDetail(
          icon: Icons.location_city,
          text: meeting.siteName ?? 'All sites',
        ),
        AccentDetail(
          icon: Icons.person_outline,
          text: 'Run by ${meeting.facilitatorName ?? 'Unknown person'}',
        ),
        AccentDetail(
          icon: Icons.groups_outlined,
          text:
              '${meeting.attendeeCount} attended · '
              '${meeting.topics.length} '
              'subject${meeting.topics.length == 1 ? '' : 's'}',
        ),
      ],
    );
  }
}

/// Everything recorded for one meeting.
class SafetyMeetingDetailScreen extends StatelessWidget {
  const SafetyMeetingDetailScreen({
    super.key,
    required this.meeting,
    this.printReport,
  });

  final SafetyMeeting meeting;

  /// Injected in tests; defaults to the device's print window.
  final ReportPrinter? printReport;

  Future<void> _print() async {
    final organizationName = await organizationNameFor(meeting.organizationId);
    await (printReport ?? PdfReport.printDocument)(
      name:
          '${meeting.kind.label} - ${meeting.siteName ?? 'All sites'} - '
          '${meeting.date}',
      build: (format) => buildSafetyMeetingPdf(
        meeting: meeting,
        organizationName: organizationName,
        format: format,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final attendees = [
      for (final uid in meeting.attendeeUids)
        meeting.attendeeNames[uid] ?? 'Unknown person',
    ]..sort();
    final color = meeting.kind.color;
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Meeting Details')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            title: meeting.kind.label,
            subtitle:
                '${_dayText(meeting)} · ${meeting.siteName ?? 'All sites'}',
            icon: meeting.kind.icon,
            color: color,
            chips: [
              FeatureChip(
                icon: Icons.person,
                label: 'Run by ${meeting.facilitatorName ?? 'Unknown person'}',
              ),
              FeatureChip(
                icon: Icons.groups,
                label: '${meeting.attendeeCount} attended',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          PrintReportButton(onPrint: _print),
          const SizedBox(height: AppSpacing.md),
          _Section(
            title: 'Subjects covered',
            icon: Icons.checklist,
            color: color,
            lines: meeting.topics,
          ),
          _Section(
            title: 'Attended',
            icon: Icons.groups,
            color: AppColors.people,
            lines: [
              ...attendees,
              for (final name in meeting.otherAttendees) '$name (no account)',
            ],
          ),
          if (meeting.concerns.isNotEmpty)
            _Section(
              title: 'Concerns raised',
              icon: Icons.report_problem,
              color: AppColors.hazards,
              lines: meeting.concerns,
            ),
          if (meeting.notes != null)
            _Section(
              title: 'Notes',
              icon: Icons.notes,
              color: AppColors.textSecondary,
              lines: [meeting.notes!],
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.color,
    required this.lines,
  });

  final String title;
  final IconData icon;
  final Color color;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FeatureSectionTitle(
            title: title,
            icon: icon,
            color: color,
            count: lines.length,
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.circle, size: 8, color: color),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(line, style: AppTextStyles.bodyLarge)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
