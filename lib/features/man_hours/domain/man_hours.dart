import 'package:cloud_firestore/cloud_firestore.dart';

/// One site's man-hours for a month — the Safety Plan's Section 8a
/// (`organizations/{orgId}/man_hours/{siteId}_{yyyy-MM}`, written by
/// `saveManHours`).
class ManHoursEntry {
  const ManHoursEntry({
    required this.siteId,
    required this.month,
    required this.hours,
    required this.workers,
    this.siteName,
    this.notes,
    this.enteredByName,
    this.updatedAt,
  });

  final String siteId;
  final String? siteName;

  /// `yyyy-MM`.
  final String month;
  final double hours;
  final int workers;
  final String? notes;
  final String? enteredByName;
  final DateTime? updatedAt;

  factory ManHoursEntry.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    return ManHoursEntry(
      siteId: data['siteId'] as String? ?? '',
      siteName: data['siteName'] as String?,
      month: data['month'] as String? ?? '',
      hours: (data['hours'] as num?)?.toDouble() ?? 0,
      workers: (data['workers'] as num?)?.toInt() ?? 0,
      notes: data['notes'] as String?,
      enteredByName: data['enteredByName'] as String?,
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// A month as reported to the Safety Office (`man_hours_reports/{yyyy-MM}`,
/// written by `markManHoursReported`).
class ManHoursReport {
  const ManHoursReport({
    required this.month,
    this.reportedAt,
    this.reportedByName,
    this.totalHours = 0,
    this.sites = 0,
  });

  final String month;
  final DateTime? reportedAt;
  final String? reportedByName;
  final double totalHours;
  final int sites;

  factory ManHoursReport.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    return ManHoursReport(
      month: data['month'] as String? ?? doc.id,
      reportedAt: (data['reportedAt'] as Timestamp?)?.toDate(),
      reportedByName: data['reportedByName'] as String?,
      totalHours: (data['totalHours'] as num?)?.toDouble() ?? 0,
      sites: (data['sites'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `yyyy-MM` for [date].
String monthId(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}';

/// The month whose man-hours are being reported at [now] — last month
/// (reported by the 25th of this one).
String reportingMonth(DateTime now) =>
    monthId(DateTime(now.year, now.month - 1));

/// The [count] months up to and including last month, newest first.
List<String> recentMonths(DateTime now, {int count = 6}) => [
  for (var i = 1; i <= count; i++) monthId(DateTime(now.year, now.month - i)),
];

/// When [month]'s man-hours are due: the 25th of the following month.
DateTime manHoursDueDate(String month) {
  final parts = month.split('-');
  return DateTime(int.parse(parts[0]), int.parse(parts[1]) + 1, 25);
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "September 2026" for `2026-09`.
String monthLabel(String month) {
  final parts = month.split('-');
  if (parts.length != 2) return month;
  final m = int.tryParse(parts[1]) ?? 1;
  return '${_monthNames[(m - 1).clamp(0, 11)]} ${parts[0]}';
}

/// "25 Oct" for [date].
String shortDay(DateTime date) =>
    '${date.day} ${_monthNames[date.month - 1].substring(0, 3)}';
