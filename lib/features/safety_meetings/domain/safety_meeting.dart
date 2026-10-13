import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';

/// Which of the Safety Plan's regular meetings this is (Sections 4 and 6) —
/// matching `functions/src/safety_meeting_callable.ts`'s
/// `SAFETY_MEETING_KINDS`. The Foreman's daily toolbox talk is NOT one of
/// these: it is the separate Daily Safety Meeting.
enum SafetyMeetingKind {
  weeklyEmployee,
  monthlySupervisory;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    SafetyMeetingKind.weeklyEmployee => 'Weekly employee safety meeting',
    SafetyMeetingKind.monthlySupervisory => 'Monthly supervisory meeting',
  };

  /// When the Safety Plan schedules it.
  String get schedule => switch (this) {
    SafetyMeetingKind.weeklyEmployee => 'Every Thursday, 08:00',
    SafetyMeetingKind.monthlySupervisory => 'One Thursday a month, 08:30',
  };

  /// Who it is for.
  String get audience => switch (this) {
    SafetyMeetingKind.weeklyEmployee => 'All employees on the site',
    SafetyMeetingKind.monthlySupervisory =>
      'Foremen, Site Managers and the Safety Manager',
  };

  /// The subjects offered as a checklist when recording the meeting — the
  /// Safety Plan's Section 6a safety checklist for the weekly meeting; a
  /// review of the month's safety record for the supervisory one. Any other
  /// subject can be added on the form.
  List<String> get defaultTopics => switch (this) {
    SafetyMeetingKind.weeklyEmployee => const [
      'PPE: wearing it, its condition, replacing damaged items',
      'Emergency numbers and AAR Healthcare contact details',
      'First aid: where the kit is and who the first-aiders are',
      'Fire extinguishers: where they are and how to use them',
      'Emergency and evacuation plan, assembly point',
      'Reporting accidents, near-misses and hazards straight away',
      'Working at height and fall protection',
      'Tools, cords and machinery: daily checks, tag out anything faulty',
      'Housekeeping, access routes and waste',
      "This week's hazards, incidents and lessons learned",
      "Next week's work and its hazards",
    ],
    SafetyMeetingKind.monthlySupervisory => const [
      "The month's incidents, near-misses and hazards",
      'Open deficiencies and overdue corrective actions',
      'Inspection and HSE walk-down findings',
      'Activity hazard analyses for upcoming work',
      'Daily safety meetings and Pre-Start Checks: are they happening?',
      'Training and competence needs',
      'PPE and first-aid supplies',
      'Emergency preparedness: drills, extinguishers, contacts',
      'Subcontractor safety performance',
    ],
  };

  static SafetyMeetingKind? tryFromId(String? id) {
    for (final value in values) {
      if (value.id == id) return value;
    }
    return null;
  }
}

/// A weekly employee or monthly supervisory safety meeting, stored at
/// `organizations/{organizationId}/safety_meetings/{id}`. Recorded once,
/// after the meeting, by `recordSafetyMeeting` and never changed — the
/// Safety Plan's record of facilitator, attendees, date and subjects.
/// Read-only client-side.
class SafetyMeeting {
  const SafetyMeeting({
    required this.id,
    required this.organizationId,
    required this.kind,
    required this.date,
    required this.facilitatorUid,
    this.siteId,
    this.siteName,
    this.topics = const [],
    this.attendeeUids = const [],
    this.attendeeNames = const {},
    this.otherAttendees = const [],
    this.concerns = const [],
    this.notes,
    this.facilitatorName,
    this.createdAt,
  });

  final String id;
  final String organizationId;
  final SafetyMeetingKind kind;

  /// The day the meeting was held, `yyyy-MM-dd`.
  final String date;

  /// Null for a monthly supervisory meeting covering every site.
  final String? siteId;
  final String? siteName;
  final List<String> topics;
  final List<String> attendeeUids;

  /// uid → name, stored when the meeting was recorded.
  final Map<String, String> attendeeNames;

  /// People without an account (visitors, subcontractors), by name.
  final List<String> otherAttendees;
  final List<String> concerns;
  final String? notes;
  final String facilitatorUid;
  final String? facilitatorName;
  final DateTime? createdAt;

  int get attendeeCount => attendeeUids.length + otherAttendees.length;

  /// [date] as a local calendar date, or null if it is malformed.
  DateTime? get day => DateTime.tryParse(date);

  factory SafetyMeeting.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That safety meeting could not be loaded.');
    }
    return SafetyMeeting.fromMap(doc.id, data);
  }

  factory SafetyMeeting.fromMap(String id, Map<String, dynamic> data) {
    final kind = SafetyMeetingKind.tryFromId(data['kind'] as String?);
    if (kind == null) {
      throw const DataException('That safety meeting has an unknown type.');
    }
    List<String> strings(Object? raw) =>
        (raw as List<dynamic>?)?.whereType<String>().toList() ?? const [];
    final names = data['attendeeNames'];
    return SafetyMeeting(
      id: id,
      organizationId: data['organizationId'] as String? ?? '',
      kind: kind,
      date: data['date'] as String? ?? '',
      siteId: data['siteId'] as String?,
      siteName: data['siteName'] as String?,
      topics: strings(data['topics']),
      attendeeUids: strings(data['attendeeUids']),
      attendeeNames: names is Map
          ? {
              for (final entry in names.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            }
          : const {},
      otherAttendees: strings(data['otherAttendees']),
      concerns: strings(data['concerns']),
      notes: data['notes'] as String?,
      facilitatorUid: data['facilitatorUid'] as String? ?? '',
      facilitatorName: data['facilitatorName'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// `yyyy-MM-dd` for [date]'s calendar day.
String meetingDateId(DateTime date) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}

/// Whether [meeting] took place in the same Monday–Sunday week as [now]
/// (weekly) or the same calendar month (monthly) — i.e. it counts for the
/// current period of its kind.
bool isInCurrentPeriod(SafetyMeeting meeting, DateTime now) {
  final day = meeting.day;
  if (day == null) return false;
  switch (meeting.kind) {
    case SafetyMeetingKind.weeklyEmployee:
      final today = DateTime(now.year, now.month, now.day);
      final monday = today.subtract(Duration(days: today.weekday - 1));
      final nextMonday = monday.add(const Duration(days: 7));
      return !day.isBefore(monday) && day.isBefore(nextMonday);
    case SafetyMeetingKind.monthlySupervisory:
      return day.year == now.year && day.month == now.month;
  }
}
