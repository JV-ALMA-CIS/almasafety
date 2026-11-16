import 'package:flutter/material.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/feature_header.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/corrective_action_service.dart';
import '../domain/corrective_action.dart';
import '../domain/corrective_action_status.dart';
import 'submit_corrective_action_screen.dart';
import '../../../core/widgets/mobile_title.dart';

/// Where a reviewer verifies submitted work: the task, who did it, what
/// evidence was required and what was actually submitted (the assignee's
/// note and photos). Then either **Approve & complete** — the only way an
/// action reaches `completed` — or **Send back** with a reason the
/// assignee sees on their own screen.
///
/// Also opened for any other action as a read-only detail view (the
/// approve/send-back buttons only appear while it awaits review).
class ReviewCorrectiveActionScreen extends StatefulWidget {
  const ReviewCorrectiveActionScreen({
    super.key,
    required this.organizationId,
    required this.action,
    required this.assignedToName,
    required this.siteName,
    this.currentUid,
    this.service,
  });

  /// The signed-in person. When it is the assignee, this screen offers
  /// **Complete & Submit** (and never lets them approve their own work).
  final String? currentUid;

  final String organizationId;
  final CorrectiveAction action;
  final String assignedToName;
  final String siteName;

  /// Injected in tests.
  final CorrectiveActionService? service;

  @override
  State<ReviewCorrectiveActionScreen> createState() =>
      _ReviewCorrectiveActionScreenState();
}

class _ReviewCorrectiveActionScreenState
    extends State<ReviewCorrectiveActionScreen> {
  late final CorrectiveActionService _service =
      widget.service ?? CorrectiveActionService();
  bool _isSaving = false;
  String? _errorMessage;

  Future<void> _decide(
    CorrectiveActionStatus status, {
    String? feedback,
  }) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _service.updateCorrectiveActionStatus(
        organizationId: widget.organizationId,
        actionId: widget.action.id,
        status: status.id,
        reviewFeedback: feedback,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _sendBack() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _SendBackDialog(),
    );
    if (reason == null) return;
    await _decide(
      CorrectiveActionStatus.inProgress,
      feedback: reason.isEmpty ? null : reason,
    );
  }

  bool get _isMine => widget.currentUid == widget.action.assignedTo;

  bool get _canSubmit =>
      _isMine &&
      (widget.action.status == CorrectiveActionStatus.open ||
          widget.action.status == CorrectiveActionStatus.inProgress);

  Future<void> _openSubmit() async {
    final submitted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SubmitCorrectiveActionScreen(
          organizationId: widget.organizationId,
          action: widget.action,
          service: _service,
        ),
      ),
    );
    if (submitted == true && mounted) Navigator.of(context).pop(true);
  }

  void _openPhoto(String url) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const MobileTitle('Review Action')),
          backgroundColor: Colors.black,
          body: InteractiveViewer(
            child: Center(
              child: Image.network(
                url,
                errorBuilder: (context, error, stackTrace) => const Text(
                  'Could not load the photo.',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final awaitingReview =
        action.status == CorrectiveActionStatus.submittedForReview;
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Review Action')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            eyebrow: awaitingReview ? 'Review submission' : 'Corrective action',
            title: action.title,
            subtitle: action.description,
            icon: awaitingReview ? Icons.fact_check : Icons.build_circle,
            color: AppColors.correctiveActions,
            chips: [
              FeatureChip(icon: Icons.flag, label: action.status.label),
              FeatureChip(icon: Icons.person, label: widget.assignedToName),
              if (widget.siteName.isNotEmpty)
                FeatureChip(icon: Icons.place, label: widget.siteName),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (_errorMessage != null) ...[
            AuthErrorBanner(message: _errorMessage!),
            const SizedBox(height: AppSpacing.md),
          ],
          const FeatureSectionTitle(
            title: 'Details',
            icon: Icons.list_alt,
            color: AppColors.correctiveActions,
          ),
          const SizedBox(height: AppSpacing.sm),
          _Row('Assigned to', widget.assignedToName),
          _Row('Assigned by', action.assignedByName ?? 'A supervisor'),
          _Row('Due', _formatDate(action.dueDate)),
          _Row(
            'Evidence required',
            action.requiredEvidence.isEmpty
                ? 'None'
                : action.requiredEvidence.map((k) => k.label).join(', '),
          ),
          if (action.evidenceInstructions != null)
            _Row('Instructions', action.evidenceInstructions!),
          if (action.completedByName != null)
            _Row('Verified by', action.completedByName!),
          const SizedBox(height: AppSpacing.md),
          const FeatureSectionTitle(
            title: 'Submitted evidence',
            icon: Icons.verified,
            color: AppColors.analytics,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (action.submittedAt == null) ...[
            Text(
              _canSubmit
                  ? 'This is assigned to you. Do the work, then submit your '
                        'evidence here.'
                  : 'Nothing has been submitted yet.',
              style: AppTextStyles.bodyMedium,
            ),
            if (_canSubmit) ...[
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: AppSpacing.minTouchTarget,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.correctiveActions,
                    foregroundColor: AppColors.onColor(
                      AppColors.correctiveActions,
                    ),
                  ),
                  onPressed: _openSubmit,
                  icon: const Icon(Icons.task_alt),
                  label: const Text('Complete & Submit'),
                ),
              ),
            ],
          ] else ...[
            _Row('Submitted', _formatDateTime(action.submittedAt!)),
            _Row('What was done', action.completionNote ?? '(no note)'),
            const SizedBox(height: AppSpacing.sm),
            if (action.evidencePhotos.isEmpty)
              const Text('No photos attached.', style: AppTextStyles.bodyMedium)
            else
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final photo in action.evidencePhotos)
                    InkWell(
                      onTap: () => _openPhoto(photo.downloadUrl),
                      borderRadius: BorderRadius.circular(10),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          photo.downloadUrl,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const SizedBox(
                                width: 120,
                                height: 120,
                                child: Center(child: Icon(Icons.broken_image)),
                              ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
          if (_canSubmit && action.submittedAt != null) ...[
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              height: AppSpacing.minTouchTarget,
              child: FilledButton.icon(
                onPressed: _openSubmit,
                icon: const Icon(Icons.task_alt),
                label: const Text('Resubmit evidence'),
              ),
            ),
          ],
          if (awaitingReview && _isMine) ...[
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'Submitted. Another reviewer must approve your own work.',
              style: AppTextStyles.bodyMedium,
            ),
          ],
          if (awaitingReview && !_isMine) ...[
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              height: AppSpacing.minTouchTarget,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                ),
                onPressed: _isSaving
                    ? null
                    : () => _decide(CorrectiveActionStatus.completed),
                icon: const Icon(Icons.task_alt),
                label: const Text('Approve & complete'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              height: AppSpacing.minTouchTarget,
              child: OutlinedButton.icon(
                onPressed: _isSaving ? null : _sendBack,
                icon: const Icon(Icons.reply),
                label: const Text('Send back'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SendBackDialog extends StatefulWidget {
  const _SendBackDialog();

  @override
  State<_SendBackDialog> createState() => _SendBackDialogState();
}

class _SendBackDialogState extends State<_SendBackDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Send back'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(
          labelText: 'What needs fixing? (shown to the assignee)',
          hintText: 'e.g. Photo is blurry — please retake',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Send back'),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 140, child: Text(label, style: AppTextStyles.label)),
          Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

String _formatDate(DateTime date) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}

String _formatDateTime(DateTime date) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${_formatDate(date)} ${two(date.hour)}:${two(date.minute)}';
}
