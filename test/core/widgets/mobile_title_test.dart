import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/widgets/mobile_title.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/lesson_quiz.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning_type.dart';
import 'package:jva_safety/features/safety_learning/presentation/learning_detail_screen.dart';

class _QuietService extends WorkerLearningService {
  @override
  Future<LessonQuiz> getLessonQuiz({
    required String organizationId,
    required String learningId,
  }) async =>
      const LessonQuiz(questions: [], required: false, quizRequired: false);
}

void main() {
  void setWidth(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Finder barTitle(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  for (final (width, shown) in [
    (320.0, true),
    (599.0, true),
    (600.0, false),
    (1440.0, false),
  ]) {
    testWidgets('at ${width.toInt()}px the title is '
        '${shown ? 'shown' : 'left to the banner'}', (tester) async {
      setWidth(tester, width);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const MobileTitle('Hazard Details')),
          ),
        ),
      );
      expect(barTitle('Hazard Details'), shown ? findsOneWidget : findsNothing);
    });
  }

  testWidgets('a lesson opened on a phone: back arrow, "Learning Details", '
      'banner below, no overflow', (tester) async {
    setWidth(tester, 360);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LearningDetailScreen(
                  organizationId: 'org-a',
                  learning: const SafetyLearning(
                    id: 'l1',
                    organizationId: 'org-a',
                    title:
                        'A very long lesson title about working safely at '
                        'height on scaffolds',
                    type: SafetyLearningType.video,
                    contentReference: 'https://www.youtube.com/watch?v=x',
                    status: OrganizationRecordStatus.active,
                  ),
                  watchOnly: true,
                  workerLearningService: _QuietService(),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(barTitle('Learning Details'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
  });
}
