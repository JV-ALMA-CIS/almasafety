import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/domain/organization_user.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/site_repository.dart';
import '../domain/site.dart';

/// A Foreman's read-only view of the Workers assigned to their own site(s)
/// within their active organization.
///
/// A Site Manager approves/places Foremen, but it's the Foreman who
/// approves and works day-to-day alongside Workers on their assigned
/// site(s) — this screen is where a Foreman sees who those Workers
/// currently are, without the assign/remove authority
/// [SiteWorkersScreen] gives a Site Manager (a Foreman has no
/// `assignWorkerToSite`/`removeWorkerFromSite` authorization server-side;
/// see `site_assignment_callable.ts`'s `requireOrganizationScopedAdmin`).
/// New Workers reach this list through [PendingApprovalsScreen] instead —
/// a Foreman approves them there, choosing the role/worker type/site(s) at
/// approval time, exactly like [SiteWorkersScreen] does for other roles.
///
/// Scoped to the Foreman's OWN `siteIds` — not the whole organization — to
/// match their actual authority: PROJECT_CONTEXT.md §16 confines a
/// Foreman's approval/oversight to their own assigned site(s), never every
/// site in the organization (that org-wide view belongs to
/// [SitesScreen]/[SiteWorkersScreen], Site Manager/Admin only).
class MyWorkersScreen extends StatefulWidget {
  const MyWorkersScreen({
    super.key,
    this.approvalService,
    this.siteRepositoryFor,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real service.
  final AccountApprovalService? approvalService;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real, organization-scoped repository.
  final SiteRepository Function(String organizationId)? siteRepositoryFor;

  @override
  State<MyWorkersScreen> createState() => _MyWorkersScreenState();
}

class _MyWorkersScreenState extends State<MyWorkersScreen> {
  late final AccountApprovalService _approvalService =
      widget.approvalService ?? AccountApprovalService();
  late final SiteRepository Function(String organizationId) _siteRepositoryFor =
      widget.siteRepositoryFor ??
      (organizationId) => SiteRepository(
        firestoreService: FirestoreService(),
        organizationId: organizationId,
      );

  List<OrganizationUser> _workers = const [];
  Map<String, String> _siteNames = const {};
  bool _isLoading = true;
  String? _errorMessage;
  String? _loadedForOrganizationId;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final membership = sessionController.activeMembership;
    final organizationId = sessionController.activeOrganizationId;
    final isForeman = membership?.role == AppRole.foreman;
    final siteIds = membership?.siteIds ?? const [];

    if (!isForeman || organizationId == null || siteIds.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'My Workers is available to a Foreman assigned to a site.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_loadedForOrganizationId != organizationId) {
      // Fires during build, deliberately: mirrors the established pattern
      // in this codebase's other screens whose data depends on the active
      // organization (e.g. DailySafetyMeetingScreen), since switching
      // organizations while this screen is open must reload rather than
      // silently keep showing the previous organization's data.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _load(organizationId, siteIds),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(organizationId, siteIds),
      child: _buildBody(siteIds),
    );
  }

  Future<void> _load(String organizationId, List<String> siteIds) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _loadedForOrganizationId = organizationId;
    });
    try {
      final results = await Future.wait([
        _approvalService.listUsers(
          status: AccountStatus.active,
          organizationId: organizationId,
        ),
        _siteRepositoryFor(organizationId).watchAll().first,
      ]);
      if (!mounted) return;
      final users = results[0] as List<OrganizationUser>;
      final sites = results[1] as List<Site>;
      setState(() {
        _workers = users
            .where(
              (user) =>
                  user.role == AppRole.worker &&
                  user.siteIds.any(siteIds.contains),
            )
            .toList(growable: false);
        _siteNames = {for (final site in sites) site.id: site.name};
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildBody(List<String> siteIds) {
    if (_isLoading && _workers.isEmpty && _errorMessage == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text('My Workers', style: AppTextStyles.headlineMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          siteIds.length > 1
              ? 'Workers assigned to your sites.'
              : 'Workers assigned to your site.',
          style: AppTextStyles.bodyMedium,
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: AppSpacing.md),
          AuthErrorBanner(message: _errorMessage!),
        ],
        const SizedBox(height: AppSpacing.md),
        if (!_isLoading && _workers.isEmpty && _errorMessage == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: Text(
              'No workers are assigned to your site(s) yet. Approve one '
              'from Pending Approvals.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        for (final worker in _workers) ...[
          _WorkerCard(worker: worker, siteNames: _siteNames),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _WorkerCard extends StatelessWidget {
  const _WorkerCard({required this.worker, required this.siteNames});

  final OrganizationUser worker;
  final Map<String, String> siteNames;

  @override
  Widget build(BuildContext context) {
    final siteLabel = worker.siteIds
        .map((id) => siteNames[id] ?? id)
        .join(', ');
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text(worker.name),
        subtitle: Text(
          [
            if (worker.workerType != null) worker.workerType!.label,
            if (siteLabel.isNotEmpty) siteLabel,
          ].join(' · '),
        ),
      ),
    );
  }
}
