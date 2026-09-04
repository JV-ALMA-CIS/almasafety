import 'dart:typed_data';

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

/// The worker-facing "Report a Hazard" flow — PROJECT_CONTEXT.md §24.
///
/// **Deliberately unrestricted by role.** Any active member of the
/// organization with site access can report a hazard: a worker, a foreman, a
/// contracted worker — see `functions/src/hazard_callable.ts`'s header note
/// on why creation has no role check, only a site-membership one. A user
/// with more than one assigned site reports against the first, mirroring
/// [DailySafetyMeetingScreen]'s own "first assigned site" UX — this is UX
/// only; `createHazard` re-verifies site access server-side regardless.
///
/// Kept to exactly the MVP fields (PROJECT_CONTEXT.md §24): category,
/// description, location, and an optional photo. No narrative report, no
/// severity picker, no assignment — those belong to the reviewer-side
/// acknowledge/link/close flow, not to the report itself.
///
/// Provides its own [Scaffold]/`AppBar`, unlike most screens in this
/// codebase's `lib/routing` tree (which return bare content into
/// `AppShell`'s own `ResponsiveScaffold`) — this screen is reached by
/// [Navigator.push] from [MyHazardsScreen], a separate route outside the
/// shell, so it needs to be self-sufficient.
class ReportHazardScreen extends StatefulWidget {
  const ReportHazardScreen({super.key, this.hazardService, this.imagePicker});

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

  HazardCategory? _category;
  XFile? _photo;
  Uint8List? _photoBytes;

  bool _isSubmitting = false;
  bool _isPickingPhoto = false;
  String? _errorMessage;
  bool _submitted = false;

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
      final photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        imageQuality: 85,
      );
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
        _errorMessage = 'Could not capture a photo. You can still submit '
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

  Future<void> _submit({
    required String organizationId,
    required String siteId,
  }) async {
    final category = _category;
    if (!(_formKey.currentState?.validate() ?? false) || category == null) {
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
      _category = null;
      _photo = null;
      _photoBytes = null;
      _submitted = false;
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<SessionController>().profile;
    final organizationId = profile?.organizationId;
    final siteId = profile?.siteIds.isNotEmpty == true
        ? profile!.siteIds.first
        : null;

    if (organizationId == null || siteId == null) {
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
        body: _SuccessView(onReportAnother: _reportAnother),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Report a Hazard')),
      body: _ReportForm(
        formKey: _formKey,
        descriptionController: _descriptionController,
        locationController: _locationController,
        category: _category,
        onCategorySelected: (value) => setState(() => _category = value),
        photoBytes: _photoBytes,
        isPickingPhoto: _isPickingPhoto,
        onPickPhoto: _pickPhoto,
        onRemovePhoto: _removePhoto,
        errorMessage: _errorMessage,
        isSubmitting: _isSubmitting,
        onSubmit: () => _submit(organizationId: organizationId, siteId: siteId),
      ),
    );
  }
}

class _ReportForm extends StatelessWidget {
  const _ReportForm({
    required this.formKey,
    required this.descriptionController,
    required this.locationController,
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

  final GlobalKey<FormState> formKey;
  final TextEditingController descriptionController;
  final TextEditingController locationController;
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
        Text('Report a Hazard', style: AppTextStyles.headlineMedium),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'Tell us what you saw. A photo helps but is not required.',
          style: AppTextStyles.bodyMedium,
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
              Text('Category', style: AppTextStyles.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final option in HazardCategory.values)
                    ChoiceChip(
                      label: Text(option.label),
                      selected: category == option,
                      onSelected: (_) => onCategorySelected(option),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Description', style: AppTextStyles.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: descriptionController,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'What is the hazard?',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'A description is required.'
                    : null,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Location (optional)', style: AppTextStyles.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: locationController,
                decoration: const InputDecoration(
                  hintText: 'e.g. East wing, 3rd floor',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Photo (optional)', style: AppTextStyles.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              _PhotoPicker(
                photoBytes: photoBytes,
                isPicking: isPickingPhoto,
                onPick: onPickPhoto,
                onRemove: onRemovePhoto,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        SizedBox(
          height: AppSpacing.minTouchTarget,
          child: FilledButton(
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
  const _SuccessView({required this.onReportAnother});

  final VoidCallback onReportAnother;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.check_circle_outline,
              color: AppColors.success,
              size: 64,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Hazard Reported', style: AppTextStyles.headlineMedium),
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
                child: const Text('Report Another Hazard'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
