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
import '../domain/video_source.dart';
import 'knowledge_check_questions_screen.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/mobile_title.dart';

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
/// Video items are checked against [VideoSource]: the form offers "Upload a
/// JVA video" or "Link to an external video" (YouTube, Vimeo or a direct
/// HTTPS video file only), and each card shows its source or "Link problem".
///
/// Creating and editing go through [showSafetyLearningForm], which saves
/// from inside the form: a failed save keeps the form open with its input.
class SafetyLearningLibraryScreen extends StatefulWidget {
  const SafetyLearningLibraryScreen({
    super.key,
    this.organizationId,
    this.repository,
    this.adminService,
    this.organizationRepository,
    this.storageService,
    this.storageBucket,
  });

  /// The Storage bucket used to recognise JVA videos. Defaults to the
  /// running Firebase app's configured bucket.
  final String? storageBucket;

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
  SafetyLearningRepository? _repository;
  String? _selectedOrganizationId;
  int _loadAttempt = 0;

  /// True while a form or the questions screen is open — stops a double tap
  /// from pushing it twice.
  bool _navigating = false;
  late final String? _storageBucket =
      widget.storageBucket ??
      (widget.storageService ?? StorageService()).bucket;

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

  Future<void> _guarded(Future<void> Function() open) async {
    if (_navigating) return;
    _navigating = true;
    try {
      await open();
    } finally {
      _navigating = false;
    }
  }

