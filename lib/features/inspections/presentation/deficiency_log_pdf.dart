import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/reports/pdf_report.dart';

/// One line of the printed Deficiency Log.
class DeficiencyLogLine {
  const DeficiencyLogLine({
    required this.identified,
    required this.site,
    required this.description,
    required this.foundIn,
    required this.responsible,
    required this.targetDate,
    required this.resolved,
    required this.status,
    required this.isOpen,
  });

  final DateTime? identified;
  final String site;
  final String description;
  final String? foundIn;
  final String responsible;
  final DateTime? targetDate;
  final DateTime? resolved;
  final String status;
  final bool isOpen;
}

/// The Safety Plan's DEFICIENCY LOG (Section 7c) as a printable PDF: for
/// each deficiency the date identified, description, person responsible,
/// projected resolution date and date actually resolved — plus its site,
/// the inspection it was found in, and where it stands now.
Future<Uint8List> buildDeficiencyLogPdf({
  required List<DeficiencyLogLine> lines,
  required String organizationName,
  required String scope,
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? generatedAt,

  /// Off in tests, so the text can be read back.
  bool compress = true,
}) async {
  final now = generatedAt ?? DateTime.now();
  final logo = await PdfReport.logo();
  final open = lines.where((l) => l.isOpen).length;
  final doc = pw.Document(
    compress: compress,
    title: 'Deficiency Log',
    author: PdfReport.clean(organizationName),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: format.landscape,
      margin: const pw.EdgeInsets.all(28),
      header: (context) => PdfReport.header(
        organizationName: organizationName,
        logo: logo,
        title: 'DEFICIENCY LOG',
        subtitle:
            '$scope - ${lines.length} deficienc'
            '${lines.length == 1 ? 'y' : 'ies'}, $open open',
      ),
      footer: (context) => PdfReport.footer(context, now),
      build: (context) => [
        if (lines.isEmpty)
          PdfReport.text('No deficiencies to show.')
        else
          pw.Table(
            border: PdfReport.border,
            columnWidths: const {
              0: pw.FixedColumnWidth(22),
              1: pw.FixedColumnWidth(60),
              2: pw.FlexColumnWidth(1.1),
              3: pw.FlexColumnWidth(3),
              4: pw.FlexColumnWidth(1.3),
              5: pw.FlexColumnWidth(1.3),
              6: pw.FixedColumnWidth(60),
              7: pw.FixedColumnWidth(60),
              8: pw.FlexColumnWidth(1.1),
            },
            children: [
              pw.TableRow(
                repeat: true,
                children: [
                  PdfReport.headCell('#'),
                  PdfReport.headCell('Date identified'),
                  PdfReport.headCell('Site'),
                  PdfReport.headCell('Description'),
                  PdfReport.headCell('Found in'),
                  PdfReport.headCell('Person responsible'),
                  PdfReport.headCell('Target date'),
                  PdfReport.headCell('Date resolved'),
                  PdfReport.headCell('Status'),
                ],
              ),
              for (var i = 0; i < lines.length; i++)
                pw.TableRow(
                  children: [
                    PdfReport.cell(PdfReport.text('${i + 1}')),
                    PdfReport.cell(
                      PdfReport.text(PdfReport.date(lines[i].identified)),
                    ),
                    PdfReport.cell(PdfReport.text(lines[i].site)),
                    PdfReport.cell(PdfReport.text(lines[i].description)),
                    PdfReport.cell(PdfReport.text(lines[i].foundIn ?? '-')),
                    PdfReport.cell(PdfReport.text(lines[i].responsible)),
                    PdfReport.cell(
                      PdfReport.text(PdfReport.date(lines[i].targetDate)),
                    ),
                    PdfReport.cell(
                      PdfReport.text(PdfReport.date(lines[i].resolved)),
                    ),
                    PdfReport.cell(
                      PdfReport.text(
                        lines[i].status,
                        bold: true,
                        color: lines[i].isOpen
                            ? PdfReport.red
                            : PdfReport.green,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        pw.SizedBox(height: 8),
        PdfReport.text(
          'Each deficiency is tracked to closure in the app: its corrective '
          'action names the person responsible and target date, and approval '
          'of that action is the follow-up inspection confirming the fix.',
          size: 7,
          color: PdfReport.muted,
        ),
      ],
    ),
  );
  return doc.save();
}
