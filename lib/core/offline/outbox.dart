import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../errors/app_exception.dart';
import 'connection_status.dart';

/// Calls one callable; returns its result data.
typedef OutboxCaller =
    Future<Object?> Function(String callable, Map<String, Object?> data);

/// Uploads [bytes] to [storagePath] in Cloud Storage; returns the download URL.
typedef OutboxUploader =
    Future<String> Function(String storagePath, Uint8List bytes);

/// A photo that has to be uploaded before the entry's callable is sent; its
/// download URL goes into the callable's data under [field].
class OutboxPhoto {
  const OutboxPhoto({
    required this.storagePath,
    required this.bytes,
    this.field = 'photoUrl',
  });

  final String storagePath;
  final Uint8List bytes;
  final String field;

  Map<String, Object?> toJson() => {
    'storagePath': storagePath,
    'bytes': base64Encode(bytes),
    'field': field,
  };

  static OutboxPhoto? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['storagePath'];
    final bytes = json['bytes'];
    if (path is! String || bytes is! String) return null;
    return OutboxPhoto(
      storagePath: path,
      bytes: base64Decode(bytes),
      field: json['field'] as String? ?? 'photoUrl',
    );
  }
}

/// One entry saved on this phone, waiting to be sent.
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.uid,
    required this.callable,
    required this.data,
    required this.label,
    required this.createdAt,
    this.photo,
    this.attempts = 0,
    this.error,
  });

  final String id;

  /// Who saved it — only ever sent while that same person is signed in.
  final String uid;
  final String callable;
  final Map<String, Object?> data;

  /// What it is, in words, e.g. "Hazard report - Rosslyn Ridge".
  final String label;
  final DateTime createdAt;
  final OutboxPhoto? photo;
  final int attempts;

  /// Set when the server refused it (not a signal problem) — it then waits
  /// for the person to try again or remove it.
  final String? error;

  bool get failed => error != null;

  OutboxEntry copyWith({
    Map<String, Object?>? data,
    bool clearPhoto = false,
    int? attempts,
    String? error,
    bool clearError = false,
  }) => OutboxEntry(
    id: id,
    uid: uid,
    callable: callable,
    data: data ?? this.data,
    label: label,
    createdAt: createdAt,
    photo: clearPhoto ? null : photo,
    attempts: attempts ?? this.attempts,
    error: clearError ? null : error ?? this.error,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'uid': uid,
    'callable': callable,
    'data': data,
    'label': label,
    'createdAt': createdAt.toIso8601String(),
    'photo': photo?.toJson(),
    'attempts': attempts,
    'error': error,
  };

  static OutboxEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final uid = json['uid'];
    final callable = json['callable'];
    final data = json['data'];
    if (id is! String || uid is! String || callable is! String) return null;
    if (data is! Map) return null;
    return OutboxEntry(
      id: id,
      uid: uid,
      callable: callable,
      data: Map<String, Object?>.from(data),
      label: json['label'] as String? ?? callable,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      photo: OutboxPhoto.fromJson(json['photo']),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      error: json['error'] as String?,
    );
  }
}

/// Keeps field entries working with a weak or no signal.
///
/// Screens send their entries through [send]. With a signal it is an ordinary
/// callable (plus photo upload). Without one, the entry is saved on this
/// phone and [send] throws [SavedOfflineException] so the screen can say so;
/// the outbox then sends it, in order, as soon as the connection is back —
/// when the browser says it is online again, every [retryEvery] while
/// anything is waiting, and when someone taps "Send now".
///
/// Only entries the server can safely receive twice go through here (the
/// connection can drop after the server got it but before the answer came
/// back): hazards and incidents carry their own pre-allocated ids, and a
/// repeat Pre-Start check, attendance mark, inspection answer or man-hours
/// figure just saves the same thing again. A repeat that the server answers
/// with `already-exists` counts as sent.
class Outbox extends ChangeNotifier {
  Outbox({
    OutboxCaller? caller,
    OutboxUploader? uploader,
    String? Function()? currentUid,
    bool Function()? isOnline,
    Future<SharedPreferences> Function()? preferences,
    this.retryEvery = const Duration(seconds: 30),
    this.callTimeout = const Duration(seconds: 25),
    DateTime Function()? now,
  }) : _caller = caller ?? _defaultCaller,
       _uploader = uploader ?? _defaultUploader,
       _currentUid = currentUid ?? _defaultUid,
       _isOnline = isOnline ?? deviceIsOnline,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _now = now ?? DateTime.now;

  /// The app-wide outbox; [start]ed from `main`.
  static final Outbox instance = Outbox();

  static const _storageKey = 'outbox.v1';

