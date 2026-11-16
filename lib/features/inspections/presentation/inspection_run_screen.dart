import '../../../core/offline/saved_on_phone_note.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/widgets/photo_capture.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/inspection_repository.dart';
import '../data/inspection_service.dart';
import '../domain/inspection.dart';
import 'inspection_style.dart';
import '../../../core/widgets/mobile_title.dart';

/// Carrying out an inspection: every checklist item, grouped by section,
/// answered ✅ OK / ❌ Not OK / N/A with one tap. "Not OK" asks what is
/// wrong (required) and offers a photo. Every answer is saved as you go, so
/// a walk-down can be paused and resumed. Submitting turns each "Not OK"
/// into a deficiency tracked through hazards → corrective actions.
class InspectionRunScreen extends StatefulWidget {
  const InspectionRunScreen({
    super.key,
    required this.organizationId,
    required this.inspectionId,
    required this.repository,
    this.service,
    this.imagePicker,
  });

  final String organizationId;
  final String inspectionId;
  final InspectionRepository repository;

  /// Injected in tests.
  final InspectionService? service;
  final ImagePicker? imagePicker;

  @override
  State<InspectionRunScreen> createState() => _InspectionRunScreenState();
}

/// A local answer, shown immediately while it saves.
class _Answer {
  const _Answer(this.result, this.note, this.photoUrl);

  final InspectionResult? result;
  final String? note;
  final String? photoUrl;
}

class _InspectionRunScreenState extends State<InspectionRunScreen> {
  late final InspectionService _service = widget.service ?? InspectionService();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();
  final Map<String, _Answer> _local = {};
  final Map<String, Timer> _noteTimers = {};
  int _saving = 0;
  bool _isSubmitting = false;
  String? _errorMessage;
  String? _uploadingItemId;

  /// True once an answer had to be kept on this phone for lack of signal.
  bool _savedOffline = false;

  @override
  void dispose() {
    for (final timer in _noteTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  _Answer _answerFor(InspectionItem item) =>
      _local[item.id] ?? _Answer(item.result, item.note, item.photoUrl);

  Future<void> _save(String itemId, _Answer answer) async {
    setState(() {
      _local[itemId] = answer;
      _saving++;
      _errorMessage = null;
    });
    try {
      await _service.recordItem(
        organizationId: widget.organizationId,
        inspectionId: widget.inspectionId,
        itemId: itemId,
        result: answer.result,
        note: answer.note,
        photoUrl: answer.photoUrl,
      );
    } on SavedOfflineException {
      if (mounted) setState(() => _savedOffline = true);
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _saving--);
    }
  }

  void _setResult(InspectionItem item, InspectionResult result) {
    final current = _answerFor(item);
    // Tapping the chosen answer again clears it.
    final next = current.result == result ? null : result;
    _save(
      item.id,
      _Answer(
        next,
        next == InspectionResult.notOk ? current.note : null,
        next == InspectionResult.notOk ? current.photoUrl : null,
      ),
    );
  }

  void _setNote(InspectionItem item, String text) {
    final current = _answerFor(item);
    final note = text.trim().isEmpty ? null : text.trim();
    setState(
      () => _local[item.id] = _Answer(current.result, note, current.photoUrl),
    );
    _noteTimers[item.id]?.cancel();
    _noteTimers[item.id] = Timer(
      const Duration(milliseconds: 700),
      () => _save(item.id, _Answer(current.result, note, current.photoUrl)),
    );
  }

  Future<void> _addPhoto(InspectionItem item) async {
    final photo = await takePhoto(context, picker: _picker);
    if (photo == null || !mounted) return;
    setState(() => _uploadingItemId = item.id);
    try {
      final url = await _service.uploadPhoto(
        organizationId: widget.organizationId,
        inspectionId: widget.inspectionId,
        fileName: photo.name,
        bytes: await photo.readAsBytes(),
      );
      final current = _answerFor(item);
      await _save(item.id, _Answer(current.result, current.note, url));
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _uploadingItemId = null);
    }
  }

  Future<void> _submit(Inspection inspection) async {
    for (final timer in _noteTimers.values) {
      timer.cancel();
    }
    final notOk = inspection.items
        .where((i) => _answerFor(i).result == InspectionResult.notOk)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Submit inspection?'),
        content: Text(
          notOk == 0
              ? 'Everything was OK. The inspection goes to the Safety '
                    'Manager for sign-off.'
              : '$notOk deficiency${notOk == 1 ? '' : 'ies'} will be '
                    'recorded and tracked until fixed. The inspection goes to '
                    'the Safety Manager for sign-off.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep checking'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      // Make sure the last typed notes are saved first.
      for (final item in inspection.items) {
        final local = _local[item.id];
        if (local != null && local.note != item.note) {
          try {
            await _service.recordItem(
              organizationId: widget.organizationId,
              inspectionId: widget.inspectionId,
              itemId: item.id,
              result: local.result,
              note: local.note,
              photoUrl: local.photoUrl,
            );
          } on SavedOfflineException {
            // Kept on this phone; it goes ahead of the submission below.
          }
        }
      }
      try {
        await _service.submit(
          organizationId: widget.organizationId,
          inspectionId: widget.inspectionId,
        );
      } on SavedOfflineException {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            content: const Text(
              'No signal - this inspection is saved on this phone and will '
              'be submitted automatically when the signal comes back.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Inspection')),
      body: LiveStreamBuilder<Inspection?>(
        streamKey: widget.inspectionId,
        stream: () => widget.repository.watchInspection(widget.inspectionId),
        builder: (context, snapshot) {
          final inspection = snapshot.data;
          if (inspection == null) {
            return Center(
              child: snapshot.hasError
                  ? const Text('Could not load this inspection.')
                  : const CircularProgressIndicator(),
            );
          }
          if (inspection.status != InspectionStatus.inProgress) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  'This inspection has been submitted.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return _body(inspection);
        },
      ),
    );
  }

