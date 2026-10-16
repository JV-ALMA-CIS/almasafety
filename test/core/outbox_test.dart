import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/offline/outbox.dart';
import 'package:jva_safety/core/offline/outbox_status_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A pretend server and signal for the outbox.
class _World {
  bool online = true;

  /// When set, every call/upload fails as if the signal dropped.
  bool dropSignal = false;
  String uid = 'fred';
  final calls = <String>[];
  final uploads = <String>[];

  /// Errors the server raises, by callable name.
  final refuse = <String, FirebaseFunctionsException>{};

  Outbox outbox() => Outbox(
    caller: call,
    uploader: (path, bytes) async {
      if (dropSignal) {
        throw FirebaseFunctionsException(
          code: 'unavailable',
          message: 'unavailable',
        );
      }
      uploads.add('$path:${bytes.length}');
      return 'https://files/$path';
    },
    currentUid: () => uid,
    isOnline: () => online,
    preferences: SharedPreferences.getInstance,
  );

  Future<Object?> call(String name, Map<String, Object?> data) async {
    if (dropSignal) {
      throw FirebaseFunctionsException(code: 'internal', message: 'internal');
    }
    final refusal = refuse[name];
    if (refusal != null) throw refusal;
    calls.add('$name ${data['n'] ?? ''}${data['photoUrl'] ?? ''}'.trim());
    return {'id': 'ok'};
  }
}

Matcher get _savedOffline => throwsA(isA<SavedOfflineException>());

