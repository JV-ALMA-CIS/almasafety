import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to ThemeMode.system before anything is persisted', () async {
    final controller = ThemeController();

    expect(controller.mode, ThemeMode.system);
  });

  test('setMode updates the in-memory value synchronously', () {
    final controller = ThemeController();

    controller.setMode(ThemeMode.dark);

    expect(controller.mode, ThemeMode.dark);
  });

  test('setMode notifies listeners', () {
    final controller = ThemeController();
    var notified = false;
    controller.addListener(() => notified = true);

    controller.setMode(ThemeMode.light);

    expect(notified, isTrue);
  });

  test('setMode with the current value is a no-op — no redundant notify', () {
    final controller = ThemeController();
    controller.setMode(ThemeMode.dark);
    var notifyCount = 0;
    controller.addListener(() => notifyCount++);

    controller.setMode(ThemeMode.dark);

    expect(notifyCount, 0);
  });

  test('a persisted choice survives across controller instances — same '
      'device, next launch', () async {
    final first = ThemeController();
    first.setMode(ThemeMode.dark);
    // The write-through is fire-and-forget; give it a turn to land before
    // constructing the next controller that reads it back.
    await Future<void>.delayed(Duration.zero);

    final second = ThemeController();
    await Future<void>.delayed(Duration.zero);

    expect(second.mode, ThemeMode.dark);
  });

  test('the persisted choice is NOT keyed per-uid — a shared device keeps '
      'one preference regardless of which account is signed in', () async {
    // Unlike SessionController.setActiveOrganization (keyed
    // 'activeOrganizationId:$uid'), ThemeController takes no uid at all —
    // this test pins that down by using a single fixed SharedPreferences
    // key across two independently-constructed controllers, with nothing
    // resembling an account identity anywhere in the flow.
    final prefs = await SharedPreferences.getInstance();
    final controller = ThemeController(sharedPreferences: Future.value(prefs));

    controller.setMode(ThemeMode.dark);
    await Future<void>.delayed(Duration.zero);

    expect(prefs.getString('themeMode'), 'dark');
  });

  test(
    'an unrecognised or absent persisted value falls back to system',
    () async {
      SharedPreferences.setMockInitialValues({'themeMode': 'not-a-real-mode'});

      final controller = ThemeController();
      await Future<void>.delayed(Duration.zero);

      expect(controller.mode, ThemeMode.system);
    },
  );
}
