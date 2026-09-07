import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
import '../data/corrective_action_repository.dart';
import '../data/corrective_action_service.dart';
import '../domain/corrective_action.dart';
import '../domain/corrective_action_status.dart';

/// The Corrective Actions list for an authorized supervisor/manager —
/// `admin`/`siteManager`, the same role set
/// `AppRole.canReviewPendingAccounts` already grants review authority to
/// elsewhere in this app. A `foreman` or
/// `worker` sees an access message instead: they create corrective actions
/// from within a meeting ([DailySafetyMeetingScreen]'s Concerns step), but
/// status management is a supervisor/management responsibility, not a
/// per-meeting one — see `corrective_action_callable.ts`'s
/// `requireOrganizationScopedReviewer`, which this screen's actions mirror.
///
/// An `admin` has no organization of their own, so this screen
/// shows [OrganizationScopeSelector] for that role instead of blocking it —
/// `firestore.rules`'s `isAdmin()` already permits reading
/// every organization's corrective actions; the selector only decides which
/// organization's data to display.
///
/// Shows every corrective action across the organization's sites and
/// meetings — action, site, assigned person, due date, status — with a
/// large status control per row for the common "move this along" action.
/// Evidence upload is explicitly out of scope; there is no attachment UI
/// here.
class CorrectiveActionsScreen extends StatefulWidget {
  const CorrectiveActionsScreen({
    super.key,
    this.repository,
    this.service,
    this.siteRepository,
    this.organizationRepository,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final CorrectiveActionRepository? repository;
  final CorrectiveActionService? service;
  final SiteRepository? siteRepository;

  /// Injected in tests. Backs [OrganizationScopeSelector] for a System
  /// Administrator, who has no organization of their own to scope
  /// [repository]/[siteRepository] to.
  final OrganizationRepository? organizationRepository;

  @override
  State<CorrectiveActionsScreen> createState() =>
      _CorrectiveActionsScreenState();
}

class _CorrectiveActionsScreenState extends State<CorrectiveActionsScreen> {
  late final CorrectiveActionService _service =
      widget.service ?? CorrectiveActionService();

  CorrectiveActionRepository? _repository;
  SiteRepository? _siteRepository;

  String? _errorMessage;
  bool _isSaving = false;
  String? _selectedOrganizationId;

  CorrectiveActionRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = widget.repository ??
        CorrectiveActionRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _repository = created;
    return created;
  }

  SiteRepository _siteRepositoryFor(String organizationId) {
    final existing = _siteRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = widget.siteRepository ??
        SiteRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _siteRepository = created;
    return created;
  }

  Future<void> _updateStatus(
    String organizationId,
    CorrectiveAction action,
    CorrectiveActionStatus status,
  ) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _service.updateCorrectiveActionStatus(
        organizationId: organizationId,
        actionId: action.id,
        status: status.id,
      );
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final canManage = isPlatformAdministrator ||
        (sessionController.activeMembership?.role.canReviewPendingAccounts ??
            false);
    final organizationId = isPlatformAdministrator
        ? _selectedOrganizationId
        : sessionController.activeOrganizationId;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Corrective Actions are available to Organization '
            'Administrators, Safety Managers and Site Superintendents.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (organizationId == null) {
      if (isPlatformAdministrator) {
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: OrganizationScopeSelector(
            selectedOrganizationId: _selectedOrganizationId,
            onChanged: (value) => setState(() => _selectedOrganizationId = value),
            repository: widget.organizationRepository,
          ),
        );
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Corrective Actions are available to Organization '
            'Administrators, Safety Managers and Site Superintendents.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return StreamBuilder<List<CorrectiveAction>>(
      stream: _repositoryFor(organizationId).watchForOrganization(),
      builder: (context, actionSnapshot) {
        final actions = actionSnapshot.data ?? const <CorrectiveAction>[];
        final isLoading =
            actionSnapshot.connectionState == ConnectionState.waiting;

        return StreamBuilder<List<Site>>(
          stream: _siteRepositoryFor(organizationId).watchAll(),
          builder: (context, siteSnapshot) {
            final sitesById = {
              for (final site in siteSnapshot.data ?? const <Site>[])
                site.id: site,
            };

            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Text('Corrective Actions', style: AppTextStyles.headlineMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${actions.length} across every site',
                  style: AppTextStyles.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.md),
                if (isPlatformAdministrator)
                  OrganizationScopeSelector(
                    selectedOrganizationId: _selectedOrganizationId,
                    onChanged: (value) =>
                        setState(() => _selectedOrganizationId = value),
                    repository: widget.organizationRepository,
                  ),
                if (_errorMessage != null) ...[
                  AuthErrorBanner(message: _errorMessage!),
                  const SizedBox(height: AppSpacing.md),
                ],
                if (isLoading && actions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (!isLoading && actions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Text(
                      'No corrective actions recorded yet.',
                      style: AppTextStyles.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final action in actions) ...[
                  _CorrectiveActionRow(
                    action: action,
                    siteName: sitesById[action.siteId]?.name ?? action.siteId,
                    isSaving: _isSaving,
                    onStatusChange: (status) =>
                        _updateStatus(organizationId, action, status),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _CorrectiveActionRow extends StatelessWidget {
  const _CorrectiveActionRow({
    required this.action,
    required this.siteName,
    required this.isSaving,
    required this.onStatusChange,
  });

  final CorrectiveAction action;
  final String siteName;
  final bool isSaving;
  final void Function(CorrectiveActionStatus status) onStatusChange;

  Color get _statusColor => switch (action.status) {
    CorrectiveActionStatus.open => AppColors.textSecondary,
    CorrectiveActionStatus.inProgress => AppColors.info,
    CorrectiveActionStatus.completed => AppColors.success,
    CorrectiveActionStatus.overdue => AppColors.danger,
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(action.title, style: AppTextStyles.titleLarge),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: _statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppSpacing.sm),
                  ),
                  child: Text(
                    action.status.label,
                    style: AppTextStyles.label.copyWith(color: _statusColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Site: $siteName',
              style: AppTextStyles.bodyMedium,
            ),
            Text(
              'Assigned: ${action.assignedTo}',
              style: AppTextStyles.bodyMedium,
            ),
            Text(
              'Due: ${_formatDate(action.dueDate)}',
              style: AppTextStyles.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final status in CorrectiveActionStatus.values)
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: AppSpacing.minTouchTarget,
                    ),
                    child: status == action.status
                        ? ElevatedButton(
                            onPressed: null,
                            child: Text(status.label),
                          )
                        : OutlinedButton(
                            onPressed: isSaving
                                ? null
                                : () => onStatusChange(status),
                            child: Text(status.label),
                          ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
