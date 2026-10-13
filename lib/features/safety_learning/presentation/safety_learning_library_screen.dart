import 'dart:typed_data';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/widgets/choice_list.dart';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart' show SettableMetadata;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../data/safety_learning_admin_service.dart';
import '../data/safety_learning_repository.dart';
import '../domain/safety_learning.dart';
import '../domain/safety_learning_type.dart';
import 'knowledge_check_questions_screen.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/color_choice_chips.dart';

/// The Safety Learning library: lists an organization's learning content and
/// lets an authorized administrator create or edit an item.
///
/// Follows [ActivitiesScreen]'s pattern exactly, including its `canManage`
/// gate — a System Administrator OR an Organization Administrator of the
/// matching organization, which is precisely what
/// `createSafetyLearning`/`updateSafetyLearning` authorize server-side via
/// `requireOrganizationScopedAdmin`. The status dropdown doubles as
/// activate/deactivate; there is no delete, matching every other record type
/// here (an inactive item is retained so historical learning records keep
/// referring to something real).
///
/// Unlike [ActivitiesScreen], this screen resolves its organization from the
/// signed-in user's own profile rather than an `extra`-threaded
/// [Organization]: it is reached directly from [AdministrationScreen] rather
/// than by drilling down through Organization -> Project -> Site. A System
/// Administrator belongs to no organization, so they must arrive with one
/// supplied — see [organizationId].
class SafetyLearningLibraryScreen extends StatefulWidget {
  const SafetyLearningLibraryScreen({
    super.key,
    this.organizationId,
    this.repository,
    this.adminService,
    this.organizationRepository,
    this.storageService,
  });

  /// The organization whose library to show. When null, falls back to the
  /// signed-in user's own `organizationId` — the Organization Administrator
  /// case. A System Administrator has no organization of their own, so when
  /// neither this nor a membership resolves one, an [OrganizationScopeSelector]
  /// lets them pick one instead of showing a false "no permission" message.
  final String? organizationId;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the resolved organization.
  final SafetyLearningRepository? repository;
  final SafetyLearningAdminService? adminService;

  /// Injected in tests. Backs [OrganizationScopeSelector] for a System
  /// Administrator, who has no organization of their own.
  final OrganizationRepository? organizationRepository;

  /// Injected in tests. Threaded through to the create/edit form dialog's
  /// own cover-image upload.
  final StorageService? storageService;

  @override
  State<SafetyLearningLibraryScreen> createState() =>
      _SafetyLearningLibraryScreenState();
}

