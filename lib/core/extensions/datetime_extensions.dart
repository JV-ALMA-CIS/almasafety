/// Formatting helpers for dates used in safety records (meetings, audits).
extension DateTimeX on DateTime {
  String get toDisplayDate =>
      '${day.toString().padLeft(2, '0')}/${month.toString().padLeft(2, '0')}/$year';

  String get toDisplayDateTime =>
      '$toDisplayDate ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
