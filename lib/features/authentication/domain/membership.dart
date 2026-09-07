import 'package:cloud_firestore/cloud_firestore.dart';
import 'app_role.dart';
import 'worker_type.dart';

/// The two values of a membership's own per-organization status field.
///
/// Distinct from [AccountStatus]: a person's account can be active while one
/// specific membership of theirs is suspended, and vice versa is never
/// possible (a suspended/rejected/pending account has no operational access
/// regardless of any membership's own status). See
/// `functions/src/approval_callable.ts`'s `suspendMembership`/
/// `reinstateMembership`.
enum MembershipStatus {
  active,
  suspended;

  /// The value stored in the Firestore `status` field.
  String get id => name;

  /// Parses a stored value, returning null when [id] is unrecognised.
  static MembershipStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in MembershipStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }
}

/// One organization a user belongs to, stored at
/// `users/{uid}/memberships/{organizationId}`.
///
/// Under the multi-organization membership model, a Site Manager or Foreman
/// may hold more than one of these at once — role, workerType, trade,
/// siteIds and a per-org active/suspended status all live here, not as
/// scalar fields on [UserProfile]. `accountStatus` on the profile stays a
/// single, account-level gate independent of any individual membership's own
/// [status]. See `functions/src/approval_callable.ts`'s header note for the
/// full model.
class Membership {
  const Membership({
    required this.organizationId,
    required this.role,
    required this.status,
    this.workerType,
    this.trade,
    this.siteIds = const [],
    this.approvedAt,
    this.approvedBy,
    this.createdAt,
    this.updatedAt,
  });

  final String organizationId;
  final AppRole role;
  final WorkerType? workerType;
  final String? trade;
  final List<String> siteIds;

  /// This membership's own active/suspended status — independent of the
  /// account-level [AccountStatus] and of the user's other memberships.
  final MembershipStatus status;

  final DateTime? approvedAt;
  final String? approvedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Parses a membership document.
  ///
  /// Returns null when the document is missing or carries no recognisable
  /// role/status — a malformed membership must not be treated as a valid
  /// one, but (unlike [UserProfile]) it fails quietly rather than throwing:
  /// one bad membership document should not blank the caller's whole
  /// membership list.
  static Membership? fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) return null;
    return Membership.fromMap(doc.id, data);
  }

  static Membership? fromMap(String organizationId, Map<String, dynamic> data) {
    final role = AppRole.tryFromId(data['role'] as String?);
    if (role == null) return null;

    final status = MembershipStatus.tryFromId(data['status'] as String?);
    if (status == null) return null;

    final rawOrganizationId = data['organizationId'];
    final resolvedOrganizationId =
        (rawOrganizationId is String && rawOrganizationId.isNotEmpty)
        ? rawOrganizationId
        : organizationId;

    return Membership(
      organizationId: resolvedOrganizationId,
      role: role,
      status: status,
      workerType: WorkerType.tryFromId(data['workerType'] as String?),
      trade: data['trade'] as String?,
      siteIds: () {
        final rawSiteIds = data['siteIds'];
        if (rawSiteIds is! List) return const <String>[];
        return rawSiteIds.whereType<String>().toList(growable: false);
      }(),
      approvedAt: (data['approvedAt'] as Timestamp?)?.toDate(),
      approvedBy: data['approvedBy'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