class _SafetyLearningLibraryScreenState
    extends State<SafetyLearningLibraryScreen> {
  late final SafetyLearningAdminService _adminService =
      widget.adminService ?? SafetyLearningAdminService();

  SafetyLearningRepository? _repository;
  String? _errorMessage;
  bool _isSaving = false;
  String? _selectedOrganizationId;

  /// Builds (once per organization) the repository this screen streams from.
  /// Constructed lazily in [build] rather than in a field initializer because
  /// the organization is not known until the session profile is read.
  SafetyLearningRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.repository ??
        SafetyLearningRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _repository = created;
    return created;
  }

  Future<void> _openCreateDialog(String organizationId) async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<_SafetyLearningFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => _SafetyLearningFormDialog(
              organizationId: organizationId,
              storageService: widget.storageService,
            ),
          ),
        );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.createSafetyLearning(
        organizationId: organizationId,
        title: result.title,
        type: result.type,
        contentReference: result.contentReference,
        description: result.description,
        status: result.status,
        minimumWatchSeconds: result.minimumWatchSeconds,
        passingScorePercent: result.passingScorePercent,
      ),
    );
  }

  Future<void> _openEditDialog(
    String organizationId,
    SafetyLearning learning,
  ) async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<_SafetyLearningFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => _SafetyLearningFormDialog(
              organizationId: organizationId,
              existing: learning,
              storageService: widget.storageService,
            ),
          ),
        );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.updateSafetyLearning(
        organizationId,
        learning.id,
        title: result.title,
        type: result.type,
        contentReference: result.contentReference,
        description: result.description,
        status: result.status,
        minimumWatchSeconds: result.minimumWatchSeconds,
        passingScorePercent: result.passingScorePercent,
      ),
    );
  }

  Future<void> _save(Future<void> Function() action) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await action();
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
    final organizationId =
        widget.organizationId ??
        sessionController.activeOrganizationId ??
        (isPlatformAdministrator ? _selectedOrganizationId : null);
    // Admin-only: the Safety Learning library is a platform-level,
    // company-wide responsibility deliberately not delegated to Site
    // Managers (PROJECT_CONTEXT.md §4, §12).
    final canManage = profile?.canManageSafetyLearningLibrary == true;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to manage safety learning.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (organizationId == null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: OrganizationScopeSelector(
          selectedOrganizationId: _selectedOrganizationId,
          onChanged: (value) => setState(() => _selectedOrganizationId = value),
          repository: widget.organizationRepository,
        ),
      );
    }

    return LiveStreamBuilder<List<SafetyLearning>>(
      streamKey: _repositoryFor(organizationId),
      stream: () => _repositoryFor(organizationId).watchAll(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <SafetyLearning>[];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final streamError = snapshot.hasError
            ? 'Could not load safety learning. Please try again.'
            : null;

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            FeatureHeader(
              title: 'Safety Learning',
              subtitle:
                  'Videos, courses, guides, documents and knowledge checks available to this organization.',
              icon: Icons.school,
              color: AppColors.learning,
              chips: [
                for (final type in SafetyLearningType.values)
                  FeatureChip(
                    icon: _typeIcon(type),
                    label:
                        '${items.where((i) => i.type == type).length} ${type.label.toLowerCase()}',
                  ),
              ],
              footer: Tooltip(
                message: 'Add learning item',
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.learning,
                    minimumSize: const Size(0, AppSpacing.minTouchTarget),
                  ),
                  onPressed: _isSaving
                      ? null
                      : () => _openCreateDialog(organizationId),
                  icon: const Icon(Icons.add),
                  label: const Text('New Learning Item'),
                ),
              ),
            ),

            if ((_errorMessage ?? streamError) != null) ...[
              const SizedBox(height: AppSpacing.md),
              AuthErrorBanner(message: _errorMessage ?? streamError!),
            ],
            const SizedBox(height: AppSpacing.md),
            if (isLoading && items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!isLoading && items.isEmpty && streamError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Text(
                  'No safety learning items yet.',
                  style: AppTextStyles.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            for (final item in items) ...[
              _SafetyLearningCard(
                learning: item,
                onEdit: () => _openEditDialog(organizationId, item),
                onManageQuestions: () =>
                    Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute<void>(
                        builder: (_) => KnowledgeCheckQuestionsScreen(
                          organizationId: organizationId,
                          learning: item,
                          adminService: widget.adminService,
                        ),
                      ),
                    ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        );
      },
    );
  }
}

/// Each lesson type's color and icon — the same as the lesson screen.
Color _typeColor(SafetyLearningType type) => switch (type) {
  SafetyLearningType.video => AppColors.videos,
  SafetyLearningType.course => AppColors.learning,
  SafetyLearningType.visualGuide => AppColors.analytics,
  SafetyLearningType.document => AppColors.meetings,
  SafetyLearningType.knowledgeCheck => AppColors.correctiveActions,
};

IconData _typeIcon(SafetyLearningType type) => switch (type) {
  SafetyLearningType.video => Icons.play_circle_fill,
  SafetyLearningType.course => Icons.school,
  SafetyLearningType.visualGuide => Icons.image,
  SafetyLearningType.document => Icons.description,
  SafetyLearningType.knowledgeCheck => Icons.quiz,
};

class _SafetyLearningCard extends StatelessWidget {
  const _SafetyLearningCard({
    required this.learning,
    required this.onEdit,
    required this.onManageQuestions,
  });

