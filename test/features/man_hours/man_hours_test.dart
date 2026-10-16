import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/incidents/data/incident_repository.dart';
import 'package:jva_safety/features/man_hours/data/man_hours_repository.dart';
import 'package:jva_safety/features/man_hours/data/man_hours_service.dart';
import 'package:jva_safety/features/man_hours/domain/man_hours.dart';
import 'package:jva_safety/features/man_hours/presentation/man_hours_pdf.dart';
import 'package:jva_safety/features/man_hours/presentation/man_hours_screen.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _Session extends SessionController {
  _Session(this.role);

  final AppRole role;

  @override
  UserProfile? get profile => const UserProfile(
    uid: 'me',
    name: 'Eston',
    email: 'e@example.com',
    accountStatus: AccountStatus.active,
  );

  @override
  String? get activeOrganizationId => 'org';

  @override
  Membership? get activeMembership => Membership(
    organizationId: 'org',
    role: role,
    siteIds: const ['rosslyn'],
    status: MembershipStatus.active,
  );
}

class _FakeService extends ManHoursService {
  final saved = <String>[];
  final reported = <String>[];

  @override
  Future<void> save({
    required String organizationId,
    required String siteId,
    required String month,
    required double hours,
    required int workers,
    String? notes,
  }) async => saved.add('$siteId|$month|$hours|$workers|$notes');

  @override
  Future<void> markReported({
    required String organizationId,
    required String month,
  }) async => reported.add(month);

  @override
  Future<({int workerDays, int meetingDays})> suggestion({
    required String organizationId,
    required String siteId,
    required String month,
  }) async => (workerDays: 110, meetingDays: 22);
}

String _pdfWords(Uint8List bytes) {
  final raw = latin1.decode(bytes);
  return [
    for (final m in RegExp(r'\[\((.*?)\)\]TJ').allMatches(raw)) m.group(1)!,
  ].join(' ');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('months', () {
    test('the month being reported is last month, due the 25th after', () {
      expect(reportingMonth(DateTime(2026, 10, 15)), '2026-09');
      expect(reportingMonth(DateTime(2026, 1, 3)), '2025-12');
      expect(manHoursDueDate('2026-09'), DateTime(2026, 10, 25));
      expect(manHoursDueDate('2025-12'), DateTime(2026, 1, 25));
      expect(monthLabel('2026-09'), 'September 2026');
    });
  });

  test('the printed report has every site, totals and incidents', () async {
    final text = _pdfWords(
      await buildManHoursPdf(
        month: '2026-09',
        organizationName: 'JV ALMA C.I.S.',
        compress: false,
        lines: const [
          ManHoursPdfLine(
            site: 'Rosslyn Ridge',
            workers: 20,
            hours: 3520,
            lostTime: 1,
            recordable: 2,
            enteredBy: 'Fred',
          ),
          ManHoursPdfLine(
            site: 'Italian Embassy',
            workers: null,
            hours: null,
            lostTime: 0,
            recordable: 0,
          ),
        ],
      ),
    );
    for (final expected in [
      'MONTHLY MAN-HOURS REPORT',
      'September 2026',
      'Rosslyn Ridge',
      '3520',
      'NOT ENTERED',
      'TOTAL',
      '1 site not entered yet.',
    ]) {
      expect(text, contains(expected), reason: expected);
    }
  });

  group('the page', () {
    late FakeFirebaseFirestore firestore;
    late _FakeService service;

    setUp(() async {
      firestore = FakeFirebaseFirestore();
      service = _FakeService();
      for (final (id, name) in [
        ('rosslyn', 'Rosslyn Ridge'),
        ('embassy', 'Italian Embassy'),
      ]) {
        await firestore.doc('organizations/org/sites/$id').set({
          'organizationId': 'org',
          'projectId': 'p',
          'name': name,
          'code': id,
          'status': 'active',
        });
      }
    });

    Future<void> open(WidgetTester tester, AppRole role) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final fs = FirestoreService(firestore: firestore);
      await tester.pumpWidget(
        ChangeNotifierProvider<SessionController>(
          create: (_) => _Session(role),
          child: MaterialApp(
            home: Scaffold(
              body: ManHoursScreen(
                repository: ManHoursRepository(
                  firestoreService: fs,
                  organizationId: 'org',
                ),
                service: service,
                siteRepository: SiteRepository(
                  firestoreService: fs,
                  organizationId: 'org',
                ),
                incidentRepository: IncidentRepository(
                  firestoreService: fs,
                  organizationId: 'org',
                ),
                printReport: ({required name, required build}) async =>
                    build(PdfPageFormat.a4),
                now: () => DateTime(2026, 10, 15),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a Site Manager sees every site for last month, due date', (
      tester,
    ) async {
      await open(tester, AppRole.siteManager);
      expect(find.text('Rosslyn Ridge'), findsOneWidget);
      expect(find.text('Italian Embassy'), findsOneWidget);
      expect(find.text('0 of 2 sites entered'), findsOneWidget);
      expect(
        find.textContaining('Due 25 Oct - not yet reported'),
        findsOneWidget,
      );
    });

    testWidgets('a Foreman sees only their site; the suggestion fills the '
        'hours and Save sends them', (tester) async {
      await open(tester, AppRole.foreman);
      expect(find.text('Italian Embassy'), findsNothing);
      expect(find.text('Mark as reported to the Safety Office'), findsNothing);

      await tester.tap(find.text('Suggest from attendance'));
      await tester.pumpAndSettle();
      expect(find.textContaining('110 worker-days'), findsOneWidget);
      expect(find.widgetWithText(TextField, '880'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Workers'), '6');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(service.saved, ['rosslyn|2026-09|880.0|6|null']);
    });

    testWidgets('a Site Manager marks the month reported', (tester) async {
      await firestore.doc('organizations/org/man_hours/rosslyn_2026-09').set({
        'siteId': 'rosslyn',
        'month': '2026-09',
        'hours': 880,
        'workers': 6,
      });
      await open(tester, AppRole.siteManager);
      expect(find.text('1 of 2 sites entered'), findsOneWidget);
      await tester.tap(find.text('Mark as reported to the Safety Office'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark reported'));
      await tester.pumpAndSettle();
      expect(service.reported, ['2026-09']);
    });
  });
}
