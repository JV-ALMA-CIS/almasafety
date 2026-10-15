import '../../features/organizations/data/organization_repository.dart';
import '../services/firestore_service.dart';

/// The organization's name for a report heading; a neutral fallback when it
/// cannot be loaded (e.g. offline), so printing never fails over it.
Future<String> organizationNameFor(
  String organizationId, {
  OrganizationRepository? repository,
}) async {
  try {
    final organization =
        await (repository ??
                OrganizationRepository(firestoreService: FirestoreService()))
            .getById(organizationId);
    final name = organization?.name.trim() ?? '';
    return name.isEmpty ? 'Safety record' : name;
  } on Object {
    return 'Safety record';
  }
}
