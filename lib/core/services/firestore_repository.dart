import 'package:cloud_firestore/cloud_firestore.dart';
import '../errors/app_exception.dart';
import 'firestore_service.dart';

/// Generic Firestore CRUD foundation for feature repositories.
///
/// This deliberately knows nothing about JVA Safety's entities — feature
/// repositories (e.g. a future `ProjectsRepository`) extend or compose this
/// with their own `fromFirestore`/`toFirestore` converters and collection
/// path, per FIRESTORE_DATA_MODEL.md. Firestore exceptions are translated to
/// [AppException] so presentation code only needs to handle one error type.
class FirestoreRepository<T> {
  FirestoreRepository({
    required this._firestoreService,
    required this.collectionPath,
    required this.fromFirestore,
    required this.toFirestore,
  });

  final FirestoreService _firestoreService;
  final String collectionPath;
  final T Function(DocumentSnapshot<Map<String, dynamic>> doc) fromFirestore;
  final Map<String, dynamic> Function(T value) toFirestore;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestoreService.require.collection(collectionPath);

  Future<T?> getById(String id) async {
    try {
      final doc = await _collection.doc(id).get();
      if (!doc.exists) return null;
      return fromFirestore(doc);
    } on FirebaseException catch (e) {
      throw _mapException(e);
    }
  }

  Stream<T?> watchById(String id) {
    return _collection.doc(id).snapshots().map((doc) {
      if (!doc.exists) return null;
      return fromFirestore(doc);
    });
  }

  Stream<List<T>> watchCollection({
    Query<Map<String, dynamic>> Function(Query<Map<String, dynamic>> query)?
    queryBuilder,
  }) {
    final query = queryBuilder?.call(_collection) ?? _collection;
    return query.snapshots().map(
      (snapshot) => snapshot.docs.map(fromFirestore).toList(),
    );
  }

  /// Fetches a collection once, rather than subscribing to live updates —
  /// see [OrganizationRepository.getAll]'s own doc comment for why a caller
  /// that only needs a one-time, settled read should prefer this over
  /// [watchCollection] (whose `.snapshots()` can emit a stale/empty LOCAL
  /// CACHE result before the server's real answer arrives).
  Future<List<T>> getCollection({
    Query<Map<String, dynamic>> Function(Query<Map<String, dynamic>> query)?
    queryBuilder,
  }) async {
    try {
      final query = queryBuilder?.call(_collection) ?? _collection;
      final snapshot = await query.get();
      return snapshot.docs.map(fromFirestore).toList();
    } on FirebaseException catch (e) {
      throw _mapException(e);
    }
  }

  Future<String> create(T value) async {
    try {
      final doc = await _collection.add(toFirestore(value));
      return doc.id;
    } on FirebaseException catch (e) {
      throw _mapException(e);
    }
  }

  Future<void> update(String id, Map<String, dynamic> fields) async {
    try {
      await _collection.doc(id).update(fields);
    } on FirebaseException catch (e) {
      throw _mapException(e);
    }
  }

  Future<void> delete(String id) async {
    try {
      await _collection.doc(id).delete();
    } on FirebaseException catch (e) {
      throw _mapException(e);
    }
  }

  AppException _mapException(FirebaseException e) {
    if (e.code == 'permission-denied') {
      return PermissionDeniedException(
        'You do not have permission to perform this action.',
        cause: e,
      );
    }
    if (e.code == 'unavailable') {
      return NetworkException('Firestore is currently unavailable.', cause: e);
    }
    return DataException(e.message ?? 'A data error occurred.', cause: e);
  }
}
