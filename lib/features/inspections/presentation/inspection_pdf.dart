import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/reports/pdf_report.dart';
import '../domain/inspection.dart';

/// An inspection as a printable report: who inspected which site with which
/// checklist and when; the score; every deficiency ("Not OK") with its note;
/// the whole checklist with each answer, by section; and the sign-off.
/// Photos stay in the app (the report says which items have one).
Future<Uint8List> buildInspectionPdf({
  required Inspection inspection,
  required String organizationName,
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? generatedAt,

  /// Off in tests, so the text can be read back.
  bool compress = true,
}) async {
  final now = generatedAt ?? DateTime.now();
  final logo = await PdfReport.logo();
  final deficiencies = [
    for (final item in inspection.items)
      if (item.result == InspectionResult.notOk) item,
  ];
  final sections = <String, List<InspectionItem>>{};
  for (final item in inspection.items) {
    sections.putIfAbsent(item.section, () => []).add(item);
  }
  String answer(InspectionResult? result) => switch (result) {
    InspectionResult.ok => 'OK',
    InspectionResult.notOk => 'NOT OK',
    InspectionResult.na => 'N/A',
    null => '-',
  };
  final status = switch (inspection.status) {
    InspectionStatus.inProgress => 'In progress - not submitted',
    InspectionStatus.submitted => 'Submitted - awaiting sign-off',
    InspectionStatus.signedOff => 'Signed off',
  };

  final doc = pw.Document(
    compress: compress,
    title: PdfReport.clean(inspection.templateName),
    author: PdfReport.clean(organizationName),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(32),
      header: (context) => PdfReport.header(
        organizationName: organizationName,
        logo: logo,
        title: '${inspection.templateName} report'.toUpperCase(),
        subtitle:
            '${inspection.siteName ?? 'Site'} - '
            '${PdfReport.date(inspection.submittedAt ?? inspection.startedAt)}',
      ),
      footer: (context) => PdfReport.footer(context, now),
      build: (context) => [
        pw.Table(
          border: PdfReport.border,
          children: [
            pw.TableRow(
              children: [
                PdfReport.field('Checklist', inspection.templateName),
                PdfReport.field('Site', inspection.siteName),
                PdfReport.field('Inspector', inspection.inspectorName),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.field(
                  'Started',
                  PdfReport.date(inspection.startedAt),
                ),
                PdfReport.field(
                  'Submitted',
                  PdfReport.date(inspection.submittedAt),
                ),
                PdfReport.field('Status', status),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.field(
                  'Result',
                  '${inspection.okCount} OK - ${inspection.notOkCount} Not '
                      'OK - ${inspection.naCount} N/A',
                ),
                PdfReport.field('Signed off by', inspection.signedOffByName),
                PdfReport.field(
                  'Signed off',
                  PdfReport.date(inspection.signedOffAt),
                ),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 10),
        PdfReport.text(
          'DEFICIENCIES (${deficiencies.length})',
          size: 10,
          bold: true,
          color: deficiencies.isEmpty ? PdfReport.green : PdfReport.red,
        ),
        pw.SizedBox(height: 4),
        if (deficiencies.isEmpty)
          PdfReport.text('None - every item was OK or not applicable.')
        else
          for (final item in deficiencies)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: PdfReport.text(
                '- ${item.text}: ${item.note ?? 'no note'}'
                '${item.photoUrl == null ? '' : ' (photo in the app)'}',
              ),
            ),
        if (deficiencies.isNotEmpty)
          PdfReport.text(
            'Each deficiency is tracked to closure in the Deficiency Log.',
            size: 7,
            color: PdfReport.muted,
          ),
        pw.SizedBox(height: 10),
        PdfReport.text('CHECKLIST', size: 10, bold: true),
        pw.SizedBox(height: 4),
        pw.Table(
          border: PdfReport.border,
          columnWidths: const {
            0: pw.FixedColumnWidth(22),
            1: pw.FlexColumnWidth(4),
            2: pw.FixedColumnWidth(48),
            3: pw.FlexColumnWidth(2.4),
          },
          children: [
            pw.TableRow(
              repeat: true,
              children: [
                PdfReport.headCell('#'),
                PdfReport.headCell('Item'),
                PdfReport.headCell('Result'),
                PdfReport.headCell('Note'),
              ],
            ),
            for (final entry in sections.entries) ...[
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfReport.shade),
                children: [
                  pw.SizedBox(),
                  PdfReport.cell(PdfReport.text(entry.key, bold: true)),
                  pw.SizedBox(),
                  pw.SizedBox(),
                ],
              ),
              for (var i = 0; i < entry.value.length; i++)
                pw.TableRow(
                  children: [
                    PdfReport.cell(PdfReport.text('${i + 1}')),
                    PdfReport.cell(PdfReport.text(entry.value[i].text)),
                    PdfReport.cell(
                      PdfReport.text(
                        answer(entry.value[i].result),
                        bold: true,
                        color: entry.value[i].result == InspectionResult.notOk
                            ? PdfReport.red
                            : PdfReport.ink,
                      ),
                    ),
                    PdfReport.cell(PdfReport.text(entry.value[i].note ?? '')),
                  ],
                ),
            ],
          ],
        ),
        if (inspection.signOffNote != null) ...[
          pw.SizedBox(height: 8),
          PdfReport.text('Sign-off note: ${inspection.signOffNote}'),
        ],
        pw.SizedBox(height: 22),
        PdfReport.signatureLine('Inspector', inspection.inspectorName),
        pw.SizedBox(height: 14),
        PdfReport.signatureLine(
          'Signed off by',
          inspection.signedOffByName,
          on: inspection.signedOffAt,
        ),
      ],
    ),
  );
  return doc.save();
}
