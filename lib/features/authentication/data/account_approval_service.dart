import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/account_status.dart';
import '../domain/app_role.dart';
import '../domain/organization_user.dart';
import '../domain/pending_account.dart';
import '../domain/worker_type.dart';

/// Client for the account-approval callables in
/// `functions/src/approval_callable.ts`.
///
/// Approval is a privileged operation: it writes `accountStatus`,
/// `organizationId`, `role` and `workerType`, all of which `firestore.rules`
/// denies to every client. There is therefore deliberately no Firestore
/// repository for it — this class only invokes server-side functions, which
/// run under the Admin SDK after verifying the caller's [AppRole] themselves.
///
/// Nothing this class sends is trusted by the server. In particular the
/// approving organization is never a parameter: the callable reads it from
/// the caller's own stored profile, so a modified client cannot approve
/// anyone into an organization it does not belong to. The server also
/// rejects a target uid equal to the caller's own, so self-approval is
/// unreachable regardless of what a modified client sends.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring [AuthService] and
/// [FirestoreService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class AccountApprovalService {
  AccountApprovalService({FirebaseFunctions? functions})
    : _injected = functions;

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

  /// Fetches the accounts awaiting review.
  ///
  /// Returns the server's narrow projection, not whole profile documents.
  Future<List<PendingAccount>> listPendingApprovals() async {
    final result = await _call<Map<Object?, Object?>>('listPendingApprovals');
    final accounts = result['accounts'];
    if (accounts is! List) return const [];
    return accounts
        .whereType<Map<Object?, Object?>>()
        .map(PendingAccount.fromCallable)
        .toList(growable: false);
  }

  /// Approves [uid], assigning [role] and [workerType].
  ///
  /// [role] must be a role the caller is authorized to grant — an ordinary
  /// operational role ([AppRole.worker], [AppRole.foreman], or one of the
  /// review-authorized roles) is always a valid assignment outcome; the
  /// server independently rejects any attempt to hand out more authority
  /// than the caller holds.
  ///
  /// [organizationId] is OPTIONAL only for [AppRole.admin] granting
  /// [AppRole.siteManager]: an Admin approving a colleague they know by name
  /// typically has no way to know which organization that person operates
  /// in, so leaving it unset approves the account with no organization yet —
  /// the new Site Manager creates (or is assigned into) one afterward. Admin
  /// may still supply it explicitly (including naming an organization that
  /// does not exist yet, to stand up its first member) when they do know it.
  ///
  /// For EVERY OTHER reviewer role, [organizationId] is now REQUIRED: under
  /// the multi-organization membership model a Site Manager/Foreman may hold
  /// more than one membership, so there is no longer an implicit "the"
  /// organization the server can read off their profile — the caller must
  /// say which of their own memberships they are acting in. Callers should
  /// pass `SessionController.activeOrganizationId` here. The server
  /// independently verifies this is an organization the caller actually
  /// holds an active, authorized-role membership in — a modified client
  /// cannot use this to name a different organization than one of its own.
  ///
  /// [siteIds] assigns the approved user directly to one or more sites
  /// within [organizationId] as part of the same call — most relevantly for
  /// [AppRole.foreman]: without at least one assigned site, a Foreman has
  /// no site to run Daily Safety Meetings for (`DailySafetyMeetingScreen`
  /// requires `membership.siteIds` to be non-empty), so leaving this unset
  /// at approval time silently strands them until someone separately visits
  /// Organizations → Project → Site → Workers to assign one.
  Future<void> approve(
    String uid, {
    required AppRole role,
    WorkerType? workerType,
    String? organizationId,
    List<String>? siteIds,
  }) => _call<Object?>('approvePendingAccount', {
    'uid': uid,
    'role': role.id,
    if (workerType != null) 'workerType': workerType.id,
    'organizationId': ?organizationId,
    if (siteIds != null && siteIds.isNotEmpty) 'siteIds': siteIds,
  });

  /// Rejects [uid]. The profile is retained; rejection is a status, not a
  /// deletion.
  Future<void> reject(String uid) =>
      _call<Object?>('rejectPendingAccount', {'uid': uid});

  /// Fetches already-reviewed users at [status] (`active` by default).
  ///
  /// Scoped to the caller's ONE acting organization ([organizationId]) for
  /// every reviewer role except [AppRole.admin], which sees every
  /// organization — the same boundary [approve] and [suspend] enforce,
  /// applied here to a list query. [organizationId] is required for a
  /// non-Admin caller, exactly like [approve] — the server's
  /// `requireApprover` requires it from any non-admin caller, since a
  /// caller with several memberships must say which one they are listing.
  /// Callers should pass `SessionController.activeOrganizationId`.
  /// [AccountStatus.pending] is refused server-side: that queue is
  /// [listPendingApprovals] instead. Returns one row PER PERSON PER
  /// ORGANIZATION — a person with two memberships in the queried scope
  /// appears once per organization.
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
    String? organizationId,
  }) async {
    final result = await _call<Map<Object?, Object?>>('listOrganizationUsers', {
      'accountStatus': status.id,
      'organizationId': ?organizationId,
    });
    final users = result['users'];
    if (users is! List) return const [];
    return users
        .whereType<Map<Object?, Object?>>()
        .map(OrganizationUser.fromCallable)
        .toList(growable: false);
  }

  /// Suspends [uid], an active account, withdrawing its operational access
  /// without deleting it. ACCOUNT-level: touches `accountStatus` alone, not
  /// any individual membership's own status — see [suspendMembership] for
  /// the per-organization equivalent. Confined to the caller's own
  /// organization; refuses self-action, exactly like [approve] and [reject].
  Future<void> suspend(String uid) =>
      _call<Object?>('suspendActiveAccount', {'uid': uid});

  /// Restores a suspended account to active. ACCOUNT-level, mirroring
  /// [suspend] — see [reinstateMembership] for the per-organization
  /// equivalent. Confined to the caller's own organization; refuses
  /// self-action, exactly like [approve] and [reject].
  Future<void> reinstate(String uid) =>
      _call<Object?>('reinstateSuspendedAccount', {'uid': uid});

  /// Suspends [uid]'s membership in [organizationId] only, leaving
  /// `accountStatus` and their other memberships untouched.
  /// [organizationId] is the caller's own acting organization (typically
  /// `SessionController.activeOrganizationId`); the server verifies the
  /// caller holds an authorized membership there.
  Future<void> suspendMembership(
    String uid, {
    required String organizationId,
  }) => _call<Object?>('suspendMembership', {
    'uid': uid,
    'organizationId': organizationId,
  });

  /// Reinstates [uid]'s membership in [organizationId] only. See
  /// [suspendMembership].
  Future<void> reinstateMembership(
    String uid, {
    required String organizationId,
  }) => _call<Object?>('reinstateMembership', {
    'uid': uid,
    'organizationId': organizationId,
  });

  /// Places an already-active [uid] into an additional organization
  /// ([organizationId]), assigning [role]/[workerType]/[siteIds] there —
  /// without touching `accountStatus` or any of their other memberships.
  /// Mirrors [approve]'s authorization shape: the caller must hold an
  /// active, authorized-role membership in [organizationId]. Throws if a
  /// membership already exists for [uid] in [organizationId] (server-side
  /// `already-exists`).
  Future<void> addOrganizationMembership(
    String uid, {
    required AppRole role,
    WorkerType? workerType,
    List<String>? siteIds,
    required String organizationId,
  }) => _call<Object?>('addOrganizationMembership', {
    'uid': uid,
    'role': role.id,
    if (workerType != null) 'workerType': workerType.id,
    'siteIds': ?siteIds,
    'organizationId': organizationId,
  });

  Future<T> _call<T>(String name, [Map<String, Object?>? data]) async {
    try {
      final callable = _require().httpsCallable(name);
      final result = await callable.call<T>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw mapCallableError(e);
    }
  }

  /// Translates a callable failure into the app exception hierarchy.
  ///
  /// The server returns one opaque `permission-denied` for every
  /// authorization failure, and this preserves that: the message here says
  /// only that the action was refused, never which condition failed.
  static AppException mapCallableError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'permission-denied':
      case 'unauthenticated':
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
      case 'not-found':
        return DataException('That account no longer exists.', cause: e);
      case 'already-exists':
        return DataException(
          'That user already belongs to that organization.',
          cause: e,
        );
      case 'failed-precondition':
        // Reachable from the UI when another reviewer already acted first:
        // the target was reviewed, suspended or reinstated between the list
        // loading and this action being attempted.
        return DataException(
          'That account has already changed. Refresh to see its current '
          'status.',
          cause: e,
        );
      case 'invalid-argument':
        // Reachable when a non-Admin reviewer's organizationId could not be
        // resolved (e.g. they have no active organization yet) — the UI
        // should catch this earlier (see PendingApprovalsScreen._approve),
        // but this keeps a direct callable failure legible rather than
        // falling into the opaque default case below.
        return DataException(
          e.message ??
              'That request was missing required information. Please try '
                  'again.',
          cause: e,
        );
      default:
        return DataException(
          'Something went wrong. Please try again.',
          cause: e,
        );
    }
  }
}
