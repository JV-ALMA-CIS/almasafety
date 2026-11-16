import 'dart:typed_data';
import '../../../core/widgets/photo_capture.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/feature_header.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/corrective_action_service.dart';
import '../domain/corrective_action.dart';
import '../domain/corrective_action_evidence.dart';
import '../../../core/widgets/mobile_title.dart';

/// Where the assignee finishes their corrective action: says what was
/// done, attaches the evidence the action asks for, and submits it for a
/// reviewer to verify (`submitCorrectiveActionForReview`).
///
/// Shows exactly what is required up front — "Photo of the finished work",
/// "Written confirmation", the creator's own instructions, and why it was
/// sent back if it was — and won't submit until those are there. The
/// server enforces the same rule; this only saves a wasted round trip.
class SubmitCorrectiveActionScreen extends StatefulWidget {
  const SubmitCorrectiveActionScreen({
    super.key,
    required this.organizationId,
    required this.action,
    this.service,
    this.imagePicker,
  });

  final String organizationId;
  final CorrectiveAction action;

  /// Injected in tests.
  final CorrectiveActionService? service;
  final ImagePicker? imagePicker;

  @override
  State<SubmitCorrectiveActionScreen> createState() =>
      _SubmitCorrectiveActionScreenState();
}

class _PendingPhoto {
  _PendingPhoto(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

class _SubmitCorrectiveActionScreenState
    extends State<SubmitCorrectiveActionScreen> {
  static const _maxPhotos = 5;

  late final CorrectiveActionService _service =
      widget.service ?? CorrectiveActionService();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();
  final _noteController = TextEditingController();
  final List<_PendingPhoto> _photos = [];

  bool _isSubmitting = false;
  String? _errorMessage;

  List<CorrectiveActionEvidenceKind> get _required =>
      widget.action.requiredEvidence;
  bool get _needsPhoto =>
      _required.contains(CorrectiveActionEvidenceKind.photo);
  bool get _needsConfirmation =>
      _required.contains(CorrectiveActionEvidenceKind.confirmation);

  bool get _photoDone => !_needsPhoto || _photos.isNotEmpty;
  bool get _confirmationDone =>
      !_needsConfirmation || _noteController.text.trim().isNotEmpty;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _addPhoto(ImageSource source) async {
    try {
      final photo = source == ImageSource.camera
          ? await takePhoto(context, picker: _picker)
          : await _picker.pickImage(
              source: source,
              maxWidth: 1600,
              imageQuality: 85,
            );
      if (photo == null) return;
      final bytes = await photo.readAsBytes();
      if (!mounted) return;
      setState(() => _photos.add(_PendingPhoto(photo.name, bytes)));
    } on Object catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Could not get that photo. Try again.');
    }
  }

  Future<void> _submit() async {
    if (!_photoDone || !_confirmationDone) {
      setState(
        () => _errorMessage = 'Please add the evidence this action asks for.',
      );
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final uploaded = <EvidencePhoto>[];
      for (final photo in _photos) {
        uploaded.add(
          await _service.uploadEvidencePhoto(
            organizationId: widget.organizationId,
            actionId: widget.action.id,
            fileName: photo.name,
            bytes: photo.bytes,
          ),
        );
      }
      final note = _noteController.text.trim();
      await _service.submitForReview(
        organizationId: widget.organizationId,
        actionId: widget.action.id,
        completionNote: note.isEmpty ? null : note,
        evidencePhotos: uploaded,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Submit Action')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            eyebrow: 'Complete & submit',
            title: action.title,
            subtitle: action.description,
            icon: Icons.task_alt,
            color: AppColors.correctiveActions,
          ),
          const SizedBox(height: AppSpacing.md),
          if (action.reviewFeedback != null) ...[
            _Callout(
              icon: Icons.reply,
              color: AppColors.hazards,
              title: 'Sent back by the reviewer',
              text: action.reviewFeedback!,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_required.isNotEmpty) ...[
            _Callout(
              icon: Icons.verified,
              color: AppColors.analytics,
              title: 'Evidence required',
              text: [
                for (final kind in _required) '• ${kind.label}',
                if (action.evidenceInstructions != null)
                  '“${action.evidenceInstructions}”',
              ].join('\n'),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_errorMessage != null) ...[
            AuthErrorBanner(message: _errorMessage!),
            const SizedBox(height: AppSpacing.md),
          ],
          FormSection(
            title: _needsConfirmation
                ? 'What did you do? (required)'
                : 'What did you do? (optional)',
            icon: Icons.edit_note,
            color: AppColors.meetings,
            child: TextField(
              controller: _noteController,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText:
                    'e.g. Fitted a new guard rail on level 3 and '
                    'checked it with the foreman.',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          FormSection(
            title: _needsPhoto
                ? 'Photos (at least one required)'
                : 'Photos (optional)',
            icon: Icons.photo_camera,
            color: AppColors.analytics,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_photos.isNotEmpty)
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      for (final (index, photo) in _photos.indexed)
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.memory(
                                photo.bytes,
                                width: 96,
                                height: 96,
                                fit: BoxFit.cover,
                              ),
                            ),
                            Positioned(
                              right: 0,
                              top: 0,
                              child: IconButton.filledTonal(
                                tooltip: 'Remove photo',
                                iconSize: 18,
                                onPressed: _isSubmitting
                                    ? null
                                    : () => setState(
                                        () => _photos.removeAt(index),
                                      ),
                                icon: const Icon(Icons.close),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                if (_photos.length < _maxPhotos) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _isSubmitting
                            ? null
                            : () => _addPhoto(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: const Text('Take photo'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isSubmitting
                            ? null
                            : () => _addPhoto(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('From gallery'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: AppSpacing.minTouchTarget,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.correctiveActions,
                foregroundColor: AppColors.onColor(AppColors.correctiveActions),
              ),
              onPressed: _isSubmitting || !_photoDone || !_confirmationDone
                  ? null
                  : _submit,
              icon: _isSubmitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: const Text('Submit for Review'),
            ),
          ),
          if (!_photoDone || !_confirmationDone)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                !_photoDone
                    ? 'Add at least one photo to submit.'
                    : 'Write what you did to submit.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}

/// A tinted box with an icon, a bold title and some text — used for "what
/// evidence is required" and "why it was sent back".
class _Callout extends StatelessWidget {
  const _Callout({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.readable(color, brightness)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.bodyLarge.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.readable(color, brightness),
                  ),
                ),
                const SizedBox(height: 2),
                Text(text, style: AppTextStyles.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
