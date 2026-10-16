import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/reports/pdf_report.dart';
import '../domain/risk_assessment.dart';

/// An AHA as a printable PDF, laid out like the Safety Plan's form
/// (EM 385-1-1 Figure 1-2): the details block; principal steps beside their
/// potential safety/health hazards and recommended controls; equipment,
/// inspection and training requirements side by side; and the prepared /
/// accepted / COR block. A draft is marked DRAFT on every page.
Future<Uint8List> buildAhaPdf({
  required RiskAssessment aha,
  required String organizationName,
  List<String> activityNames = const [],
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? generatedAt,

  /// Off in tests, so the text can be read back.
  bool compress = true,
}) async {
  final now = generatedAt ?? DateTime.now();
  final logo = await PdfReport.logo();
  final isDraft = aha.status == RiskAssessmentStatus.draft;
  final status = switch (aha.status) {
    RiskAssessmentStatus.draft => 'DRAFT - not yet accepted',
    RiskAssessmentStatus.accepted => 'Accepted - in use',
    RiskAssessmentStatus.superseded => 'Superseded by a newer revision',
  };
  final doc = pw.Document(
    compress: compress,
    title: 'AHA - ${PdfReport.clean(aha.featureOfWork)}',
    author: PdfReport.clean(organizationName),
  );

  doc.addPage(
    pw.MultiPage(
      pageFormat: format.landscape,
      margin: const pw.EdgeInsets.all(28),
      header: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          PdfReport.header(
            organizationName: organizationName,
            logo: logo,
            title: 'ACTIVITY HAZARD ANALYSIS (AHA)',
            subtitle:
                '${aha.featureOfWork} - ${aha.siteName ?? 'Site'} - '
                'Revision ${aha.revision}',
          ),
          if (isDraft)
            pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 6),
              padding: const pw.EdgeInsets.all(4),
              color: const PdfColor.fromInt(0xFFFDECEC),
              child: PdfReport.text(
                'DRAFT - not yet accepted. Not for use on site.',
                bold: true,
                color: PdfReport.red,
              ),
            ),
        ],
      ),
      footer: (context) => PdfReport.footer(context, now),
      build: (context) => [
        // ---- Details ----
        pw.Table(
          border: PdfReport.border,
          columnWidths: const {
            0: pw.FlexColumnWidth(2),
            1: pw.FlexColumnWidth(2),
            2: pw.FlexColumnWidth(2),
            3: pw.FlexColumnWidth(1.4),
          },
          children: [
            pw.TableRow(
              children: [
                PdfReport.field('Feature of work', aha.featureOfWork),
                PdfReport.field('Site', aha.siteName),
                PdfReport.field('Location', aha.location),
                PdfReport.field('Contract No.', aha.contractNo),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.field('Activity', aha.activity),
                PdfReport.field(
                  'Activities covered',
                  aha.activityIds.isEmpty
                      ? 'All work at this site'
                      : activityNames.isEmpty
                      ? '${aha.activityIds.length} activities'
                      : activityNames.join(', '),
                ),
                PdfReport.field('Estimated start date', aha.estimatedStartDate),
                PdfReport.field('Status', status),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 10),

        // ---- Steps, hazards, controls ----
        pw.Table(
          border: PdfReport.border,
          columnWidths: const {
            0: pw.FlexColumnWidth(1.3),
            1: pw.FlexColumnWidth(1.6),
            2: pw.FlexColumnWidth(2.4),
          },
          children: [
            pw.TableRow(
              repeat: true,
              children: [
                PdfReport.headCell('PRINCIPAL STEPS'),
                PdfReport.headCell('POTENTIAL SAFETY / HEALTH HAZARDS'),
                PdfReport.headCell('RECOMMENDED CONTROLS'),
              ],
            ),
            for (var i = 0; i < aha.steps.length; i++)
              pw.TableRow(
                children: [
                  PdfReport.cell(
                    PdfReport.text(
                      '${i + 1}. ${aha.steps[i].step}',
                      bold: true,
                    ),
                  ),
                  PdfReport.cell(PdfReport.bullets(aha.steps[i].hazards)),
                  PdfReport.cell(PdfReport.bullets(aha.steps[i].controls)),
                ],
              ),
          ],
        ),
        pw.SizedBox(height: 10),

        // ---- Equipment, inspections, training ----
        pw.Table(
          border: PdfReport.border,
          columnWidths: const {
            0: pw.FlexColumnWidth(),
            1: pw.FlexColumnWidth(),
            2: pw.FlexColumnWidth(),
          },
          children: [
            pw.TableRow(
              children: [
                PdfReport.headCell('EQUIPMENT TO BE USED'),
                PdfReport.headCell('INSPECTION REQUIREMENTS'),
                PdfReport.headCell(
                  'TRAINING REQUIREMENTS (incl. hazard communication)',
                ),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.cell(PdfReport.bullets(aha.equipment)),
                PdfReport.cell(PdfReport.bullets(aha.inspectionRequirements)),
                PdfReport.cell(PdfReport.bullets(aha.trainingRequirements)),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 10),

        // ---- Sign-off ----
        pw.Table(
          border: PdfReport.border,
          columnWidths: const {
            0: pw.FlexColumnWidth(),
            1: pw.FlexColumnWidth(),
            2: pw.FlexColumnWidth(),
          },
          children: [
            pw.TableRow(
              children: [
                _signature(
                  'Prepared by (competent / qualified person)',
                  aha.preparedByName,
                  aha.updatedAt ?? aha.createdAt,
                ),
                _signature('Accepted by', aha.acceptedByName, aha.acceptedAt),
                _signature('Reviewed by COR', aha.corName, null),
              ],
            ),
          ],
        ),
        if (aha.acceptanceNote != null) ...[
          pw.SizedBox(height: 4),
          PdfReport.text('Acceptance note: ${aha.acceptanceNote}', size: 8),
        ],
        pw.SizedBox(height: 6),
        PdfReport.text(
          'This AHA will be reviewed and modified as necessary to address '
          'changing site conditions, operations, or change of competent / '
          'qualified person(s).',
          size: 7,
          color: PdfReport.muted,
        ),
      ],
    ),
  );
  return doc.save();
}

pw.Widget _signature(String label, String? name, DateTime? at) {
  return pw.Padding(
    padding: const pw.EdgeInsets.all(6),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        PdfReport.text(label, size: 7, color: PdfReport.muted),
        pw.SizedBox(height: 4),
        PdfReport.text(name ?? '', bold: true),
        pw.SizedBox(height: 14),
        pw.Row(
          children: [
            PdfReport.text('Signature: ', size: 7, color: PdfReport.muted),
            pw.Expanded(
              child: pw.Container(height: 0.6, color: PdfReport.rule),
            ),
            pw.SizedBox(width: 8),
            PdfReport.text(
              'Date: ${at == null ? '' : PdfReport.date(at)}',
              size: 7,
              color: PdfReport.muted,
            ),
          ],
        ),
      ],
    ),
  );
}
