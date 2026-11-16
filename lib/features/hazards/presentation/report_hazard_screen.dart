import '../../../core/offline/saved_on_phone_note.dart';
import 'dart:typed_data';
import '../../../core/widgets/photo_capture.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/hazard_service.dart';
import '../domain/hazard_category.dart';
import '../domain/hazard_kind.dart';
import '../../incidents/presentation/report_incident_screen.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/presentation/report_site_picker.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/feature_header.dart';
import 'hazard_style.dart';
import '../../../core/widgets/mobile_title.dart';

/// The worker-facing "Report a Hazard" flow — PROJECT_CONTEXT.md §24.
///
/// **Deliberately unrestricted by role.** Any active member of the
/// organization with site access can report a hazard: a worker, a foreman, a
/// contracted worker — see `functions/src/hazard_callable.ts`'s header note
/// on why creation has no role check, only a site one. The site is chosen
/// with [ReportSitePicker]: any site of the organization for a Site
/// Manager/Admin, any of their own assigned sites for a Foreman/Worker
/// (chosen automatically when there is only one). `createHazard`
/// re-verifies the site server-side regardless.
///
/// Kept to exactly the MVP fields (PROJECT_CONTEXT.md §24): category,
/// description, location, and an optional photo — plus one tap up front for
/// the [HazardKind] ("something could happen" vs "something nearly
/// happened"), which defaults to a hazard so the old flow is unchanged. No narrative report, no
/// severity picker, no assignment — those belong to the reviewer-side
/// acknowledge/link/close flow, not to the report itself.
///
/// Provides its own [Scaffold]/`AppBar`, unlike most screens in this
/// codebase's `lib/routing` tree (which return bare content into
/// `AppShell`'s own `ResponsiveScaffold`) — this screen is reached by
/// [Navigator.push] from [MyHazardsScreen], a separate route outside the
/// shell, so it needs to be self-sufficient.
class ReportHazardScreen extends StatefulWidget {
  const ReportHazardScreen({
    super.key,
    this.hazardService,
    this.imagePicker,
    this.siteRepository,
    this.initialKind = HazardKind.hazard,
    this.initialSiteId,
  });

  /// What the form starts on — [HazardKind.nearMiss] when the incident
  /// form sends someone here ("nobody hurt, nothing damaged").
  final HazardKind initialKind;

  /// A site already chosen on the form that sent them here.
  final String? initialSiteId;

  /// Injected in tests.
  final SiteRepository? siteRepository;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependency.
  final HazardService? hazardService;

  /// Injected in tests to avoid touching the platform camera/gallery.
  final ImagePicker? imagePicker;

  @override
  State<ReportHazardScreen> createState() => _ReportHazardScreenState();
}

class _ReportHazardScreenState extends State<ReportHazardScreen> {
  late final HazardService _hazardService =
      widget.hazardService ?? HazardService();
  late final ImagePicker _imagePicker = widget.imagePicker ?? ImagePicker();

  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _locationController = TextEditingController();

  late HazardKind _kind = widget.initialKind;
  HazardCategory? _category;
  late String? _siteId = widget.initialSiteId;
  XFile? _photo;
  Uint8List? _photoBytes;

  bool _isSubmitting = false;
  bool _isPickingPhoto = false;
  String? _errorMessage;
  bool _submitted = false;

  /// No signal: the report is saved on this phone and sent later.
  bool _savedOffline = false;