  final OutboxCaller _caller;
  final OutboxUploader _uploader;
  final String? Function() _currentUid;
  final bool Function() _isOnline;
  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _now;
  final Duration retryEvery;
  final Duration callTimeout;

  List<OutboxEntry> _all = [];
  bool _loaded = false;
  Future<void>? _loading;
  Future<void>? _flushing;
  Timer? _timer;
  StreamSubscription<User?>? _authSub;
  int _counter = 0;

  /// The signed-in person's entries, oldest first.
  List<OutboxEntry> get entries {
    final uid = _currentUid();
    return List.unmodifiable([
      for (final e in _all)
        if (e.uid == uid) e,
    ]);
  }

  List<OutboxEntry> get waiting => [
    for (final e in entries)
      if (!e.failed) e,
  ];

  List<OutboxEntry> get failed => [
    for (final e in entries)
      if (e.failed) e,
  ];

  /// False when the device is sure it has no connection.
  bool get isOnline => _isOnline();

  /// Whether a send is running right now.
  bool get isSending => _flushing != null;

  /// The signed-in person's entries for one [callable], optionally narrowed
  /// with [where] — lets a screen show what it has waiting to send.
  List<OutboxEntry> pending(
    String callable, [
    bool Function(Map<String, Object?> data)? where,
  ]) => [
    for (final e in entries)
      if (e.callable == callable && (where == null || where(e.data))) e,
  ];

  /// Loads what was saved on this phone, and starts sending it whenever the
  /// signal or the signed-in person comes back.
  Future<void> start() async {
    await _load();
    onConnectionChanged(() {
      notifyListeners();
      if (_isOnline()) unawaited(flush());
    });
    if (Firebase.apps.isNotEmpty) {
      _authSub ??= FirebaseAuth.instance.authStateChanges().listen((_) {
        notifyListeners();
        unawaited(flush());
      });
    }
    unawaited(flush());
  }

  /// Sends [callable] with [data] (after uploading [photo], when given).
  ///
  /// Returns the callable's result when it went straight through. Throws
  /// [SavedOfflineException] when it was saved on this phone instead, and
  /// lets any other error (a [FirebaseFunctionsException] the server raised,
  /// say) through for the caller to map as usual.
  Future<Object?> send({
    required String callable,
    required Map<String, Object?> data,
    required String label,
    OutboxPhoto? photo,
    OutboxCaller? caller,
  }) async {
    await _load();
    final uid = _currentUid();
    if (uid == null) {
      throw const DataException('Please sign in again, then try once more.');
    }

    // Older entries go first, so things arrive in the order they were made.
    if (waiting.isNotEmpty && _isOnline()) await flush();
    if (waiting.isNotEmpty || !_isOnline()) {
      await _enqueue(uid, callable, data, label, photo);
      throw const SavedOfflineException();
    }

    final call = caller ?? _caller;
    var payload = data;
    var pendingPhoto = photo;
    try {
      if (pendingPhoto != null) {
        final url = await _uploader(
          pendingPhoto.storagePath,
          pendingPhoto.bytes,
        ).timeout(callTimeout * 2);
        payload = {...payload, pendingPhoto.field: url};
        pendingPhoto = null;
      }
      return await call(callable, payload).timeout(callTimeout);
    } catch (e) {
      if (!isConnectionError(e)) rethrow;
      await _enqueue(uid, callable, payload, label, pendingPhoto);
      throw const SavedOfflineException();
    }
  }

  /// Sends everything the signed-in person has waiting, oldest first. Stops
  /// at the first signal failure; an entry the server refuses is marked
  /// failed and the rest carry on.
  Future<void> flush() {
    final running = _flushing;
    if (running != null) return running;
    final future = _flush().whenComplete(() {
      _flushing = null;
      _syncTimer();
      notifyListeners();
    });
    _flushing = future;
    notifyListeners();
    return future;
  }

  Future<void> _flush() async {
    await _load();
    final uid = _currentUid();
    if (uid == null || !_isOnline()) return;
    for (final entry in waiting) {
      var current = entry;
      try {
        final photo = current.photo;
        if (photo != null) {
          final url = await _uploader(
            photo.storagePath,
            photo.bytes,
          ).timeout(callTimeout * 2);
          current = current.copyWith(
            data: {...current.data, photo.field: url},
            clearPhoto: true,
          );
          await _replace(current);
        }
        await _caller(current.callable, current.data).timeout(callTimeout);
        await _remove(current.id);
      } catch (e) {
        if (isConnectionError(e)) {
          await _replace(current.copyWith(attempts: current.attempts + 1));
          return;
        }
        if (e is FirebaseFunctionsException && e.code == 'already-exists') {
          await _remove(current.id);
          continue;
        }
        await _replace(
          current.copyWith(attempts: current.attempts + 1, error: _describe(e)),
        );
      }
    }
  }

