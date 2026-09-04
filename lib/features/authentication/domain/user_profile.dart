import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'account_status.dart';
import 'app_role.dart';
import 'worker_type.dart';

/// The authenticated user's profile, stored at `users/{uid}`.
///
/// **Top-level, not organization-scoped.** Under the self-registration model
/// a user registers *before* any organization is known — an approver assigns
/// [organizationId] later. There is therefore no organization path to write
/// the document to at registration time, which is why this collection is
/// top-level and [organizationId] is nullable. Organization isolation for
/// operational data is still structural (`organizations/{orgId}/...`); it is
/// only the identity document that sits outside that tree.
///
/// The client may create its own document at registration with
/// `accountStatus: pending` and no organization, and may thereafter update
/// only [name] and [phone]. `accountStatus`, `organizationId`,
/// `approvedAt` and `approvedBy` are approval-authority fields written
/// exclusively server-side, and `firestore.rules` rejects client writes that
/// touch them.
///
/// [platformRole] ([AppRole]) and [workerType] are assigned by an authorized
/// reviewer during account review, alongside [organizationId] — never chosen
/// by the registrant at signup. [platformRole] is null until then; a null
/// role has no authority of any kind, so an account cannot be
/// [AccountStatus.active] without one in practice, because review assigns
/// organization, role and status together. [workerType] carries no
/// authorization weight — it describes who employs the person, not what
/// they may do; see [WorkerType].
///
/// Site- and activity-scoped narrowing of a role (e.g. limiting a Site
/// Superintendent to specific sites) is deferred to the Sites/Activities
/// stage.
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.accountStatus,
    this.organizationId,
    this.phone,
    this.createdAt,
    this.updatedAt,
    this.approvedAt,
    this.approvedBy,
    this.platformRole,
    this.workerType,
    this.siteIds = const [],
  });

  final String uid;

  /// Null until an approver assigns the user to an organization. A profile
  /// with a null organization can never be [AccountStatus.active] in
  /// practice, because approval assigns both at once.
  final String? organizationId;

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
  /// [AccountStatus.pending].
  final DateTime? approvedAt;
  final String? approvedBy;

  /// The user's platform authorization role, assigned by an authorized
  /// reviewer during account review. Null until then, and null carries no
  /// authority — see [AppRole]. Stored in Firestore as `platformRole`.
  ///
  /// Like [accountStatus] and [organizationId], this is written exclusively
  /// by the Admin SDK. `firestore.rules` rejects any client write that names
  /// it — at creation or afterwards, on one's own profile or anybody else's —
  /// so a reviewer cannot grant themselves a role, escalate a colleague's
  /// role, or let a registrant choose one at signup.
  final AppRole? platformRole;

  /// Workforce type — who employs the person, not what they may do. Assigned
  /// alongside [platformRole] during review. See [WorkerType].
  final WorkerType? workerType;

  /// The sites this user has been granted access to, assigned by a Site
  /// Manager or Admin through the
  /// `assignWorkerToSite`/`removeWorkerFromSite` callables — never chosen by
  /// the user. Like [platformRole] and [workerType], `firestore.rules`
  /// rejects any client write that names this field, so it is
  /// Admin-SDK-only.
  ///
  /// Empty by default: a freshly reviewed account has no site access until
  /// explicitly granted.
  final List<String> siteIds;

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

    // Absent, empty or non-string organizationId all mean "not yet assigned",
    // which is the normal state for a pending user.
    final rawOrganizationId = data['organizationId'];
    final organizationId = (rawOrganizationId is String &&
            rawOrganizationId.isNotEmpty)
        ? rawOrganizationId
        : null;

    return UserProfile(
      uid: uid,
      organizationId: organizationId,
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
      workerType: WorkerType.tryFromId(data['workerType'] as String?),
      // A malformed (non-list) value reads as no sites rather than
      // throwing — like role, this is an authorization-relevant field and
      // the safe default is "no access", not denying the whole profile.
      siteIds: () {
        final rawSiteIds = data['siteIds'];
        if (rawSiteIds is! List) return const <String>[];
        return rawSiteIds.whereType<String>().toList(growable: false);
      }(),
    );
  }

  /// The exact document a client is permitted to create for itself at
  /// registration.
  ///
  /// [AccountStatus.pending] is hardcoded, not a parameter — there is no
  /// call site anywhere in the app that can register an account into any
  /// other state. The map deliberately omits `organizationId`, `approvedAt`,
  /// `approvedBy`, `platformRole`, `workerType`, `trade`, `siteIds` and
  /// `supervisorUid`: including any of them would be rejected by
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
      organizationId: organizationId,
      name: name ?? this.name,
      email: email,
      phone: phone ?? this.phone,
      accountStatus: accountStatus,
      createdAt: createdAt,
      updatedAt: updatedAt,
      approvedAt: approvedAt,
      approvedBy: approvedBy,
      platformRole: platformRole,
      workerType: workerType,
      siteIds: siteIds,
    );
  }
}
