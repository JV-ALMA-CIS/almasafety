import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
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
/// BOOTSTRAP CASE: a Site Manager approved with no organization yet (see
/// `account_approval.ts`'s `approveAccount` — an Admin approving a Site
/// Manager they know by name typically has no way to know which
/// organization to name, so the new Site Manager creates it themselves
/// afterward) has `activeOrganizationId == null` here. Rather than a dead
/// end, this screen shows a one-time "Set up JV ALMA CIS" prompt that
/// calls `createOrganization` directly with the company's fixed name/code
/// — there is only ever one company, so there is nothing to ask the Site
/// Manager to type. Once created, this screen (and every other Site
/// Manager's) resolves it normally from then on; the prompt never appears
/// again for this or any other account.
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
    final organizationId = sessionController.activeOrganizationId;

    if (organizationId == null) {
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

    return StreamBuilder<Organization?>(
      stream: _organizationRepository.watchById(organizationId),
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
