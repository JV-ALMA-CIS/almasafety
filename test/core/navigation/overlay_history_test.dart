import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jva_safety/core/navigation/overlay_history.dart';

/// A browser session history: one entry per step, each with the depth
/// OverlayHistory tagged it with (0 = a page's own entry). Like a browser,
/// pushing drops the forward entries, and `go` lands asynchronously.
class _FakeBrowser implements HistoryPort {
  final List<int> entries = [0];
  int index = 0;
  late void Function(int depth) _onPop;

  @override
  int get currentDepth => entries[index];

  @override
  void push(int depth) {
    entries
      ..removeRange(index + 1, entries.length)
      ..add(depth);
    index++;
  }

  @override
  void go(int delta) => scheduleMicrotask(() => _land(index + delta));

  @override
  void listen(void Function(int depth) onPop) => _onPop = onPop;

  void _land(int target) {
    index = target.clamp(0, entries.length - 1);
    _onPop(entries[index]);
  }

  /// The user presses the browser's (or Android's) Back.
  void back() => _land(index - 1);

  /// The user presses Forward.
  void forward() => _land(index + 1);
}

void main() {
  late _FakeBrowser browser;
  late OverlayHistory history;

  setUp(() {
    browser = _FakeBrowser();
    history = OverlayHistory(browser);
  });

  Future<void> pumpApp(WidgetTester tester, {Widget? detail}) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [history.observer()],
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const Text('List'),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          detail ??
                          Scaffold(
                            appBar: AppBar(),
                            body: Builder(
                              builder: (context) => TextButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => Scaffold(
                                      appBar: AppBar(),
                                      body: const Text('Quiz'),
                                    ),
                                  ),
                                ),
                                child: const Text('Detail'),
                              ),
                            ),
                          ),
                    ),
                  ),
                  child: const Text('Open'),
                ),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          const AlertDialog(content: Text('Dialog')),
                    ),
                    child: const Text('Ask'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Browser and app agree: one step per open screen.
  void expectInStep() {
    expect(browser.currentDepth, history.openRoutes.length);
  }

  testWidgets('opening a screen adds one browser step; browser Back closes '
      'it and returns to the list', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(browser.entries, [0, 1]);
    expect(find.text('Detail'), findsOneWidget);

    browser.back();
    await tester.pumpAndSettle();
    expect(find.text('Detail'), findsNothing);
    expect(find.text('List'), findsOneWidget);
    expectInStep();
  });

  testWidgets('closing in the app removes the step, so the next Back '
      'leaves the page as expected', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('List'), findsOneWidget);
    expect(browser.index, 0);
    expectInStep();
  });

  testWidgets('nested screens close one per Back — the quiz returns to its '
      'lesson, then the lesson to the list', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detail'));
    await tester.pumpAndSettle();
    expect(find.text('Quiz'), findsOneWidget);
    expect(browser.entries, [0, 1, 2]);

    browser.back();
    await tester.pumpAndSettle();
    expect(find.text('Quiz'), findsNothing);
    expect(find.text('Detail'), findsOneWidget);

    browser.back();
    await tester.pumpAndSettle();
    expect(find.text('List'), findsOneWidget);
    expect(find.text('Detail'), findsNothing);
    expectInStep();
  });

  testWidgets('Back closes an open dialog, not the page under it', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('Dialog'), findsOneWidget);

    browser.back();
    await tester.pumpAndSettle();
    expect(find.text('Dialog'), findsNothing);
    expect(find.text('List'), findsOneWidget);
    expectInStep();
  });

  group('unsaved changes', () {
    Widget form() => Builder(
      builder: (context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final discard = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Discard changes?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Keep editing'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Discard'),
                ),
              ],
            ),
          );
          if (discard == true && context.mounted) Navigator.of(context).pop();
        },
        child: Scaffold(appBar: AppBar(), body: const Text('Form')),
      ),
    );

    testWidgets('Back asks first; Keep editing keeps the form and its step', (
      tester,
    ) async {
      await pumpApp(tester, detail: form());
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      browser.back();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('Form'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Form'), findsOneWidget);
      expectInStep();
      expect(browser.currentDepth, 1);
    });

    testWidgets('Discard closes the form and lands on the list, without '
        'overshooting', (tester) async {
      await pumpApp(tester, detail: form());
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      browser.back();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Form'), findsNothing);
      expect(find.text('List'), findsOneWidget);
      expectInStep();
      expect(browser.index, greaterThanOrEqualTo(0));
      expect(browser.entries.first, 0);
    });
  });

  testWidgets('Forward onto a closed screen does nothing', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    browser.back();
    await tester.pumpAndSettle();

    browser.forward();
    await tester.pumpAndSettle();
    expect(find.text('List'), findsOneWidget);
    expect(find.text('Detail'), findsNothing);
  });

  testWidgets('go_router pages are left to go_router — no extra steps', (
    tester,
  ) async {
    final router = GoRouter(
      observers: [history.observer()],
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('Home')),
        GoRoute(path: '/b', builder: (_, _) => const Text('B')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/b');
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    expect(history.openRoutes, isEmpty);
    expect(browser.entries, [0]);
  });
}