void main() {
  late _World world;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    world = _World();
  });

  test('with signal it is an ordinary call', () async {
    final outbox = world.outbox();
    final result = await outbox.send(
      callable: 'createHazard',
      data: {'n': 1},
      label: 'Hazard report',
    );
    expect(result, {'id': 'ok'});
    expect(world.calls, ['createHazard 1']);
    expect(outbox.entries, isEmpty);
    outbox.dispose();
  });

  test('with no signal it is kept on the phone, then sent with its photo '
      'once the signal is back', () async {
    final outbox = world.outbox();
    world.online = false;
    await expectLater(
      outbox.send(
        callable: 'createHazard',
        data: {'n': 1},
        label: 'Hazard report',
        photo: OutboxPhoto(
          storagePath: 'organizations/o/hazards/h/p.jpg',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ),
      _savedOffline,
    );
    expect(world.calls, isEmpty);
    expect(outbox.waiting.single.label, 'Hazard report');

    // A fresh start (app reopened) still has it.
    final reopened = world.outbox();
    await reopened.flush();
    expect(world.calls, isEmpty, reason: 'still no signal');
    expect(reopened.waiting, hasLength(1));

    world.online = true;
    await reopened.flush();
    expect(world.uploads, ['organizations/o/hazards/h/p.jpg:3']);
    expect(world.calls, [
      'createHazard 1https://files/organizations/o/hazards/h/p.jpg',
    ]);
    expect(reopened.entries, isEmpty);
    outbox.dispose();
    reopened.dispose();
  });

  test('a dropped signal mid-send is kept; a real refusal is not', () async {
    final outbox = world.outbox();
    world.dropSignal = true;
    await expectLater(
      outbox.send(callable: 'saveManHours', data: {'n': 1}, label: 'x'),
      _savedOffline,
    );
    expect(outbox.waiting, hasLength(1));

    world.dropSignal = false;
    await outbox.flush();
    world.refuse['saveManHours'] = FirebaseFunctionsException(
      code: 'invalid-argument',
      message: 'hours must be a number',
    );
    await expectLater(
      outbox.send(callable: 'saveManHours', data: {'n': 2}, label: 'x'),
      throwsA(isA<FirebaseFunctionsException>()),
    );
    expect(outbox.entries, isEmpty);
    expect(world.calls, ['saveManHours 1']);
    outbox.dispose();
  });

  test('entries go in the order they were made', () async {
    final outbox = world.outbox();
    world.online = false;
    for (final n in [1, 2]) {
      await expectLater(
        outbox.send(
          callable: 'recordInspectionItem',
          data: {'n': n},
          label: 'a',
        ),
        _savedOffline,
      );
    }
    world.online = true;
    // A new entry waits behind the older ones, which go first.
    await outbox.send(callable: 'submitInspection', data: {'n': 3}, label: 's');
    expect(world.calls, [
      'recordInspectionItem 1',
      'recordInspectionItem 2',
      'submitInspection 3',
    ]);
    outbox.dispose();
  });

  test('a repeat the server already has counts as sent; a refusal waits '
      'for Try again or Remove', () async {
    final outbox = world.outbox();
    world.online = false;
    for (final name in ['createIncident', 'submitPreStartCheck']) {
      await expectLater(
        outbox.send(callable: name, data: const {}, label: name),
        _savedOffline,
      );
    }
    world.online = true;
    world.refuse['createIncident'] = FirebaseFunctionsException(
      code: 'already-exists',
      message: 'An incident with that id already exists.',
    );
    world.refuse['submitPreStartCheck'] = FirebaseFunctionsException(
      code: 'failed-precondition',
      message: 'This Pre-Start Check was for 2026-10-14.',
    );
    await outbox.flush();
    expect(outbox.waiting, isEmpty);
    final failed = outbox.failed.single;
    expect(failed.callable, 'submitPreStartCheck');
    expect(failed.error, 'This Pre-Start Check was for 2026-10-14.');

    world.refuse.clear();
    await outbox.retry(failed.id);
    expect(outbox.entries, isEmpty);
    expect(world.calls, ['submitPreStartCheck']);
    outbox.dispose();
  });

  test('each person only sees and sends their own entries', () async {
    final outbox = world.outbox();
    world.online = false;
    await expectLater(
      outbox.send(callable: 'saveManHours', data: {'n': 1}, label: 'x'),
      _savedOffline,
    );
    world.uid = 'eston';
    expect(outbox.entries, isEmpty);
    world.online = true;
    await outbox.flush();
    expect(world.calls, isEmpty);
    world.uid = 'fred';
    await outbox.flush();
    expect(world.calls, ['saveManHours 1']);
    outbox.dispose();
  });

  test('connection errors are told apart from server errors', () {
    expect(
      Outbox.isConnectionError(
        FirebaseFunctionsException(code: 'unavailable', message: 'x'),
      ),
      isTrue,
    );
    expect(
      Outbox.isConnectionError(
        FirebaseFunctionsException(code: 'internal', message: 'internal'),
      ),
      isTrue,
    );
    expect(
      Outbox.isConnectionError(
        FirebaseFunctionsException(
          code: 'internal',
          message: 'Could not compute the outcome.',
        ),
      ),
      isFalse,
    );
    expect(
      Outbox.isConnectionError(
        FirebaseFunctionsException(code: 'permission-denied', message: 'no'),
      ),
      isFalse,
    );
  });

  group('the status strip', () {
    Future<void> pump(WidgetTester tester, Outbox outbox) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OutboxStatusBar(outbox: outbox, child: const Text('page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('hidden when there is signal and nothing waiting', (
      tester,
    ) async {
      final outbox = world.outbox();
      await pump(tester, outbox);
      expect(find.text('page'), findsOneWidget);
      expect(find.textContaining('saved on this phone'), findsNothing);
      expect(find.textContaining('No signal'), findsNothing);
      outbox.dispose();
    });

    testWidgets('no signal, then waiting entries, listed on tap', (
      tester,
    ) async {
      final outbox = world.outbox();
      world.online = false;
      await pump(tester, outbox);
      expect(find.textContaining('No signal - keep working'), findsOneWidget);

      await tester.runAsync(() async {
        await expectLater(
          outbox.send(
            callable: 'createHazard',
            data: const {},
            label: 'Hazard report',
          ),
          _savedOffline,
        );
      });
      await tester.pumpAndSettle();
      expect(
        find.text(
          '1 entry saved on this phone - will send when the signal comes '
          'back',
        ),
        findsOneWidget,
      );
      await tester.tap(find.textContaining('1 entry saved'));
      await tester.pumpAndSettle();
      expect(find.text('Saved on this phone'), findsOneWidget);
      expect(find.text('Hazard report'), findsOneWidget);
      outbox.dispose();
    });

    testWidgets('a refused entry can be removed', (tester) async {
      final outbox = world.outbox();
      world.online = false;
      await tester.runAsync(() async {
        await expectLater(
          outbox.send(
            callable: 'submitPreStartCheck',
            data: const {},
            label: 'Daily Pre-Start Check',
          ),
          _savedOffline,
        );
        world.online = true;
        world.refuse['submitPreStartCheck'] = FirebaseFunctionsException(
          code: 'failed-precondition',
          message: 'Too late for that day.',
        );
        await outbox.flush();
      });
      await pump(tester, outbox);
      expect(
        find.text('1 entry could not be sent - tap to see why'),
        findsOneWidget,
      );
      await tester.tap(find.textContaining('could not be sent'));
      await tester.pumpAndSettle();
      expect(find.text('Too late for that day.'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(outbox.entries, isEmpty);
      expect(find.text('Everything has been sent.'), findsOneWidget);
      outbox.dispose();
    });
  });
}