  /// Puts a failed entry back in line and sends it.
  Future<void> retry(String id) async {
    final index = _all.indexWhere((e) => e.id == id);
    if (index < 0) return;
    await _replace(_all[index].copyWith(clearError: true));
    await flush();
  }

  /// Throws an entry away without sending it.
  Future<void> remove(String id) => _remove(id);

  /// Whether [error] means "no signal" rather than "the server said no".
  static bool isConnectionError(Object error) {
    if (error is TimeoutException) return true;
    if (error is SavedOfflineException) return true;
    if (error is FirebaseFunctionsException) {
      if (error.code == 'unavailable' || error.code == 'deadline-exceeded') {
        return true;
      }
      // The web SDK reports a failed fetch as a bare "internal"; a real
      // server error carries its own message.
      return error.code == 'internal' &&
          (error.message ?? 'internal').toLowerCase() == 'internal';
    }
    if (error is FirebaseException) {
      return const {
        'unavailable',
        'network-request-failed',
        'retry-limit-exceeded',
        'unknown',
      }.contains(error.code);
    }
    final text = error.toString().toLowerCase();
    return text.contains('failed to fetch') ||
        text.contains('network') ||
        text.contains('socketexception') ||
        text.contains('xmlhttprequest');
  }

  static String _describe(Object e) {
    if (e is FirebaseFunctionsException) {
      return e.message ?? 'The safety service refused this entry.';
    }
    if (e is AppException) return e.message;
    return 'The safety service refused this entry.';
  }

  Future<void> _enqueue(
    String uid,
    String callable,
    Map<String, Object?> data,
    String label,
    OutboxPhoto? photo,
  ) async {
    final entry = OutboxEntry(
      id: '${_now().microsecondsSinceEpoch}-${_counter++}',
      uid: uid,
      callable: callable,
      data: data,
      label: label,
      createdAt: _now(),
      photo: photo,
    );
    _all = [..._all, entry];
    try {
      await _save();
    } catch (e) {
      _all = [
        for (final x in _all)
          if (x.id != entry.id) x,
      ];
      throw DataException(
        photo != null
            ? 'No signal, and not enough space on this phone to keep the '
                  'photo. Try again without the photo, or once you have '
                  'signal.'
            : 'No signal, and this could not be saved on this phone. Please '
                  'try again once you have signal.',
        cause: e,
      );
    }
    _syncTimer();
    notifyListeners();
  }

  Future<void> _replace(OutboxEntry entry) async {
    _all = [for (final e in _all) e.id == entry.id ? entry : e];
    await _saveQuietly();
    notifyListeners();
  }

  Future<void> _remove(String id) async {
    _all = [
      for (final e in _all)
        if (e.id != id) e,
    ];
    await _saveQuietly();
    _syncTimer();
    notifyListeners();
  }

  Future<void> _load() {
    if (_loaded) return Future.value();
    return _loading ??= () async {
      try {
        final prefs = await _preferences();
        final raw = prefs.getString(_storageKey);
        if (raw != null) {
          final decoded = jsonDecode(raw);
          _all = [
            if (decoded is List)
              for (final item in decoded) ?OutboxEntry.fromJson(item),
          ];
        }
      } catch (e) {
        debugPrint('Outbox: could not read saved entries: $e');
      }
      _loaded = true;
      _syncTimer();
      notifyListeners();
    }();
  }

  Future<void> _save() async {
    final prefs = await _preferences();
    final ok = await prefs.setString(
      _storageKey,
      jsonEncode([for (final e in _all) e.toJson()]),
    );
    if (!ok) throw StateError('Could not save the outbox.');
  }

  Future<void> _saveQuietly() async {
    try {
      await _save();
    } catch (e) {
      debugPrint('Outbox: could not save: $e');
    }
  }

  /// Retries on a timer only while something is waiting.
  void _syncTimer() {
    if (waiting.isEmpty) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(retryEvery, (_) => unawaited(flush()));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  static Future<Object?> _defaultCaller(
    String callable,
    Map<String, Object?> data,
  ) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable(callable)
        .call<Object?>(data);
    return result.data;
  }

  static Future<String> _defaultUploader(
    String storagePath,
    Uint8List bytes,
  ) async {
    final ref = FirebaseStorage.instance.ref(storagePath);
    await ref.putData(bytes);
    return ref.getDownloadURL();
  }

  static String? _defaultUid() {
    if (Firebase.apps.isEmpty) return null;
    return FirebaseAuth.instance.currentUser?.uid;
  }
}
