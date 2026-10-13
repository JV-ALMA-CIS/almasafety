import 'dart:typed_data';
import '../../../core/widgets/photo_capture.dart';
import '../../hazards/presentation/report_hazard_screen.dart';
import '../../hazards/domain/hazard_kind.dart';
import '../../../core/widgets/choice_list.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/feature_header.dart';
import '../data/incident_service.dart';
import '../domain/incident_enums.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/presentation/report_site_picker.dart';
import 'incident_style.dart';

/// The worker-facing "Report an Incident" flow — something that ACTUALLY
/// happened. A Site Manager/Admin may report at any site of the
/// organization; a Foreman/Worker at any of their own assigned sites —
/// chosen with [ReportSitePicker] (automatic when there is only one).
/// `createIncident` re-verifies the site server-side.
///
/// Asks only what is needed at the moment of reporting: what kind of thing
/// happened, when, what happened, who was hurt (injury only), what was done
/// straight away, where, and an optional photo. Severity, root cause and
/// corrective actions belong to the reviewer's investigation.
class ReportIncidentScreen extends StatefulWidget {
  const ReportIncidentScreen({
    super.key,
    this.incidentService,
    this.imagePicker,
    this.now,
    this.organizationId,
    this.siteRepository,
  });

  /// The organization to report in — passed by a System Administrator's
  /// [IncidentsScreen], who has no organization of their own. Everyone else
  /// reports in their active organization.
  final String? organizationId;

  /// Injected in tests.
  final SiteRepository? siteRepository;

  /// Injected in tests.
  final IncidentService? incidentService;
  final ImagePicker? imagePicker;

  /// Injected in tests so "when it happened" is deterministic.
  final DateTime Function()? now;

  @override
  State<ReportIncidentScreen> createState() => _ReportIncidentScreenState();
}

class _ReportIncidentScreenState extends State<ReportIncidentScreen> {
  late final IncidentService _service =
      widget.incidentService ?? IncidentService();
  late final ImagePicker _imagePicker = widget.imagePicker ?? ImagePicker();
  late DateTime _occurredAt = _now();

  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _injuredPersonController = TextEditingController();
  final _immediateActionController = TextEditingController();
  final _locationController = TextEditingController();

  IncidentType? _type;
  String? _siteId;
  XFile? _photo;
  Uint8List? _photoBytes;
  bool _isSubmitting = false;
  bool _submitted = false;
  String? _errorMessage;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void dispose() {
    _descriptionController.dispose();
    _injuredPersonController.dispose();
    _immediateActionController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _pickOccurredAt() async {
    final now = _now();
    final date = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
    );
    if (time == null) return;
    var picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (picked.isAfter(now)) picked = now;
    setState(() => _occurredAt = picked);
  }

