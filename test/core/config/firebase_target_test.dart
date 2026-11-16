import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/config/firebase_target.dart';

void main() {
  const production = FirebaseOptions(
    apiKey: 'key',
    appId: 'app',
    messagingSenderId: 'sender',
    projectId: 'jva-safety',
    storageBucket: 'jva-safety.firebasestorage.app',
  );

  test('a normal build (no --dart-define) uses production, unchanged', () {
    expect(FirebaseTarget.useEmulators, isFalse);
    expect(identical(FirebaseTarget.options(production), production), isTrue);
  });

  test('the emulator target is a demo- project with its own bucket', () {
    expect(FirebaseTarget.emulatorProjectId, startsWith('demo-'));
    expect(FirebaseTarget.firestorePort, isNot(8080));
  });
}
