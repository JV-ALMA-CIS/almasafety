import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/corrective_actions/domain/corrective_action.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/daily_safety_meeting.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/meeting_attendance.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/meeting_concern.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/meeting_foreman_point.dart';
import 'package:jva_safety/features/daily_safety_meetings/presentation/daily_meeting_pdf.dart';

/// The PDF's text runs, readable when built with `compress: false` — the
/// same reader `printable_reports_test.dart` uses.
String _pdfText(Uint8List bytes) {
  final raw = latin1.decode(bytes);
  return [
    for (final m in RegExp(r'\[\((.*?)\)\]TJ').allMatches(raw))
      m.group(1)!.replaceAll(r'\(', '(').replaceAll(r'\)', ')'),
  ].join(' ');
}

void main() {
  final meeting = DailySafetyMeeting.fromMap('m1', {
    'organizationId': 'org',
    'projectId': 'project-1',
    'siteId': 'site-1',
    'date': '2026-10-28',
    'foremanId': 'foreman-1',
    'status': 'completed',
    'activityIds': ['roof'],
    'meetingPointIds': ['height'],
    'crewOutcome': 'go',
  });
  // 06:40 and 07:05 in Nairobi.
  final timed = DailySafetyMeeting(
    id: meeting.id,
    organizationId: meeting.organizationId,
    projectId: meeting.projectId,
    siteId: meeting.siteId,
    date: meeting.date,
    foremanId: meeting.foremanId,
    status: meeting.status,
    activityIds: meeting.activityIds,
    meetingPointIds: meeting.meetingPointIds,
    crewOutcome: meeting.crewOutcome,
    startTime: DateTime.utc(2026, 10, 28, 3, 40),
    endTime: DateTime.utc(2026, 10, 28, 4, 5),
  );

  MeetingAttendance attendee(
    String id,
    String status, {
    bool briefed = false,
  }) => MeetingAttendance.fromMap(id, {
    'meetingId': 'm1',
    'organizationId': 'org',
    'siteId': 'site-1',
    'workerId': id,
    'status': status,
    'briefedInPerson': briefed,
    'briefedLearningTitles': briefed ? ['Ladder safety'] : <String>[],
  });

  DailyMeetingReport build() => dailyMeetingReport(
    meeting: timed,
    siteName: 'Rosslyn Ridge',
    projectName: 'Roof replacement',
    foremanName: 'Fred Foreman',
    activityNames: const {'roof': 'Roofing'},
    pointTitles: const {'height': 'Working at Height'},
    pointNotes: const {'height': 'Harness checked by everyone'},
    attendance: [
      attendee('wanjiru', 'present'),
      attendee('otieno', 'present', briefed: true),
      attendee('baraka', 'absent'),
    ],
    concerns: const <MeetingConcern>[],
    correctiveActions: const <CorrectiveAction>[],
    nameFor: (uid) => {'wanjiru': 'Wanjiru', 'otieno': 'Otieno'}[uid],
  );

  test('builds the record from what was recorded: times, totals, and who '
      'was briefed in person', () {
    final report = build();

    expect(report.startTime, '06:40');
    expect(report.endTime, '07:05');
    expect(report.presentCount, 2);
    expect(report.absentCount, 1);
    expect(report.crewResult, 'GO');
    expect(report.activities, ['Roofing']);
    expect(report.points, [
      ('Working at Height', 'Harness checked by everyone'),
    ]);
    expect(report.attendance, [
      ('Wanjiru', 'Present'),
      ('Otieno', 'Present (briefed in person)'),
      // No name found: the id stands in.
      ('baraka', 'Absent'),
    ]);
  });

  test(
    'prints the times, the attendance total and the briefed marker',
    () async {
      final text = _pdfText(
        await buildDailyMeetingPdf(
          organizationName: 'JV ALMA C.I.S.',
          compress: false,
          report: build(),
        ),
      );

      for (final expected in [
        'Started',
        '06:40',
        'Finished',
        '07:05',
        '2 present, 1 absent (3 recorded)',
        'Present (briefed in person)',
      ]) {
        expect(text, contains(expected), reason: expected);
      }
    },
  );

  test('a meeting with no recorded times prints without them', () {
    final report = dailyMeetingReport(
      meeting: meeting,
      siteName: 'Site',
      projectName: 'Project',
      foremanName: 'Foreman',
      activityNames: const {},
      pointTitles: const {},
      pointNotes: const {},
      attendance: const [],
      concerns: const [],
      correctiveActions: const [],
      nameFor: (_) => null,
    );
    expect(report.startTime, isNull);
    expect(report.endTime, isNull);
    expect(report.presentCount, 0);
    expect(report.absentCount, 0);
  });
  test("prints the Foreman's own points after the library's, marked, with "
      'the activity and what was discussed', () async {
    MeetingForemanPoint own(String title, {String? note, String? activity}) =>
        MeetingForemanPoint(
          id: title,
          meetingId: 'm1',
          organizationId: 'org',
          siteId: 'site-1',
          title: title,
          note: note,
          activityId: activity,
        );
    final report = dailyMeetingReport(
      meeting: timed,
      siteName: 'Rosslyn Ridge',
      projectName: 'Roof replacement',
      foremanName: 'Fred Foreman',
      activityNames: const {'roof': 'Roofing'},
      pointTitles: const {'height': 'Working at Height'},
      pointNotes: const {},
      foremanPoints: [
        own('Wet sheets', note: 'Wait until dry', activity: 'roof'),
        own('Housekeeping'),
      ],
      attendance: const [],
      concerns: const [],
      correctiveActions: const [],
      nameFor: (_) => null,
    );

    expect(report.points, [
      ('Working at Height', null),
      ('Wet sheets (added by Foreman, about Roofing)', 'Wait until dry'),
      ('Housekeeping (added by Foreman)', null),
    ]);
    final text = _pdfText(
      await buildDailyMeetingPdf(
        organizationName: 'JV ALMA C.I.S.',
        compress: false,
        report: report,
      ),
    );
    expect(text, contains('Wet sheets (added by Foreman, about Roofing)'));
    expect(text, contains('Wait until dry'));
  });
}
