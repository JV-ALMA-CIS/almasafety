import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/reports/pdf_report.dart';
import '../../../core/utils/meeting_date.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../domain/daily_safety_meeting.dart';
import '../domain/meeting_attendance.dart';
import '../domain/meeting_attendance_status.dart';
import '../domain/meeting_concern.dart';
import '../domain/meeting_foreman_point.dart';

/// Everything printed on a daily safety meeting record, gathered by the
/// screen that prints it (names already resolved).
class DailyMeetingReport {
  const DailyMeetingReport({
    required this.siteName,
    required this.projectName,
    required this.date,
    required this.foremanName,
    required this.status,
    this.startTime,
    this.endTime,
    this.presentCount,
    this.absentCount,
    this.crewResult,
    this.activities = const [],
    this.points = const [],
    this.ahasCovered = const [],
    this.attendance = const [],
    this.concerns = const [],
    this.correctiveActions = const [],
  });

  final String siteName;
  final String projectName;
  final String date;
  final String foremanName;
  final String status;

  /// Nairobi clock times, e.g. "06:45". Null when not recorded.
  final String? startTime;
  final String? endTime;

  /// Attendance totals. Null when the report was built without them.
  final int? presentCount;
  final int? absentCount;

  /// e.g. "GO" or "STOP - scaffold not tagged".
  final String? crewResult;
  final List<String> activities;

  /// (point, discussion note).
  final List<(String, String?)> points;

  /// e.g. "Removals (revision 2)".
  final List<String> ahasCovered;

  /// (name, attendance status) — the status names a "briefed in person"
  /// attendance, e.g. "Present (briefed in person)".
  final List<(String, String)> attendance;
  final List<String> concerns;
  final List<String> correctiveActions;
}

/// A daily safety meeting (toolbox talk) as a printable record: site, date,
/// Foreman, the work covered, the safety points and AHAs gone through with
/// the crew, attendance with a signature column, concerns, corrective
/// actions and the crew's GO / STOP result.
Future<Uint8List> buildDailyMeetingPdf({
  required DailyMeetingReport report,
  required String organizationName,
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? generatedAt,

  /// Off in tests, so the text can be read back.
  bool compress = true,
}) async {
  final now = generatedAt ?? DateTime.now();
  final logo = await PdfReport.logo();
  pw.Widget heading(String title) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 10, bottom: 4),
    child: PdfReport.text(title, size: 10, bold: true),
  );

  final doc = pw.Document(
    compress: compress,
    title: 'Daily safety meeting',
    author: PdfReport.clean(organizationName),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(32),
      header: (context) => PdfReport.header(
        organizationName: organizationName,
        logo: logo,
        title: 'DAILY SAFETY MEETING (TOOLBOX TALK)',
        subtitle: '${report.siteName} - ${report.date}',
      ),
      footer: (context) => PdfReport.footer(context, now),
      build: (context) => [
        pw.Table(
          border: PdfReport.border,
          children: [
            pw.TableRow(
              children: [
                PdfReport.field('Site', report.siteName),
                PdfReport.field('Project', report.projectName),
                PdfReport.field('Date', report.date),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.field('Foreman', report.foremanName),
                PdfReport.field('Status', report.status),
                PdfReport.field('Crew result', report.crewResult),
              ],
            ),
            pw.TableRow(
              children: [
                PdfReport.field('Started', report.startTime),
                PdfReport.field('Finished', report.endTime),
                PdfReport.field('Attendance', _attendanceTotal(report)),
              ],
            ),
          ],
        ),
        heading('WORK COVERED (ACTIVITIES)'),
        PdfReport.bullets(report.activities),
        heading('SAFETY POINTS DISCUSSED'),
        if (report.points.isEmpty)
          PdfReport.text('-')
        else
          for (final (point, note) in report.points)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: PdfReport.text('- $point${note == null ? '' : ': $note'}'),
            ),
        heading('RISK ASSESSMENTS (AHA) COVERED WITH THE CREW'),
        PdfReport.bullets(report.ahasCovered),
        heading('ATTENDANCE'),
        pw.Table(
          border: PdfReport.border,
          columnWidths: const {
            0: pw.FixedColumnWidth(24),
            1: pw.FlexColumnWidth(3),
            2: pw.FlexColumnWidth(1.6),
            3: pw.FlexColumnWidth(2),
          },
          children: [
            pw.TableRow(
              repeat: true,
              children: [
                PdfReport.headCell('#'),
                PdfReport.headCell('Name'),
                PdfReport.headCell('Attendance'),
                PdfReport.headCell('Signature'),
              ],
            ),
            for (var i = 0; i < report.attendance.length; i++)
              pw.TableRow(
                children: [
                  PdfReport.cell(PdfReport.text('${i + 1}')),
                  PdfReport.cell(PdfReport.text(report.attendance[i].$1)),
                  PdfReport.cell(PdfReport.text(report.attendance[i].$2)),
                  pw.SizedBox(height: 20),
                ],
              ),
          ],
        ),
        heading('CONCERNS RAISED'),
        PdfReport.bullets(report.concerns),
        heading('CORRECTIVE ACTIONS'),
        PdfReport.bullets(report.correctiveActions),
        pw.SizedBox(height: 22),
        PdfReport.signatureLine('Foreman', report.foremanName),
      ],
    ),
  );
  return doc.save();
}

