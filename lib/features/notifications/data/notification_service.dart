import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the `markNotificationRead`/`markAllNotificationsRead`
/// callables in `functions/src/notification_callable.ts`.
///
/// Mirrors [WorkerLearningService]: neither callable accepts a
/// `recipientUid` argument — the server derives the acting user from
/// `request.auth.uid`, which is the structural guarantee that a user can
/// never mark another user's notification read. There is deliberately no
/// `createNotification` method here: notification creation is a
/// server-side-only helper other Cloud Functions call directly (see
/// `notification_callable.ts`'s header note), not a client-callable
/// surface — a client cannot create a notification at all, satisfying this
/// stage's "client cannot create notifications" requirement structurally
/// rather than by convention.
class NotificationService {
  NotificationService({FirebaseFunctions? functions}) : _injected = functions;

  final FirebaseFunctions? _injected;

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

  /// Marks the caller's own notification [notificationId] as read.
  Future<void> markNotificationRead({
    required String organizationId,
    required String notificationId,
  }) => _call<Object?>('markNotificationRead', {
    'organizationId': organizationId,
    'notificationId': notificationId,
  });

  /// Marks every one of the caller's own unread notifications within
  /// [organizationId] as read in one call.
  Future<void> markAllNotificationsRead({required String organizationId}) =>
      _call<Object?>('markAllNotificationsRead', {
        'organizationId': organizationId,
      });

  Future<T> _call<T>(String name, [Map<String, Object?>? data]) async {
    try {
      final callable = _require().httpsCallable(name);
      final result = await callable.call<T>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }
}
