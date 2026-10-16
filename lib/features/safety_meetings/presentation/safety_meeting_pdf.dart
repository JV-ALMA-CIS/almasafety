import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/reports/pdf_report.dart';
import '../domain/safety_meeting.dart';

/// A weekly employee or monthly supervisory safety meeting as a printable
/// record — the Safety Plan's "documented with the facilitator, attendees,
/// date and subjects": the details, every subject covered, the attendance
/// list with a signature column (for signing on paper), concerns, notes and
/// the facilitator's sign-off.
Future<Uint8List> buildSafetyMeetingPdf({
  required SafetyMeeting meeting,
  required String organizationName,
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? generatedAt,

  /// Off in tests, so the text can be read back.
  bool compress = true,
}) async {
  final now = generatedAt ?? DateTime.now();
  final logo = await PdfReport.logo();
  final attendees = [
    for (final uid in meeting.attendeeUids)
      meeting.attendeeNames[uid] ?? 'Unknown person',
  ]..sort();
  final everyone = [
    for (final name in attendees) (name, ''),
    for (final name in meeting.otherAttendees) (name, 'No account'),
  ];
  final doc = pw.Document(
    compress: compress,
    title: PdfReport.clean(meeting.kind.label),
    author: PdfReport.clean(organizationName),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(32),
      header: (context) => PdfReport.header(
        organizationName: organizationName,
        logo: logo,
        title: meeting.kind.label.toUpperCase(),
        subtitle:
            '${meeting.date} - ${meeting.siteName ?? 'All sites'} - '
            '${meeting.kind.schedule}',
      ),
      footer: (context) => PdfReport.footer(context, now),
      build: (context) => [
        pw.Table(
          border: PdfReport.border,
          children: [
            pw.TableRow(
              children: [
                PdfReport.field('Meeting', meeting.kind.label),
                PdfReport.field('Date', meeting.date),
                PdfReport.field('Site', meeting.siteName ?? 'All sites'),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.field('Facilitator', meeting.facilitatorName),
                PdfReport.field('Attended', '${meeting.attendeeCount}'),
                PdfReport.field('For', meeting.kind.audience),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 12),
        PdfReport.text('SUBJECTS COVERED', size: 10, bold: true),
        pw.SizedBox(height: 4),
        for (var i = 0; i < meeting.topics.length; i++)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: PdfReport.text('${i + 1}. ${meeting.topics[i]}'),
          ),
        pw.SizedBox(height: 12),
        PdfReport.text('ATTENDANCE', size: 10, bold: true),
        pw.SizedBox(height: 4),
        pw.Table(
          border: PdfReport.border,
          columnWidths: const {
            0: pw.FixedColumnWidth(24),
            1: pw.FlexColumnWidth(3),
            2: pw.FlexColumnWidth(1.4),
            3: pw.FlexColumnWidth(2),
          },
          children: [
            pw.TableRow(
              repeat: true,
              children: [
                PdfReport.headCell('#'),
                PdfReport.headCell('Name'),
                PdfReport.headCell('Note'),
                PdfReport.headCell('Signature'),
              ],
            ),
            for (var i = 0; i < everyone.length; i++)
              pw.TableRow(
                children: [
                  PdfReport.cell(PdfReport.text('${i + 1}')),
                  PdfReport.cell(PdfReport.text(everyone[i].$1)),
                  PdfReport.cell(
                    PdfReport.text(everyone[i].$2, color: PdfReport.muted),
                  ),
                  pw.SizedBox(height: 20),
                ],
              ),
          ],
        ),
        if (meeting.concerns.isNotEmpty) ...[
          pw.SizedBox(height: 12),
          PdfReport.text('CONCERNS RAISED', size: 10, bold: true),
          pw.SizedBox(height: 4),
          PdfReport.bullets(meeting.concerns),
        ],
        if (meeting.notes != null) ...[
          pw.SizedBox(height: 12),
          PdfReport.text('NOTES', size: 10, bold: true),
          pw.SizedBox(height: 4),
          PdfReport.text(meeting.notes),
        ],
        pw.SizedBox(height: 18),
        PdfReport.signatureLine('Facilitator', meeting.facilitatorName),
      ],
    ),
  );
  return doc.save();
}
