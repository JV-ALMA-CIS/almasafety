import 'dart:convert';

import '../../../core/offline/outbox.dart';
import '../../../core/utils/meeting_date.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../domain/pre_start_answer.dart';
import '../domain/pre_start_check.dart';
import '../domain/pre_start_outcome.dart';

/// A worker's answer to one question, as submitted.
typedef PreStartResponse = ({PreStartAnswer answer, String? note});

/// Client for the Daily Pre-Start Check callables in
/// `functions/src/pre_start_check_callable.ts`.
///
/// Like every worker-facing write in this app, a check goes through a
/// callable, never a direct Firestore write: the server re-derives today's
/// questions and computes the outcome, and no callable accepts a worker uid
/// — a worker can only ever submit their own check.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [WorkerLearningService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class PreStartCheckService {
  PreStartCheckService({
    FirebaseFunctions? functions,
    this._outbox,
    this._preferences,
    this._now,
  }) : _injected = functions;

  final FirebaseFunctions? _injected;
  final Outbox? _outbox;
  final Future<SharedPreferences> Function()? _preferences;
  final DateTime Function()? _now;

  FirebaseFunctions? get _functions {
    if (_injected != null) return _injected;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseFunctions.instance;
  }

  FirebaseFunctions _require() {
    final functions = _functions;
    if (functions == null) {
      throw const DataException(
        'Cannot reach the safety service right now. Please try again.',
      );
    }
    return functions;
  }

  /// Today's questions for the signed-in worker, or the check they already
  /// submitted today.
  ///
  /// Each answer is remembered on this phone, so with no signal the worker
  /// still gets today's questions (if they opened the app earlier today)
  /// and can do the check; it is then sent once the signal returns.
  Future<MyPreStartCheck> getMyPreStartCheck({
    required String organizationId,
  }) async {
    final key = 'preStart.lastCheck.$organizationId.${_uid() ?? ''}';
    try {
      final result = await _require()
          .httpsCallable('getMyPreStartCheck')
          .call<Map<Object?, Object?>>({'organizationId': organizationId});
      await _remember(key, result.data);
      return MyPreStartCheck.fromMap(result.data);
    } catch (e) {
      if (Outbox.isConnectionError(e)) {
        final remembered = await _remembered(key);
        if (remembered != null &&
            remembered.date == meetingDate((_now ?? DateTime.now)())) {
          return remembered;
        }
        throw const NetworkException(
          'No signal. Open the app once with signal each morning so the '
          "Pre-Start questions are on your phone, then you can do today's "
          'check without signal.',
        );
      }
      if (e is FirebaseFunctionsException) {
        throw OrganizationAdminService.mapCallableError(e);
      }
      rethrow;
    }
  }

  String? _uid() {
    if (Firebase.apps.isEmpty) return null;
    return FirebaseAuth.instance.currentUser?.uid;
  }

  Future<void> _remember(String key, Map<Object?, Object?> data) async {
    try {
      final prefs = await (_preferences ?? SharedPreferences.getInstance)();
      await prefs.setString(key, jsonEncode(data));
    } catch (e) {
      debugPrint('Pre-Start: could not keep the questions: $e');
    }
  }

  Future<MyPreStartCheck?> _remembered(String key) async {
    try {
      final prefs = await (_preferences ?? SharedPreferences.getInstance)();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<Object?, Object?>
          ? MyPreStartCheck.fromMap(decoded)
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Submits the signed-in worker's [answers] — one per question id in
  /// [MyPreStartCheck.questions] — and returns the outcome the server
  /// decided.
  ///
  /// With no signal it is saved on this phone (throwing
  /// [SavedOfflineException]) and sent when the connection comes back.
  /// [forDate] (the day the questions were for) stops a check from being
  /// counted for the next day if the signal only returns then.
  Future<PreStartOutcome> submitPreStartCheck({
    required String organizationId,
    required Map<String, PreStartResponse> answers,
    String? forDate,
  }) async {
    final result = await _send('submitPreStartCheck', {
      'organizationId': organizationId,
      'forDate': ?forDate,
      'answers': [
        for (final entry in answers.entries)
          {
            'questionId': entry.key,
            'answer': entry.value.answer.id,
            'note': entry.value.note,
          },
      ],
    }, label: 'Daily Pre-Start Check');
    final outcome = PreStartOutcome.tryFromId(
      result is Map ? result['outcome'] : null,
    );
    if (outcome == null) {
      throw const DataException('Unexpected response from the safety service.');
    }
    return outcome;
  }

  /// Today's result for every crew member at [siteId].
  Future<List<CrewPreStartRow>> getSiteCrewPreStartChecks({
    required String organizationId,
    required String siteId,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'getSiteCrewPreStartChecks',
      {'organizationId': organizationId, 'siteId': siteId},
    );
    final workers = result['workers'];
    return [
      if (workers is List)
        for (final entry in workers.whereType<Map<Object?, Object?>>())
          ?CrewPreStartRow.fromMap(entry),
    ];
  }

  Future<T> _call<T>(String name, [Map<String, Object?>? data]) async {
    try {
      final callable = _require().httpsCallable(name);
      final result = await callable.call<T>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }

  /// Sends [name] through the [Outbox]: with no signal the entry is saved on
  /// this phone and [SavedOfflineException] is thrown, and it is sent once
  /// the connection comes back.
  Future<Object?> _send(
    String name,
    Map<String, Object?> data, {
    required String label,
  }) async {
    try {
      return await (_outbox ?? Outbox.instance).send(
        callable: name,
        data: data,
        label: label,
        caller: (name, data) async =>
            (await _require().httpsCallable(name).call<Object?>(data)).data,
      );
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }
}
