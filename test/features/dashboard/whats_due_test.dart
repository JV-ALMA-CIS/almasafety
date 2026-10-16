import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/dashboard/domain/whats_due.dart';
import 'package:jva_safety/features/dashboard/presentation/whats_due_card.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/incidents/data/incident_repository.dart';
import 'package:jva_safety/features/man_hours/data/man_hours_repository.dart';
import 'package:jva_safety/features/inspections/data/inspection_repository.dart';
import 'package:jva_safety/features/inspections/domain/inspection.dart';
import 'package:jva_safety/features/man_hours/domain/man_hours.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/site.dart';
import 'package:jva_safety/features/risk_assessments/data/risk_assessment_repository.dart';
import 'package:jva_safety/features/risk_assessments/domain/risk_assessment.dart';
import 'package:jva_safety/features/safety_meetings/data/safety_meeting_repository.dart';
import 'package:jva_safety/features/safety_meetings/domain/safety_meeting.dart';

/// Thursday 15 October 2026, 09:00.
final _now = DateTime(2026, 10, 15, 9);

Site _site(String id, String name) => Site(
  id: id,
  organizationId: 'org',
  projectId: 'p',
  name: name,
  code: id.toUpperCase(),
  status: OrganizationRecordStatus.active,
);

InspectionTemplate _daily({List<String> siteIds = const []}) =>
    InspectionTemplate(
      id: 't-daily',
      name: 'Daily site inspection',
      kind: InspectionKind.daily,
      sections: const [],
      isActive: true,
      siteIds: siteIds,
    );

Inspection _inspection({
  required String siteId,
  InspectionStatus status = InspectionStatus.submitted,
  String inspector = 'foreman-1',
  DateTime? at,
}) => Inspection(
  id: 'i-$siteId-${status.id}-$inspector',
  organizationId: 'org',
  siteId: siteId,
  templateId: 't',
  templateName: 'Daily site inspection',
  kind: InspectionKind.daily,
  items: const [],
  status: status,
  inspectorUid: inspector,
  startedAt: at ?? _now,
  submittedAt: status == InspectionStatus.inProgress ? null : at ?? _now,
);

SafetyMeeting _meeting(SafetyMeetingKind kind, String date, {String? site}) =>
    SafetyMeeting.fromMap('m-$date-${kind.id}', {
      'kind': kind.id,
      'date': date,
      'siteId': site,
      'facilitatorUid': 'x',
    });