  Future<void> _pickPhoto() async {
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
      setState(
        () => _errorMessage =
            'Could not capture a photo. You can still submit without one.',
      );
    }
  }

  String? _trimmedOrNull(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : value;
  }

  Future<void> _submit({required String organizationId}) async {
    final type = _type;
    if (!(_formKey.currentState?.validate() ?? false) ||
        type == null ||
        _siteId == null) {
      setState(() => _errorMessage = 'Please fill in the required fields.');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      await _service.reportIncident(
        organizationId: organizationId,
        siteId: _siteId!,
        type: type.id,
        description: _descriptionController.text.trim(),
        occurredAt: _occurredAt,
        location: _trimmedOrNull(_locationController),
        injuredPersonName: type == IncidentType.injury
            ? _trimmedOrNull(_injuredPersonController)
            : null,
        immediateAction: _trimmedOrNull(_immediateActionController),
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

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final organizationId =
        widget.organizationId ?? session.activeOrganizationId;
    final siteIds = reportableSiteIds(
      isPlatformAdministrator:
          session.profile?.isPlatformAdministrator ?? false,
      role: session.activeMembership?.role,
      assignedSiteIds: session.activeMembership?.siteIds ?? const [],
    );

    Widget body;
    if (organizationId == null || (siteIds != null && siteIds.isEmpty)) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Incident reporting is available once you are assigned to a site.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else if (_submitted) {
      body = _SuccessView(onDone: () => Navigator.of(context).maybePop());
    } else {
      body = _buildForm(organizationId: organizationId, siteIds: siteIds);
    }
    return Scaffold(appBar: AppBar(), body: body);
  }

  Widget _buildForm({
    required String organizationId,
    required List<String>? siteIds,
  }) {
    final type = _type;
    final color = type?.color ?? AppColors.stop;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        FeatureHeader(
          title: 'Report an Incident',
          subtitle:
              'Something actually happened. Make the area safe and get help '
              'first — then tell us here.',
          icon: type?.icon ?? Icons.personal_injury,
          color: color,
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppSpacing.sm),
            ),
            child: Text(
              _errorMessage!,
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.danger),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormSection(
                title: 'Site',
                icon: Icons.location_city,
                color: AppColors.projects,
                child: ReportSitePicker(
                  organizationId: organizationId,
                  siteIds: siteIds,
                  selectedSiteId: _siteId,
                  onChanged: (id) => setState(() => _siteId = id),
                  siteRepository: widget.siteRepository,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'What happened?',
                icon: Icons.category,
                color: color,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _NearMissLink(siteId: _siteId),
                    const SizedBox(height: AppSpacing.sm),
                    ChoiceList<IncidentType>(
                      items: [
                        for (final option in IncidentType.values)
                          ChoiceItem(
                            value: option,
                            title: option.label,
                            subtitle: option.hint,
                            badge: option.emoji,
                            color: option.color,
                          ),
                      ],
                      selected: type,
                      onChanged: (value) => setState(() => _type = value),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'When',
                icon: Icons.schedule,
                color: AppColors.meetings,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_formatDateTime(_occurredAt)),
                  trailing: const Text('Change'),
                  onTap: _pickOccurredAt,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'Description',
                icon: Icons.edit_note,
                color: AppColors.meetings,
                child: TextFormField(
                  controller: _descriptionController,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: 'What happened?',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'A description is required.'
                      : null,
                ),
              ),
              if (type == IncidentType.injury) ...[
                const SizedBox(height: AppSpacing.md),
                FormSection(
                  title: 'Who was hurt? (optional)',
                  icon: Icons.person,
                  color: AppColors.stop,
                  child: TextFormField(
                    controller: _injuredPersonController,
                    decoration: const InputDecoration(
                      hintText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'What was done straight away? (optional)',
                icon: Icons.medical_services,
                color: AppColors.success,
                child: TextFormField(
                  controller: _immediateActionController,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'e.g. First aid given, area cordoned off',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'Location (optional)',
                icon: Icons.place,
                color: AppColors.projects,
                child: TextFormField(
                  controller: _locationController,
                  decoration: const InputDecoration(
                    hintText: 'e.g. East wing, 3rd floor',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FormSection(
                title: 'Photo (optional)',
                icon: Icons.photo_camera,
                color: AppColors.analytics,
                child: _photoBytes != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(AppSpacing.sm),
                            child: Image.memory(
                              _photoBytes!,
                              height: 160,
                              fit: BoxFit.cover,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => setState(() {
                              _photo = null;
                              _photoBytes = null;
                            }),
                            icon: const Icon(Icons.close),
                            label: const Text('Remove photo'),
                          ),
                        ],
                      )
                    : SizedBox(
                        height: AppSpacing.minTouchTarget,
                        child: OutlinedButton.icon(
                          onPressed: _pickPhoto,
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('Add Photo'),
                        ),
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
              backgroundColor: color,
              foregroundColor: AppColors.onColor(color),
            ),
            onPressed: _isSubmitting
                ? null
                : () => _submit(organizationId: organizationId),
            child: _isSubmitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Submit Incident'),
          ),
        ),
      ],
    );
  }
}

/// The way to the right form for a near-miss — "a tool fell and narrowly
/// missed someone" is not an incident (nobody hurt, nothing damaged) but a
/// hazard report of kind near-miss. Opens it with near-miss chosen and the
/// same site.
class _NearMissLink extends StatelessWidget {
  const _NearMissLink({required this.siteId});

  final String? siteId;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.learning.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.learning),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => ReportHazardScreen(
              initialKind: HazardKind.nearMiss,
              initialSiteId: siteId,
            ),
          ),
        ),
        child: const Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Text('😮', style: TextStyle(fontSize: 28)),
              SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nobody hurt, nothing damaged?',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      "That's a near-miss (e.g. a tool fell and narrowly "
                      'missed someone) — report it here.',
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: AppColors.learning),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  const _SuccessView({required this.onDone});

  final VoidCallback onDone;

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
            Text('Incident Reported', style: AppTextStyles.headlineMedium),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Thank you. Your supervisor will review it and start an '
              'investigation.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              height: AppSpacing.minTouchTarget,
              child: OutlinedButton(
                onPressed: onDone,
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDateTime(DateTime date) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}
