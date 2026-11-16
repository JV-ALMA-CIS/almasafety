import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Thin wrapper around FirebaseStorage.
///
/// Feature code (e.g. hazard photo uploads, safety learning media) should
/// depend on this rather than calling FirebaseStorage.instance directly.
///
/// Resolves [FirebaseStorage.instance] lazily, mirroring [AuthService].
class StorageService {
  StorageService({FirebaseStorage? storage}) : _injected = storage;

  final FirebaseStorage? _injected;

  FirebaseStorage? get instance {
    if (_injected != null) return _injected;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseStorage.instance;
  }

  /// Throws [StateError] if Storage is not available.
  FirebaseStorage get require {
    final storage = instance;
    if (storage == null) {
      throw StateError('Firebase has not been initialized.');
    }
    return storage;
  }

  /// Convenience reference builder for org-scoped evidence paths, matching
  /// the `organizations/{organizationId}/...` layout enforced by
  /// storage.rules. Callers append their own sub-path, e.g.:
  ///   orgRef(orgId).child('hazards/$hazardId/$fileName')
  /// The configured Storage bucket name (e.g. `jva-safety.firebasestorage.app`),
  /// or null before Firebase is initialized. Used to recognise this app's own
  /// download URLs — see `VideoSource`.
  String? get bucket => instance?.bucket;

  Reference orgRef(String organizationId) =>
      require.ref().child('organizations/$organizationId');

  /// [uid]'s own staging folder for Safety Learning uploads — the only
  /// place a client may put a library file; `publishLearningUpload` then
  /// moves it into the organization's library after an author check (see
  /// `storage.rules`).
  Reference learningUploadRef(String uid) =>
      require.ref().child('learning_uploads/$uid');
}