  Future<void> _openForm(String organizationId, {SafetyLearning? existing}) =>
      _guarded(
        () => showSafetyLearningForm(
          context,
          organizationId: organizationId,
          existing: existing,
          adminService: widget.adminService,
          storageService: widget.storageService,
          storageBucket: _storageBucket,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final organizationId =
        widget.organizationId ??
        sessionController.activeOrganizationId ??
        (isPlatformAdministrator ? _selectedOrganizationId : null);
    // Admin-only: the full Safety Learning library (every learning type) is
    // a platform-level, company-wide responsibility (PROJECT_CONTEXT.md §4,
    // §12). Site Managers manage VIDEO items from Safety Videos instead.
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
      streamKey: (_repositoryFor(organizationId), _loadAttempt),
      stream: () =>
          _repositoryFor(organizationId).watchAll().handleError((Object error) {
            debugPrint('Safety Learning library: could not load items: $error');
            throw error;
          }),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <SafetyLearning>[];
        final failed = snapshot.hasError;
        final isLoading = !failed && snapshot.data == null;

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
                  onPressed: () => _openForm(organizationId),
                  icon: const Icon(Icons.add),
                  label: const Text('New Learning Item'),
                ),
              ),
            ),
            if (failed) ...[
              const SizedBox(height: AppSpacing.md),
              const AuthErrorBanner(
                message: 'Could not load safety learning. Please try again.',
              ),
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, AppSpacing.minTouchTarget),
                  ),
                  onPressed: () => setState(() => _loadAttempt++),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            if (isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!isLoading && !failed && items.isEmpty)
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
                videoSource: videoSourceFor(
                  type: item.type,
                  reference: item.contentReference,
                  organizationId: organizationId,
                  storageBucket: _storageBucket,
                ),
                onEdit: () => _openForm(organizationId, existing: item),
                onManageQuestions: () => _guarded(
                  () => Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute<void>(
                      builder: (_) => KnowledgeCheckQuestionsScreen(
                        organizationId: organizationId,
                        learning: item,
                        adminService: widget.adminService,
                      ),
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

/// Opens the create (no [existing]) or edit form for a learning item and
/// saves it from inside the form, so a failed save keeps the form — and
/// everything typed into it — open with the error shown. Returns true once
/// saved; false when cancelled.
///
/// [videoOnly] locks the type to Video (Safety Videos' Add/Edit, and the
/// only kind a Site Manager may author — `createSafetyLearning`/
/// `updateSafetyLearning` enforce that server-side regardless).
Future<bool> showSafetyLearningForm(
  BuildContext context, {
  required String organizationId,
  SafetyLearning? existing,
  bool videoOnly = false,
  SafetyLearningAdminService? adminService,
  StorageService? storageService,
  String? storageBucket,
}) async {
  final service = adminService ?? SafetyLearningAdminService();
  Future<void> submit(_SafetyLearningFormResult result) async {
    if (existing == null) {
      await service.createSafetyLearning(
        organizationId: organizationId,
        title: result.title,
        type: result.type,
        contentReference: result.contentReference,
        description: result.description,
        status: result.status,
        minimumWatchSeconds: result.minimumWatchSeconds,
        passingScorePercent: result.passingScorePercent,
      );
    } else {
      await service.updateSafetyLearning(
        organizationId,
        existing.id,
        title: result.title,
        type: result.type,
        contentReference: result.contentReference,
        description: result.description,
        status: result.status,
        minimumWatchSeconds: result.minimumWatchSeconds,
        passingScorePercent: result.passingScorePercent,
      );
    }
  }

  final saved = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _SafetyLearningFormDialog(
        organizationId: organizationId,
        existing: existing,
        initialType: videoOnly ? SafetyLearningType.video : null,
        videoOnly: videoOnly,
        storageService: storageService,
        storageBucket: storageBucket,
        onSubmit: submit,
        adminService: service,
      ),
    ),
  );
  return saved ?? false;
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
    required this.videoSource,
    required this.onEdit,
    required this.onManageQuestions,
  });

  final SafetyLearning learning;

  /// Null unless [learning] is a video.
  final VideoSource? videoSource;
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
            if (videoSource case final source?) ...[
              const SizedBox(height: AppSpacing.xs),
              _VideoSourcePreview(source: source),
            ],
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
    required this.onSubmit,
    this.existing,
    this.initialType,
    required this.adminService,
    this.videoOnly = false,
    this.storageService,
    this.storageBucket,
  });

  final String organizationId;
  final SafetyLearning? existing;

  /// Publishes uploads into the library folder, and backs the quiz screen.
  final SafetyLearningAdminService adminService;

  /// Saves the form. The form stays open (with its input and the error)
  /// when this throws, and closes with `true` when it completes.
  final Future<void> Function(_SafetyLearningFormResult result) onSubmit;

  /// The type a new item starts as (Document when null).
  final SafetyLearningType? initialType;

  /// Locks the type to Video and hides the type choice.
  final bool videoOnly;

  /// Injected in tests.
  final StorageService? storageService;

  /// Recognises this organization's own uploads as JVA videos.
  final String? storageBucket;

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
  late SafetyLearningType _type = widget.videoOnly
      ? SafetyLearningType.video
      : widget.existing?.type ??
            widget.initialType ??
            SafetyLearningType.document;
  late OrganizationRecordStatus _status =
      widget.existing?.status ?? OrganizationRecordStatus.active;
  bool _isUploading = false;
  String? _uploadError;
  bool _isSaving = false;
  String? _saveError;

  /// Every editable value, to tell whether anything changed since opening.
  String get _snapshot => [
    _titleController.text,
    _contentReferenceController.text,
    _descriptionController.text,
    _minimumWatchSecondsController.text,
    _passingScorePercentController.text,
    _type.id,
    _status.id,
  ].join('|');
  late final String _initialSnapshot = _snapshot;

  bool get _isDirty => _snapshot != _initialSnapshot;

  /// Asks before leaving with unsaved changes; true to leave.
  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your changes to this item have not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  /// For a video: upload to JVA Safety, or link elsewhere. Not stored — the
  /// link itself says which it is. An existing external link opens on Link.
  late _VideoEntryMode _videoMode =
      widget.existing != null &&
          !_sourceOf(widget.existing!.contentReference).isJva
      ? _VideoEntryMode.link
      : _VideoEntryMode.upload;

  VideoSource _sourceOf(String reference) => VideoSource.classify(
    reference,
    organizationId: widget.organizationId,
    storageBucket: widget.storageBucket,
  );

  /// True when [reference] is this existing video's own saved link, left
  /// unchanged. Such a link is not re-checked, so an older video whose link
  /// no longer passes can still be renamed or made inactive; any NEW link
  /// must pass. (A video that is still active with a bad link stays
  /// "Video unavailable" for workers until its link is fixed.)
  bool _isUnchangedExistingVideoLink(String reference) {
    final existing = widget.existing;
    return existing != null &&
        existing.type == SafetyLearningType.video &&
        reference == existing.contentReference.trim();
  }

  @override
  void initState() {
    super.initState();
    _initialSnapshot;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentReferenceController.dispose();
    _descriptionController.dispose();
    _minimumWatchSecondsController.dispose();
    _passingScorePercentController.dispose();
    super.dispose();
  }

  /// Picks a file appropriate to [_type], uploads it to the author's own
  /// staging folder (`learning_uploads/{uid}/{a fresh id}/{fileName}`) and
  /// has `publishLearningUpload` move it into
  /// `organizations/{organizationId}/safety_learning/...` after a
  /// server-side author check — no client may write the library folder
  /// directly (see `storage.rules`). Fills [_contentReferenceController]
  /// with the published download URL. Pasting a URL directly remains
  /// available; this only fills the same field.
  Future<void> _pickAndUploadFile() async {
    if (_isUploading || _isSaving) return;
    setState(() => _uploadError = null);
    try {
      final String fileName;
      final Uint8List bytes;
      if (_type == SafetyLearningType.video) {
        final picked = await ImagePicker().pickVideo(
          source: ImageSource.gallery,
        );
        if (picked == null) return;
        final sizeError = uploadSizeError(await picked.length());
        if (sizeError != null) {
          if (mounted) setState(() => _uploadError = sizeError);
          return;
        }
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
        final sizeError = uploadSizeError(data.length);
        if (sizeError != null) {
          if (mounted) setState(() => _uploadError = sizeError);
          return;
        }
        fileName = picked.name;
        bytes = data;
      }

      // Storage only accepts the library's own file types (see
      // `storage.rules`), so an unrecognised one is refused here, clearly,
      // rather than by a generic upload failure.
      final typeError = uploadTypeError(
        fileName,
        videoOnly: _type == SafetyLearningType.video,
      );
      if (typeError != null) {
        if (mounted) setState(() => _uploadError = typeError);
        return;
      }

      if (!mounted) return;
      final uid = context.read<SessionController>().profile?.uid;
      if (uid == null) {
        setState(() => _uploadError = 'Sign in again to upload a file.');
        return;
      }
      setState(() => _isUploading = true);
      final uploadId = DateTime.now().microsecondsSinceEpoch.toString();
      final ref = _storageService
          .learningUploadRef(uid)
          .child('$uploadId/$fileName');
      // Without an explicit contentType, Firebase Storage defaults every
      // upload to application/octet-stream — most OSes/browsers then refuse
      // to open the resulting URL inline (e.g. a PDF link that does nothing
      // when tapped) rather than falling back to a generic download.
      final contentType = lookupMimeType(fileName);
      await ref.putData(
        bytes,
        contentType != null ? SettableMetadata(contentType: contentType) : null,
      );
      final url = await widget.adminService.publishLearningUpload(
        organizationId: widget.organizationId,
        uploadPath: ref.fullPath,
      );
      if (!mounted) return;
      setState(() => _contentReferenceController.text = url);
    } on Object catch (e) {
      debugPrint('Safety Learning form: upload failed: $e');
      if (!mounted) return;
      setState(
        () => _uploadError =
            'Could not upload the file. Check your '
            'connection and try again.',
      );
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  /// Validates and saves. On failure the form stays open with everything
  /// typed into it and the reason shown; a second tap while saving is
  /// ignored.
  Future<void> _submit() async {
    if (_isSaving || _isUploading) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final description = _descriptionController.text.trim();
    final passingScorePercentText = _passingScorePercentController.text.trim();
    final result = _SafetyLearningFormResult(
      title: _titleController.text.trim(),
      type: _type,
      contentReference: _contentReferenceController.text.trim(),
      description: description.isEmpty ? null : description,
      status: _status,
      minimumWatchSeconds:
          int.tryParse(_minimumWatchSecondsController.text.trim()) ?? 0,
      passingScorePercent: passingScorePercentText.isEmpty
          ? null
          : int.tryParse(passingScorePercentText),
    );
    setState(() {
      _isSaving = true;
      _saveError = null;
    });
    try {
      await widget.onSubmit(result);
      if (mounted) Navigator.of(context).pop(true);
    } on AppException catch (e) {
      debugPrint('Safety Learning form: save failed: ${e.message}');
      if (mounted) setState(() => _saveError = e.message);
    } on Object catch (e) {
      debugPrint('Safety Learning form: save failed: $e');
      if (mounted) {
        setState(
          () => _saveError =
              'Could not save. Check your connection and '
              'try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// The way into this video's quiz. Questions belong to a saved video, so
  /// a new one is saved first. Whether a learner MUST pass it is set per
  /// lesson in Safety Requirements, not here.
  Widget _quizSection() {
    final existing = widget.existing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          existing == null
              ? 'Save the video first, then add its quiz questions with '
                    'Manage Quiz on its card.'
              : 'Add, edit, reorder or remove this video\'s quiz questions. '
                    'Whether passing it is required is set for each '
                    'requirement in Safety Requirements.',
          style: AppTextStyles.bodyMedium,
        ),
        if (existing != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, AppSpacing.minTouchTarget),
              ),
              onPressed: _isSaving
                  ? null
                  : () => Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute<void>(
                        builder: (_) => KnowledgeCheckQuestionsScreen(
                          organizationId: widget.organizationId,
                          learning: existing,
                          adminService: widget.adminService,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.quiz_outlined),
              label: const Text('Manage Quiz'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _uploadButton(String label) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, AppSpacing.minTouchTarget),
      ),
      onPressed: _isUploading ? null : _pickAndUploadFile,
      icon: _isUploading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.upload_file_outlined),
      label: Text(_isUploading ? 'Uploading...' : label),
    );
  }

  /// A video's content: upload to JVA Safety, or link to YouTube, Vimeo or a
  /// direct HTTPS video file. Either way the result is the same single
  /// `contentReference`, checked here against [VideoSource] before saving.
  /// This is a convenience for administrators — the server's own checks are
  /// unchanged and remain the authority on who may save an item.
  List<Widget> _videoContentFields() {
    final reference = _contentReferenceController.text.trim();
    final source = reference.isEmpty ? null : _sourceOf(reference);
    final isUpload = _videoMode == _VideoEntryMode.upload;
    return [
      ChoiceList<_VideoEntryMode>(
        label: 'Where is the video?',
        selected: _videoMode,
        onChanged: (value) {
          if (value != null) setState(() => _videoMode = value);
        },
        items: const [
          ChoiceItem(
            value: _VideoEntryMode.upload,
            title: 'Upload a JVA video',
            subtitle: 'Stored in ALMASAFETY. Best for critical training.',
            color: AppColors.videos,
            icon: Icons.cloud_upload,
          ),
          ChoiceItem(
            value: _VideoEntryMode.link,
            title: 'Link to an external video',
            subtitle: 'YouTube, Vimeo, or a direct .mp4/.webm/.mov file',
            color: AppColors.meetings,
            icon: Icons.link,
          ),
        ],
        allowDeselect: false,
      ),
      const SizedBox(height: AppSpacing.sm),
      if (isUpload) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: _uploadButton(
            reference.isEmpty ? 'Upload a video' : 'Replace video',
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'Up to 25 MB. MP4 (H.264) plays on every phone.',
          style: AppTextStyles.bodyMedium,
        ),
        // Holds the uploaded file's link so the form can validate it; it is
        // filled in by the upload, not typed.
        TextFormField(
          key: const ValueKey('uploaded-video-link'),
          controller: _contentReferenceController,
          readOnly: true,
          maxLines: 1,
          decoration: const InputDecoration(
            labelText: 'Uploaded video',
            helperText: 'Filled in automatically after uploading.',
          ),
          validator: (value) {
            final trimmed = value?.trim() ?? '';
            if (trimmed.isEmpty) return 'Upload a video first.';
            if (_isUnchangedExistingVideoLink(trimmed)) return null;
            if (!_sourceOf(trimmed).isJva) {
              return 'This is not a video uploaded to this organization. '
                  'Upload it again, or choose "Link to an external video".';
            }
            return null;
          },
        ),
      ] else ...[
        TextFormField(
          key: const ValueKey('external-video-link'),
          controller: _contentReferenceController,
          decoration: const InputDecoration(
            labelText: 'Video link',
            helperText:
                'A full https:// link to a YouTube or Vimeo video, or to a '
                '.mp4, .m4v, .webm or .mov file.',
          ),
          keyboardType: TextInputType.url,
          autofillHints: const [],
          onChanged: (_) => setState(() {}),
          validator: (value) {
            final trimmed = value?.trim() ?? '';
            if (trimmed.isEmpty) return 'A video link is required.';
            if (_isUnchangedExistingVideoLink(trimmed)) return null;
            return _sourceOf(trimmed).problem;
          },
        ),
      ],
      // An unusable link is previewed only when it is the item's saved one,
      // so the admin can see why workers get "Video unavailable"; a link
      // being typed shows its problem through the field's own validation.
      if (source != null &&
          (!source.isUnsupported ||
              _isUnchangedExistingVideoLink(reference))) ...[
        const SizedBox(height: AppSpacing.sm),
        _VideoSourcePreview(source: source),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final busy = _isSaving || _isUploading;
    final noun = widget.videoOnly ? 'video' : 'learning item';
    final actions = <Widget>[
      TextButton(
        // Same as back: asks first when there are unsaved changes.
        onPressed: _isSaving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      ElevatedButton(
        onPressed: busy ? null : _submit,
        child: _isSaving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(isEditing ? 'Save' : 'Create'),
      ),
    ];
    // Leaving mid-save would drop the result on the floor, and leaving with
    // unsaved changes asks first; back, the close button and Cancel all go
    // through here.
    return PopScope(
      canPop: !_isSaving && !_isDirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _isSaving) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard() && mounted) navigator.pop(false);
      },
      child: Scaffold(
        appBar: AppBar(title: const MobileTitle('Learning Item')),
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
                        eyebrow: isEditing ? 'Edit $noun' : 'New $noun',
                        title: _titleController.text.trim().isEmpty
                            ? 'Safety Learning'
                            : _titleController.text.trim(),
                        icon: _typeIcon(_type),
                        color: _typeColor(_type),
                        chips: [
                          FeatureChip(
                            icon: _typeIcon(_type),
                            label: _type.label,
                          ),
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
                            if (!widget.videoOnly) ...[
                              const SizedBox(height: AppSpacing.sm),
                              ChoiceList<SafetyLearningType>(
                                label: 'Type',
                                selected: _type,
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _type = value);
                                  }
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
                            if (_type == SafetyLearningType.video)
                              ..._videoContentFields()
                            else ...[
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
                                child: _uploadButton('Upload a file instead'),
                              ),
                            ],
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
                      if (_type == SafetyLearningType.video) ...[
                        FormSection(
                          title: 'Quiz',
                          icon: Icons.quiz,
                          color: AppColors.correctiveActions,
                          child: _quizSection(),
                        ),
                        const SizedBox(height: AppSpacing.md),
                      ],
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Shown right above Save, so it is visible however far the
                // form is scrolled; the form keeps everything typed.
                if (_saveError != null) ...[
                  AuthErrorBanner(message: _saveError!),
                  const SizedBox(height: AppSpacing.sm),
                ],
                Row(
                  children: [
                    for (final (index, action) in actions.indexed) ...[
                      if (index > 0) const SizedBox(width: AppSpacing.sm),
                      Expanded(child: action),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// How a video's content is entered in the form.
enum _VideoEntryMode { upload, link }

/// The warning shown wherever an external video is chosen or listed.
const externalVideoWarning =
    'External videos can be removed by their owner. Prefer a JVA upload for '
    'critical required training.';

/// A video's detected source — "JVA video", "External · YouTube"… — with the
/// external-content warning, or "Link problem" and the reason.
class _VideoSourcePreview extends StatelessWidget {
  const _VideoSourcePreview({required this.source});

  final VideoSource source;

  @override
  Widget build(BuildContext context) {
    final color = source.isUnsupported
        ? AppColors.danger
        : source.isJva
        ? AppColors.videos
        : AppColors.meetings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Source: ', style: AppTextStyles.bodyMedium),
            Flexible(
              child: StatusBadge(label: source.label, color: color),
            ),
          ],
        ),
        if (source.isUnsupported && source.problem != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            source.problem!,
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.danger),
          ),
        ],
        if (source.isExternal) ...[
          const SizedBox(height: AppSpacing.xs),
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppSpacing.sm),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: AppColors.warning,
                ),
                SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    externalVideoWarning,
                    style: AppTextStyles.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
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
