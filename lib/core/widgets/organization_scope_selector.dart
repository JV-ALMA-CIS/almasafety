import 'package:flutter/material.dart';
import 'live_stream_builder.dart';
import 'choice_list.dart';
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
///
/// **Auto-selects the sole organization.** JV Safety runs a single company
/// today (PROJECT_CONTEXT.md's single-company framing) — with exactly one
/// [Organization] in Firestore, asking an Admin to pick it from a dropdown
/// with only one entry is a pointless extra step, not a real choice. Once
/// [OrganizationRepository.watchAll] resolves to exactly one organization
/// and the caller has not made a selection yet, this widget calls
/// [onChanged] with that organization's id itself, which (per the "renders
/// nothing once picked" behavior above) immediately collapses the widget
/// out of view — the caller's screen proceeds exactly as if the Admin had
/// picked it. The moment a second organization ever exists, this stops
/// firing (`organizations.length != 1`) and the dropdown behaves exactly as
/// it does today — a real choice the Admin must make. Nothing here assumes
/// there will only ever be one organization; it only special-cases the
/// trivial "nothing to choose between" case.
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

class _OrganizationScopeSelectorState extends State<OrganizationScopeSelector> {
  late final OrganizationRepository _repository =
      widget.repository ??
      OrganizationRepository(firestoreService: FirestoreService());

  @override
  Widget build(BuildContext context) {
    if (widget.selectedOrganizationId != null) {
      return const SizedBox.shrink();
    }

    return LiveStreamBuilder<List<Organization>>(
      streamKey: _repository,
      stream: () => _repository.watchAll(),
      builder: (context, snapshot) {
        final organizations = snapshot.data ?? const <Organization>[];

        // Nothing to actually choose between: auto-pick the sole
        // organization instead of making the Admin select it from a
        // one-item dropdown — see this widget's own doc comment. Scheduled
        // for after this frame since `onChanged` triggers a parent
        // `setState`, which must not happen synchronously inside `build`.
        if (organizations.length == 1 &&
            widget.selectedOrganizationId == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onChanged(organizations.single.id);
          });
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Organization', style: AppTextStyles.label),
              const SizedBox(height: AppSpacing.xs),
              ChoiceList<String>(
                items: [
                  for (final organization in organizations)
                    ChoiceItem(
                      value: organization.id,
                      title: organization.name,
                      badge: organization.code,
                    ),
                ],
                selected: widget.selectedOrganizationId,
                searchHint: 'Search organizations',
                onChanged: widget.onChanged,
              ),
            ],
          ),
        );
      },
    );
  }
}
