import 'account_status.dart';
import 'app_role.dart';
import 'membership.dart';
import 'worker_type.dart';

/// One already-reviewed user, as returned by the `listOrganizationUsers`
/// callable — the Active Users and Suspended/Rejected Users lists.
///
/// Deliberately not a [UserProfile]: the server returns only the narrow
/// projection a reviewer needs to see the account and decide whether to
/// suspend, reinstate or otherwise act on it, never the whole document.
class OrganizationUser {
  const OrganizationUser({
    required this.uid,
    required this.name,
    required this.email,
    required this.accountStatus,
    this.phone,
    this.role,
    this.workerType,
    this.trade,
    this.organizationId,
    this.membershipStatus,
    this.registeredAt,
    this.siteIds = const [],
  });

  final String uid;
  final String name;
  final String email;
  final String? phone;
  final AccountStatus accountStatus;
  final AppRole? role;
  final WorkerType? workerType;

  /// The worker's trade/profession (e.g. "Painter", "Electrician") — a job
  /// discipline, NEVER an authorization role. Already returned by
  /// `listOrganizationUsers` server-side; only worker-role rows carry a
  /// meaningful value. See FIRESTORE_DATA_MODEL.md's "Trade must never be
  /// used as an authorization role" note.
  final String? trade;

  /// The organization this row belongs to. Now present on every row: one row
  /// exists PER PERSON PER ORGANIZATION under the multi-organization
  /// membership model, so a person with two memberships shows up twice, once
  /// per organization.
  final String? organizationId;

  /// This row's own membership status (`active`/`suspended`), distinct from
  /// [accountStatus] — see `functions/src/approval_callable.ts`'s
  /// `listOrganizationUsers`, which returns both independently.
  final MembershipStatus? membershipStatus;

  /// The sites this user has been granted access to. Included in the
  /// `listOrganizationUsers` projection so the Activities worker picker can
  /// filter candidates to those who already have a target activity's site
  /// in their `siteIds`, without a second privileged read surface just for
  /// that. See [UserProfile.siteIds].
  final List<String> siteIds;

  /// When the account originally registered.
  final DateTime? registeredAt;

  /// Parses one entry of the callable's `users` list.
  ///
  /// Callable payloads arrive as `Map<Object?, Object?>` with dynamically
  /// typed values, so every field is read defensively: a malformed entry
  /// degrades gracefully rather than throwing and blanking the whole list.
  /// This is display data only — nothing here is an authorization input, so
  /// a lenient parse is safe.
  factory OrganizationUser.fromCallable(Map<Object?, Object?> data) {
    final rawPhone = data['phone'];
    final rawCreatedAt = data['createdAt'];
    final rawOrganizationId = data['organizationId'];
    final rawTrade = data['trade'];
    return OrganizationUser(
      uid: data['uid'] as String? ?? '',
      name: data['name'] as String? ?? '',
      email: data['email'] as String? ?? '',
      phone: (rawPhone is String && rawPhone.isNotEmpty) ? rawPhone : null,
      accountStatus:
          AccountStatus.tryFromId(data['accountStatus'] as String?) ??
          AccountStatus.pending,
      role: AppRole.tryFromId(data['role'] as String?),
      workerType: WorkerType.tryFromId(data['workerType'] as String?),
      trade: (rawTrade is String && rawTrade.isNotEmpty) ? rawTrade : null,
      organizationId:
          (rawOrganizationId is String && rawOrganizationId.isNotEmpty)
          ? rawOrganizationId
          : null,
      membershipStatus: MembershipStatus.tryFromId(
        data['membershipStatus'] as String?,
      ),
      registeredAt: rawCreatedAt is String
          ? DateTime.tryParse(rawCreatedAt)
          : null,
      siteIds:
          (data['siteIds'] as List<dynamic>?)?.whereType<String>().toList(
            growable: false,
          ) ??
          const [],
    );
  }
}