  @override
  void dispose() {
    _descriptionController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    setState(() {
      _isPickingPhoto = true;
      _errorMessage = null;
    });
    try {
      final photo = await takePhoto(context, picker: _imagePicker);
      if (photo == null) return;
      final bytes = await photo.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photo = photo;
        _photoBytes = bytes;
      });
    } on Object catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Could not capture a photo. You can still submit '
            'without one.';
      });
    } finally {
      if (mounted) setState(() => _isPickingPhoto = false);
    }
  }

  void _removePhoto() {
    setState(() {
      _photo = null;
      _photoBytes = null;
    });
  }

  Future<void> _submit({required String organizationId}) async {
    final category = _category;
    final siteId = _siteId;
    if (!(_formKey.currentState?.validate() ?? false) ||
        category == null ||
        siteId == null) {
      setState(() => _errorMessage = 'Please fill in the required fields.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      await _hazardService.reportHazard(
        organizationId: organizationId,
        siteId: siteId,
        kind: _kind.id,
        category: category.id,
        description: _descriptionController.text.trim(),
        location: _locationController.text.trim().isEmpty
            ? null
            : _locationController.text.trim(),
        photoFileName: _photo?.name,
        photoBytes: _photoBytes,
      );
      if (!mounted) return;
      setState(() => _submitted = true);
    } on SavedOfflineException {
      if (!mounted) return;
      setState(() {
        _submitted = true;
        _savedOffline = true;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _reportAnother() {
    _formKey.currentState?.reset();
    _descriptionController.clear();
    _locationController.clear();
    setState(() {
      _kind = HazardKind.hazard;
      _category = null;
      _photo = null;
      _photoBytes = null;
      _submitted = false;
      _savedOffline = false;
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final membership = sessionController.activeMembership;
    final organizationId = sessionController.activeOrganizationId;
    final siteIds = reportableSiteIds(
      isPlatformAdministrator:
          sessionController.profile?.isPlatformAdministrator ?? false,
      role: membership?.role,
      assignedSiteIds: membership?.siteIds ?? const [],
    );

    if (organizationId == null || (siteIds != null && siteIds.isEmpty)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Report a Hazard')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Text(
              'Hazard reporting is available once you are assigned to a '
              'site.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_submitted) {
      return Scaffold(
        appBar: AppBar(title: const Text('Report a Hazard')),
        body: Column(
          children: [
            if (_savedOffline)
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  0,
                ),
                child: SavedOnPhoneNote(
                  text:
                      'No signal - your report is saved on this phone and '
                      'will be sent automatically when the signal comes '
                      'back. If it is dangerous right now, tell your Foreman '
                      'in person.',
                ),
              ),
            Expanded(
              child: _SuccessView(kind: _kind, onReportAnother: _reportAnother),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Report a Hazard')),
      body: _ReportForm(
        siteSection: ReportSitePicker(
          organizationId: organizationId,
          siteIds: siteIds,
          selectedSiteId: _siteId,
          onChanged: (id) => setState(() => _siteId = id),
          siteRepository: widget.siteRepository,
        ),
        formKey: _formKey,
        descriptionController: _descriptionController,
        locationController: _locationController,
        kind: _kind,
        onKindSelected: (value) => setState(() => _kind = value),
        category: _category,
        onCategorySelected: (value) => setState(() => _category = value),
        photoBytes: _photoBytes,
        isPickingPhoto: _isPickingPhoto,
        onPickPhoto: _pickPhoto,
        onRemovePhoto: _removePhoto,
        errorMessage: _errorMessage,
        isSubmitting: _isSubmitting,
        onSubmit: () => _submit(organizationId: organizationId),
      ),
    );
  }
}

class _ReportForm extends StatelessWidget {
  const _ReportForm({
    required this.siteSection,
    required this.formKey,
    required this.descriptionController,
    required this.locationController,
    required this.kind,
    required this.onKindSelected,
    required this.category,
    required this.onCategorySelected,
    required this.photoBytes,
    required this.isPickingPhoto,
    required this.onPickPhoto,
    required this.onRemovePhoto,
    required this.errorMessage,
    required this.isSubmitting,
    required this.onSubmit,
  });

  /// The "Site" choice — see [ReportSitePicker].
  final Widget siteSection;
  final GlobalKey<FormState> formKey;
  final TextEditingController descriptionController;
  final TextEditingController locationController;
  final HazardKind kind;
  final ValueChanged<HazardKind> onKindSelected;
  final HazardCategory? category;
  final ValueChanged<HazardCategory> onCategorySelected;
  final Uint8List? photoBytes;
  final bool isPickingPhoto;
  final VoidCallback onPickPhoto;
  final VoidCallback onRemovePhoto;
  final String? errorMessage;
  final bool isSubmitting;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        FeatureHeader(
          title: 'Report a Hazard',
          subtitle: kind == HazardKind.nearMiss
              ? 'Tell us what nearly happened. A photo helps but is not '
                    'required.'
              : 'Tell us what you saw. A photo helps but is not required.',
          icon: category?.icon ?? Icons.add_alert,
          color: category?.color ?? AppColors.hazards,
        ),
        const SizedBox(height: AppSpacing.lg),
        if (errorMessage != null) ...[
          _ErrorBanner(message: errorMessage!),
          const SizedBox(height: AppSpacing.md),
        ],
        Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FormSection(
                title: 'Site',
                icon: Icons.location_city,
                color: AppColors.projects,
                child: siteSection,
              ),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'What happened?',
                icon: kind.icon,
                color: kind.color,
                child: Row(
                  children: [
                    for (final option in HazardKind.values) ...[
                      if (option != HazardKind.values.first)
                        const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: _KindTile(
                          kind: option,
                          selected: kind == option,
                          onTap: () => onKindSelected(option),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              const _IncidentLink(),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'Category',
                icon: Icons.category,
                color: category?.color ?? AppColors.hazards,
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final option in HazardCategory.values)
                      _CategoryTile(
                        category: option,
                        selected: category == option,
                        onTap: () => onCategorySelected(option),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'Description',
                icon: Icons.edit_note,
                color: AppColors.meetings,
                child: TextFormField(
                  controller: descriptionController,
                  minLines: 3,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: kind == HazardKind.nearMiss
                        ? 'What nearly happened?'
                        : 'What is the hazard?',
                    border: const OutlineInputBorder(),
                  ),
                  autofillHints: const [],
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'A description is required.'
                      : null,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'Location (optional)',
                icon: Icons.place,
                color: AppColors.projects,
                child: TextFormField(
                  controller: locationController,
                  decoration: const InputDecoration(
                    hintText: 'e.g. East wing, 3rd floor',
                    border: OutlineInputBorder(),
                  ),
                  autofillHints: const [],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'Photo (optional)',
                icon: Icons.photo_camera,
                color: AppColors.analytics,
                child: _PhotoPicker(
                  photoBytes: photoBytes,
                  isPicking: isPickingPhoto,
                  onPick: onPickPhoto,
                  onRemove: onRemovePhoto,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        SizedBox(
          height: AppSpacing.minTouchTarget,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: category?.color ?? AppColors.hazards,
              foregroundColor: AppColors.onColor(
                category?.color ?? AppColors.hazards,
              ),
            ),
            onPressed: isSubmitting ? null : onSubmit,
            child: isSubmitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Submit Report'),
          ),
        ),
      ],
    );
  }
}

/// The way out to [ReportIncidentScreen] for something that ACTUALLY
/// happened — someone hurt, something damaged — which is not a hazard or a
/// near-miss and needs its own fields.
class _IncidentLink extends StatelessWidget {
  const _IncidentLink();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.stop.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.stop),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context, rootNavigator: true).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const ReportIncidentScreen()),
        ),
        child: const Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Text('🤕', style: TextStyle(fontSize: 28)),
              SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Something actually happened — someone hurt or something '
                  'damaged',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Icon(Icons.chevron_right, color: AppColors.stop),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the two large "What happened?" choices on the report form — the
/// kind's picture and plain-language prompt in its own color, solid when
/// chosen.
class _KindTile extends StatelessWidget {
  const _KindTile({
    required this.kind,
    required this.selected,
    required this.onTap,
  });

  final HazardKind kind;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = kind.color;
    return Material(
      color: selected ? color : color.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.md,
            horizontal: AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(kind.emoji, style: const TextStyle(fontSize: 32)),
              const SizedBox(height: 4),
              Text(
                kind.prompt,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? AppColors.onColor(color) : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One large category choice on the report form: the hazard's picture and
/// name in its own color, solid when chosen.
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final HazardCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = category.color;
    return SizedBox(
      width: 104,
      child: Material(
        color: selected ? color : color.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.sm + 2,
              horizontal: AppSpacing.xs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(category.emoji, style: const TextStyle(fontSize: 28)),
                const SizedBox(height: 4),
                Text(
                  category.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: selected ? AppColors.onColor(color) : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({
    required this.photoBytes,
    required this.isPicking,
    required this.onPick,
    required this.onRemove,
  });

  final Uint8List? photoBytes;
  final bool isPicking;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final bytes = photoBytes;
    if (bytes != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.sm),
            child: Image.memory(bytes, height: 160, fit: BoxFit.cover),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton.icon(
            onPressed: onRemove,
            icon: const Icon(Icons.close),
            label: const Text('Remove photo'),
          ),
        ],
      );
    }
    return SizedBox(
      height: AppSpacing.minTouchTarget,
      child: OutlinedButton.icon(
        onPressed: isPicking ? null : onPick,
        icon: isPicking
            ? const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.camera_alt_outlined),
        label: const Text('Add Photo'),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Text(
        message,
        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.danger),
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  const _SuccessView({required this.kind, required this.onReportAnother});

  final HazardKind kind;
  final VoidCallback onReportAnother;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircleAvatar(
              radius: 44,
              backgroundColor: AppColors.success,
              child: Icon(Icons.check, color: Colors.white, size: 56),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('${kind.label} Reported', style: AppTextStyles.headlineMedium),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Thank you. Your report has been submitted and will be '
              'reviewed.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              height: AppSpacing.minTouchTarget,
              child: OutlinedButton(
                onPressed: onReportAnother,
                child: const Text('Report Another'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
