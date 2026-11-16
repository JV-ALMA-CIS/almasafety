import 'deficiency_log_pdf.dart';
import '../../organizations/domain/site.dart';
import '../../organizations/data/site_repository.dart';
import '../../../core/reports/report_context.dart';
import '../../../core/reports/pdf_report.dart';
import 'package:flutter/material.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../authentication/data/people_directory.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../corrective_actions/presentation/report_progress.dart';
import '../../hazards/data/hazard_repository.dart';
import '../../hazards/domain/hazard.dart';
import '../../hazards/domain/hazard_status.dart';
import '../../../core/widgets/mobile_title.dart';

/// The Safety Plan's DEFICIENCY LOG (Section 7c): every deficiency found by
/// an inspection, with the five things the plan asks for — date identified,
/// description, person responsible, projected resolution date and date
/// actually resolved — plus where it stands now.
///
/// Built from what the app already records: each "Not OK" is a hazard
/// linked to its inspection, and its corrective action carries the person
/// responsible, the target date and the completion; approval of that action
/// is the plan's follow-up inspection.
class DeficiencyLogScreen extends StatefulWidget {
  const DeficiencyLogScreen({
    super.key,
    required this.organizationId,
    this.hazardRepository,
    this.correctiveActionRepository,
    this.peopleDirectory,
    this.siteRepository,
    this.printReport,
  });

  final String organizationId;

  /// Injected in tests.
  final SiteRepository? siteRepository;

  /// Injected in tests; defaults to the device's print window.
  final ReportPrinter? printReport;

  /// Injected in tests.
  final HazardRepository? hazardRepository;
  final CorrectiveActionRepository? correctiveActionRepository;
  final PeopleDirectory? peopleDirectory;

  @override
  State<DeficiencyLogScreen> createState() => _DeficiencyLogScreenState();
}

