import 'package:cloud_firestore/cloud_firestore.dart';

/// How serious an incident is for REPORTING — the Safety Plan's Section 8.
/// Decides which reporting steps it needs and their deadlines; matches
/// `functions/src/incident_reporting.ts`'s `REPORTING_LEVELS`.
enum IncidentReportingLevel {
  immediate,
  lostTime,
  medical,
  minorDamage,
  firstAid;

  String get id => name;

  String get label => switch (this) {
    IncidentReportingLevel.immediate => 'Immediate notification',
    IncidentReportingLevel.lostTime => 'Lost time or major damage',
    IncidentReportingLevel.medical => 'Medical treatment, no lost time',
    IncidentReportingLevel.minorDamage => 'Minor property damage',
    IncidentReportingLevel.firstAid => 'First aid only / no damage',
  };

  /// When this level applies, in the plan's terms.
  String get description => switch (this) {
    IncidentReportingLevel.immediate =>
      'Fatality, permanent disability, 3 or more people admitted to '
          'hospital, or damage of \$200,000 or more. Phone at once and seal '
          'off the site.',
    IncidentReportingLevel.lostTime =>
      'Time off work beyond the day or shift it happened, or damage of '
          '\$2,000 – \$200,000. 24-hour notice; ENG Form 3394 within 5 days.',
    IncidentReportingLevel.medical =>
      'Medical treatment but no time off work. 24-hour notice and an email '
          'record within 24 hours.',
    IncidentReportingLevel.minorDamage =>
      'Property damage under \$2,000. Email record within 24 hours.',
    IncidentReportingLevel.firstAid =>
      'First aid only, or nobody hurt and nothing damaged. Tell the COR.',
  };

  static IncidentReportingLevel? tryFromId(String? id) {
    for (final value in values) {
      if (value.id == id) return value;
    }
    return null;
  }
}

/// One reporting step an incident needs, with its deadline and, once done,
/// who did it and when.
class ReportingStep {
  const ReportingStep({
    required this.id,
    required this.label,
    required this.dueAt,
    this.doneAt,
    this.doneByName,
    this.note,
  });

  final String id;
  final String label;
  final DateTime dueAt;
  final DateTime? doneAt;
  final String? doneByName;

  /// e.g. a reference number or who was told.
  final String? note;

  bool get isDone => doneAt != null;
  bool isOverdue(DateTime now) => !isDone && now.isAfter(dueAt);

  /// Not done, and due within [within] (but not yet overdue).
  bool isDueSoon(DateTime now, {Duration within = const Duration(hours: 24)}) =>
      !isDone && !isOverdue(now) && dueAt.difference(now) <= within;

  static ReportingStep? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final dueAt = raw['dueAt'];
    if (id is! String || dueAt is! Timestamp) return null;
    return ReportingStep(
      id: id,
      label: raw['label'] as String? ?? id,
      dueAt: dueAt.toDate(),
      doneAt: (raw['doneAt'] as Timestamp?)?.toDate(),
      doneByName: raw['doneByName'] as String?,
      note: raw['note'] as String?,
    );
  }
}

/// "in 5 h", "in 2 days", "3 h ago" — how far [time] is from [now].
String relativeTime(DateTime time, DateTime now) {
  final diff = time.difference(now);
  final past = diff.isNegative;
  final d = diff.abs();
  final String amount;
  if (d.inMinutes < 60) {
    amount = '${d.inMinutes} min';
  } else if (d.inHours < 48) {
    amount = '${d.inHours} h';
  } else {
    amount = '${d.inDays} days';
  }
  return past ? '$amount ago' : 'in $amount';
}
