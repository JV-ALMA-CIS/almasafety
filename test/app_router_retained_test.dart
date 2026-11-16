import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jva_safety/app.dart';
import 'package:jva_safety/core/services/theme_controller.dart';

void main() {
  testWidgets('changing the appearance keeps the same router — the user is '
      'not sent back to the start and open screens stay open', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const JvaSafetyApp());
    await tester.pump();

    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    final before = app().routerConfig;
    expect(before, isNotNull);

    final controller = Provider.of<ThemeController>(
      tester.element(find.byType(MaterialApp)),
      listen: false,
    );
    controller.setMode(ThemeMode.dark);
    await tester.pump();

    expect(app().themeMode, ThemeMode.dark);
    expect(identical(app().routerConfig, before), isTrue);
  });

  testWidgets('Large text (Settings) scales text on every screen and keeps '
      'the router', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const JvaSafetyApp());
    await tester.pump();
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    final before = app().routerConfig;
    double scale() =>
        MediaQuery.textScalerOf(
          tester.element(find.byType(CircularProgressIndicator)),
        ).scale(10) /
        10;
    expect(scale(), 1);

    Provider.of<ThemeController>(
      tester.element(find.byType(MaterialApp)),
      listen: false,
    ).setTextSize(AppTextSize.large);
    await tester.pump();
    expect(scale(), closeTo(1.15, 0.001));
    expect(identical(app().routerConfig, before), isTrue);
  });
}
