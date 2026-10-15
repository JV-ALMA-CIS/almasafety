import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/reports/pdf_report.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/data/people_directory.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/inspections/presentation/deficiency_log_pdf.dart';
import 'package:jva_safety/features/inspections/presentation/deficiency_log_screen.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/risk_assessments/data/risk_assessment_repository.dart';
import 'package:jva_safety/features/risk_assessments/domain/risk_assessment.dart';
import 'package:jva_safety/features/risk_assessments/domain/standard_ahas.dart';
import 'package:jva_safety/features/risk_assessments/presentation/aha_pdf.dart';
import 'package:jva_safety/features/risk_assessments/presentation/risk_assessments_screen.dart';

/// The words drawn in an uncompressed PDF, joined with spaces. The PDF
/// writes each word separately (`[(word)]TJ`), so phrases are rebuilt here.
String _pdfText(Uint8List bytes) {
  final raw = latin1.decode(bytes);
  final words = [
    for (final m in RegExp(r'\[\((.*?)\)\]TJ').allMatches(raw))
      m.group(1)!.replaceAll(r'\(', '(').replaceAll(r'\)', ')'),
  ];
  return '${raw.substring(0, 8)} ${words.join(' ')}';
}

class _Session extends SessionController {
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
  Membership? get activeMembership => const Membership(
    organizationId: 'org',
    role: AppRole.siteManager,
    siteIds: [],
    status: MembershipStatus.active,
  );
}

class _NoPeople extends PeopleDirectory {
  @override
  Future<Map<String, String>> namesFor(String organizationId) async => {
    'fred': 'Fred Foreman',
  };
}

/// Records what would be printed, and builds the PDF like the print window
/// would.
class _Printer {
  String? name;
  Uint8List? pdf;

  Future<void> call({
    required String name,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  }) async {
    this.name = name;
    pdf = await build(PdfPageFormat.a4);
  }
}

RiskAssessment _aha({String status = 'accepted'}) =>
    RiskAssessment.fromMap('aha-1', {
      'organizationId': 'org',
      'siteId': 'site-1',
      'siteName': 'Italian Embassy',
      'featureOfWork': 'Interior painting',
      'activity': 'Painting the residence — 2nd floor',
      'status': status,
      'revision': 2,
      'steps': [
        {
          'id': 's1',
          'step': 'Erect scaffold',
          'hazards': ['Falls from height'],
          'controls': ['Guardrails on open sides — 42" high'],
        },
      ],
      'equipment': ['Scaffold'],
      'inspectionRequirements': ['Scaffold tagged daily'],
      'trainingRequirements': ['Working at height'],
      'preparedByName': 'Eston',
      'acceptedByName': 'Giuseppe',
      'corName': 'J. Smith',
    });

