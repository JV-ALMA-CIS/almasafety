import 'package:flutter/material.dart';
import '../../features/organizations/data/organization_repository.dart';
import '../../features/organizations/domain/organization.dart';
import '../services/firestore_service.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A dropdown letting a System Administrator choose which organization's
/// data an organization-scoped screen (Corrective Actions, Safety Alerts,
/// Reports, Analytics, ...) should show.
///
/// A System Administrator has no organization of their own — every
/// operational repository behind those screens is nonetheless constructed
/// scoped to exactly one organization. This widget supplies that
/// organization by explicit choice instead of leaving the screen unable to
/// pick one at all. It is a viewing convenience only: it grants no new
/// authority. `firestore.rules`'s `isSystemAdministrator()` already permits
/// this role to read every organization's data in these collections, so
/// selecting an organization here only decides which of the reads this role
/// could already make gets displayed.
///
/// **This widget's "Admin-only" framing is no longer the whole multi-org
/// story.** Under the multi-organization membership model a Site Manager or
/// Foreman may also belong to more than one organization — but that is a
/// different need from what this widget serves: "which of MY OWN
/// memberships am I acting in right now," not "let me view ANY
/// organization for oversight." The former is
/// `SessionController.activeOrganizationId`/`activeMembership` and
/// `setActiveOrganization` (Stage 4) — a self-scoping choice a non-Admin
/// member makes about their own memberships, enforced server-side by
/// `requireApprover`'s `organizationId` argument on every relevant
/// callable. This widget remains the oversight tool: it stays reserved for
/// a caller (System Administrator today) who may legitimately view an
/// organization they do not themselves belong to at all. A UI surface for
/// the multi-membership "switch which of my own organizations I'm acting
/// in" case is a later stage — not built here.
///
/// Renders nothing (a zero-height [SizedBox]) once an organization is
/// picked, so callers place it once above their existing content and it
/// gets out of the way after the first selection.
class OrganizationScopeSelector extends StatefulWidget {
  const OrganizationScopeSelector({
    super.key,
    required this.selectedOrganizationId,
    required this.onChanged,
    this.repository,
  });

  final String? selectedOrganizationId;
  final ValueChanged<String?> onChanged;

  /// Injected in tests.
  final OrganizationRepository? repository;

  @override
  State<OrganizationScopeSelector> createState() =>
      _OrganizationScopeSelectorState();
}

class _OrganizationScopeSelectorState
    extends State<OrganizationScopeSelector> {
  late final OrganizationRepository _repository =
      widget.repository ??
      OrganizationRepository(firestoreService: FirestoreService());

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Organization>>(
      stream: _repository.watchAll(),
      builder: (context, snapshot) {
        final organizations = snapshot.data ?? const <Organization>[];

        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Organization', style: AppTextStyles.label),
              const SizedBox(height: AppSpacing.xs),
              DropdownButtonFormField<String>(
                initialValue: widget.selectedOrganizationId,
                decoration: const InputDecoration(
                  hintText: 'Choose an organization',
                ),
                items: [
                  for (final organization in organizations)
                    DropdownMenuItem(
                      value: organization.id,
                      child: Text(organization.name),
                    ),
                ],
                onChanged: widget.onChanged,
              ),
            ],
          ),
        );
      },
    );
  }
}
