import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/authentication/domain/membership.dart';
import '../../features/organizations/data/organization_repository.dart';
import '../services/firestore_service.dart';
import '../services/session_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A compact app-bar control letting a multi-membership user choose which of
/// their OWN organizations they are currently acting within.
///
/// Renders nothing (a zero-size [SizedBox]) whenever
/// [SessionController.memberships] holds one or fewer entries — a
/// single-membership user has nothing to switch between, and an [AppRole]
/// admin holds no memberships at all (platform-level, org-less by
/// construction) — matching [OrganizationScopeSelector]'s "renders nothing"
/// convention for the same reason: a widget that has nothing useful to show
/// should not claim any layout space or visual attention.
///
/// This is the self-scoping counterpart to [OrganizationScopeSelector]: that
/// widget lets an oversight role (System Administrator) view ANY
/// organization; this widget lets an ordinary member choose which of their
/// OWN memberships is active. Selecting an organization here only changes
/// [SessionController.activeOrganizationId] — a UI convenience with no
/// bearing on server-side authorization (see SessionController's SECURITY
/// WARNING doc comment).
///
/// DESIGN DECISION — suspended memberships stay selectable, not disabled.
/// A suspended membership is still real: the user needs a way to see *why*
/// screens scoped to that organization behave oddly (every reviewer/content
/// action is refused server-side for a suspended membership), and hiding or
/// disabling the row would make that invisible. Each row instead shows a
/// clear "Suspended" indicator, and the active-organization button itself
/// shows the same indicator when the currently active membership is
/// suspended — so a suspended organization can be viewed, but never mistaken
/// for an active one.
class OrganizationSwitcher extends StatelessWidget {
  const OrganizationSwitcher({super.key, this.repository});

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real repository.
  final OrganizationRepository? repository;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final memberships = sessionController.memberships;

    if (memberships.length <= 1) return const SizedBox.shrink();

    final repo =
        repository ?? OrganizationRepository(firestoreService: FirestoreService());
    final activeMembership = sessionController.activeMembership;

    return _OrganizationSwitcherBody(
      repository: repo,
      memberships: memberships,
      activeMembership: activeMembership,
      onSelected: sessionController.setActiveOrganization,
    );
  }
}

class _OrganizationSwitcherBody extends StatefulWidget {
  const _OrganizationSwitcherBody({
    required this.repository,
    required this.memberships,
    required this.activeMembership,
    required this.onSelected,
  });

  final OrganizationRepository repository;
  final List<Membership> memberships;
  final Membership? activeMembership;
  final ValueChanged<String> onSelected;

  @override
  State<_OrganizationSwitcherBody> createState() =>
      _OrganizationSwitcherBodyState();
}

class _OrganizationSwitcherBodyState
    extends State<_OrganizationSwitcherBody> {
  /// organizationId -> resolved name. Populated as each fetch resolves; a
  /// row shows the raw id as a fallback until then rather than blocking the
  /// whole control on every organization loading.
  final Map<String, String> _names = {};

  @override
  void initState() {
    super.initState();
    _loadNames();
  }

  @override
  void didUpdateWidget(covariant _OrganizationSwitcherBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.memberships.map((m) => m.organizationId).toSet();
    final newIds = widget.memberships.map((m) => m.organizationId).toSet();
    if (!oldIds.containsAll(newIds)) _loadNames();
  }

  void _loadNames() {
    for (final membership in widget.memberships) {
      final organizationId = membership.organizationId;
      if (_names.containsKey(organizationId)) continue;
      widget.repository.getById(organizationId).then((organization) {
        if (!mounted || organization == null) return;
        setState(() => _names[organizationId] = organization.name);
      });
    }
  }

  String _nameFor(String organizationId) =>
      _names[organizationId] ?? organizationId;

  @override
  Widget build(BuildContext context) {
    final active = widget.activeMembership;
    final activeLabel = active == null
        ? 'Choose organization'
        : _nameFor(active.organizationId);
    final activeSuspended = active?.status == MembershipStatus.suspended;

    return PopupMenuButton<String>(
      tooltip: 'Switch organization',
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final membership in widget.memberships)
          PopupMenuItem<String>(
            value: membership.organizationId,
            child: _MembershipRow(
              name: _nameFor(membership.organizationId),
              suspended: membership.status == MembershipStatus.suspended,
              selected: membership.organizationId == active?.organizationId,
            ),
          ),
      ],
      onSelected: widget.onSelected,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.apartment_outlined,
              size: 18,
              color: activeSuspended
                  ? AppColors.warning
                  : Theme.of(context).colorScheme.onSurface,
            ),
            const SizedBox(width: AppSpacing.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                activeLabel,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.label.copyWith(
                  color: activeSuspended ? AppColors.warning : null,
                ),
              ),
            ),
            if (activeSuspended) ...[
              const SizedBox(width: AppSpacing.xs),
              const _SuspendedChip(),
            ],
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

class _MembershipRow extends StatelessWidget {
  const _MembershipRow({
    required this.name,
    required this.suspended,
    required this.selected,
  });

  final String name;
  final bool suspended;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (selected)
          const Padding(
            padding: EdgeInsets.only(right: AppSpacing.xs),
            child: Icon(Icons.check, size: 16, color: AppColors.primary),
          ),
        Expanded(
          child: Text(
            name,
            style: AppTextStyles.bodyMedium.copyWith(
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        if (suspended) ...[
          const SizedBox(width: AppSpacing.sm),
          const _SuspendedChip(),
        ],
      ],
    );
  }
}

class _SuspendedChip extends StatelessWidget {
  const _SuspendedChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.xs),
      ),
      child: const Text(
        'Suspended',
        style: TextStyle(fontSize: 10, color: AppColors.warning),
      ),
    );
  }
}
