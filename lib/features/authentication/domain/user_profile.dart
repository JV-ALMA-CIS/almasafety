import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'account_status.dart';
import 'app_role.dart';
import 'worker_type.dart';

/// The authenticated user's profile, stored at `users/{uid}`.
///
/// **Top-level, not organization-scoped.** Under the self-registration model
/// a user registers *before* any organization is known. There is therefore no
/// organization path to write the document to at registration time, which is
/// why this collection is top-level. Organization isolation for operational
/// data is still structural (`organizations/{orgId}/...`); it is only the
/// identity document that sits outside that tree.
///
/// **Multi-organization membership model.** A person's relationship to a
/// specific organization — role, workerType, trade, siteIds and a per-org
/// active/suspended status — no longer lives on this profile: it lives on
/// `users/{uid}/memberships/{organizationId}`, one document per organization
/// the person belongs to, because a Site Manager or Foreman may hold more
/// than one at once. See [Membership]. This profile keeps only
/// account-level identity and state: [platformRole] here is now used
/// EXCLUSIVELY for [AppRole.admin] (platform-level, org-less by
/// construction) — every other role lives on a [Membership] instead, never
/// as a scalar on this class. [organizationId], [workerType] and [siteIds]
/// have been removed accordingly; see call sites that used to read them —
/// they now read a [Membership] (typically the one named by
/// `SessionController.activeOrganizationId`/`activeMembership`) instead.
///
/// The client may create its own document at registration with
/// `accountStatus: pending`, and may thereafter update only [name] and
/// [phone]. `accountStatus`, `approvedAt`, `approvedBy` and `platformRole`
/// are approval-authority fields written exclusively server-side, and
/// `firestore.rules` rejects client writes that touch them.
///
/// [platformRole] is null for everyone except an [AppRole.admin] (and,
/// transiently, a Site Manager approved with no organization yet — see
/// `functions/src/account_approval.ts`'s `approveAccount`). A null role
/// carries no authority.
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.accountStatus,
    this.phone,
    this.createdAt,
    this.updatedAt,
    this.approvedAt,
    this.approvedBy,
    this.platformRole,
  });

  final String uid;

  final String name;
  final String email;
  final String? phone;

  /// The authoritative account-state field. See [AccountStatus].
  final AccountStatus accountStatus;

  /// Server-assigned timestamps. Null only in the brief window between a
  /// local write and the server acknowledging it (Firestore surfaces
  /// pending `serverTimestamp()` sentinels as null).
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Approval audit trail — written only by the approval authority, never by
  /// the user being approved. Null while [accountStatus] is
  /// [AccountStatus.pending]. Still written to the profile at first-ever
  /// approval alongside the person's first membership document — see
  /// `approveAccount` in `functions/src/account_approval.ts`.
  final DateTime? approvedAt;
  final String? approvedBy;

  /// The user's platform-level authorization role. Null for everyone except
  /// [AppRole.admin] — every other role now lives on a [Membership], not
  /// here. See [AppRole]. Stored in Firestore as `platformRole`.
  ///
  /// Like [accountStatus], this is written exclusively by the Admin SDK.
  /// `firestore.rules` rejects any client write that names it — at creation
  /// or afterwards, on one's own profile or anybody else's — so a reviewer
  /// cannot grant themselves a role or let a registrant choose one at
  /// signup.
  final AppRole? platformRole;

  /// Whether this profile grants access to operational routes and data.
  bool get hasOperationalAccess => accountStatus.grantsAccess;

  /// Whether this user may review pending accounts: approve/reject them and
  /// assign organization, role and worker type. See [AppRole.canReviewPendingAccounts].
  bool get canReviewPendingAccounts =>
      platformRole?.canReviewPendingAccounts ?? false;

  /// Whether this user holds platform-level authority not scoped to any
  /// single organization. See [AppRole.isPlatformLevel].
  bool get isPlatformAdministrator => platformRole?.isPlatformLevel ?? false;

  /// Whether this user may review completed Daily Safety Meetings
  /// organization-wide. See [AppRole.canReviewDailySafetyMeetings].
  bool get canReviewDailySafetyMeetings =>
      platformRole?.canReviewDailySafetyMeetings ?? false;

  /// Whether this user may create a new organization. See
  /// [AppRole.canCreateOrganization].
  bool get canCreateOrganization =>
      platformRole?.canCreateOrganization ?? false;

  /// Whether this user may manage projects/sites/activities/Foremen for the
  /// organization(s) they manage. See [AppRole.canManageOrgContent].
  bool get canManageOrgContent => platformRole?.canManageOrgContent ?? false;

  /// Whether this user manages the company-wide Safety Learning library. See
  /// [AppRole.canManageSafetyLearningLibrary].
  bool get canManageSafetyLearningLibrary =>
      platformRole?.canManageSafetyLearningLibrary ?? false;

  /// Whether this user manages the company-wide Safety Meeting Point
  /// library. See [AppRole.canManageSafetyMeetingPointLibrary].
  bool get canManageSafetyMeetingPointLibrary =>
      platformRole?.canManageSafetyMeetingPointLibrary ?? false;

  /// Parses a profile document.
  ///
  /// Throws [DataException] when the document is missing required fields or
  /// carries an unrecognised account status. Failing loudly is intentional:
  /// a malformed profile must deny access, never degrade into a default
  /// identity. [SessionController] maps this to a denied-access state.
  factory UserProfile.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('Your user profile could not be loaded.');
    }
    return UserProfile.fromMap(doc.id, data);
  }

  factory UserProfile.fromMap(String uid, Map<String, dynamic> data) {
    final AccountStatus accountStatus;
    try {
      accountStatus = AccountStatus.fromId(data['accountStatus'] as String?);
    } on ArgumentError {
      // An unknown status is a data-integrity problem. It must never be
      // resolved to a default — least of all `active`.
      throw const DataException(
        'Your account status could not be read. Contact your administrator.',
      );
    }

    return UserProfile(
      uid: uid,
      name: data['name'] as String? ?? '',
      email: data['email'] as String? ?? '',
      phone: data['phone'] as String?,
      accountStatus: accountStatus,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      approvedAt: (data['approvedAt'] as Timestamp?)?.toDate(),
      approvedBy: data['approvedBy'] as String?,
      // An unrecognised or malformed role reads as "no role" rather than
      // throwing: a role, unlike accountStatus, must fail closed — denying
      // the whole profile over a bad role value would be a stricter failure
      // mode than the field warrants, since a null role already grants
      // nothing.
      platformRole: AppRole.tryFromId(data['platformRole'] as String?),
    );
  }

  /// The exact document a client is permitted to create for itself at
  /// registration.
  ///
  /// [AccountStatus.pending] is hardcoded, not a parameter — there is no
  /// call site anywhere in the app that can register an account into any
  /// other state. The map deliberately omits `approvedAt`, `approvedBy` and
  /// `platformRole`: including any of them would be rejected by
  /// `firestore.rules`, and their absence is what makes "registration grants
  /// no privileges" true by construction rather than by convention.
  static Map<String, Object?> registrationPayload({
    required String uid,
    required String name,
    required String email,
    required String phone,
  }) {
    return {
      'uid': uid,
      'name': name,
      'email': email,
      'phone': phone,
      'accountStatus': AccountStatus.pending.id,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  /// The subset of fields a user may write to their own existing profile.
  ///
  /// `updatedAt` uses a server timestamp so the client cannot backdate or
  /// forge audit metadata. `platformRole` is absent for the same reason
  /// `accountStatus` is: a user must not be able to grant or change their
  /// own role.
  static Map<String, Object?> selfEditablePayload({
    required String name,
    String? phone,
  }) {
    return {
      'name': name,
      'phone': phone,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  UserProfile copyWith({String? name, String? phone}) {
    return UserProfile(
      uid: uid,
      name: name ?? this.name,
      email: email,
      phone: phone ?? this.phone,
      accountStatus: accountStatus,
      createdAt: createdAt,
      updatedAt: updatedAt,
      approvedAt: approvedAt,
      approvedBy: approvedBy,
      platformRole: platformRole,
    );
  }
}
