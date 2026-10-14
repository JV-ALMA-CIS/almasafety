import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/dashboard/domain/whats_due.dart';
import 'package:jva_safety/features/incidents/domain/incident.dart';
import 'package:jva_safety/features/incidents/domain/incident_reporting.dart';
import 'package:jva_safety/features/incidents/presentation/incident_reporting_section.dart';

/// Tuesday 13 October 2026, 08:00 — when the incident happened.
final _occurred = DateTime(2026, 10, 13, 8);

Map<String, Object?> _step(
  String id,
  String label,
  int hours, {
  DateTime? doneAt,
  String? by,
  String? note,
}) => {
  'id': id,
  'label': label,
  'dueAt': Timestamp.fromDate(_occurred.add(Duration(hours: hours))),
  'doneAt': doneAt == null ? null : Timestamp.fromDate(doneAt),
  'doneByName': by,
  'note': note,
};

Incident _incident({
  String? level,
  List<Map<String, Object?>> steps = const [],
}) => Incident.fromMap('inc-1', {
  'organizationId': 'org',
  'projectId': 'p',
  'siteId': 'site-1',
  'reportedByUid': 'worker-1',
  'type': 'injury',
  'description': 'Fell from a ladder',
  'occurredAt': Timestamp.fromDate(_occurred),
  'status': 'underInvestigation',
  'correctiveActionIds': <String>[],
  'reportingLevel': level,
  'reportingSteps': steps,
});

void main() {
  final lostTime = _incident(
    level: 'lostTime',
    steps: [
      _step(
        'notifyCor',
        "Tell the client's representative (COR)",
        0,
        doneAt: _occurred.add(const Duration(minutes: 20)),
        by: 'Eston',
        note: 'Called J. Smith',
      ),
      _step('notify24h', '24-hour notification (phone and/or email)', 24),
      _step('form3394', 'ENG Form 3394 accident investigation report', 120),
    ],
  );

  group('the incident', () {
    test('reads its reporting level and steps', () {
      expect(lostTime.reportingLevel, IncidentReportingLevel.lostTime);
      expect(lostTime.reportingSteps.map((s) => s.id), [
        'notifyCor',
        'notify24h',
        'form3394',
      ]);
      expect(lostTime.isReportingComplete, isFalse);
    });

    test('overdue and due-soon steps depend on the time', () {
      final dayLater = _occurred.add(const Duration(hours: 30));
      expect(lostTime.overdueSteps(dayLater).map((s) => s.id), ['notify24h']);
      final soon = _occurred.add(const Duration(hours: 10));
      expect(
        lostTime.reportingSteps
            .where((s) => s.isDueSoon(soon))
            .map((s) => s.id),
        ['notify24h'],
      );
    });
  });

  group('the reporting section', () {
    Future<void> pump(
      WidgetTester tester,
      Incident incident, {
      bool canEdit = true,
      DateTime? now,
      void Function(ReportingStep, bool)? onStep,
      VoidCallback? onChooseLevel,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IncidentReportingSection(
                incident: incident,
                canEdit: canEdit,
                busy: false,
                onChooseLevel: onChooseLevel ?? () {},
                onStep: onStep ?? (_, _) {},
                now: () => now ?? _occurred.add(const Duration(hours: 2)),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('no level yet: says so, and offers to set it', (tester) async {
      var chose = false;
      await pump(tester, _incident(), onChooseLevel: () => chose = true);
      expect(find.text('Reporting level not set'), findsOneWidget);
      await tester.tap(find.text('Set reporting level'));
      expect(chose, isTrue);
    });

    testWidgets('a worker sees the level but cannot change it', (tester) async {
      await pump(tester, lostTime, canEdit: false);
      expect(find.text('Lost time or major damage'), findsOneWidget);
      expect(find.text('Change level'), findsNothing);
      expect(find.text('Mark done'), findsNothing);
    });

    testWidgets('each step shows done, due or overdue', (tester) async {
      await pump(
        tester,
        lostTime,
        now: _occurred.add(const Duration(hours: 30)),
      );
      expect(find.textContaining('by Eston — Called J. Smith'), findsOneWidget);
      expect(find.textContaining('OVERDUE'), findsOneWidget);
      expect(find.textContaining('Due Sun 18 Oct'), findsOneWidget);
    });

    testWidgets('tapping a step ticks it', (tester) async {
      final ticks = <(String, bool)>[];
      await pump(
        tester,
        lostTime,
        onStep: (s, done) => ticks.add((s.id, done)),
      );
      await tester.tap(find.text('24-hour notification (phone and/or email)'));
      await tester.tap(find.text("Tell the client's representative (COR)"));
      expect(ticks, [('notify24h', true), ('notifyCor', false)]);
    });
  });

  group("What's Due", () {
    test('managers see overdue, unset and soon-due reporting first', () {
      final noLevel = _incident();
      final items = computeDueItems(
        uid: 'manager-1',
        isManager: true,
        sites: const [],
        templates: const [],
        inspections: const [],
        meetings: const [],
        incidents: [lostTime, noLevel],
        now: _occurred.add(const Duration(hours: 30)),
      );
      expect(items.take(2).map((i) => i.kind), [
        DueKind.incidentReportsOverdue,
        DueKind.incidentReportingNotSet,
      ]);
      expect(items.first.title, '1 incident reporting step OVERDUE');
    });

    test('a Foreman is not shown incident reporting', () {
      final items = computeDueItems(
        uid: 'foreman-1',
        isManager: false,
        sites: const [],
        templates: const [],
        inspections: const [],
        meetings: const [],
        incidents: [lostTime],
        now: _occurred.add(const Duration(hours: 30)),
      );
      expect(items, isEmpty);
    });
  });
}
