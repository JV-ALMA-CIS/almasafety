import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/reports/pdf_report.dart';
import '../domain/man_hours.dart';

/// One site's line on the printed man-hours report.
class ManHoursPdfLine {
  const ManHoursPdfLine({
    required this.site,
    required this.workers,
    required this.hours,
    required this.lostTime,
    required this.recordable,
    this.enteredBy,
  });

  final String site;

  /// Null when the site has not been entered.
  final int? workers;
  final double? hours;
  final int lostTime;
  final int recordable;
  final String? enteredBy;
}

/// A month's man-hours as a printable report for the Safety Office (Safety
/// Plan 8a): every site's workers and man-hours, its lost-time and
/// recordable incidents, the totals, and who reported it.
Future<Uint8List> buildManHoursPdf({
  required String month,
  required String organizationName,
  required List<ManHoursPdfLine> lines,
  String? reportedBy,
  DateTime? reportedAt,
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? generatedAt,

  /// Off in tests, so the text can be read back.
  bool compress = true,
}) async {
  final now = generatedAt ?? DateTime.now();
  final logo = await PdfReport.logo();
  String hours(double? h) => h == null
      ? 'NOT ENTERED'
      : h == h.roundToDouble()
      ? h.toStringAsFixed(0)
      : h.toStringAsFixed(1);
  final totalHours = lines.fold<double>(0, (s, l) => s + (l.hours ?? 0));
  final totalWorkers = lines.fold<int>(0, (s, l) => s + (l.workers ?? 0));
  final totalLost = lines.fold<int>(0, (s, l) => s + l.lostTime);
  final totalRecordable = lines.fold<int>(0, (s, l) => s + l.recordable);
  final missing = lines.where((l) => l.hours == null).length;

  final doc = pw.Document(
    compress: compress,
    title: 'Man-hours ${monthLabel(month)}',
    author: PdfReport.clean(organizationName),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(32),
      header: (context) => PdfReport.header(
        organizationName: organizationName,
        logo: logo,
        title: 'MONTHLY MAN-HOURS REPORT',
        subtitle:
            '${monthLabel(month)} - Safety Plan 8a - due '
            '${PdfReport.date(manHoursDueDate(month))}',
      ),
      footer: (context) => PdfReport.footer(context, now),
      build: (context) => [
        pw.Table(
          border: PdfReport.border,
          columnWidths: const {
            0: pw.FlexColumnWidth(3),
            1: pw.FlexColumnWidth(1.2),
            2: pw.FlexColumnWidth(1.4),
            3: pw.FlexColumnWidth(1.4),
            4: pw.FlexColumnWidth(1.4),
            5: pw.FlexColumnWidth(2),
          },
          children: [
            pw.TableRow(
              repeat: true,
              children: [
                PdfReport.headCell('Site'),
                PdfReport.headCell('Workers'),
                PdfReport.headCell('Man-hours'),
                PdfReport.headCell('Lost-time incidents'),
                PdfReport.headCell('Recordable incidents'),
                PdfReport.headCell('Entered by'),
              ],
            ),
            for (final line in lines)
              pw.TableRow(
                children: [
                  PdfReport.cell(PdfReport.text(line.site)),
                  PdfReport.cell(PdfReport.text('${line.workers ?? '-'}')),
                  PdfReport.cell(
                    PdfReport.text(
                      hours(line.hours),
                      bold: line.hours == null,
                      color: line.hours == null ? PdfReport.red : PdfReport.ink,
                    ),
                  ),
                  PdfReport.cell(PdfReport.text('${line.lostTime}')),
                  PdfReport.cell(PdfReport.text('${line.recordable}')),
                  PdfReport.cell(PdfReport.text(line.enteredBy ?? '-')),
                ],
              ),
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfReport.shade),
              children: [
                PdfReport.cell(PdfReport.text('TOTAL', bold: true)),
                PdfReport.cell(PdfReport.text('$totalWorkers', bold: true)),
                PdfReport.cell(PdfReport.text(hours(totalHours), bold: true)),
                PdfReport.cell(PdfReport.text('$totalLost', bold: true)),
                PdfReport.cell(PdfReport.text('$totalRecordable', bold: true)),
                pw.SizedBox(),
              ],
            ),
          ],
        ),
        if (missing > 0) ...[
          pw.SizedBox(height: 6),
          PdfReport.text(
            '$missing site${missing == 1 ? '' : 's'} not entered yet.',
            color: PdfReport.red,
            bold: true,
          ),
        ],
        pw.SizedBox(height: 6),
        PdfReport.text(
          'Lost-time incidents: reporting level "immediate" or "lost time". '
          'Recordable: those plus "medical treatment".',
          size: 7,
          color: PdfReport.muted,
        ),
        pw.SizedBox(height: 22),
        PdfReport.signatureLine(
          'Reported to the Safety Office by',
          reportedBy,
          on: reportedAt,
        ),
      ],
    ),
  );
  return doc.save();
}
