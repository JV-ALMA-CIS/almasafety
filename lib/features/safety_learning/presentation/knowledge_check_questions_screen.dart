import 'package:flutter/material.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/safety_learning_admin_service.dart';
import '../domain/knowledge_check_admin_question.dart';
import '../domain/knowledge_check_question.dart';
import '../domain/safety_learning.dart';

/// Minimal multiple-choice question editor for one [SafetyLearning] item's
/// knowledge check — reached via "Manage Questions" on
/// [SafetyLearningLibraryScreen]'s item card.
///
/// **Deliberately minimal, per this phase's own scope**: multiple-choice
/// only, 2-6 options per question, no drag-to-reorder (a question's
/// position is set by a plain numeric "order" field instead). This is the
/// one screen in this codebase that ever handles a correct-answer value —
/// see [KnowledgeCheckAdminQuestion]'s doc comment for why that is safe
/// (this screen calls `listKnowledgeCheckQuestions`, `admin`-only, the sole
/// path that returns `correctOptionId` at all).
class KnowledgeCheckQuestionsScreen extends StatefulWidget {
  const KnowledgeCheckQuestionsScreen({
    required this.organizationId,
    required this.learning,
    super.key,
    this.adminService,
  });

  final String organizationId;
  final SafetyLearning learning;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real service.
  final SafetyLearningAdminService? adminService;

  @override
  State<KnowledgeCheckQuestionsScreen> createState() =>
      _KnowledgeCheckQuestionsScreenState();
}

