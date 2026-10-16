import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'app.dart';
import 'core/offline/outbox.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Guarded so the app (and widget tests, which never call main()) can still
  // run if Firebase init fails for any reason (e.g. missing platform config,
  // no network in a test environment).
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // Weak site signal: keep everything already loaded on this device, so
    // screens still show it offline and update when the signal returns.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
    // Sends entries that were saved on this phone with no signal.
    unawaited(Outbox.instance.start());
  } catch (_) {
    // Firebase unavailable; app continues in an unauthenticated/offline state.
  }

  runApp(const JvaSafetyApp());
}
