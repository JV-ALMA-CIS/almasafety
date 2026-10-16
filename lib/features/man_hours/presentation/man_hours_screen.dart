import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/reports/pdf_report.dart';
import '../../../core/reports/print_report_button.dart';
import '../../../core/reports/report_context.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../incidents/data/incident_repository.dart';
import '../../incidents/domain/incident.dart';
import '../../incidents/domain/incident_reporting.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../../organizations/domain/site.dart';
import '../data/man_hours_repository.dart';
import '../data/man_hours_service.dart';
import '../domain/man_hours.dart';
import 'man_hours_pdf.dart';

/// The "Monthly Man-Hours" page — the Safety Plan's Section 8a: man-hours
/// worked are reported to the Safety Office by the 25th of every month.
///
/// Pick the month (last month by default); each site's man-hours and number
/// of workers are entered — with a suggested figure from the daily safety
/// meeting attendance — and Site Managers/Admins print the month's report
/// (with lost-time and recordable incidents) and mark it reported.
class ManHoursScreen extends StatefulWidget {
  const ManHoursScreen({
    super.key,
    this.repository,
    this.service,
    this.siteRepository,
    this.incidentRepository,
    this.printReport,
    this.now,
  });

  /// Injected in tests.
  final ManHoursRepository? repository;
  final ManHoursService? service;
  final SiteRepository? siteRepository;
  final IncidentRepository? incidentRepository;
  final ReportPrinter? printReport;
  final DateTime Function()? now;

  @override
  State<ManHoursScreen> createState() => _ManHoursScreenState();
}

/// One site's line of the month: its entry (if any) and incidents.
class _SiteLine {
  const _SiteLine(this.site, this.entry, this.lostTime, this.recordable);

  final Site site;
  final ManHoursEntry? entry;
  final int lostTime;
  final int recordable;
}

class _ManHoursScreenState extends State<ManHoursScreen> {
  late final ManHoursService _service = widget.service ?? ManHoursService();
  late final DateTime _now = (widget.now ?? DateTime.now)();
  late String _month = reportingMonth(_now);
  String? _errorMessage;
  bool _marking = false;

  ManHoursRepository _repository(String org) =>
      widget.repository ??
      ManHoursRepository(
        firestoreService: FirestoreService(),
        organizationId: org,
      );

  SiteRepository _sites(String org) =>
      widget.siteRepository ??
      SiteRepository(firestoreService: FirestoreService(), organizationId: org);

  IncidentRepository _incidents(String org) =>
      widget.incidentRepository ??
      IncidentRepository(
        firestoreService: FirestoreService(),
        organizationId: org,
      );

  /// Lost-time incidents (immediate or lost-time reporting level) and
  /// recordable ones (those plus medical treatment) at [siteId] in the month.
  (int, int) _incidentCounts(List<Incident> incidents, String siteId) {
    var lostTime = 0;
    var recordable = 0;
    for (final i in incidents) {
      if (i.siteId != siteId || monthId(i.occurredAt) != _month) continue;
      final level = i.reportingLevel;
      if (level == IncidentReportingLevel.immediate ||
          level == IncidentReportingLevel.lostTime) {
        lostTime++;
      }
      if (level == IncidentReportingLevel.immediate ||
          level == IncidentReportingLevel.lostTime ||
          level == IncidentReportingLevel.medical) {
        recordable++;
      }
    }
    return (lostTime, recordable);
  }

