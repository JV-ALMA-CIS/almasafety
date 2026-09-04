import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Thin wrapper around FirebaseFirestore.
///
/// Feature repositories should depend on this rather than calling
/// FirebaseFirestore.instance directly, so Firestore access can be mocked in
/// tests and centralized per FIRESTORE_DATA_MODEL.md / firestore_paths.dart.
///
/// Resolves [FirebaseFirestore.instance] lazily, mirroring [AuthService], so
/// it can be constructed before Firebase.initializeApp() has run.
class FirestoreService {
  FirestoreService({FirebaseFirestore? firestore}) : _injected = firestore;

  final FirebaseFirestore? _injected;

  FirebaseFirestore? get instance {
    if (_injected != null) return _injected;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseFirestore.instance;
  }

  /// Throws [StateError] if Firestore is not available, for call sites that
  /// require a live instance rather than degrading gracefully.
  FirebaseFirestore get require {
    final db = instance;
    if (db == null) {
      throw StateError('Firebase has not been initialized.');
    }
    return db;
  }
}
