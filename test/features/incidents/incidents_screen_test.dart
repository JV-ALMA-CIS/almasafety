import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/widgets/accent_card.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/incidents/data/incident_repository.dart';
import 'package:jva_safety/features/incidents/data/incident_service.dart';
import 'package:jva_safety/features/incidents/presentation/incidents_screen.dart';
import 'package:jva_safety/features/incidents/presentation/report_incident_screen.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole role, this.uid = 'worker-1'})
    : _membership = Membership(
        organizationId: 'alpha',
        role: role,
        siteIds: const ['site-1'],
        status: MembershipStatus.active,
      );

  final String uid;
  final Membership _membership;

  @override
  UserProfile? get profile => UserProfile(
    uid: uid,
    name: 'Test User',
    email: 'user@example.com',
    accountStatus: AccountStatus.active,
  );

  @override
  String? get activeOrganizationId => 'alpha';

  @override
  Membership? get activeMembership => _membership;
}

class _FakeIncidentService extends IncidentService {
  final List<Map<String, Object?>> reports = [];
  final List<Map<String, Object?>> investigations = [];
  final List<Map<String, Object?>> closures = [];

  @override
  Future<String> reportIncident({
    required String organizationId,
    required String siteId,
    required String type,
    required String description,
    required DateTime occurredAt,
    String? location,
    String? injuredPersonName,
    String? immediateAction,
    String? photoFileName,
    Uint8List? photoBytes,
  }) async {
    reports.add({
      'siteId': siteId,
      'type': type,
      'description': description,
      'occurredAt': occurredAt,
      'injuredPersonName': injuredPersonName,
      'immediateAction': immediateAction,
    });
    return 'incident-new';
  }

  @override
  Future<void> startInvestigation({
    required String organizationId,
    required String incidentId,
    required String severity,
  }) async {
    investigations.add({'incidentId': incidentId, 'severity': severity});
  }

