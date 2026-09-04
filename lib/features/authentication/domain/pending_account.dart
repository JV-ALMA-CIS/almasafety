/// One account awaiting review, as returned by the `listPendingApprovals`
/// callable.
///
/// This is deliberately not a [UserProfile]. The server returns only the few
/// fields an approver needs to make a decision — never a whole profile
/// document — so modelling it as a full profile would invite code to assume
/// fields that were never sent.
class PendingAccount {
  const PendingAccount({
    required this.uid,
    required this.name,
    required this.email,
    this.phone,
    this.submittedAt,
  });

  final String uid;
  final String name;
  final String email;
  final String? phone;

  /// When the account registered. Null if the server timestamp had not
  /// landed when the document was read.
  final DateTime? submittedAt;

  /// Parses one entry of the callable's `accounts` list.
  ///
  /// Callable payloads arrive as `Map<Object?, Object?>` with dynamically
  /// typed values, so every field is read defensively: a malformed entry
  /// degrades to empty strings rather than throwing and blanking the whole
  /// queue. This is display data only — nothing here is an authorization
  /// input, so a lenient parse is safe.
  factory PendingAccount.fromCallable(Map<Object?, Object?> data) {
    final rawPhone = data['phone'];
    final rawCreatedAt = data['createdAt'];
    return PendingAccount(
      uid: data['uid'] as String? ?? '',
      name: data['name'] as String? ?? '',
      email: data['email'] as String? ?? '',
      phone: (rawPhone is String && rawPhone.isNotEmpty) ? rawPhone : null,
      submittedAt: rawCreatedAt is String
          ? DateTime.tryParse(rawCreatedAt)
          : null,
    );
  }
}