class _DeficiencyLogScreenState extends State<DeficiencyLogScreen> {
  late final HazardRepository _hazards =
      widget.hazardRepository ??
      HazardRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organizationId,
      );
  late final CorrectiveActionRepository _actions =
      widget.correctiveActionRepository ??
      CorrectiveActionRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organizationId,
      );
  late final Future<Map<String, String>> _names =
      (widget.peopleDirectory ?? PeopleDirectory()).namesFor(
        widget.organizationId,
      );
  bool _openOnly = true;
  bool _isPrinting = false;

  /// Prints the log as shown (open only, or all) — or saves it as PDF.
  Future<void> _print(
    List<Hazard> shown,
    Map<String, CorrectiveAction> actionsById,
    Map<String, String> names,
  ) async {
    setState(() => _isPrinting = true);
    try {
      final organizationName = await organizationNameFor(widget.organizationId);
      final sites =
          await (widget.siteRepository ??
                  SiteRepository(
                    firestoreService: FirestoreService(),
                    organizationId: widget.organizationId,
                  ))
              .watchAll()
              .first
              .catchError((Object _) => const <Site>[]);
      final siteNames = {for (final s in sites) s.id: s.name};
      final lines = [
        for (final hazard in shown)
          _lineFor(
            hazard,
            actionsById[hazard.correctiveActionId],
            names,
            siteNames,
          ),
      ];
      await (widget.printReport ?? PdfReport.printDocument)(
        name: 'Deficiency Log - ${PdfReport.date(DateTime.now())}',
        build: (format) => buildDeficiencyLogPdf(
          lines: lines,
          organizationName: organizationName,
          scope: _openOnly ? 'Open deficiencies' : 'All deficiencies',
          format: format,
        ),
      );
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  DeficiencyLogLine _lineFor(
    Hazard hazard,
    CorrectiveAction? action,
    Map<String, String> names,
    Map<String, String> siteNames,
  ) {
    final progress = ReportProgress.forHazard(hazard, action);
    return DeficiencyLogLine(
      identified: hazard.createdAt,
      site: siteNames[hazard.siteId] ?? '-',
      description: hazard.description,
      foundIn: hazard.inspectionName,
      responsible: action == null
          ? 'Not assigned yet'
          : nameOf(action.assignedTo, names, stored: action.assignedToName),
      targetDate: action?.dueDate,
      resolved: hazard.closedAt ?? action?.completedAt,
      status: progress.label,
      isOpen: hazard.status != HazardStatus.closed,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Deficiency Log')),
      body: LiveStreamBuilder<List<Hazard>>(
        streamKey: widget.organizationId,
        stream: () => _hazards.watchForOrganization(),
        builder: (context, hazardSnapshot) {
          final deficiencies = [
            for (final hazard in hazardSnapshot.data ?? const <Hazard>[])
              if (hazard.isDeficiency) hazard,
          ];
          return LiveStreamBuilder<List<CorrectiveAction>>(
            streamKey: widget.organizationId,
            stream: () => _actions.watchForOrganization(),
            builder: (context, actionSnapshot) {
              final actionsById = {
                for (final action
                    in actionSnapshot.data ?? const <CorrectiveAction>[])
                  action.id: action,
              };
              return FutureBuilder<Map<String, String>>(
                future: _names,
                builder: (context, namesSnapshot) {
                  final names = namesSnapshot.data ?? const {};
                  final open = deficiencies
                      .where((h) => h.status != HazardStatus.closed)
                      .length;
                  final shown = _openOnly
                      ? deficiencies
                            .where((h) => h.status != HazardStatus.closed)
                            .toList()
                      : deficiencies;
                  return ListView(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    children: [
                      FeatureHeader(
                        title: 'Deficiency Log',
                        subtitle:
                            'Deficiencies found by inspections, tracked '
                            'until fixed (Safety Plan, Section 7c).',
                        icon: Icons.list_alt,
                        color: AppColors.inspections,
                        chips: [
                          FeatureChip(icon: Icons.report, label: '$open open'),
                          FeatureChip(
                            icon: Icons.check_circle,
                            label: '${deficiencies.length - open} corrected',
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(
                              0,
                              AppSpacing.minTouchTarget,
                            ),
                          ),
                          onPressed: _isPrinting
                              ? null
                              : () => _print(shown, actionsById, names),
                          icon: const Icon(Icons.print),
                          label: const Text('Print / PDF'),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      ColorChoiceChips<bool>(
                        selected: _openOnly,
                        onSelected: (value) =>
                            setState(() => _openOnly = value),
                        choices: const [
                          ColorChoice(
                            value: true,
                            label: 'Open',
                            color: AppColors.stop,
                            icon: Icons.report,
                          ),
                          ColorChoice(
                            value: false,
                            label: 'All',
                            color: AppColors.textSecondary,
                            icon: Icons.all_inclusive,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (shown.isEmpty)
                        const EmptyState(
                          icon: Icons.task_alt,
                          title: 'No deficiencies to show',
                        ),
                      for (final hazard in shown) ...[
                        _DeficiencyRow(
                          hazard: hazard,
                          action: actionsById[hazard.correctiveActionId],
                          names: names,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _DeficiencyRow extends StatelessWidget {
  const _DeficiencyRow({
    required this.hazard,
    required this.action,
    required this.names,
  });

  final Hazard hazard;
  final CorrectiveAction? action;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    final progress = ReportProgress.forHazard(hazard, action);
    final resolved = hazard.closedAt ?? action?.completedAt;
    return AccentCard(
      color: progress.color,
      icon: progress.icon,
      title: hazard.description,
      dimmed: hazard.status == HazardStatus.closed,
      badges: [AccentBadge(label: progress.label, color: progress.color)],
      details: [
        AccentDetail(
          icon: Icons.event,
          text: 'Identified: ${_date(hazard.createdAt)}',
        ),
        AccentDetail(
          icon: Icons.person_outline,
          text:
              'Responsible: '
              '${action == null ? 'Not assigned yet' : nameOf(action.assignedTo, names, stored: action.assignedToName)}',
        ),
        AccentDetail(
          icon: Icons.flag_outlined,
          text: 'Target date: ${action == null ? '—' : _date(action.dueDate)}',
        ),
        AccentDetail(
          icon: Icons.task_alt,
          text: 'Resolved: ${resolved == null ? 'Not yet' : _date(resolved)}',
        ),
        if (hazard.inspectionName != null)
          AccentDetail(
            icon: Icons.fact_check_outlined,
            text: 'Found in: ${hazard.inspectionName}',
          ),
      ],
    );
  }
}

String _date(DateTime? date) {
  if (date == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}