class _KnowledgeCheckQuestionsScreenState
    extends State<KnowledgeCheckQuestionsScreen> {
  late final SafetyLearningAdminService _adminService =
      widget.adminService ?? SafetyLearningAdminService();

  List<KnowledgeCheckAdminQuestion> _questions = const [];
  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final questions = await _adminService.listKnowledgeCheckQuestions(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
      );
      if (!mounted) return;
      setState(() => _questions = questions);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openAddDialog() async {
    final result = await showDialog<_QuestionFormResult>(
      context: context,
      builder: (_) => _QuestionFormDialog(nextOrder: _questions.length),
    );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.addKnowledgeCheckQuestion(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
        prompt: result.prompt,
        options: result.options,
        correctOptionId: result.correctOptionId,
        order: result.order,
      ),
    );
  }

  Future<void> _openEditDialog(KnowledgeCheckAdminQuestion question) async {
    final result = await showDialog<_QuestionFormResult>(
      context: context,
      builder: (_) => _QuestionFormDialog(existing: question),
    );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.updateKnowledgeCheckQuestion(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
        questionId: question.id,
        prompt: result.prompt,
        options: result.options,
        correctOptionId: result.correctOptionId,
        order: result.order,
      ),
    );
  }

  Future<void> _remove(KnowledgeCheckAdminQuestion question) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove question'),
        content: Text('Remove "${question.prompt}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _save(
      () => _adminService.removeKnowledgeCheckQuestion(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
        questionId: question.id,
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
      await _load();
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.learning.title} — Questions')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          const Text(
            'Multiple-choice questions for this item\'s knowledge check. '
            'An item with no questions has no knowledge-check gate — '
            'workers complete it as before.',
            style: AppTextStyles.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          if (_errorMessage != null) ...[
            AuthErrorBanner(message: _errorMessage!),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (!_isLoading && _questions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Text(
                'No questions yet.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          for (final question in _questions) ...[
            _QuestionCard(
              question: question,
              onEdit: () => _openEditDialog(question),
              onRemove: () => _remove(question),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.md),
          ElevatedButton.icon(
            onPressed: _isSaving || _isLoading ? null : _openAddDialog,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('Add Question'),
          ),
        ],
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.onEdit,
    required this.onRemove,
  });

  final KnowledgeCheckAdminQuestion question;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(question.prompt, style: AppTextStyles.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            for (final option in question.options)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Row(
                  children: [
                    Icon(
                      option.id == question.correctOptionId
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      size: 16,
                      color: option.id == question.correctOptionId
                          ? AppColors.success
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(option.text, style: AppTextStyles.bodyMedium),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                    minWidth: 100,
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
                    minWidth: 100,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: onRemove,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: AppColors.danger,
                    ),
                    label: const Text(
                      'Remove',
                      style: TextStyle(color: AppColors.danger),
                    ),
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

class _QuestionFormResult {
  const _QuestionFormResult({
    required this.prompt,
    required this.options,
    required this.correctOptionId,
    required this.order,
  });

  final String prompt;
  final List<KnowledgeCheckOption> options;
  final String correctOptionId;
  final int order;
}

const int _minOptions = 2;
const int _maxOptions = 6;

class _QuestionFormDialog extends StatefulWidget {
  const _QuestionFormDialog({this.existing, this.nextOrder = 0});

  final KnowledgeCheckAdminQuestion? existing;
  final int nextOrder;

  @override
  State<_QuestionFormDialog> createState() => _QuestionFormDialogState();
}

class _OptionEntry {
  _OptionEntry({required this.id, String text = ''})
    : controller = TextEditingController(text: text);

  final String id;
  final TextEditingController controller;
}

class _QuestionFormDialogState extends State<_QuestionFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _promptController = TextEditingController(
    text: widget.existing?.prompt,
  );
  late final List<_OptionEntry> _options = widget.existing != null
      ? [
          for (final option in widget.existing!.options)
            _OptionEntry(id: option.id, text: option.text),
        ]
      : [_OptionEntry(id: _newOptionId()), _OptionEntry(id: _newOptionId())];
  late String? _correctOptionId = widget.existing?.correctOptionId;

  int _optionCounter = 0;

  String _newOptionId() =>
      'option_${_optionCounter++}_'
      '${DateTime.now().microsecondsSinceEpoch}';

  @override
  void dispose() {
    _promptController.dispose();
    for (final option in _options) {
      option.controller.dispose();
    }
    super.dispose();
  }

  void _addOption() {
    if (_options.length >= _maxOptions) return;
    setState(() => _options.add(_OptionEntry(id: _newOptionId())));
  }

  void _removeOption(_OptionEntry entry) {
    if (_options.length <= _minOptions) return;
    setState(() {
      _options.remove(entry);
      if (_correctOptionId == entry.id) _correctOptionId = null;
      entry.controller.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit Question' : 'Add Question'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _promptController,
                  decoration: const InputDecoration(labelText: 'Question'),
                  maxLines: 2,
                  autofillHints: const [],
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'A question prompt is required.'
                      : null,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Options ($_minOptions-$_maxOptions) — select the '
                  'correct one',
                  style: AppTextStyles.label,
                ),
                const SizedBox(height: AppSpacing.xs),
                Column(
                  children: [
                    for (final option in _options)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: Row(
                          children: [
                            _CorrectAnswerToggle(
                              isCorrect: _correctOptionId == option.id,
                              onTap: () => setState(
                                () => _correctOptionId =
                                    _correctOptionId == option.id
                                    ? null
                                    : option.id,
                              ),
                            ),
                            Expanded(
                              child: TextFormField(
                                controller: option.controller,
                                decoration: const InputDecoration(
                                  labelText: 'Option text',
                                ),
                                autofillHints: const [],
                                validator: (value) =>
                                    (value == null || value.trim().isEmpty)
                                    ? 'Required'
                                    : null,
                              ),
                            ),
                            if (_options.length > _minOptions)
                              IconButton(
                                tooltip: 'Remove option',
                                onPressed: () => _removeOption(option),
                                icon: const Icon(Icons.close),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
                if (_options.length < _maxOptions)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _addOption,
                      icon: const Icon(Icons.add),
                      label: const Text('Add option'),
                    ),
                  ),
                if (_correctOptionId == null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  const Text(
                    'Select the correct option.',
                    style: TextStyle(color: AppColors.danger),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) return;
            final correctOptionId = _correctOptionId;
            if (correctOptionId == null) return;
            Navigator.of(context).pop(
              _QuestionFormResult(
                prompt: _promptController.text.trim(),
                options: [
                  for (final option in _options)
                    KnowledgeCheckOption(
                      id: option.id,
                      text: option.controller.text.trim(),
                    ),
                ],
                correctOptionId: correctOptionId,
                order: widget.existing?.order ?? widget.nextOrder,
              ),
            );
          },
          child: Text(isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

/// Marks one option as the correct answer — a tick that turns solid green
/// when chosen (tap again to unmark), in place of a plain radio button.
class _CorrectAnswerToggle extends StatelessWidget {
  const _CorrectAnswerToggle({required this.isCorrect, required this.onTap});

  final bool isCorrect;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: isCorrect ? 'Correct answer' : 'Mark as the correct answer',
      onPressed: onTap,
      style: IconButton.styleFrom(
        backgroundColor: isCorrect
            ? AppColors.success
            : AppColors.success.withValues(alpha: 0.08),
        side: BorderSide(
          color: AppColors.success.withValues(alpha: isCorrect ? 1 : 0.45),
        ),
      ),
      icon: Icon(
        Icons.check,
        color: isCorrect ? Colors.white : AppColors.success,
      ),
    );
  }
}
