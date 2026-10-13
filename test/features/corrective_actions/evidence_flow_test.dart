import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_service.dart';
import 'package:jva_safety/features/corrective_actions/domain/corrective_action.dart';
import 'package:jva_safety/features/corrective_actions/domain/corrective_action_evidence.dart';
import 'package:jva_safety/features/corrective_actions/domain/corrective_action_status.dart';
import 'package:jva_safety/features/corrective_actions/presentation/review_corrective_action_screen.dart';
import 'package:jva_safety/features/corrective_actions/presentation/submit_corrective_action_screen.dart';

class _FakeService extends CorrectiveActionService {
  final submits = <Map<String, Object?>>[];
  final updates = <Map<String, Object?>>[];

  @override
  Future<void> submitForReview({
    required String organizationId,
    required String actionId,
    String? completionNote,
    List<EvidencePhoto> evidencePhotos = const [],
  }) async {
    submits.add({
      'actionId': actionId,
      'note': completionNote,
      'photos': evidencePhotos.length,
    });
  }

  @override
  Future<EvidencePhoto> uploadEvidencePhoto({
    required String organizationId,
    required String actionId,
    required String fileName,
    required Uint8List bytes,
  }) async => EvidencePhoto(
    storagePath: 'organizations/$organizationId/corrective_actions/$actionId/x',
    downloadUrl: 'https://example.com/x.jpg',
  );

  @override
  Future<void> updateCorrectiveActionStatus({
    required String organizationId,
    required String actionId,
    required String status,
    String? reviewFeedback,
  }) async {
    updates.add({'status': status, 'feedback': reviewFeedback});
  }
}

CorrectiveAction _action({
  CorrectiveActionStatus status = CorrectiveActionStatus.open,
  List<CorrectiveActionEvidenceKind> kinds = const [],
  bool evidenceRequired = false,
  String? reviewFeedback,
  String? completionNote,
  DateTime? submittedAt,
}) => CorrectiveAction(
  id: 'ca-1',
  organizationId: 'org-alpha',
  projectId: 'project-1',
  siteId: 'site-1',
  title: 'Fit guard rail',
  description: 'Level 3 edge has no guard rail',
  assignedTo: 'worker-1',
  assignedBy: 'manager-1',
  assignedByName: 'Grace Achieng',
  dueDate: DateTime(2026, 10, 20),
  status: status,
  evidenceRequired: evidenceRequired,
  hazardId: 'hazard-1',
  evidenceKinds: kinds,
  evidenceInstructions: kinds.isEmpty ? null : 'Photo of the new rail',
  reviewFeedback: reviewFeedback,
  completionNote: completionNote,
  submittedAt: submittedAt,
);

void main() {
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(Widget child) => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<bool>(builder: (_) => child)),
          child: const Text('open'),
        ),
      ),
    ),
  );

  group('SubmitCorrectiveActionScreen', () {
    testWidgets('shows what evidence is required and blocks submitting '
        'without the photo', (tester) async {
      tall(tester);
      final service = _FakeService();
      await tester.pumpWidget(
        host(
          SubmitCorrectiveActionScreen(
            organizationId: 'org-alpha',
            action: _action(kinds: [CorrectiveActionEvidenceKind.photo]),
            service: service,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Evidence required'), findsOneWidget);
      expect(find.textContaining('Photo of the finished work'), findsOneWidget);
      expect(find.textContaining('Photo of the new rail'), findsOneWidget);
      expect(find.text('Add at least one photo to submit.'), findsOneWidget);

      final submit = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Submit for Review'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(submit.onPressed, isNull);
    });

    testWidgets('a written confirmation is enough when that is what is asked', (
      tester,
    ) async {
      tall(tester);
      final service = _FakeService();
      await tester.pumpWidget(
        host(
          SubmitCorrectiveActionScreen(
            organizationId: 'org-alpha',
            action: _action(kinds: [CorrectiveActionEvidenceKind.confirmation]),
            service: service,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField),
        'Rail fitted and inspected with the foreman',
      );
      await tester.pump();
      await tester.tap(find.text('Submit for Review'));
      await tester.pumpAndSettle();

      expect(service.submits.single, {
        'actionId': 'ca-1',
        'note': 'Rail fitted and inspected with the foreman',
        'photos': 0,
      });
    });

    testWidgets(
      'an older action with only "evidence required" asks for a photo',
      (tester) async {
        tall(tester);
        await tester.pumpWidget(
          host(
            SubmitCorrectiveActionScreen(
              organizationId: 'org-alpha',
              action: _action(evidenceRequired: true),
              service: _FakeService(),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.text('Photos (at least one required)'), findsOneWidget);
      },
    );

    testWidgets('shows why the work was sent back', (tester) async {
      tall(tester);
      await tester.pumpWidget(
        host(
          SubmitCorrectiveActionScreen(
            organizationId: 'org-alpha',
            action: _action(
              status: CorrectiveActionStatus.inProgress,
              reviewFeedback: 'Photo is blurry — please retake',
            ),
            service: _FakeService(),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Sent back by the reviewer'), findsOneWidget);
      expect(find.text('Photo is blurry — please retake'), findsOneWidget);
    });
  });

  group('ReviewCorrectiveActionScreen', () {
    CorrectiveAction submitted() => _action(
      status: CorrectiveActionStatus.submittedForReview,
      kinds: [CorrectiveActionEvidenceKind.confirmation],
      completionNote: 'Rail fitted',
      submittedAt: DateTime(2026, 10, 12, 9, 30),
    );

    testWidgets('shows names and the submitted note, and approving completes '
        'the action', (tester) async {
      tall(tester);
      final service = _FakeService();
      await tester.pumpWidget(
        host(
          ReviewCorrectiveActionScreen(
            organizationId: 'org-alpha',
            action: submitted(),
            assignedToName: 'Peter Otieno',
            siteName: 'Embassy',
            service: service,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Peter Otieno'), findsWidgets);
      expect(find.text('Grace Achieng'), findsOneWidget);
      expect(find.text('Rail fitted'), findsOneWidget);
      expect(find.text('worker-1'), findsNothing);

      await tester.tap(find.text('Approve & complete'));
      await tester.pumpAndSettle();
      expect(service.updates.single, {'status': 'completed', 'feedback': null});
    });

    testWidgets('sending back records the reason', (tester) async {
      tall(tester);
      final service = _FakeService();
      await tester.pumpWidget(
        host(
          ReviewCorrectiveActionScreen(
            organizationId: 'org-alpha',
            action: submitted(),
            assignedToName: 'Peter Otieno',
            siteName: 'Embassy',
            service: service,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Send back'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Show the bolts');
      await tester.tap(find.widgetWithText(FilledButton, 'Send back'));
      await tester.pumpAndSettle();

      expect(service.updates.single, {
        'status': 'inProgress',
        'feedback': 'Show the bolts',
      });
    });

    testWidgets('an action not awaiting review has no approve button', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(
        host(
          ReviewCorrectiveActionScreen(
            organizationId: 'org-alpha',
            action: _action(),
            assignedToName: 'Peter Otieno',
            siteName: 'Embassy',
            service: _FakeService(),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Approve & complete'), findsNothing);
      expect(find.text('Nothing has been submitted yet.'), findsOneWidget);
    });
  });
}
