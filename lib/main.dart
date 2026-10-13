import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'app.dart';
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
  } catch (_) {
    // Firebase unavailable; app continues in an unauthenticated/offline state.
  }

  runApp(const JvaSafetyApp());
}
