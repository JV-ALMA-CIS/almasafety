import 'package:firebase_core/firebase_core.dart';

/// Which Firebase the app talks to — production unless a build explicitly
/// asks for the local emulators:
///
///     flutter run -d chrome --dart-define=USE_FIREBASE_EMULATORS=true
///
/// With the flag the app uses the `demo-jva-safety` project (a `demo-`
/// project can never reach real Firebase resources, by Firebase's own
/// design) on the emulator ports of `firebase.emulators.json`, and push
/// notifications are switched off. Without it nothing changes. A build
/// cannot be in both modes: the value is fixed at compile time.
class FirebaseTarget {
  FirebaseTarget._();

  static const bool useEmulators = bool.fromEnvironment(
    'USE_FIREBASE_EMULATORS',
  );

  /// The emulator project — must match `firebase.emulators.json` runs
  /// (`--project demo-jva-safety`).
  static const String emulatorProjectId = 'demo-jva-safety';
  static const String emulatorHost = String.fromEnvironment(
    'FIREBASE_EMULATOR_HOST',
    defaultValue: '127.0.0.1',
  );

  // Ports from firebase.emulators.json (Firestore is not on 8080, which
  // firebase.json uses but another service on the development machine
  // already occupies).
  static const int authPort = 9099;
  static const int firestorePort = 8085;
  static const int functionsPort = 5001;
  static const int storagePort = 9199;

  /// The options for [Firebase.initializeApp]: [production] unchanged, or
  /// the same app pointed at the demo project and its emulator bucket.
  static FirebaseOptions options(FirebaseOptions production) => useEmulators
      ? production.copyWith(
          projectId: emulatorProjectId,
          storageBucket: '$emulatorProjectId.appspot.com',
        )
      : production;
}