  Future<void> _markReported(String org) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Mark ${monthLabel(_month)} as reported?'),
        content: const Text(
          'Confirms the man-hours for this month have been sent to the '
          'Safety Office. Your name and today\'s date are recorded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Mark reported'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _marking = true;
      _errorMessage = null;
    });
    try {
      await _service.markReported(organizationId: org, month: _month);
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  Future<void> _print(
    String org,
    List<_SiteLine> lines,
    ManHoursReport? report,
  ) async {
    final organizationName = await organizationNameFor(org);
    await (widget.printReport ?? PdfReport.printDocument)(
      name: 'Man-hours - ${monthLabel(_month)}',
      build: (format) => buildManHoursPdf(
        month: _month,
        organizationName: organizationName,
        lines: [
          for (final line in lines)
            ManHoursPdfLine(
              site: line.site.name,
              workers: line.entry?.workers,
              hours: line.entry?.hours,
              lostTime: line.lostTime,
              recordable: line.recordable,
              enteredBy: line.entry?.enteredByName,
            ),
        ],
        reportedBy: report?.reportedByName,
        reportedAt: report?.reportedAt,
        format: format,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final org = session.activeOrganizationId;
    final role = session.activeMembership?.role;
    final isManager =
        (session.profile?.isPlatformAdministrator ?? false) ||
        role == AppRole.admin ||
        role == AppRole.siteManager;
    final isForeman = role == AppRole.foreman;
    final mySiteIds = session.activeMembership?.siteIds ?? const <String>[];

    if (org == null || !(isManager || isForeman)) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Man-hours are entered by Foremen and Site Managers.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final repository = _repository(org);
    final sites = _sites(org);
    return LiveStreamBuilder<List<Site>>(
      streamKey: (org, isManager),
      stream: () => isManager ? sites.watchAll() : sites.watchByIds(mySiteIds),
      builder: (context, siteSnapshot) {
        return LiveStreamBuilder<List<ManHoursEntry>>(
          streamKey: (org, _month),
          stream: () => repository.watchMonth(_month),
          builder: (context, entrySnapshot) {
            return LiveStreamBuilder<ManHoursReport?>(
              streamKey: (org, _month, 'report'),
              stream: () => repository.watchReport(_month),
              builder: (context, reportSnapshot) {
                return LiveStreamBuilder<List<Incident>>(
                  streamKey: (org, 'incidents'),
                  stream: () => _incidents(
                    org,
                  ).watchForOrganization().handleError((Object _) {}),
                  builder: (context, incidentSnapshot) {
                    final entries = {
                      for (final e
                          in entrySnapshot.data ?? const <ManHoursEntry>[])
                        e.siteId: e,
                    };
                    final lines = [
                      for (final site in siteSnapshot.data ?? const <Site>[])
                        if (site.status == OrganizationRecordStatus.active ||
                            entries.containsKey(site.id))
                          () {
                            final (lost, rec) = _incidentCounts(
                              incidentSnapshot.data ?? const [],
                              site.id,
                            );
                            return _SiteLine(site, entries[site.id], lost, rec);
                          }(),
                    ]..sort((a, b) => a.site.name.compareTo(b.site.name));
                    return _buildPage(
                      org,
                      isManager,
                      lines,
                      reportSnapshot.data,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildPage(
    String org,
    bool isManager,
    List<_SiteLine> lines,
    ManHoursReport? report,
  ) {
    final entered = lines.where((l) => l.entry != null).length;
    final total = lines.fold<double>(
      0,
      (sum, l) => sum + (l.entry?.hours ?? 0),
    );
    final due = manHoursDueDate(_month);
    final overdue = report == null && _now.isAfter(due);
    final months = recentMonths(_now);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        FeatureHeader(
          title: 'Monthly Man-Hours',
          subtitle:
              'Safety Plan 8a: hours worked per site, reported to the Safety '
              'Office by the 25th of the following month.',
          icon: Icons.schedule,
          color: AppColors.analytics,
          chips: [
            FeatureChip(
              icon: Icons.location_city,
              label: '$entered of ${lines.length} sites entered',
            ),
            FeatureChip(
              icon: Icons.timer,
              label: '${_formatHours(total)} hours',
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        ColorChoiceChips<String>(
          selected: _month,
          onSelected: (value) => setState(() => _month = value),
          choices: [
            for (final m in months)
              ColorChoice(
                value: m,
                label: monthLabel(m),
                color: AppColors.analytics,
                icon: Icons.calendar_month,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _StatusBanner(report: report, due: due, overdue: overdue),
        if (_errorMessage != null) ...[
          const SizedBox(height: AppSpacing.md),
          AuthErrorBanner(message: _errorMessage!),
        ],
        if (isManager) ...[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              SizedBox(
                width: 160,
                child: PrintReportButton(
                  onPrint: () => _print(org, lines, report),
                ),
              ),
              if (report == null)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, AppSpacing.minTouchTarget),
                  ),
                  onPressed: _marking || entered == 0
                      ? null
                      : () => _markReported(org),
                  icon: const Icon(Icons.send),
                  label: const Text('Mark as reported to the Safety Office'),
                ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        if (lines.isEmpty)
          const Text('No sites to show.', style: AppTextStyles.bodyMedium),
        for (final line in lines) ...[
          _SiteHoursCard(
            key: ValueKey('${line.site.id}-$_month'),
            organizationId: org,
            month: _month,
            line: line,
            service: _service,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

String _formatHours(double hours) => hours == hours.roundToDouble()
    ? hours.toStringAsFixed(0)
    : hours.toStringAsFixed(1);

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.report,
    required this.due,
    required this.overdue,
  });

  final ManHoursReport? report;
  final DateTime due;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final report = this.report;
    final color = report != null
        ? AppColors.go
        : overdue
        ? AppColors.stop
        : AppColors.warning;
    final text = report != null
        ? 'Reported to the Safety Office'
              '${report.reportedByName == null ? '' : ' by ${report.reportedByName}'}'
              '${report.reportedAt == null ? '' : ' on ${shortDay(report.reportedAt!)}'}'
              ' - ${_formatHours(report.totalHours)} hours, ${report.sites} '
              'site${report.sites == 1 ? '' : 's'}.'
        : overdue
        ? 'OVERDUE - was due ${shortDay(due)}. Enter every site and send it '
              'to the Safety Office.'
        : 'Due ${shortDay(due)} - not yet reported to the Safety Office.';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm + 4),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.10),
          Theme.of(context).colorScheme.surface,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon(report != null ? Icons.check_circle : Icons.event, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

/// One site's month: hours and workers to enter or change, a suggestion
/// from the daily meeting attendance, and its incidents.
class _SiteHoursCard extends StatefulWidget {
  const _SiteHoursCard({
    super.key,
    required this.organizationId,
    required this.month,
    required this.line,
    required this.service,
  });

  final String organizationId;
  final String month;
  final _SiteLine line;
  final ManHoursService service;

  @override
  State<_SiteHoursCard> createState() => _SiteHoursCardState();
}

class _SiteHoursCardState extends State<_SiteHoursCard> {
  late final _hours = TextEditingController(
    text: widget.line.entry == null
        ? ''
        : _formatHours(widget.line.entry!.hours),
  );
  late final _workers = TextEditingController(
    text: widget.line.entry?.workers.toString() ?? '',
  );
  late final _notes = TextEditingController(text: widget.line.entry?.notes);
  final _hoursPerDay = TextEditingController(text: '8');
  bool _saving = false;
  bool _suggesting = false;
  String? _message;
  String? _error;

  @override
  void dispose() {
    for (final c in [_hours, _workers, _notes, _hoursPerDay]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _suggest() async {
    setState(() {
      _suggesting = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await widget.service.suggestion(
        organizationId: widget.organizationId,
        siteId: widget.line.site.id,
        month: widget.month,
      );
      final perDay = double.tryParse(_hoursPerDay.text.trim()) ?? 8;
      final hours = result.workerDays * perDay;
      setState(() {
        _hours.text = _formatHours(hours);
        _message =
            '${result.workerDays} worker-days present at '
            '${result.meetingDays} daily meetings × ${_formatHours(perDay)} h '
            '= ${_formatHours(hours)} h. Check it, then save.';
      });
    } on AppException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  Future<void> _save() async {
    final hours = double.tryParse(_hours.text.trim());
    final workers = int.tryParse(_workers.text.trim());
    if (hours == null || workers == null || hours < 0 || workers < 0) {
      setState(() => _error = 'Enter the hours and the number of workers.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _message = null;
    });
    try {
      final notes = _notes.text.trim();
      await widget.service.save(
        organizationId: widget.organizationId,
        siteId: widget.line.site.id,
        month: widget.month,
        hours: hours,
        workers: workers,
        notes: notes.isEmpty ? null : notes,
      );
      if (mounted) setState(() => _message = 'Saved.');
    } on SavedOfflineException {
      if (mounted) {
        setState(
          () => _message =
              'No signal - saved on this phone. It will be sent when the '
              'signal comes back.',
        );
      }
    } on AppException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final entry = line.entry;
    final color = entry == null ? AppColors.warning : AppColors.go;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                entry == null ? Icons.pending_actions : Icons.check_circle,
                color: color,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  line.site.name,
                  style: AppTextStyles.bodyLarge.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                entry == null ? 'Not entered' : 'Entered',
                style: AppTextStyles.label.copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Incidents this month: ${line.lostTime} lost-time, '
            '${line.recordable} recordable'
            '${entry?.enteredByName == null ? '' : ' · entered by ${entry!.enteredByName}'}',
            style: AppTextStyles.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _hours,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Man-hours'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextField(
                  controller: _workers,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Workers'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _hoursPerDay,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Hours/day'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, AppSpacing.minTouchTarget),
                  ),
                  onPressed: _suggesting ? null : _suggest,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Suggest from attendance'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
          ),
          if (_message != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(_message!, style: AppTextStyles.bodyMedium),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _error!,
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.stop),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, AppSpacing.minTouchTarget),
              ),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save),
              label: Text(entry == null ? 'Save' : 'Update'),
            ),
          ),
        ],
      ),
    );
  }
}
