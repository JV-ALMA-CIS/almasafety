import '../../../core/errors/app_exception.dart';
import 'account_approval_service.dart';

/// Turns account ids into people's names on reviewer screens (Corrective
/// Actions, Hazard and Incident details), so a screen never shows a raw
/// Firestore uid.
///
/// Loads the organization's people once (through the same
/// `listOrganizationUsers` callable the approval screens use — reviewer
/// roles only) and caches them. Records created from now on also store the
/// names themselves (e.g. `CorrectiveAction.assignedToName`); this covers
/// older records and fields that don't.
class PeopleDirectory {
  PeopleDirectory({AccountApprovalService? service})
    : _service = service ?? AccountApprovalService();

  final AccountApprovalService _service;
  final Map<String, Future<Map<String, String>>> _byOrganization = {};

  /// uid → name for everyone in [organizationId]. Empty (never an error)
  /// when the list can't be loaded — screens then fall back to a neutral
  /// label via [nameOf].
  Future<Map<String, String>> namesFor(String organizationId) {
    return _byOrganization.putIfAbsent(organizationId, () async {
      try {
        final users = await _service.listUsers(organizationId: organizationId);
        return {
          for (final user in users)
            if (user.name.trim().isNotEmpty) user.uid: user.name.trim(),
        };
      } on AppException {
        return const {};
      }
    });
  }
}

/// The name to show for [uid]: the name stored on the record, else the
/// directory's, else [unknown] — never the uid itself.
String nameOf(
  String? uid,
  Map<String, String> names, {
  String? stored,
  String unknown = 'Unknown person',
}) {
  if (stored != null && stored.trim().isNotEmpty) return stored.trim();
  if (uid == null) return unknown;
  return names[uid] ?? unknown;
}
