import 'package:flutter/material.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/worker_learning_service.dart';
import '../domain/knowledge_check_result.dart';
import '../domain/safety_learning.dart';
import '../domain/safety_learning_type.dart';
import '../domain/worker_learning_record.dart';
import '../domain/worker_learning_status.dart';

/// The detail screen for one required learning item, reached via a plain
/// `Navigator.push` from [MySafetyLearningScreen] — this codebase does not
/// use go_router path parameters anywhere, so a new detail route is not
/// introduced here for consistency.
///
/// Shows the learning content reference (plain text/link — no rendering
/// pipeline) and the worker's own progress, with the one action available at
/// each status:
///  - [WorkerLearningStatus.assigned]: "Start Learning" -> `startLearning`.
///  - [WorkerLearningStatus.inProgress]: "Complete Learning" -> a trivial
///    confirmation (a single acknowledgement checkbox when the item is a
///    [SafetyLearningType.knowledgeCheck] — no real quiz engine) ->
///    `completeLearning`.
///  - [WorkerLearningStatus.completed]: read-only completion summary.
///
/// Both callables derive the acting worker from the caller's own auth token
/// server-side — see [WorkerLearningService]'s doc comment — so this screen
/// never sends a worker identifier of any kind.
class LearningDetailScreen extends StatefulWidget {
  const LearningDetailScreen({
    required this.organizationId,
    required this.learning,
    required this.record,
    super.key,
    this.workerLearningService,
  });

  final String organizationId;
  final SafetyLearning learning;
  final WorkerLearningRecord record;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real service.
  final WorkerLearningService? workerLearningService;

  @override
  State<LearningDetailScreen> createState() => _LearningDetailScreenState();
}

class _LearningDetailScreenState extends State<LearningDetailScreen> {
  late final WorkerLearningService _service =
      widget.workerLearningService ?? WorkerLearningService();

  WorkerLearningStatus? _localStatus;
  DateTime? _localCompletedAt;
  String? _errorMessage;
  bool _isSaving = false;

  WorkerLearningStatus get _status => _localStatus ?? widget.record.status;
  DateTime? get _completedAt =>
      _localCompletedAt ?? widget.record.completedAt;

  Future<void> _startLearning() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _service.startLearning(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
      );
      if (!mounted) return;
      setState(() => _localStatus = WorkerLearningStatus.inProgress);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _completeLearning() async {
    final isKnowledgeCheck =
        widget.learning.type == SafetyLearningType.knowledgeCheck;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _CompleteLearningDialog(isKnowledgeCheck: isKnowledgeCheck),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _service.completeLearning(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
        knowledgeCheckResult:
            isKnowledgeCheck ? const KnowledgeCheckResult(passed: true) : null,
      );
      if (!mounted) return;
      setState(() {
        _localStatus = WorkerLearningStatus.completed;
        _localCompletedAt = DateTime.now();
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final learning = widget.learning;
    return Scaffold(
      appBar: AppBar(title: Text(learning.title)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(learning.title, style: AppTextStyles.headlineMedium),
              ),
              _StatusBadge(status: _status),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(learning.type.label, style: AppTextStyles.bodyMedium),
          if (learning.description != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(learning.description!, style: AppTextStyles.bodyLarge),
          ],
          const SizedBox(height: AppSpacing.md),
          const Text('Content', style: AppTextStyles.label),
          const SizedBox(height: AppSpacing.xs),
          SelectableText(
            learning.contentReference,
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.info),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_errorMessage != null) ...[
            AuthErrorBanner(message: _errorMessage!),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_status == WorkerLearningStatus.assigned)
            ElevatedButton.icon(
              onPressed: _isSaving ? null : _startLearning,
              icon: const Icon(Icons.play_arrow_outlined),
              label: const Text('Start Learning'),
            ),
          if (_status == WorkerLearningStatus.inProgress)
            ElevatedButton.icon(
              onPressed: _isSaving ? null : _completeLearning,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Complete Learning'),
            ),
          if (_status == WorkerLearningStatus.completed) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _completedAt != null
                  ? 'Completed on ${_completedAt!.toLocal()}'.split('.').first
                  : 'Completed',
              style: AppTextStyles.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }
}

class _CompleteLearningDialog extends StatefulWidget {
  const _CompleteLearningDialog({required this.isKnowledgeCheck});

  final bool isKnowledgeCheck;

  @override
  State<_CompleteLearningDialog> createState() =>
      _CompleteLearningDialogState();
}

class _CompleteLearningDialogState extends State<_CompleteLearningDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Complete Learning'),
      content: widget.isKnowledgeCheck
          ? CheckboxListTile(
              value: _acknowledged,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I have reviewed this and confirm I understand.',
              ),
              onChanged: (checked) =>
                  setState(() => _acknowledged = checked ?? false),
            )
          : const Text('Mark this learning item as completed?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: (!widget.isKnowledgeCheck || _acknowledged)
              ? () => Navigator.of(context).pop(true)
              : null,
          child: const Text('Submit'),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final WorkerLearningStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      WorkerLearningStatus.assigned => AppColors.textSecondary,
      WorkerLearningStatus.inProgress => AppColors.warning,
      WorkerLearningStatus.completed => AppColors.success,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Text(
        status.label,
        style: AppTextStyles.label.copyWith(color: color),
      ),
    );
  }
}
