import 'package:flutter/material.dart';
import '../theme/app_spacing.dart';

/// The "Print / PDF" button on a record's page. [onPrint] prepares the PDF
/// and opens the print window; while it runs the button shows a spinner,
/// and if it fails a short message says so.
class PrintReportButton extends StatefulWidget {
  const PrintReportButton({super.key, required this.onPrint});

  final Future<void> Function() onPrint;

  @override
  State<PrintReportButton> createState() => _PrintReportButtonState();
}

class _PrintReportButtonState extends State<PrintReportButton> {
  bool _busy = false;

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      await widget.onPrint();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not prepare the PDF. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.minTouchTarget),
        ),
        onPressed: _busy ? null : _print,
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.print),
        label: const Text('Print / PDF'),
      ),
    );
  }
}