  Widget _body(Inspection inspection) {
    final answers = {
      for (final item in inspection.items) item.id: _answerFor(item),
    };
    final answered = answers.values.where((a) => a.result != null).length;
    final notOk = answers.values
        .where((a) => a.result == InspectionResult.notOk)
        .length;
    final missingNotes = answers.values
        .where(
          (a) =>
              a.result == InspectionResult.notOk &&
              (a.note == null || a.note!.isEmpty),
        )
        .length;
    final total = inspection.items.length;
    final canSubmit = answered == total && missingNotes == 0 && !_isSubmitting;

    final sections = <String, List<InspectionItem>>{};
    for (final item in inspection.items) {
      (sections[item.section] ??= []).add(item);
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            key: const PageStorageKey('inspection-run'),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              FeatureHeader(
                eyebrow: inspection.kind.label,
                title: inspection.templateName,
                subtitle:
                    '${inspection.siteName ?? 'Site'} · tap ✅ OK, ❌ Not OK '
                    'or N/A for each item.',
                icon: inspection.kind.icon,
                color: AppColors.inspections,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.md),
                AuthErrorBanner(message: _errorMessage!),
              ],
              if (_savedOffline) ...[
                const SizedBox(height: AppSpacing.md),
                const SavedOnPhoneNote(
                  text:
                      'No signal - your answers are saved on this phone and '
                      'will be sent when the signal comes back. Keep going. '
                      'Photos need signal.',
                ),
              ],
              for (final entry in sections.entries) ...[
                const SizedBox(height: AppSpacing.md),
                FeatureSectionTitle(
                  title: entry.key,
                  icon: Icons.checklist,
                  color: AppColors.inspections,
                  count: entry.value.length,
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final item in entry.value) ...[
                  _ItemCard(
                    item: item,
                    answer: answers[item.id]!,
                    isUploading: _uploadingItemId == item.id,
                    onResult: (result) => _setResult(item, result),
                    onNote: (text) => _setNote(item, text),
                    onPhoto: () => _addPhoto(item),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: const [
                BoxShadow(blurRadius: 8, color: Color(0x22000000)),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$answered / $total answered',
                        style: AppTextStyles.bodyLarge.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        missingNotes > 0
                            ? '$missingNotes Not OK need a note'
                            : notOk > 0
                            ? '$notOk Not OK'
                            : _saving > 0
                            ? 'Saving…'
                            : 'Saved',
                        style: AppTextStyles.bodyMedium,
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.inspections,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, AppSpacing.minTouchTarget),
                  ),
                  onPressed: canSubmit ? () => _submit(inspection) : null,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  label: const Text('Submit'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ItemCard extends StatefulWidget {
  const _ItemCard({
    required this.item,
    required this.answer,
    required this.isUploading,
    required this.onResult,
    required this.onNote,
    required this.onPhoto,
  });

  final InspectionItem item;
  final _Answer answer;
  final bool isUploading;
  final ValueChanged<InspectionResult> onResult;
  final ValueChanged<String> onNote;
  final VoidCallback onPhoto;

  @override
  State<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<_ItemCard> {
  late final TextEditingController _note = TextEditingController(
    text: widget.answer.note ?? '',
  );

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.answer.result;
    final color = result?.color ?? Theme.of(context).colorScheme.outline;
    return Material(
      color: result == null
          ? Theme.of(context).colorScheme.surface
          : result.color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: color.withValues(alpha: result == null ? 0.4 : 1),
          width: result == null ? 1 : 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm + 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.item.text, style: AppTextStyles.bodyLarge),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                for (final option in InspectionResult.values) ...[
                  if (option != InspectionResult.values.first)
                    const SizedBox(width: AppSpacing.xs + 2),
                  Expanded(
                    child: _ResultButton(
                      result: option,
                      selected: result == option,
                      onTap: () => widget.onResult(option),
                    ),
                  ),
                ],
              ],
            ),
            if (result == InspectionResult.notOk) ...[
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _note,
                minLines: 1,
                maxLines: 3,
                onChanged: widget.onNote,
                decoration: InputDecoration(
                  labelText: 'What is wrong? (required)',
                  hintText: 'e.g. Two workers not tied off on block 3',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: (widget.answer.note ?? '').isEmpty
                      ? 'Needed to submit'
                      : null,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  if (widget.answer.photoUrl != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        widget.answer.photoUrl!,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            const Icon(Icons.image),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  OutlinedButton.icon(
                    onPressed: widget.isUploading ? null : widget.onPhoto,
                    icon: widget.isUploading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_camera_outlined),
                    label: Text(
                      widget.answer.photoUrl == null
                          ? 'Add photo'
                          : 'Replace photo',
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultButton extends StatelessWidget {
  const _ResultButton({
    required this.result,
    required this.selected,
    required this.onTap,
  });

  final InspectionResult result;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = result.color;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? color : color.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: color, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            height: AppSpacing.minTouchTarget,
            child: Center(
              child: Text(
                '${result.emoji} ${result.label}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: selected
                      ? AppColors.onColor(color)
                      : AppColors.readable(color, Theme.of(context).brightness),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
