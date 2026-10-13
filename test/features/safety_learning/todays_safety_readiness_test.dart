import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/daily_safety_meeting_status.dart';
import 'package:jva_safety/features/safety_learning/domain/todays_safety_readiness.dart';

Map<Object?, Object?> item(String id, {bool canStart = true}) => {
  'learningId': id,
  'title': 'Learning $id',
  'type': 'video',
  'status': 'assigned',
  'canStart': canStart,
};

void main() {
  test('fromMap parses sections, scope and an in-progress meeting', () {
    final readiness = TodaysSafetyReadiness.fromMap({
      'gatingSource': 'meeting',
      'meeting': {
        'id': 'meeting-1',
        'status': 'inProgress',
        'startTime': '2026-09-25T05:00:00.000Z',
      },
      'scope': {
        'projects': [
          {'id': 'p1', 'name': 'Rosslyn Project'},
        ],
        'sites': [
          {'id': 's1', 'name': 'Site A'},
        ],
        'activities': [
          {'id': 'a1', 'name': 'Roofing'},
          {'id': 'a2', 'name': ''},
        ],
      },
      'beforeMeeting': [item('g1')],
      'beforeWork': [item('p1'), item('p2', canStart: false)],
      'additional': [item('x1')],
    });

    expect(readiness.gatingSource, ReadinessGatingSource.meeting);
    expect(readiness.meeting!.id, 'meeting-1');
    expect(readiness.meeting!.status, DailySafetyMeetingStatus.inProgress);
    expect(readiness.meeting!.startTime, isNotNull);
    expect(readiness.projects.single.label, 'Rosslyn Project');
    expect(readiness.activities.map((a) => a.label), ['Roofing', 'a2']);
    expect(readiness.beforeMeeting.single.learningId, 'g1');
    expect(readiness.beforeWork.map((i) => i.canStart), [true, false]);
    expect(readiness.additional.single.status, ReadinessItemStatus.assigned);
    expect(readiness.isReady, isFalse);
  });

  test('fromMap tolerates a missing meeting and malformed entries', () {
    final readiness = TodaysSafetyReadiness.fromMap({
      'gatingSource': 'assignments',
      'meeting': null,
      'beforeMeeting': [
        {'title': 'no id'},
        'not a map',
      ],
    });

    expect(readiness.gatingSource, ReadinessGatingSource.assignments);
    expect(readiness.meeting, isNull);
    expect(readiness.beforeMeeting, isEmpty);
    expect(readiness.isReady, isTrue);
  });

  test('withoutCompleted removes completed items from every section', () {
    final readiness = TodaysSafetyReadiness.fromMap({
      'beforeMeeting': [item('a'), item('b')],
      'beforeWork': [item('c')],
      'additional': [item('d')],
    });

    final filtered = readiness.withoutCompleted({'a', 'c', 'd'});

    expect(filtered.beforeMeeting.map((i) => i.learningId), ['b']);
    expect(filtered.beforeWork, isEmpty);
    expect(filtered.additional, isEmpty);
    expect(filtered.withoutCompleted({'b'}).isReady, isTrue);
  });

  test('fromMap reads the caller role', () {
    expect(
      TodaysSafetyReadiness.fromMap({'role': 'foreman'}).isForeman,
      isTrue,
    );
    expect(
      TodaysSafetyReadiness.fromMap({'role': 'worker'}).isForeman,
      isFalse,
    );
    expect(TodaysSafetyReadiness.fromMap(const {}).isForeman, isFalse);
  });

  test('withoutCompleted keeps the role', () {
    final readiness = TodaysSafetyReadiness.fromMap({
      'role': 'foreman',
      'beforeMeeting': [item('a')],
    });

    expect(readiness.withoutCompleted({'a'}).isForeman, isTrue);
  });

  test('isReady ignores additional learning', () {
    final readiness = TodaysSafetyReadiness.fromMap({
      'additional': [item('x')],
    });

    expect(readiness.isReady, isTrue);
  });
}
