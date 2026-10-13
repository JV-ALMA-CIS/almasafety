import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_attendance_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/crew_readiness.dart';
import 'package:jva_safety/features/daily_safety_meetings/presentation/crew_readiness_card.dart';

class _FakeAttendanceService extends MeetingAttendanceService {
  _FakeAttendanceService({this.site, this.meeting = const {}, this.error});

  final CrewReadiness? site;
  final Map<String, List<String>> meeting;
  final AppException? error;
  final List<String> calls = [];

  @override
  Future<CrewReadiness> getSiteCrewReadiness({
    required String organizationId,
    required String siteId,
  }) async {
    calls.add('site:$siteId');
    final e = error;
    if (e != null) throw e;
    return site!;
  }

  @override
  Future<Map<String, List<String>>> getMeetingAttendeeLearningStatus({
    required String organizationId,
    required String meetingId,
  }) async {
    calls.add('meeting:$meetingId');
    return meeting;
  }
}

void main() {
  Widget wrap(_FakeAttendanceService service, {String? meetingId}) {
    return MaterialApp(
      home: Scaffold(
        body: CrewReadinessCard(
          organizationId: 'org-alpha',
          siteId: 'site-1',
          meetingId: meetingId,
          attendanceService: service,
          workerNames: Future.value(const {'w1': 'Amina', 'w2': 'Brian'}),
        ),
      ),
    );
  }

  testWidgets('before the meeting: counts Ready vs Need attention and names '
      'the blocking learning', (tester) async {
    final service = _FakeAttendanceService(
      site: const CrewReadiness(
        activityNames: ['Roofing'],
        outstandingByWorker: {
          'w1': ['Site Induction', 'Fall Protection'],
          'w2': [],
          'w3': [],
        },
      ),
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    expect(service.calls, ['site:site-1']);
    expect(find.text("Before today's meeting"), findsOneWidget);
    expect(find.text('Roofing'), findsOneWidget);
    expect(find.text('3 workers'), findsOneWidget);
    expect(find.text('2 Ready'), findsOneWidget);
    expect(find.text('1 Need attention'), findsOneWidget);
    expect(find.text('Amina'), findsOneWidget);
    expect(
      find.text('Must complete: Site Induction, Fall Protection'),
      findsOneWidget,
    );
    // Ready workers are not listed individually.
    expect(find.text('Brian'), findsNothing);
  });

  testWidgets('once the meeting exists, uses the meeting callable', (
    tester,
  ) async {
    final service = _FakeAttendanceService(
      meeting: const {
        'w1': [],
        'w2': ['PPE'],
      },
    );
    await tester.pumpWidget(wrap(service, meetingId: 'meeting-1'));
    await tester.pumpAndSettle();

    expect(service.calls, ['meeting:meeting-1']);
    expect(find.text("Today's Safety Meeting"), findsOneWidget);
    expect(find.text('1 Ready'), findsOneWidget);
    expect(find.text('Must complete: PPE'), findsOneWidget);
  });

  testWidgets('meeting with nothing gating attendance says so', (tester) async {
    final service = _FakeAttendanceService();
    await tester.pumpWidget(wrap(service, meetingId: 'meeting-1'));
    await tester.pumpAndSettle();

    expect(
      find.text('No learning blocks attendance for this meeting.'),
      findsOneWidget,
    );
  });

  testWidgets('re-fetches from the meeting once it is started', (tester) async {
    final service = _FakeAttendanceService(
      site: const CrewReadiness(outstandingByWorker: {'w1': []}),
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();
    await tester.pumpWidget(wrap(service, meetingId: 'meeting-1'));
    await tester.pumpAndSettle();

    expect(service.calls, ['site:site-1', 'meeting:meeting-1']);
  });

  testWidgets('shows an error with Retry', (tester) async {
    final service = _FakeAttendanceService(error: const DataException('boom'));
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    expect(find.text('Could not load crew readiness.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