  final SafetyLearning learning;
  final VoidCallback onEdit;
  final VoidCallback onManageQuestions;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: (_typeColor(learning.type)).withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AccentIconBadge(
                  color: _typeColor(learning.type),
                  icon: _typeIcon(learning.type),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(learning.title, style: AppTextStyles.titleLarge),
                ),
                _StatusChip(status: learning.status),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(
              icon: Icons.category_outlined,
              value: learning.type.label,
            ),
            _DetailRow(
              icon: Icons.link_outlined,
              value: learning.contentReference,
            ),
            if (learning.description != null)
              _DetailRow(
                icon: Icons.description_outlined,
                value: learning.description!,
              ),
            if (learning.minimumWatchSeconds != null &&
                learning.minimumWatchSeconds! > 0)
              _DetailRow(
                icon: Icons.timer_outlined,
                value:
                    'Minimum engagement time: '
                    '${learning.minimumWatchSeconds} seconds',
              ),
            if (learning.passingScorePercent != null)
              _DetailRow(
                icon: Icons.quiz_outlined,
                value:
                    'Knowledge check passing score: '
                    '${learning.passingScorePercent}%',
              ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                    minWidth: 140,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit'),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                    minWidth: 140,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: onManageQuestions,
                    icon: const Icon(Icons.quiz_outlined),
                    label: const Text('Manage Questions'),
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

class _SafetyLearningFormResult {
  const _SafetyLearningFormResult({
    required this.title,
    required this.type,
    required this.contentReference,
    required this.status,
    this.description,
    this.minimumWatchSeconds = 0,
    this.passingScorePercent,
  });

  final String title;
  final SafetyLearningType type;
  final String contentReference;
  final String? description;
  final OrganizationRecordStatus status;

  /// Meaningful for any [SafetyLearningType]; 0 means "no minimum" — see
  /// `SafetyLearning.minimumWatchSeconds`'s doc comment.
  final int minimumWatchSeconds;

  /// The knowledge-check passing threshold (0-100), or null to leave it
  /// unset — see `SafetyLearning.passingScorePercent`'s doc comment. Only
  /// takes effect once at least one question is configured (via "Manage
  /// Questions" on the item's own card).
  final int? passingScorePercent;
}

class _SafetyLearningFormDialog extends StatefulWidget {
  const _SafetyLearningFormDialog({
    required this.organizationId,
    this.existing,
    this.storageService,
  });

  final String organizationId;
  final SafetyLearning? existing;

  /// Injected in tests.
  final StorageService? storageService;

  @override
  State<_SafetyLearningFormDialog> createState() =>
      _SafetyLearningFormDialogState();
}

class _SafetyLearningFormDialogState extends State<_SafetyLearningFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final StorageService _storageService =
      widget.storageService ?? StorageService();
  late final _titleController = TextEditingController(
    text: widget.existing?.title,
  );
  late final _contentReferenceController = TextEditingController(
    text: widget.existing?.contentReference,
  );
  late final _descriptionController = TextEditingController(
    text: widget.existing?.description,
  );
  late final _minimumWatchSecondsController = TextEditingController(
    text: (widget.existing?.minimumWatchSeconds ?? 0) > 0
        ? widget.existing!.minimumWatchSeconds.toString()
        : '',
  );
  late final _passingScorePercentController = TextEditingController(
    text: widget.existing?.passingScorePercent?.toString() ?? '',
  );
  late SafetyLearningType _type =
      widget.existing?.type ?? SafetyLearningType.document;
  late OrganizationRecordStatus _status =
      widget.existing?.status ?? OrganizationRecordStatus.active;
  bool _isUploading = false;
  String? _uploadError;

  @override
  void dispose() {
    _titleController.dispose();
    _contentReferenceController.dispose();
    _descriptionController.dispose();
    _minimumWatchSecondsController.dispose();
    _passingScorePercentController.dispose();
    super.dispose();
  }

  /// Picks a file appropriate to [_type] and uploads it to
  /// `organizations/{organizationId}/safety_learning/{a fresh id}/{fileName}`
  /// in Cloud Storage, then fills [_contentReferenceController] with the
  /// resulting download URL — mirroring [StorageService]'s existing
  /// hazard-photo/meeting-evidence upload pattern (pick bytes, `putData`,
  /// `getDownloadURL`). Pasting a URL directly remains available and is left
  /// untouched by this — this is purely a convenience that fills the same
  /// field.
  Future<void> _pickAndUploadFile() async {
    setState(() => _uploadError = null);
    try {
      final String fileName;
      final Uint8List bytes;
      if (_type == SafetyLearningType.video) {
        final picked = await ImagePicker().pickVideo(
          source: ImageSource.gallery,
        );
        if (picked == null) return;
        fileName = picked.name;
        bytes = await picked.readAsBytes();
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const [
            'pdf',
            'doc',
            'docx',
            'ppt',
            'pptx',
            'xls',
            'xlsx',
            'png',
            'jpg',
            'jpeg',
            'mp4',
            'mov',
          ],
          withData: true,
        );
        final picked = result?.files.singleOrNull;
        final data = picked?.bytes;
        if (picked == null || data == null) return;
        fileName = picked.name;
        bytes = data;
      }

      setState(() => _isUploading = true);
      final itemId = DateTime.now().microsecondsSinceEpoch.toString();
      final ref = _storageService
          .orgRef(widget.organizationId)
          .child('safety_learning/$itemId/$fileName');
      // Without an explicit contentType, Firebase Storage defaults every
      // upload to application/octet-stream — most OSes/browsers then refuse
      // to open the resulting URL inline (e.g. a PDF link that does nothing
      // when tapped) rather than falling back to a generic download.
      final contentType = lookupMimeType(fileName);
      await ref.putData(
        bytes,
        contentType != null ? SettableMetadata(contentType: contentType) : null,
      );
      final url = await ref.getDownloadURL();
      if (!mounted) return;
      setState(() => _contentReferenceController.text = url);
    } on Object catch (_) {
      if (!mounted) return;
      setState(
        () => _uploadError = 'Could not upload the file. Please try again.',
      );
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final actions = <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      ElevatedButton(
        onPressed: () {
          if (!(_formKey.currentState?.validate() ?? false)) return;
          final description = _descriptionController.text.trim();
          final minimumWatchSeconds =
              int.tryParse(_minimumWatchSecondsController.text.trim()) ?? 0;
          final passingScorePercentText = _passingScorePercentController.text
              .trim();
          Navigator.of(context).pop(
            _SafetyLearningFormResult(
              title: _titleController.text.trim(),
              type: _type,
              contentReference: _contentReferenceController.text.trim(),
              description: description.isEmpty ? null : description,
              status: _status,
              minimumWatchSeconds: minimumWatchSeconds,
              passingScorePercent: passingScorePercentText.isEmpty
                  ? null
                  : int.tryParse(passingScorePercentText),
            ),
          );
        },
        child: Text(isEditing ? 'Save' : 'Create'),
      ),
    ];
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FeatureHeader(
                      eyebrow: isEditing
                          ? 'Edit learning item'
                          : 'New learning item',
                      title: _titleController.text.trim().isEmpty
                          ? 'Safety Learning'
                          : _titleController.text.trim(),
                      icon: _typeIcon(_type),
                      color: _typeColor(_type),
                      chips: [
                        FeatureChip(icon: _typeIcon(_type), label: _type.label),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    FormSection(
                      title: 'What it is',
                      icon: Icons.edit_note,
                      color: _typeColor(_type),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _titleController,
                            decoration: const InputDecoration(
                              labelText: 'Title',
                            ),
                            onChanged: (_) => setState(() {}),
                            autofillHints: const [],
                            validator: (value) =>
                                (value == null || value.trim().isEmpty)
                                ? 'A title is required.'
                                : null,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          ChoiceList<SafetyLearningType>(
                            label: 'Type',
                            selected: _type,
                            onChanged: (value) {
                              if (value != null) setState(() => _type = value);
                            },
                            items: [
                              for (final type in SafetyLearningType.values)
                                ChoiceItem(
                                  value: type,
                                  title: type.label,
                                  color: _typeColor(type),
                                  icon: _typeIcon(type),
                                ),
                            ],
                            allowDeselect: false,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const SizedBox(height: AppSpacing.sm),
                    FormSection(
                      title: 'Lesson content',
                      icon: _typeIcon(_type),
                      color: AppColors.meetings,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _contentReferenceController,
                            decoration: const InputDecoration(
                              labelText: 'Content reference',
                              helperText: 'A URL, or upload a file below.',
                            ),
                            autofillHints: const [],
                            validator: (value) =>
                                (value == null || value.trim().isEmpty)
                                ? 'A content reference is required.'
                                : null,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              onPressed: _isUploading
                                  ? null
                                  : _pickAndUploadFile,
                              icon: _isUploading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.upload_file_outlined),
                              label: Text(
                                _isUploading
                                    ? 'Uploading...'
                                    : 'Upload a file instead',
                              ),
                            ),
                          ),
                          if (_uploadError != null) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              _uploadError!,
                              style: AppTextStyles.bodyMedium.copyWith(
                                color: AppColors.danger,
                              ),
                            ),
                          ],
                          const SizedBox(height: AppSpacing.sm),
                          TextFormField(
                            controller: _descriptionController,
                            decoration: const InputDecoration(
                              labelText: 'Description',
                            ),
                            autofillHints: const [],
                            maxLines: 2,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const SizedBox(height: AppSpacing.sm),
                    FormSection(
                      title: 'Completion rules',
                      icon: Icons.timer,
                      color: AppColors.correctiveActions,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _minimumWatchSecondsController,
                            decoration: const InputDecoration(
                              labelText: 'Minimum engagement time (seconds)',
                              helperText:
                                  'Leave blank for no minimum. The worker '
                                  'must keep this item open at least this long '
                                  'before completing it — this confirms elapsed '
                                  'time, not that they actually watched or read '
                                  'it. Recommended for any document, course, guide '
                                  'or video without its own knowledge check.',
                            ),
                            keyboardType: TextInputType.number,
                            validator: (value) {
                              final trimmed = value?.trim() ?? '';
                              if (trimmed.isEmpty) return null;
                              final parsed = int.tryParse(trimmed);
                              if (parsed == null || parsed < 0) {
                                return 'Enter a non-negative whole number.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          TextFormField(
                            controller: _passingScorePercentController,
                            decoration: const InputDecoration(
                              labelText: 'Knowledge check passing score (%)',
                              helperText:
                                  'Leave blank to leave unset. Only applies '
                                  'once questions are added via "Manage Questions" — '
                                  'an item with no questions has no knowledge-check '
                                  'gate regardless of this value.',
                            ),
                            keyboardType: TextInputType.number,
                            validator: (value) {
                              final trimmed = value?.trim() ?? '';
                              if (trimmed.isEmpty) return null;
                              final parsed = int.tryParse(trimmed);
                              if (parsed == null ||
                                  parsed < 0 ||
                                  parsed > 100) {
                                return 'Enter a whole number between 0 and 100.';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const SizedBox(height: AppSpacing.sm),
                    ChoiceList<OrganizationRecordStatus>(
                      label: 'Status',
                      selected: _status,
                      onChanged: (value) {
                        if (value != null) setState(() => _status = value);
                      },
                      items: const [
                        ChoiceItem(
                          value: OrganizationRecordStatus.active,
                          title: 'Active',
                          color: AppColors.success,
                          icon: Icons.check_circle,
                        ),
                        ChoiceItem(
                          value: OrganizationRecordStatus.inactive,
                          title: 'Inactive',
                          color: AppColors.textSecondary,
                          icon: Icons.pause_circle,
                        ),
                      ],
                      allowDeselect: false,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              for (final (index, action) in actions.indexed) ...[
                if (index > 0) const SizedBox(width: AppSpacing.sm),
                Expanded(child: action),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final OrganizationRecordStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      OrganizationRecordStatus.active => AppColors.success,
      OrganizationRecordStatus.inactive => AppColors.textSecondary,
    };
    return StatusBadge(label: status.label, color: color);
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.primaryBright),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}