void main() {
  group('the report kit', () {
    test('typographic characters become plain ones the PDF can draw', () {
      expect(
        PdfReport.clean('Tied — 4× base “wide” → done… 😀'),
        'Tied - 4x base "wide" -> done... ',
      );
    });
  });

  group('the AHA PDF', () {
    test(
      'follows the form: steps, hazards, controls, lists, sign-off',
      () async {
        final text = _pdfText(
          await buildAhaPdf(
            aha: _aha(),
            organizationName: 'JV ALMA C.I.S.',
            compress: false,
          ),
        );
        expect(text, startsWith('%PDF'));
        for (final expected in [
          'ACTIVITY HAZARD ANALYSIS',
          'Interior painting',
          'PRINCIPAL STEPS',
          'RECOMMENDED CONTROLS',
          'Erect scaffold',
          'Falls from height',
          'Guardrails on open sides - 42',
          'EQUIPMENT TO BE USED',
          'Scaffold tagged daily',
          'Giuseppe',
          'J. Smith',
        ]) {
          expect(text, contains(expected), reason: expected);
        }
        expect(text, isNot(contains('DRAFT')));
      },
    );

    test('a draft is marked DRAFT', () async {
      final text = _pdfText(
        await buildAhaPdf(
          aha: _aha(status: 'draft'),
          organizationName: 'JV ALMA C.I.S.',
          compress: false,
        ),
      );
      expect(text, contains('DRAFT - not yet accepted'));
    });

    test('every library draft prints without trouble', () async {
      for (final draft in standardAhas) {
        final aha = RiskAssessment.fromMap('x', {
          'siteId': 's',
          'status': 'draft',
          'featureOfWork': draft.content.featureOfWork,
          'steps': [for (final s in draft.content.steps) s.toJson()],
          'equipment': draft.content.equipment,
          'inspectionRequirements': draft.content.inspectionRequirements,
          'trainingRequirements': draft.content.trainingRequirements,
        });
        final bytes = await buildAhaPdf(aha: aha, organizationName: 'Org');
        expect(bytes.length, greaterThan(1000), reason: aha.featureOfWork);
      }
    });
  });

  group('the Deficiency Log PDF', () {
    test('has the Section 7c columns and each deficiency', () async {
      final text = _pdfText(
        await buildDeficiencyLogPdf(
          organizationName: 'JV ALMA C.I.S.',
          scope: 'Open deficiencies',
          compress: false,
          lines: [
            DeficiencyLogLine(
              identified: DateTime(2026, 10, 13),
              site: 'Rosslyn Ridge',
              description: 'Guardrail missing on level 2',
              foundIn: 'Daily site inspection',
              responsible: 'Fred Foreman',
              targetDate: DateTime(2026, 10, 16),
              resolved: null,
              status: 'Being fixed',
              isOpen: true,
            ),
          ],
        ),
      );
      for (final expected in [
        'DEFICIENCY LOG',
        'Date identified',
        'Person responsible',
        'Target date',
        'Date resolved',
        'Guardrail missing on level 2',
        'Fred Foreman',
        '2026-10-16',
        '1 deficiency, 1 open',
      ]) {
        expect(text, contains(expected), reason: expected);
      }
    });
  });

  group('the Print / PDF buttons', () {
    late FakeFirebaseFirestore firestore;

    setUp(() => firestore = FakeFirebaseFirestore());

    testWidgets('an AHA prints with its own name', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await firestore.doc('organizations/org/risk_assessments/aha-1').set({
        ..._ahaData(),
        'status': 'accepted',
      });
      final printer = _Printer();
      await tester.pumpWidget(
        ChangeNotifierProvider<SessionController>(
          create: (_) => _Session(),
          child: MaterialApp(
            home: RiskAssessmentDetailScreen(
              organizationId: 'org',
              id: 'aha-1',
              repository: RiskAssessmentRepository(
                firestoreService: FirestoreService(firestore: firestore),
                organizationId: 'org',
              ),
              printReport: printer.call,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print / PDF'));
      await tester.pumpAndSettle();
      expect(printer.name, 'AHA - Interior painting - Italian Embassy - rev 2');
      expect(printer.pdf, isNotNull);
    });

    testWidgets('the Deficiency Log prints what is shown', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final service = FirestoreService(firestore: firestore);
      await firestore.doc('organizations/org/hazards/h1').set({
        'organizationId': 'org',
        'projectId': 'p',
        'siteId': 'site-1',
        'reportedByUid': 'fred',
        'category': 'workingAtHeight',
        'riskLevel': 'high',
        'description': 'Guardrail missing',
        'status': 'reported',
        'inspectionId': 'i1',
        'inspectionName': 'Daily site inspection',
        'createdAt': Timestamp.now(),
      });
      final printer = _Printer();
      await tester.pumpWidget(
        MaterialApp(
          home: DeficiencyLogScreen(
            organizationId: 'org',
            hazardRepository: HazardRepository(
              firestoreService: service,
              organizationId: 'org',
            ),
            correctiveActionRepository: CorrectiveActionRepository(
              firestoreService: service,
              organizationId: 'org',
            ),
            peopleDirectory: _NoPeople(),
            siteRepository: SiteRepository(
              firestoreService: service,
              organizationId: 'org',
            ),
            printReport: printer.call,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Guardrail missing'), findsOneWidget);
      await tester.tap(find.text('Print / PDF'));
      await tester.pumpAndSettle();
      expect(printer.name, startsWith('Deficiency Log - '));
      expect(printer.pdf, isNotNull);
    });
  });
}

Map<String, Object?> _ahaData() => {
  'organizationId': 'org',
  'siteId': 'site-1',
  'siteName': 'Italian Embassy',
  'featureOfWork': 'Interior painting',
  'revision': 2,
  'steps': [
    {
      'id': 's1',
      'step': 'Erect scaffold',
      'hazards': ['Falls'],
      'controls': ['Guardrails'],
    },
  ],
  'equipment': ['Scaffold'],
  'inspectionRequirements': ['Daily'],
  'trainingRequirements': ['Height'],
};
