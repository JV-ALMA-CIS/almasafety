import '../../../core/offline/outbox.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for `functions/src/man_hours_callable.ts`.
class ManHoursService {
  ManHoursService({this._functions, this._outbox});

  final FirebaseFunctions? _functions;
  final Outbox? _outbox;

  FirebaseFunctions _require() {
    final injected = _functions;
    if (injected != null) return injected;
    if (Firebase.apps.isEmpty) {
      throw const DataException(
        'Cannot reach the safety service right now. Please try again.',
      );
    }
    return FirebaseFunctions.instance;
  }

  Future<Map<Object?, Object?>> _call(
    String name,
    Map<String, Object?> data,
  ) async {
    try {
      final result = await _require()
          .httpsCallable(name)
          .call<Map<Object?, Object?>>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }

  /// Saves one site's man-hours for [month]. With no signal it is kept on
  /// this phone ([SavedOfflineException]) and sent later.
  Future<void> save({
    required String organizationId,
    required String siteId,
    required String month,
    required double hours,
    required int workers,
    String? notes,
  }) async {
    try {
      await (_outbox ?? Outbox.instance).send(
        callable: 'saveManHours',
        data: {
          'organizationId': organizationId,
          'siteId': siteId,
          'month': month,
          'hours': hours,
          'workers': workers,
          'notes': ?notes,
        },
        label: 'Man-hours',
        caller: (name, data) async =>
            (await _require().httpsCallable(name).call<Object?>(data)).data,
      );
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }

  /// Records that [month] was reported to the Safety Office.
  Future<void> markReported({
    required String organizationId,
    required String month,
  }) => _call('markManHoursReported', {
    'organizationId': organizationId,
    'month': month,
  });

  /// Worker-days present at the site's daily meetings in [month].
  Future<({int workerDays, int meetingDays})> suggestion({
    required String organizationId,
    required String siteId,
    required String month,
  }) async {
    final result = await _call('getManHoursSuggestion', {
      'organizationId': organizationId,
      'siteId': siteId,
      'month': month,
    });
    return (
      workerDays: (result['workerDays'] as num?)?.toInt() ?? 0,
      meetingDays: (result['meetingDays'] as num?)?.toInt() ?? 0,
    );
  }
}
