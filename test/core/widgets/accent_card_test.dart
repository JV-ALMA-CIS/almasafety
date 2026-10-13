import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/theme/app_colors.dart';
import 'package:jva_safety/core/widgets/accent_card.dart';
import 'package:jva_safety/core/widgets/color_choice_chips.dart';
import 'package:jva_safety/features/pre_start_checks/presentation/pre_start_visuals.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('AccentCard shows title, badges, body, details and actions', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      _wrap(
        AccentCard(
          color: AppColors.hazards,
          icon: Icons.warning,
          title: 'Loose scaffolding',
          badges: const [AccentBadge(label: 'Reported', color: Colors.red)],
          body: 'Board missing on level 3',
          details: const [AccentDetail(icon: Icons.place, text: 'Site A')],
          actions: [
            AccentButton(
              label: 'Acknowledge',
              icon: Icons.visibility,
              color: AppColors.meetings,
              onPressed: () => tapped = true,
            ),
          ],
        ),
      ),
    );

    expect(find.text('Loose scaffolding'), findsOneWidget);
    expect(find.text('Reported'), findsOneWidget);
    expect(find.text('Board missing on level 3'), findsOneWidget);
    expect(find.text('Site A'), findsOneWidget);
    await tester.tap(find.text('Acknowledge'));
    expect(tapped, isTrue);
  });

  testWidgets('ColorChoiceChips reports the chosen value', (tester) async {
    String? chosen;
    await tester.pumpWidget(
      _wrap(
        ColorChoiceChips<String>(
          label: 'Severity',
          selected: 'low',
          onSelected: (value) => chosen = value,
          choices: const [
            ColorChoice(value: 'low', label: 'Low', color: AppColors.meetings),
            ColorChoice(value: 'high', label: 'High', color: AppColors.stop),
          ],
        ),
      ),
    );

    expect(find.text('Severity'), findsOneWidget);
    await tester.tap(find.text('High'));
    expect(chosen, 'high');
  });

  test('AppColors.forLabel is stable for the same label, any case', () {
    expect(AppColors.forLabel('Height'), AppColors.forLabel('height'));
  });

  test('hazardEmojiFor matches activities and meeting points', () {
    expect(hazardEmojiFor('Roofing'), '🪜');
    expect(hazardEmojiFor('Electrical installation'), '⚡');
    expect(hazardEmojiFor('Painting'), '⛑️');
  });
}