void main() {
  final rosslyn = _site('rosslyn', 'Rosslyn Ridge');
  final embassy = _site('embassy', 'Italian Embassy');

  List<DueKind> kinds(List<DueItem> items) => items.map((i) => i.kind).toList();

  group('computeDueItems', () {
    test('a fresh week: inspections and meetings are due at every site', () {
      final items = computeDueItems(
        uid: 'manager-1',
        isManager: true,
        sites: [rosslyn, embassy],
        templates: [_daily()],
        inspections: const [],
        meetings: const [],
        now: _now,
      );
      expect(kinds(items), [
        DueKind.dailyInspectionNotDone,
        DueKind.weeklyMeetingNotHeld,
        DueKind.monthlyMeetingNotHeld,
      ]);
      expect(items.first.detail, 'Rosslyn Ridge, Italian Embassy');
    });

    test('what is done today / this week / this month drops off', () {
      final items = computeDueItems(
        uid: 'manager-1',
        isManager: true,
        sites: [rosslyn, embassy],
        templates: [_daily()],
        inspections: [
          _inspection(siteId: 'rosslyn'),
          // Yesterday's does not count for today.
          _inspection(siteId: 'embassy', at: DateTime(2026, 10, 14, 9)),
        ],
        meetings: [
          _meeting(
            SafetyMeetingKind.weeklyEmployee,
            '2026-10-15',
            site: 'rosslyn',
          ),
          _meeting(
            SafetyMeetingKind.weeklyEmployee,
            '2026-10-15',
            site: 'embassy',
          ),
          _meeting(SafetyMeetingKind.monthlySupervisory, '2026-10-01'),
        ],
        now: _now,
      );
      // Embassy's submitted one (from yesterday) is also awaiting sign-off.
      expect(kinds(items), [
        DueKind.inspectionsToSignOff,
        DueKind.dailyInspectionNotDone,
      ]);
      expect(items[1].detail, 'Italian Embassy');
    });

    test('a daily checklist used only elsewhere does not make one due', () {
      final items = computeDueItems(
        uid: 'manager-1',
        isManager: true,
        sites: [embassy],
        templates: [
          _daily(siteIds: ['rosslyn']),
        ],
        inspections: const [],
        meetings: [
          _meeting(
            SafetyMeetingKind.weeklyEmployee,
            '2026-10-13',
            site: 'embassy',
          ),
          _meeting(SafetyMeetingKind.monthlySupervisory, '2026-10-02'),
        ],
        now: _now,
      );
      expect(items, isEmpty);
    });

    test('a manager sees sign-offs, AHAs and deficiencies — not their own', () {
      final items = computeDueItems(
        uid: 'manager-1',
        isManager: true,
        sites: [rosslyn],
        templates: [_daily()],
        inspections: [
          _inspection(siteId: 'rosslyn', inspector: 'manager-1'),
          _inspection(
            siteId: 'rosslyn',
            status: InspectionStatus.inProgress,
            inspector: 'manager-1',
          ),
        ],
        meetings: [
          _meeting(
            SafetyMeetingKind.weeklyEmployee,
            '2026-10-12',
            site: 'rosslyn',
          ),
          _meeting(SafetyMeetingKind.monthlySupervisory, '2026-10-01'),
        ],
        riskAssessments: [
          RiskAssessment.fromMap('a1', {
            'siteId': 'rosslyn',
            'status': 'draft',
            'featureOfWork': 'Removals',
            'preparedByUid': 'manager-2',
          }),
          RiskAssessment.fromMap('a2', {
            'siteId': 'rosslyn',
            'status': 'draft',
            'featureOfWork': 'Mine',
            'preparedByUid': 'manager-1',
          }),
        ],
        now: _now,
      );
      expect(kinds(items), [
        DueKind.inspectionsInProgress,
        DueKind.ahasToAccept,
      ]);
      expect(items.last.title, contains('1 risk assessment'));
    });

    test('a Foreman sees only their own sites, no manager items', () {
      final items = computeDueItems(
        uid: 'foreman-1',
        isManager: false,
        sites: [rosslyn],
        templates: const [],
        inspections: [
          _inspection(siteId: 'rosslyn', inspector: 'someone-else'),
        ],
        meetings: const [],
        now: _now,
      );
      expect(kinds(items), [DueKind.weeklyMeetingNotHeld]);
    });

    test('no checklists set up is flagged for managers', () {
      final items = computeDueItems(
        uid: 'manager-1',
        isManager: true,
        sites: const [],
        templates: const [],
        inspections: const [],
        meetings: const [],
        now: _now,
      );
      expect(kinds(items), [DueKind.noChecklists]);
    });
  });

  group('the card', () {
    late FakeFirebaseFirestore firestore;

    setUp(() async {
      firestore = FakeFirebaseFirestore();
      await firestore.doc('organizations/org/sites/rosslyn').set({
        'organizationId': 'org',
        'projectId': 'p',
        'name': 'Rosslyn Ridge',
        'code': 'RR',
        'status': 'active',
      });
      await firestore.doc('organizations/org/sites/old').set({
        'organizationId': 'org',
        'projectId': 'p',
        'name': 'Finished Site',
        'code': 'OLD',
        'status': 'inactive',
      });
      await firestore.doc('organizations/org/inspection_templates/t').set({
        'organizationId': 'org',
        'name': 'Daily site inspection',
        'kind': 'daily',
        'status': 'active',
        'sections': <Object>[],
      });
    });

    Widget card({bool isManager = true}) {
      final service = FirestoreService(firestore: firestore);
      return MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WhatsDueCard(
              organizationId: 'org',
              uid: 'manager-1',
              isManager: isManager,
              siteRepository: SiteRepository(
                firestoreService: service,
                organizationId: 'org',
              ),
              inspectionRepository: InspectionRepository(
                firestoreService: service,
                organizationId: 'org',
              ),
              safetyMeetingRepository: SafetyMeetingRepository(
                firestoreService: service,
                organizationId: 'org',
              ),
              riskAssessmentRepository: RiskAssessmentRepository(
                firestoreService: service,
                organizationId: 'org',
              ),
              hazardRepository: HazardRepository(
                firestoreService: service,
                organizationId: 'org',
              ),
              incidentRepository: IncidentRepository(
                firestoreService: service,
                organizationId: 'org',
              ),
              manHoursRepository: ManHoursRepository(
                firestoreService: service,
                organizationId: 'org',
              ),
              now: () => _now,
            ),
          ),
        ),
      );
    }

    testWidgets('lists what is due at open sites only, live', (tester) async {
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();

      expect(find.text('Daily inspection not done today'), findsOneWidget);
      expect(find.text('Rosslyn Ridge'), findsOneWidget);
      expect(find.textContaining('Finished Site'), findsNothing);
      expect(
        find.text('Weekly employee safety meeting not recorded this week'),
        findsOneWidget,
      );

      // Recording this week's meeting removes that line.
      await firestore.doc('organizations/org/safety_meetings/m1').set({
        'organizationId': 'org',
        'kind': 'weeklyEmployee',
        'siteId': 'rosslyn',
        'date': '2026-10-15',
        'facilitatorUid': 'manager-1',
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Weekly employee safety meeting not recorded this week'),
        findsNothing,
      );
    });

    testWidgets('everything done shows an all-clear', (tester) async {
      await firestore.doc('organizations/org/inspections/i1').set({
        'organizationId': 'org',
        'siteId': 'rosslyn',
        'templateId': 't',
        'templateName': 'Daily site inspection',
        'kind': 'daily',
        'status': 'signedOff',
        'inspectorUid': 'foreman-1',
        'items': <Object>[],
        'startedAt': Timestamp.fromDate(_now),
        'submittedAt': Timestamp.fromDate(_now),
      });
      for (final (id, kind, site, date) in [
        ('w', 'weeklyEmployee', 'rosslyn', '2026-10-15'),
        ('m', 'monthlySupervisory', null, '2026-10-01'),
      ]) {
        await firestore.doc('organizations/org/safety_meetings/$id').set({
          'organizationId': 'org',
          'kind': kind,
          'siteId': site,
          'date': date,
          'facilitatorUid': 'x',
        });
      }
      // September's man-hours entered and reported.
      await firestore.doc('organizations/org/man_hours/rosslyn_2026-09').set({
        'siteId': 'rosslyn',
        'month': '2026-09',
        'hours': 1200,
        'workers': 8,
      });
      await firestore.doc('organizations/org/man_hours_reports/2026-09').set({
        'month': '2026-09',
      });
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(find.text("Nothing due — you're up to date"), findsOneWidget);
    });
  });

  group("man-hours in What's Due", () {
    final rosslyn2 = _site('rosslyn', 'Rosslyn Ridge');
    final embassy2 = _site('embassy', 'Italian Embassy');
    List<DueItem> due({
      required bool isManager,
      List<ManHoursEntry> entries = const [],
      ManHoursReport? report,
      DateTime? now,
    }) => computeDueItems(
      uid: 'u',
      isManager: isManager,
      sites: [rosslyn2, embassy2],
      templates: const [],
      inspections: const [],
      meetings: [
        _meeting(
          SafetyMeetingKind.weeklyEmployee,
          '2026-10-15',
          site: 'rosslyn',
        ),
        _meeting(
          SafetyMeetingKind.weeklyEmployee,
          '2026-10-15',
          site: 'embassy',
        ),
        _meeting(SafetyMeetingKind.monthlySupervisory, '2026-10-01'),
      ],
      manHoursEntries: entries,
      manHoursReport: report,
      now: now ?? _now,
    ).where((i) => i.kind.name.startsWith('manHours')).toList();
    ManHoursEntry entry(String site) =>
        ManHoursEntry(siteId: site, month: '2026-09', hours: 100, workers: 2);

    test('sites without last month entered are listed, with the due date', () {
      final items = due(isManager: true, entries: [entry('rosslyn')]);
      expect(items.single.kind, DueKind.manHoursNotEntered);
      expect(items.single.title, 'Man-hours for September 2026 not entered');
      expect(items.single.detail, 'Italian Embassy · due 25 Oct');
    });

    test('after the 25th it is overdue', () {
      final items = due(isManager: false, now: DateTime(2026, 10, 26));
      expect(items.single.detail, contains('OVERDUE'));
    });

    test('all entered: a manager is reminded to report it, until reported', () {
      final all = [entry('rosslyn'), entry('embassy')];
      expect(
        due(isManager: true, entries: all).single.kind,
        DueKind.manHoursNotReported,
      );
      expect(due(isManager: false, entries: all), isEmpty);
      expect(
        due(
          isManager: true,
          entries: all,
          report: const ManHoursReport(month: '2026-09'),
        ),
        isEmpty,
      );
    });
  });
}
