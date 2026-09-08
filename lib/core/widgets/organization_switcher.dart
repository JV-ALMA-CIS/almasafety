import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/authentication/domain/membership.dart';
import '../../features/organizations/data/organization_repository.dart';
import '../services/firestore_service.dart';
import '../services/session_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// Shows the signed-in user's current organization, and — once they hold
/// two or more memberships — lets them switch which one is active.
///
/// Always shown once there is at least one real membership, INCLUDING the
/// common single-org case: a member should always be able to see which
/// organization they are currently working in, not only once there are
/// several to choose between. Renders nothing (a zero-size [SizedBox]) only
/// when there are truly zero memberships to show — e.g. an [AppRole.admin],
/// who holds none at all (platform-level, org-less by construction — see
/// [OrganizationScopeSelector] for their separate "view any organization"
/// mechanism), or a brand-new Site Manager who has not created/been placed
/// into an organization yet.
///
/// With exactly one membership the control is a plain, non-interactive
/// label (nothing to switch to). With two or more it becomes a dropdown —
/// this is the self-scoping counterpart to [OrganizationScopeSelector]:
/// that widget lets an oversight role (System Administrator) view ANY
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
/// clear "Suspended" indicator, and the active-organization label itself
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

    if (memberships.isEmpty) return const SizedBox.shrink();

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
  /// organizationId -> resolved name, or null once confirmed the
  /// organization document no longer exists (e.g. deleted directly in
  /// Firestore, leaving a dangling membership behind — the client has no
  /// delete-organization path of its own, so this can currently only
  /// happen from outside the app). Absent from this map entirely means
  /// "still loading" — present with a null value means "confirmed gone",
  /// which [_nameFor] and the row/label builders treat differently: a
  /// still-loading name falls back to the raw id (best available label for
  /// now); a confirmed-gone one is never shown as if it were a normal,
  /// selectable organization.
  final Map<String, String?> _names = {};

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
        if (!mounted) return;
        // organization == null means the document does not exist —
        // recorded explicitly (not just left absent) so _nameFor can tell
        // "still loading" apart from "confirmed gone".
        setState(() => _names[organizationId] = organization?.name);
      });
    }
  }

  /// True once [organizationId] has been confirmed to have no matching
  /// document — a dangling membership left behind by an organization
  /// deleted outside the app.
  bool _isMissing(String organizationId) =>
      _names.containsKey(organizationId) && _names[organizationId] == null;

  String _nameFor(String organizationId) =>
      _names[organizationId] ?? organizationId;

  @override
  Widget build(BuildContext context) {
    // Memberships whose organization is confirmed gone are never offered
    // as a choice — there is nothing behind them to switch to.
    final selectableMemberships = widget.memberships
        .where((m) => !_isMissing(m.organizationId))
        .toList(growable: false);

    if (selectableMemberships.isEmpty) return const SizedBox.shrink();

    final active = widget.activeMembership;
    final activeIsMissing =
        active != null && _isMissing(active.organizationId);
    final activeLabel = active == null
        ? 'Choose organization'
        : (activeIsMissing
            ? 'Organization unavailable'
            : _nameFor(active.organizationId));
    final activeSuspended = active?.status == MembershipStatus.suspended;

    final labelContent = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.apartment_outlined,
            size: 18,
            color: activeSuspended ? AppColors.warning : AppColors.primary,
          ),
          const SizedBox(width: AppSpacing.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              activeLabel,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.label.copyWith(
                color: activeSuspended ? AppColors.warning : AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (activeSuspended) ...[
            const SizedBox(width: AppSpacing.xs),
            const _SuspendedChip(),
          ],
        ],
      ),
    );

    // Exactly one real organization: nothing to switch between, so this is
    // a plain label — still always visible, per this widget's own class
    // doc comment, just not interactive.
    if (selectableMemberships.length <= 1) return labelContent;

    return PopupMenuButton<String>(
      tooltip: 'Switch organization',
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final membership in selectableMemberships)
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          labelContent,
          Icon(Icons.arrow_drop_down, size: 18, color: AppColors.primary),
        ],
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
