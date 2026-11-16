import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'app.dart';
import 'core/config/firebase_target.dart';
import 'core/offline/outbox.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Guarded so the app (and widget tests, which never call main()) can still
  // run if Firebase init fails for any reason (e.g. missing platform config,
  // no network in a test environment).
  try {
    await Firebase.initializeApp(
      options: FirebaseTarget.options(DefaultFirebaseOptions.currentPlatform),
    );
    if (FirebaseTarget.useEmulators) {
      await _useEmulators();
    } else {
      // Weak site signal: keep everything already loaded on this device, so
      // screens still show it offline and update when the signal returns.
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );
    }
    // Sends entries that were saved on this phone with no signal.
    unawaited(Outbox.instance.start());
  } catch (_) {
    // Firebase unavailable; app continues in an unauthenticated/offline state.
  }

  runApp(const JvaSafetyApp());
}

/// Points every Firebase service at the local emulators — see
/// [FirebaseTarget]. No offline cache, so each run sees the emulators'
/// current data.
Future<void> _useEmulators() async {
  const host = FirebaseTarget.emulatorHost;
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: false,
  );
  FirebaseFirestore.instance.useFirestoreEmulator(
    host,
    FirebaseTarget.firestorePort,
  );
  await FirebaseAuth.instance.useAuthEmulator(host, FirebaseTarget.authPort);
  FirebaseFunctions.instance.useFunctionsEmulator(
    host,
    FirebaseTarget.functionsPort,
  );
  await FirebaseStorage.instance.useStorageEmulator(
    host,
    FirebaseTarget.storagePort,
  );
  debugPrint(
    'JVA Safety: using the Firebase EMULATORS '
    '(${FirebaseTarget.emulatorProjectId} at $host) — not production.',
  );
}
