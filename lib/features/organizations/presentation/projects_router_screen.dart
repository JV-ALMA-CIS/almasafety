import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/organization_admin_service.dart';
import '../data/organization_repository.dart';
import '../data/project_repository.dart';
import '../domain/organization.dart';
import '../domain/organization_record_status.dart';
import 'projects_screen.dart';

/// The sidebar's "Projects" destination ([AppRoutes.projects]) and the
/// app's single Operations landing page under the single-company model —
/// resolves the signed-in user's own (JV ALMA CIS) organization directly
/// and shows [ProjectsScreen] for it, with no Organizations list to
/// navigate through first.
///
/// Mirrors [DailySafetyMeetingsRouterScreen]'s shape: a top-level nav
/// destination that needs an [Organization] object, which [ProjectsScreen]
/// otherwise only receives via `extra` from a card tap. Reading
/// `SessionController.activeOrganizationId` and resolving that one
/// document directly makes Projects the primary navigation entry, while
/// [ProjectsScreen] itself is unchanged.
///
/// BOOTSTRAP CASE (Site Manager only): a Site Manager approved with no
/// organization yet (see `account_approval.ts`'s `approveAccount` — an
/// Admin approving a Site Manager they know by name typically has no way to
/// know which organization to name, so the new Site Manager creates it
/// themselves afterward) has `activeOrganizationId == null` here. Rather
/// than a dead end, this screen shows a one-time "Set up JV ALMA CIS"
/// prompt that calls `createOrganization` directly with the company's
/// fixed name/code — there is only ever one company, so there is nothing
/// to ask the Site Manager to type. Once created, this screen (and every
/// other Site Manager's) resolves it normally from then on; the prompt
/// never appears again for this or any other account.
///
/// ADMIN CASE: a System Administrator has `activeOrganizationId == null`
/// PERMANENTLY — Admin holds platform-level authority scoped to no
/// organization at all (PROJECT_CONTEXT.md §12), which is never the
/// bootstrap case above. Showing an Admin the "Set up JV ALMA CIS" prompt
/// once the real Site Manager-created org already exists would be actively
/// harmful, since `createOrganization` does not refuse a duplicate name —
/// pressing it creates a second, orphaned organization document with no
/// membership attached (an `admin` caller gets no membership from
/// `createOrganization`, unlike a `siteManager` caller), which looked like
/// the button "did nothing." An Admin instead picks the organization that
/// already exists via [OrganizationScopeSelector], matching
/// `SafetyLearningLibraryScreen`/`SafetyRequirementsScreen`'s own fallback.
class ProjectsRouterScreen extends StatefulWidget {
  const ProjectsRouterScreen({
    super.key,
    this.organizationRepository,
    this.firestoreService,
    this.projectRepository,
    this.adminService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependency.
  final OrganizationRepository? organizationRepository;

  /// Threaded through to [ProjectsScreen] so a test's fake Firestore
  /// instance backs the whole resolve-then-render chain, matching
  /// [DailySafetyMeetingsRouterScreen]'s own injection pattern.
  final FirestoreService? firestoreService;
  final ProjectRepository? projectRepository;
  final OrganizationAdminService? adminService;

  @override
  State<ProjectsRouterScreen> createState() => _ProjectsRouterScreenState();
}

class _ProjectsRouterScreenState extends State<ProjectsRouterScreen> {
  late final FirestoreService _firestoreService =
      widget.firestoreService ?? FirestoreService();
  late final OrganizationRepository _organizationRepository =
      widget.organizationRepository ??
      OrganizationRepository(firestoreService: _firestoreService);
  late final OrganizationAdminService _adminService =
      widget.adminService ?? OrganizationAdminService();

  bool _isCreating = false;
  String? _errorMessage;
  String? _selectedOrganizationId;

  Future<void> _setUpCompany() async {
    setState(() {
      _isCreating = true;
      _errorMessage = null;
    });
    try {
      // Fixed name/code: there is only ever one company on this platform,
      // so there is nothing for the Site Manager to choose or type — see
      // this screen's own class doc comment.
      await _adminService.createOrganization(
        name: 'JV ALMA CIS',
        code: 'JV-ALMA-CIS',
        status: OrganizationRecordStatus.active,
      );
      // No further navigation needed: SessionController's own membership
      // subscription picks up the new membership `createOrganization`
      // creates for the caller, which updates `activeOrganizationId` and
      // rebuilds this screen straight into the normal resolved-org path
      // below.
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final isPlatformAdministrator =
        sessionController.profile?.isPlatformAdministrator ?? false;
    final organizationId =
        sessionController.activeOrganizationId ??
        (isPlatformAdministrator ? _selectedOrganizationId : null);

    if (organizationId == null) {
      // A System Administrator has no membership of their own — that is
      // never the "nobody has set up JV ALMA CIS yet" bootstrap case below,
      // it is the normal, permanent state for this role (PROJECT_CONTEXT.md
      // §12: Admin holds platform-level authority scoped to no organization
      // at all). Showing them the "Set up JV ALMA CIS" prompt here would be
      // actively harmful: `createOrganization` does not refuse a second
      // company with the same name, so pressing it after a Site Manager has
      // already created the real org silently creates a DUPLICATE orphan
      // organization document with no membership pointing at it (see
      // `createOrganization`'s own comment on why it only creates a
      // membership for a `siteManager` caller) — which is exactly why the
      // button used to look like it "did nothing." An Admin instead picks
      // the organization that already exists, the same
      // [OrganizationScopeSelector] pattern used by
      // `SafetyLearningLibraryScreen`/`SafetyRequirementsScreen`.
      if (isPlatformAdministrator) {
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: OrganizationScopeSelector(
            selectedOrganizationId: _selectedOrganizationId,
            onChanged: (value) =>
                setState(() => _selectedOrganizationId = value),
            repository: widget.organizationRepository,
          ),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'JV ALMA CIS has not been set up yet.',
                style: AppTextStyles.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Set it up once to start adding projects, sites and '
                'workers.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.md),
                AuthErrorBanner(message: _errorMessage!),
              ],
              const SizedBox(height: AppSpacing.lg),
              ElevatedButton.icon(
                onPressed: _isCreating ? null : _setUpCompany,
                icon: _isCreating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: const Text('Set up JV ALMA CIS'),
              ),
            ],
          ),
        ),
      );
    }

    return LiveStreamBuilder<Organization?>(
      streamKey: (_organizationRepository, organizationId),
      stream: () => _organizationRepository.watchById(organizationId),
      builder: (context, snapshot) {
        final organization = snapshot.data;
        final isLoading = snapshot.connectionState == ConnectionState.waiting;

        if (isLoading && organization == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (organization == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'Could not load JV ALMA CIS. Please try again.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return ProjectsScreen(
          organization: organization,
          repository: widget.projectRepository,
          adminService: _adminService,
        );
      },
    );
  }
}
