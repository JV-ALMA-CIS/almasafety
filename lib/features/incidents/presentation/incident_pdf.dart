import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/reports/pdf_report.dart';
import '../domain/incident.dart';
import '../domain/incident_enums.dart';

/// One corrective action on the printed incident report.
class IncidentReportAction {
  const IncidentReportAction({
    required this.title,
    required this.assignedTo,
    required this.dueDate,
    required this.status,
    this.completedAt,
  });

  final String title;
  final String assignedTo;
  final DateTime? dueDate;
  final String status;
  final DateTime? completedAt;
}

/// An incident as a printable report — everything needed to complete
/// ENG Form 3394 (Accident Investigation Report) and to show the Safety
/// Plan's Section 8 reporting was done: what happened, who was hurt, what
/// was done straight away, the reporting level and each reporting step with
/// its deadline and when it was done, the investigation (severity, root
/// cause), and the corrective actions.
Future<Uint8List> buildIncidentPdf({
  required Incident incident,
  required String organizationName,
  required String siteName,
  required String reportedBy,
  List<IncidentReportAction> actions = const [],
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? generatedAt,

  /// Off in tests, so the text can be read back.
  bool compress = true,
}) async {
  final now = generatedAt ?? DateTime.now();
  final logo = await PdfReport.logo();
  String dateTime(DateTime? t) {
    if (t == null) return '-';
    final local = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${PdfReport.date(local)} ${two(local.hour)}:${two(local.minute)}';
  }

  final status = switch (incident.status) {
    IncidentStatus.reported => 'Reported - waiting for investigation',
    IncidentStatus.underInvestigation => 'Under investigation',
    IncidentStatus.closed => 'Closed',
  };
  final doc = pw.Document(
    compress: compress,
    title: 'Incident report',
    author: PdfReport.clean(organizationName),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(32),
      header: (context) => PdfReport.header(
        organizationName: organizationName,
        logo: logo,
        title: 'INCIDENT REPORT',
        subtitle:
            '${incident.type.label} - $siteName - happened '
            '${dateTime(incident.occurredAt)} - for ENG Form 3394',
      ),
      footer: (context) => PdfReport.footer(context, now),
      build: (context) => [
        pw.Table(
          border: PdfReport.border,
          children: [
            pw.TableRow(
              children: [
                PdfReport.field('Type', incident.type.label),
                PdfReport.field('Severity', incident.severity?.label),
                PdfReport.field('Status', status),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.field(
                  'Date and time it happened',
                  dateTime(incident.occurredAt),
                ),
                PdfReport.field('Reported', dateTime(incident.createdAt)),
                PdfReport.field('Reported by', reportedBy),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.field('Site', siteName),
                PdfReport.field('Location on site', incident.location),
                PdfReport.field('Person hurt', incident.injuredPersonName),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 10),
        _section('WHAT HAPPENED', PdfReport.text(incident.description)),
        _section(
          'DONE STRAIGHT AWAY',
          PdfReport.text(incident.immediateAction ?? '-'),
        ),

        // ---- Reporting (Section 8) ----
        PdfReport.text(
          'REPORTING (SAFETY PLAN SECTION 8)',
          size: 10,
          bold: true,
        ),
        pw.SizedBox(height: 4),
        PdfReport.text(
          incident.reportingLevel == null
              ? 'Reporting level: NOT SET'
              : 'Reporting level: ${incident.reportingLevel!.label} - '
                    '${incident.reportingLevel!.description}',
          color: incident.reportingLevel == null
              ? PdfReport.red
              : PdfReport.ink,
        ),
        pw.SizedBox(height: 4),
        if (incident.reportingSteps.isNotEmpty)
          pw.Table(
            border: PdfReport.border,
            columnWidths: const {
              0: pw.FlexColumnWidth(3),
              1: pw.FlexColumnWidth(1.4),
              2: pw.FlexColumnWidth(1.4),
              3: pw.FlexColumnWidth(1.4),
              4: pw.FlexColumnWidth(2),
            },
            children: [
              pw.TableRow(
                children: [
                  PdfReport.headCell('Step'),
                  PdfReport.headCell('Due'),
                  PdfReport.headCell('Done'),
                  PdfReport.headCell('By'),
                  PdfReport.headCell('Note / reference'),
                ],
              ),
              for (final step in incident.reportingSteps)
                pw.TableRow(
                  children: [
                    PdfReport.cell(PdfReport.text(step.label)),
                    PdfReport.cell(PdfReport.text(dateTime(step.dueAt))),
                    PdfReport.cell(
                      PdfReport.text(
                        step.isDone ? dateTime(step.doneAt) : 'NOT DONE',
                        bold: !step.isDone,
                        color: step.isDone
                            ? PdfReport.green
                            : step.isOverdue(now)
                            ? PdfReport.red
                            : PdfReport.ink,
                      ),
                    ),
                    PdfReport.cell(PdfReport.text(step.doneByName ?? '-')),
                    PdfReport.cell(PdfReport.text(step.note ?? '-')),
                  ],
                ),
            ],
          ),
        pw.SizedBox(height: 10),

        // ---- Investigation ----
        _section(
          'ROOT CAUSE',
          PdfReport.text(incident.rootCause ?? 'Not yet recorded'),
        ),
        if (incident.closingNotes != null)
          _section('CLOSING NOTES', PdfReport.text(incident.closingNotes)),

        PdfReport.text('CORRECTIVE ACTIONS', size: 10, bold: true),
        pw.SizedBox(height: 4),
        if (actions.isEmpty)
          PdfReport.text('None recorded.')
        else
          pw.Table(
            border: PdfReport.border,
            columnWidths: const {
              0: pw.FlexColumnWidth(3),
              1: pw.FlexColumnWidth(1.6),
              2: pw.FlexColumnWidth(1.2),
              3: pw.FlexColumnWidth(1.4),
              4: pw.FlexColumnWidth(1.2),
            },
            children: [
              pw.TableRow(
                children: [
                  PdfReport.headCell('Action'),
                  PdfReport.headCell('Assigned to'),
                  PdfReport.headCell('Due'),
                  PdfReport.headCell('Status'),
                  PdfReport.headCell('Completed'),
                ],
              ),
              for (final action in actions)
                pw.TableRow(
                  children: [
                    PdfReport.cell(PdfReport.text(action.title)),
                    PdfReport.cell(PdfReport.text(action.assignedTo)),
                    PdfReport.cell(
                      PdfReport.text(PdfReport.date(action.dueDate)),
                    ),
                    PdfReport.cell(PdfReport.text(action.status)),
                    PdfReport.cell(
                      PdfReport.text(PdfReport.date(action.completedAt)),
                    ),
                  ],
                ),
            ],
          ),
        pw.SizedBox(height: 22),
        PdfReport.signatureLine('Investigated by', null),
        pw.SizedBox(height: 14),
        PdfReport.signatureLine('Reviewed by COR', null),
      ],
    ),
  );
  return doc.save();
}

pw.Widget _section(String title, pw.Widget body) => pw.Padding(
  padding: const pw.EdgeInsets.only(bottom: 10),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      PdfReport.text(title, size: 10, bold: true),
      pw.SizedBox(height: 3),
      body,
    ],
  ),
);
