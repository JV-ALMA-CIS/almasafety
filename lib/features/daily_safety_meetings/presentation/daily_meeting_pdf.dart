import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/reports/pdf_report.dart';

/// Everything printed on a daily safety meeting record, gathered by the
/// screen that prints it (names already resolved).
class DailyMeetingReport {
  const DailyMeetingReport({
    required this.siteName,
    required this.projectName,
    required this.date,
    required this.foremanName,
    required this.status,
    this.crewResult,
    this.activities = const [],
    this.points = const [],
    this.ahasCovered = const [],
    this.attendance = const [],
    this.concerns = const [],
    this.correctiveActions = const [],
  });

  final String siteName;
  final String projectName;
  final String date;
  final String foremanName;
  final String status;

  /// e.g. "GO" or "STOP - scaffold not tagged".
  final String? crewResult;
  final List<String> activities;

  /// (point, discussion note).
  final List<(String, String?)> points;

  /// e.g. "Removals (revision 2)".
  final List<String> ahasCovered;

  /// (name, attendance status).
  final List<(String, String)> attendance;
  final List<String> concerns;
  final List<String> correctiveActions;
}

/// A daily safety meeting (toolbox talk) as a printable record: site, date,
/// Foreman, the work covered, the safety points and AHAs gone through with
/// the crew, attendance with a signature column, concerns, corrective
/// actions and the crew's GO / STOP result.
Future<Uint8List> buildDailyMeetingPdf({
  required DailyMeetingReport report,
  required String organizationName,
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? generatedAt,

  /// Off in tests, so the text can be read back.
  bool compress = true,
}) async {
  final now = generatedAt ?? DateTime.now();
  final logo = await PdfReport.logo();
  pw.Widget heading(String title) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 10, bottom: 4),
    child: PdfReport.text(title, size: 10, bold: true),
  );

  final doc = pw.Document(
    compress: compress,
    title: 'Daily safety meeting',
    author: PdfReport.clean(organizationName),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(32),
      header: (context) => PdfReport.header(
        organizationName: organizationName,
        logo: logo,
        title: 'DAILY SAFETY MEETING (TOOLBOX TALK)',
        subtitle: '${report.siteName} - ${report.date}',
      ),
      footer: (context) => PdfReport.footer(context, now),
      build: (context) => [
        pw.Table(
          border: PdfReport.border,
          children: [
            pw.TableRow(
              children: [
                PdfReport.field('Site', report.siteName),
                PdfReport.field('Project', report.projectName),
                PdfReport.field('Date', report.date),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.field('Foreman', report.foremanName),
                PdfReport.field('Status', report.status),
                PdfReport.field('Crew result', report.crewResult),
              ],
            ),
          ],
        ),
        heading('WORK COVERED (ACTIVITIES)'),
        PdfReport.bullets(report.activities),
        heading('SAFETY POINTS DISCUSSED'),
        if (report.points.isEmpty)
          PdfReport.text('-')
        else
          for (final (point, note) in report.points)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: PdfReport.text('- $point${note == null ? '' : ': $note'}'),
            ),
        heading('RISK ASSESSMENTS (AHA) COVERED WITH THE CREW'),
        PdfReport.bullets(report.ahasCovered),
        heading('ATTENDANCE'),
        pw.Table(
          border: PdfReport.border,
          columnWidths: const {
            0: pw.FixedColumnWidth(24),
            1: pw.FlexColumnWidth(3),
            2: pw.FlexColumnWidth(1.6),
            3: pw.FlexColumnWidth(2),
          },
          children: [
            pw.TableRow(
              repeat: true,
              children: [
                PdfReport.headCell('#'),
                PdfReport.headCell('Name'),
                PdfReport.headCell('Attendance'),
                PdfReport.headCell('Signature'),
              ],
            ),
            for (var i = 0; i < report.attendance.length; i++)
              pw.TableRow(
                children: [
                  PdfReport.cell(PdfReport.text('${i + 1}')),
                  PdfReport.cell(PdfReport.text(report.attendance[i].$1)),
                  PdfReport.cell(PdfReport.text(report.attendance[i].$2)),
                  pw.SizedBox(height: 20),
                ],
              ),
          ],
        ),
        heading('CONCERNS RAISED'),
        PdfReport.bullets(report.concerns),
        heading('CORRECTIVE ACTIONS'),
        PdfReport.bullets(report.correctiveActions),
        pw.SizedBox(height: 22),
        PdfReport.signatureLine('Foreman', report.foremanName),
      ],
    ),
  );
  return doc.save();
}