  @override
  Future<void> closeIncident({
    required String organizationId,
    required String incidentId,
    required String rootCause,
    String? closingNotes,
  }) async {
    closures.add({'incidentId': incidentId, 'rootCause': rootCause});
  }
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() => firestore = FakeFirebaseFirestore());

  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> seedIncident(
    String id, {
    String reportedBy = 'worker-1',
    String status = 'reported',
    String? severity,
    String description = 'Cut hand on sheet metal',
    bool reportingDone = false,
  }) async {
    await firestore.doc('organizations/alpha/incidents/$id').set({
      'organizationId': 'alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'reportedByUid': reportedBy,
      'type': 'injury',
      'description': description,
      'occurredAt': Timestamp.fromDate(DateTime(2026, 10, 9, 8, 30)),
      'status': status,
      'severity': severity,
      'correctiveActionIds': <String>[],
      'createdAt': Timestamp.now(),
      if (reportingDone) ...{
        'reportingLevel': 'firstAid',
        'reportingSteps': [
          {
            'id': 'notifyCor',
            'label': 'Tell the COR',
            'dueAt': Timestamp.fromDate(DateTime(2026, 10, 9, 8, 30)),
            'doneAt': Timestamp.fromDate(DateTime(2026, 10, 9, 9)),
          },
        ],
      },
    });
  }

  Widget wrap({
    required AppRole role,
    String uid = 'worker-1',
    IncidentService? service,
  }) {
    final firestoreService = FirestoreService(firestore: firestore);
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, uid: uid),
      child: MaterialApp(
        home: Scaffold(
          body: IncidentsScreen(
            repository: IncidentRepository(
              firestoreService: firestoreService,
              organizationId: 'alpha',
            ),
            correctiveActionRepository: CorrectiveActionRepository(
              firestoreService: firestoreService,
              organizationId: 'alpha',
            ),
            service: service ?? _FakeIncidentService(),
          ),
        ),
      ),
    );
  }

  testWidgets('a worker sees only the incidents they reported', (tester) async {
    await seedIncident('mine', description: 'My report');
    await seedIncident('theirs', reportedBy: 'worker-2', description: 'Other');

    await tester.pumpWidget(wrap(role: AppRole.worker));
    await tester.pumpAndSettle();

    expect(find.text('My Incident Reports'), findsOneWidget);
    expect(find.text('My report'), findsOneWidget);
    expect(find.text('Other'), findsNothing);
  });

  testWidgets('a reviewer sees every open incident, and the Closed filter '
      'shows closed ones', (tester) async {
    useTallSurface(tester);
    await seedIncident('a', description: 'Open one');
    await seedIncident(
      'b',
      reportedBy: 'worker-2',
      status: 'closed',
      severity: 'minor',
      description: 'Closed one',
    );

    await tester.pumpWidget(wrap(role: AppRole.siteManager, uid: 'mgr'));
    await tester.pumpAndSettle();

    expect(find.text('Open one'), findsOneWidget);
    expect(find.text('Closed one'), findsNothing);

    await tester.tap(find.text('Closed').last);
    await tester.pumpAndSettle();
    expect(find.text('Closed one'), findsOneWidget);
    expect(find.text('Open one'), findsNothing);
  });

  testWidgets('a reviewer can start an investigation with a severity', (
    tester,
  ) async {
    useTallSurface(tester);
    final service = _FakeIncidentService();
    await seedIncident('a');

    await tester.pumpWidget(
      wrap(role: AppRole.siteManager, uid: 'mgr', service: service),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cut hand on sheet metal'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start Investigation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moderate'));
    await tester.pumpAndSettle();

    expect(service.investigations.single, {
      'incidentId': 'a',
      'severity': 'moderate',
    });
  });

  testWidgets('a reviewer closes an incident with a root cause', (
    tester,
  ) async {
    useTallSurface(tester);
    final service = _FakeIncidentService();
    await seedIncident(
      'a',
      status: 'underInvestigation',
      severity: 'minor',
      reportingDone: true,
    );

    await tester.pumpWidget(
      wrap(role: AppRole.siteManager, uid: 'mgr', service: service),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cut hand on sheet metal'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Close Incident'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'No edge guards');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Close Incident'));
    await tester.pumpAndSettle();

    expect(service.closures.single, {
      'incidentId': 'a',
      'rootCause': 'No edge guards',
    });
  });

  testWidgets('a worker opening their incident gets no investigation '
      'actions', (tester) async {
    await seedIncident('a');

    await tester.pumpWidget(wrap(role: AppRole.worker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cut hand on sheet metal'));
    await tester.pumpAndSettle();

    expect(find.text('Start Investigation'), findsNothing);
  });

  group('incident page — who investigates, who submits evidence', () {
    Future<void> seedAction({required String assignedTo}) async {
      await firestore.doc('organizations/alpha/corrective_actions/ca-1').set({
        'organizationId': 'alpha',
        'projectId': 'project-1',
        'siteId': 'site-1',
        'incidentId': 'a',
        'title': 'Fit edge guards',
        'description': 'Fit guards to stored sheets',
        'assignedTo': assignedTo,
        'assignedBy': 'mgr',
        'assignedToName': 'Fred Foreman',
        'dueDate': Timestamp.fromDate(DateTime(2026, 10, 20)),
        'status': 'open',
        'evidenceRequired': true,
        'evidenceKinds': ['photo'],
      });
    }

    testWidgets('the assigned Foreman gets Complete & Submit, and no '
        'investigation buttons — regression test for the Foreman seeing '
        '"Add Corrective Action" instead of a way to submit evidence', (
      tester,
    ) async {
      useTallSurface(tester);
      await seedIncident('a', status: 'underInvestigation', severity: 'minor');
      await seedAction(assignedTo: 'foreman-1');

      await tester.pumpWidget(wrap(role: AppRole.foreman, uid: 'foreman-1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cut hand on sheet metal'));
      await tester.pumpAndSettle();

      expect(find.text('Assigned to you'), findsOneWidget);
      expect(find.text('Complete & Submit'), findsOneWidget);
      expect(find.text('Add Corrective Action'), findsNothing);
      expect(find.text('Close Incident'), findsNothing);

      await tester.tap(find.text('Complete & Submit'));
      await tester.pumpAndSettle();
      expect(find.text('Submit for Review'), findsOneWidget);
    });

    testWidgets('the Site Manager investigates', (tester) async {
      useTallSurface(tester);
      await seedIncident('a', status: 'underInvestigation', severity: 'minor');
      await seedAction(assignedTo: 'foreman-1');

      await tester.pumpWidget(wrap(role: AppRole.siteManager, uid: 'mgr'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cut hand on sheet metal'));
      await tester.pumpAndSettle();

      expect(find.text('Add Corrective Action'), findsOneWidget);
      expect(find.text('Close Incident'), findsOneWidget);
      expect(find.text('Complete & Submit'), findsNothing);
      expect(find.textContaining('Fred Foreman'), findsOneWidget);
    });
  });

  group('ReportIncidentScreen', () {
    setUp(() async {
      for (final (id, name) in [('site-1', 'Embassy'), ('site-2', 'Depot')]) {
        await firestore.doc('organizations/alpha/sites/$id').set({
          'organizationId': 'alpha',
          'projectId': 'project-1',
          'name': name,
          'code': id.toUpperCase(),
          'status': 'active',
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
        });
      }
    });

    Widget reportApp(
      _FakeIncidentService service, {
      AppRole role = AppRole.worker,
    }) {
      return ChangeNotifierProvider<SessionController>(
        create: (_) => _FakeSession(role: role),
        child: MaterialApp(
          home: ReportIncidentScreen(
            incidentService: service,
            now: () => DateTime(2026, 10, 9, 10, 0),
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'alpha',
            ),
          ),
        ),
      );
    }

    testWidgets('a Site Manager chooses any site of the organization', (
      tester,
    ) async {
      useTallSurface(tester);
      final service = _FakeIncidentService();
      await tester.pumpWidget(reportApp(service, role: AppRole.siteManager));
      await tester.pumpAndSettle();

      expect(find.text('Embassy'), findsOneWidget);
      expect(find.text('Depot'), findsOneWidget);
      await tester.tap(find.text('Depot'));
      await tester.tap(find.text('Something was damaged'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'What happened?'),
        'Excavator hit the boundary wall',
      );
      await tester.scrollUntilVisible(
        find.text('Submit Incident'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Submit Incident'));
      await tester.pumpAndSettle();

      expect(service.reports.single['siteId'], 'site-2');
    });

    testWidgets('reports an injury with the person hurt', (tester) async {
      useTallSurface(tester);
      final service = _FakeIncidentService();
      await tester.pumpWidget(reportApp(service));
      await tester.pumpAndSettle();

      expect(find.text('Who was hurt? (optional)'), findsNothing);
      await tester.tap(find.text('Someone was hurt'));
      await tester.pump();
      expect(find.text('Who was hurt? (optional)'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'What happened?'),
        'Cut hand on sheet metal',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'John',
      );
      await tester.scrollUntilVisible(
        find.text('Submit Incident'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Submit Incident'));
      await tester.pumpAndSettle();

      final report = service.reports.single;
      expect(report['type'], 'injury');
      expect(report['siteId'], 'site-1');
      expect(report['injuredPersonName'], 'John');
      expect(report['occurredAt'], DateTime(2026, 10, 9, 10, 0));
      expect(find.text('Incident Reported'), findsOneWidget);
    });

    testWidgets('a near-miss is sent to the hazard form with "Something '
        'nearly happened" already chosen', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(reportApp(_FakeIncidentService()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Nobody hurt, nothing damaged?'));
      await tester.pumpAndSettle();

      expect(find.text('Report a Hazard'), findsWidgets);
      expect(find.text('What nearly happened?'), findsOneWidget);
    });

    testWidgets('"Something else" covers anything the list does not', (
      tester,
    ) async {
      useTallSurface(tester);
      final service = _FakeIncidentService();
      await tester.pumpWidget(reportApp(service));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Something else'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'What happened?'),
        'Generator overheated and shut down',
      );
      await tester.scrollUntilVisible(
        find.text('Submit Incident'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Submit Incident'));
      await tester.pumpAndSettle();

      expect(service.reports.single['type'], 'other');
    });

    testWidgets('requires a type and a description', (tester) async {
      useTallSurface(tester);
      final service = _FakeIncidentService();
      await tester.pumpWidget(reportApp(service));

      await tester.scrollUntilVisible(
        find.text('Submit Incident'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Submit Incident'));
      await tester.pump();

      expect(service.reports, isEmpty);
      expect(find.text('Please fill in the required fields.'), findsOneWidget);
    });
  });

  testWidgets('an incident cannot be closed until its reporting is done', (
    tester,
  ) async {
    useTallSurface(tester);
    await seedIncident('a', status: 'underInvestigation', severity: 'minor');
    await tester.pumpWidget(wrap(role: AppRole.siteManager, uid: 'mgr'));
    await tester.pumpAndSettle();
    expect(find.text('Reporting not set'), findsOneWidget);
    await tester.tap(find.text('Cut hand on sheet metal'));
    await tester.pumpAndSettle();

    expect(find.text('Reporting level not set'), findsOneWidget);
    final close = tester.widget<AccentButton>(
      find.widgetWithText(AccentButton, 'Close Incident'),
    );
    expect(close.onPressed, isNull);
    expect(
      find.textContaining('Every reporting deadline must be done'),
      findsOneWidget,
    );
  });
}
