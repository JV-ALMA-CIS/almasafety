import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Prints a document (or saves it as PDF): [name] is the file name, and
/// [build] makes the PDF for the chosen page format.
typedef ReportPrinter =
    Future<void> Function({
      required String name,
      required Future<Uint8List> Function(PdfPageFormat format) build,
    });

/// Shared building blocks for the app's printable reports (AHA, Deficiency
/// Log, …): the company header, the page footer, bordered tables, and text
/// clean-up — so every report looks the same.
///
/// The PDF uses the built-in Helvetica font (nothing to download, works
/// offline). It covers Latin-1 only, so [clean] turns typographic characters
/// (long dashes, curly quotes, ×, →, bullets) into plain equivalents and
/// drops anything else it cannot draw.
class PdfReport {
  PdfReport._();

  static const ink = PdfColor.fromInt(0xFF12222E);
  static const muted = PdfColor.fromInt(0xFF51636E);
  static const rule = PdfColor.fromInt(0xFF9AA8B2);
  static const shade = PdfColor.fromInt(0xFFE8EEF2);
  static const brand = PdfColor.fromInt(0xFF0B4F6C);
  static const red = PdfColor.fromInt(0xFFC81E1E);
  static const green = PdfColor.fromInt(0xFF0E7C5A);

  static const _replacements = {
    '—': '-', // em dash
    '–': '-', // en dash
    '−': '-',
    '‘': "'",
    '’': "'",
    '“': '"',
    '”': '"',
    '…': '...',
    '×': 'x',
    '→': '->',
    '•': '-',
    '≤': '<=',
    '≥': '>=',
    ' ': ' ',
    '✓': 'v',
    '✕': 'x',
  };

  /// [text] made safe for the built-in font.
  static String clean(String? text) {
    if (text == null) return '';
    final out = StringBuffer();
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      final replacement = _replacements[char];
      if (replacement != null) {
        out.write(replacement);
      } else if (rune == 0x0A || (rune >= 0x20 && rune <= 0xFF)) {
        out.write(char);
      }
    }
    return out.toString();
  }

  /// "2026-10-15" for [date], or "-".
  static String date(DateTime? date) {
    if (date == null) return '-';
    final local = date.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  static pw.TextStyle style({
    double size = 9,
    bool bold = false,
    PdfColor color = ink,
  }) => pw.TextStyle(
    fontSize: size,
    fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    color: color,
  );

  /// Cleaned text.
  static pw.Widget text(
    String? value, {
    double size = 9,
    bool bold = false,
    PdfColor color = ink,
  }) => pw.Text(
    clean(value),
    style: style(size: size, bold: bold, color: color),
  );

  /// A bulleted list, or "-" when empty.
  static pw.Widget bullets(List<String> lines, {double size = 9}) {
    if (lines.isEmpty) return text('-', size: size);
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('- ', style: style(size: size)),
                pw.Expanded(child: text(line, size: size)),
              ],
            ),
          ),
      ],
    );
  }

  static pw.MemoryImage? _logo;

  /// The company logo (assets/images/almacis_logo.jpg), loaded once; null if
  /// it cannot be loaded, in which case the header shows the name instead.
  static Future<pw.MemoryImage?> logo() async {
    if (_logo != null) return _logo;
    try {
      final data = await rootBundle.load('assets/images/almacis_logo.jpg');
      return _logo = pw.MemoryImage(data.buffer.asUint8List());
    } on Object {
      return null;
    }
  }

  /// The heading on every page: the company logo (or its name), the report
  /// title, and a subtitle line.
  static pw.Widget header({
    required String organizationName,
    required String title,
    String? subtitle,
    pw.ImageProvider? logo,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      margin: const pw.EdgeInsets.only(bottom: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: brand, width: 1.5)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          if (logo != null) ...[
            pw.Image(logo, height: 30),
            pw.SizedBox(width: 12),
          ],
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (logo == null)
                  text(organizationName, size: 9, bold: true, color: brand),
                text(title, size: 15, bold: true),
                if (subtitle != null) text(subtitle, size: 9, color: muted),
              ],
            ),
          ),
          text('JVA Safety', size: 8, color: muted),
        ],
      ),
    );
  }

  /// "Generated … · Page x of y" at the foot of every page.
  static pw.Widget footer(pw.Context context, DateTime generatedAt) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 6),
      child: pw.Row(
        children: [
          pw.Expanded(
            child: text(
              'Generated ${date(generatedAt)} from the JVA Safety app — '
              'the app holds the live record.',
              size: 7,
              color: muted,
            ),
          ),
          text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            size: 7,
            color: muted,
          ),
        ],
      ),
    );
  }

  /// A labelled cell for a details grid: small grey label, value below.
  static pw.Widget field(String label, String? value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(4),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          text(label, size: 7, color: muted),
          text(value == null || value.isEmpty ? '-' : value, size: 9),
        ],
      ),
    );
  }

  /// "Role: Name ____ Signature ____ Date ____" for signing on paper.
  static pw.Widget signatureLine(String role, String? name, {DateTime? on}) {
    pw.Widget blank(double width) => pw.Container(
      width: width,
      height: 0.6,
      color: rule,
      margin: const pw.EdgeInsets.only(left: 4, right: 12),
    );
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        text('$role: ', size: 8, color: muted),
        text(name ?? '', size: 9, bold: true),
        pw.SizedBox(width: 16),
        text('Signature', size: 8, color: muted),
        blank(140),
        text('Date', size: 8, color: muted),
        if (on != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 4),
            child: text(date(on), size: 9),
          )
        else
          blank(70),
      ],
    );
  }

  /// A table heading cell.
  static pw.Widget headCell(String label) => pw.Container(
    color: shade,
    padding: const pw.EdgeInsets.all(4),
    child: text(label, size: 8, bold: true),
  );

  /// A table body cell.
  static pw.Widget cell(pw.Widget child) =>
      pw.Padding(padding: const pw.EdgeInsets.all(4), child: child);

  static pw.TableBorder get border =>
      pw.TableBorder.all(color: rule, width: 0.6);

  /// Opens the device's print window (print, or save as PDF; the share sheet
  /// on phones) for the document [build] makes.
  static Future<void> printDocument({
    required String name,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  }) {
    return Printing.layoutPdf(name: name, onLayout: build);
  }
}
