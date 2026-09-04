import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/user_profile.dart';

/// Reads, creates and safely updates the authenticated user's profile at
/// `users/{uid}`.
///
/// All Firestore access for user profiles goes through this class — widgets
/// and controllers never touch `FirebaseFirestore` directly.
///
/// Client writes are limited to two operations: creating one's own `pending`
/// profile at registration, and editing the safe fields (`name`, `phone`)
/// afterwards. Approval, organization assignment and status
/// changes are privileged operations; there is deliberately no client method
/// for them, and `firestore.rules` rejects them regardless of what the client
/// attempts.
class UserProfileRepository {
  UserProfileRepository({required this._firestoreService});

  final FirestoreService _firestoreService;

  DocumentReference<Map<String, dynamic>>? _docRef(String uid) {
    final db = _firestoreService.instance;
    if (db == null) return null;
    return db.doc(FirestorePaths.userProfile(uid));
  }

  DocumentReference<Map<String, dynamic>> _requireDocRef(String uid) {
    final ref = _docRef(uid);
    if (ref == null) {
      throw const DataException(
        'Cannot reach the safety database right now. Please try again.',
      );
    }
    return ref;
  }

  /// Creates the caller's own profile immediately after their Firebase Auth
  /// account is created.
  ///
  /// Always writes `accountStatus: pending` and never an organization — see
  /// [UserProfile.registrationPayload]. Uses `set` on a document whose id is
  /// the caller's uid, so a user can only ever create their own profile.
  Future<void> createPendingProfile({
    required String uid,
    required String name,
    required String email,
    required String phone,
  }) async {
    final ref = _requireDocRef(uid);
    try {
      await ref.set(
        UserProfile.registrationPayload(
          uid: uid,
          name: name,
          email: email,
          phone: phone,
        ),
      );
    } on FirebaseException catch (e) {
      throw mapFirestoreError(e);
    }
  }

  Future<UserProfile?> getByUid(String uid) async {
    final ref = _requireDocRef(uid);
    try {
      final doc = await ref.get();
      if (!doc.exists) return null;
      return UserProfile.fromFirestore(doc);
    } on FirebaseException catch (e) {
      throw mapFirestoreError(e);
    }
  }

  /// Streams the profile so an approval, suspension or rejection takes effect
  /// without requiring the user to sign out and back in — a suspended user
  /// loses access on the next snapshot, and a pending user waiting on the
  /// pending screen is moved into the app the moment they are approved.
  ///
  /// Emits null when no profile document exists for [uid].
  Stream<UserProfile?> watchByUid(String uid) {
    final ref = _docRef(uid);
    if (ref == null) {
      return Stream.error(
        const DataException(
          'Cannot reach the safety database right now. Please try again.',
        ),
      );
    }
    return ref
        .snapshots()
        .map((doc) => doc.exists ? UserProfile.fromFirestore(doc) : null)
        .handleError(
          (Object error) => throw mapFirestoreError(error as FirebaseException),
          test: (error) => error is FirebaseException,
        );
  }

  /// Updates only the fields a user is allowed to change on their own
  /// profile. `updatedAt` is set from the server clock.
  Future<void> updateOwnProfile({
    required String uid,
    required String name,
    String? phone,
  }) async {
    final ref = _requireDocRef(uid);
    try {
      await ref.update(
        UserProfile.selfEditablePayload(name: name, phone: phone),
      );
    } on FirebaseException catch (e) {
      throw mapFirestoreError(e);
    }
  }

  /// Translates Firestore failures into the app exception hierarchy without
  /// leaking Firebase internals into user-facing copy.
  static AppException mapFirestoreError(FirebaseException e) {
    switch (e.code) {
      case 'permission-denied':
        return PermissionDeniedException(
          'You do not have permission to do that.',
          cause: e,
        );
      case 'unavailable':
      case 'deadline-exceeded':
        return NetworkException(
          'Network error. Check your connection and try again.',
          cause: e,
        );
      default:
        return DataException(
          'Something went wrong loading your profile. Please try again.',
          cause: e,
        );
    }
  }
}
