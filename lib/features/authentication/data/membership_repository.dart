import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/membership.dart';

/// Reads a user's memberships from `users/{uid}/memberships`.
///
/// Read-only by design: creating, suspending or reinstating a membership is a
/// privileged operation that goes through the `approvePendingAccount` /
/// `addOrganizationMembership` / `suspendMembership` / `reinstateMembership`
/// Cloud Functions callables (`AccountApprovalService`), never through this
/// repository — mirroring why `UserProfileRepository` has no method that
/// writes `accountStatus`, and why `OrganizationRepository` has no method
/// that writes an organization. `firestore.rules` independently denies every
/// client write to this collection regardless (self or Admin may read; no
/// one may write from a client).
class MembershipRepository {
  MembershipRepository({required this._firestoreService});

  final FirestoreService _firestoreService;

  CollectionReference<Map<String, dynamic>>? _collectionRef(String uid) {
    final db = _firestoreService.instance;
    if (db == null) return null;
    return db.collection(FirestorePaths.membershipsCollection(uid));
  }

  /// Streams every membership for [uid]. Used by [SessionController] to
  /// resolve which organization(s) the signed-in user may act within.
  ///
  /// Emits an empty list when [uid] has no memberships (e.g. an Admin, who
  /// holds none, or a freshly-approved Site Manager with no organization
  /// yet).
  Stream<List<Membership>> watchAll(String uid) {
    final ref = _collectionRef(uid);
    if (ref == null) {
      return Stream.error(
        const DataException(
          'Cannot reach the safety database right now. Please try again.',
        ),
      );
    }
    return ref
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(Membership.fromFirestore)
              .whereType<Membership>()
              .toList(growable: false),
        )
        .handleError(
          (Object error) => throw mapFirestoreError(error as FirebaseException),
          test: (error) => error is FirebaseException,
        );
  }

  /// Translates Firestore failures into the app exception hierarchy without
  /// leaking Firebase internals into user-facing copy. Mirrors
  /// [UserProfileRepository.mapFirestoreError].
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
          'Something went wrong loading your organizations. Please try '
          'again.',
          cause: e,
        );
    }
  }
}