/// "17 present, 1 absent (18 recorded)", or null without totals.
String? _attendanceTotal(DailyMeetingReport report) {
  final present = report.presentCount;
  final absent = report.absentCount;
  if (present == null || absent == null) return null;
  return '$present present, $absent absent (${present + absent} recorded)';
}

/// Builds the printable record of [meeting] from what was actually
/// recorded — the same for the Site Manager's summary and the Foreman's own
/// completed meeting, so the two prints never disagree. Names are resolved
/// by the caller; anything unresolved falls back to its id.
DailyMeetingReport dailyMeetingReport({
  required DailySafetyMeeting meeting,
  required String siteName,
  required String projectName,
  required String foremanName,
  required Map<String, String> activityNames,
  required Map<String, String> pointTitles,
  required Map<String, String> pointNotes,
  List<MeetingForemanPoint> foremanPoints = const [],
  required List<MeetingAttendance> attendance,
  required List<MeetingConcern> concerns,
  required List<CorrectiveAction> correctiveActions,
  required String? Function(String uid) nameFor,
}) {
  String attendanceLabel(MeetingAttendance record) =>
      record.briefedInPerson && record.status == MeetingAttendanceStatus.present
      ? '${record.status.label} (briefed in person)'
      : record.status.label;
  final startTime = meeting.startTime;
  final endTime = meeting.endTime;
  return DailyMeetingReport(
    siteName: siteName,
    projectName: projectName,
    date: meeting.date,
    foremanName: foremanName,
    status: meeting.status.label,
    startTime: startTime == null ? null : meetingClock(startTime),
    endTime: endTime == null ? null : meetingClock(endTime),
    presentCount: attendance
        .where((a) => a.status == MeetingAttendanceStatus.present)
        .length,
    absentCount: attendance
        .where((a) => a.status == MeetingAttendanceStatus.absent)
        .length,
    crewResult: meeting.crewOutcome == null
        ? null
        : [meeting.crewOutcome!.label, ?meeting.crewOutcomeNote].join(' - '),
    activities: [for (final id in meeting.activityIds) activityNames[id] ?? id],
    points: [
      for (final id in meeting.meetingPointIds)
        (pointTitles[id] ?? id, pointNotes[id]),
      // The Foreman's own points, marked so a reader can tell them from the
      // library's.
      for (final point in foremanPoints)
        (
          [
            point.title,
            '(added by Foreman${switch (activityNames[point.activityId]) {
              final String name => ', about $name',
              null => '',
            }})',
          ].join(' '),
          point.note,
        ),
    ],
    ahasCovered: [
      for (final aha in meeting.ahasCovered)
        '${aha.featureOfWork} (revision ${aha.revision})',
    ],
    attendance: [
      for (final record in attendance)
        (nameFor(record.workerId) ?? record.workerId, attendanceLabel(record)),
    ],
    concerns: [
      for (final concern in concerns)
        '${concern.category.label}: ${concern.description}',
    ],
    correctiveActions: [
      for (final action in correctiveActions)
        '${action.title} - ${action.status.label}',
    ],
  );
}
