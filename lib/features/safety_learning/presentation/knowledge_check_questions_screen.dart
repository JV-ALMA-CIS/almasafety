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
import '../../../core/utils/responsive.dart';

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

  /// The question list could not be loaded: no "No questions yet" (that
  /// would be untrue) and no adding until a retry succeeds, since a new
  /// question's order is based on the loaded list.
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadFailed = false;
      _errorMessage = null;
    });
    try {
      final questions = await _adminService.listKnowledgeCheckQuestions(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
      );
      if (!mounted) return;
      setState(() => _questions = questions);
    } on AppException catch (e) {
      debugPrint('Knowledge check: could not load questions: ${e.message}');
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _errorMessage = e.message;
      });
    } on Object catch (e) {
      debugPrint('Knowledge check: could not load questions: $e');
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _errorMessage = 'Could not load the questions. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// True while a question dialog is open — a double tap opens it once.
  bool _dialogOpen = false;

  /// After the highest existing order, so a new question always goes last
  /// even after removals.
  int get _nextOrder => _questions.isEmpty
      ? 0
      : _questions.map((q) => q.order).reduce((a, b) => a > b ? a : b) + 1;

  /// Opens the add/edit dialog, which SAVES ITSELF: a failed save keeps
  /// it open with everything typed and the reason shown. Reloads after a
  /// save.
  Future<void> _openDialog({KnowledgeCheckAdminQuestion? existing}) async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    try {
      final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _QuestionFormDialog(
          existing: existing,
          nextOrder: _nextOrder,
          onSubmit: (result) => existing == null
              ? _adminService.addKnowledgeCheckQuestion(
                  organizationId: widget.organizationId,
                  learningId: widget.learning.id,
                  prompt: result.prompt,
                  options: result.options,
                  correctOptionId: result.correctOptionId,
                  order: result.order,
                )
              : _adminService.updateKnowledgeCheckQuestion(
                  organizationId: widget.organizationId,
                  learningId: widget.learning.id,
                  questionId: existing.id,
                  prompt: result.prompt,
                  options: result.options,
                  correctOptionId: result.correctOptionId,
                  order: result.order,
                ),
        ),
      );
      if (saved == true && mounted) await _load();
    } finally {
      _dialogOpen = false;
    }
  }

  Future<void> _openAddDialog() => _openDialog();

  Future<void> _openEditDialog(KnowledgeCheckAdminQuestion question) =>
      _openDialog(existing: question);

  /// Moves the question at [index] up (-1) or down (+1). Each question keeps
  /// its id, text and correct answer; only `order` is rewritten — to the
  /// questions' new positions, which also tidies any duplicate orders.
  Future<void> _move(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _questions.length || _isSaving) return;
    final reordered = [..._questions];
    final moved = reordered.removeAt(index);
    reordered.insert(target, moved);
    await _save(() async {
      for (final (position, question) in reordered.indexed) {
        if (question.order == position) continue;
        await _adminService.updateKnowledgeCheckQuestion(
          organizationId: widget.organizationId,
          learningId: widget.learning.id,
          questionId: question.id,
          prompt: question.prompt,
          options: question.options,
          correctOptionId: question.correctOptionId,
          order: position,
        );
      }
    });
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
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await action();
      if (!mounted) return;
      await _load();
    } on AppException catch (e) {
      debugPrint('Knowledge check: could not save: ${e.message}');
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } on Object catch (e) {
      debugPrint('Knowledge check: could not save: $e');
      if (!mounted) return;
      setState(
        () => _errorMessage =
            'Could not save. Check your connection and '
            'try again.',
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String get _savedSummary {
    final count = _questions.length;
    final passMark = widget.learning.passingScorePercent;
    return '$count saved ${count == 1 ? 'question' : 'questions'}'
        '${passMark == null ? '' : ' · pass mark $passMark%'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // A phone has room for a short name only.
        title: Text(
          Responsive.isMobile(context)
              ? 'Manage Quiz'
              : '${widget.learning.title} — Questions',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          const Text(
            'Multiple-choice questions for this item\'s knowledge check. '
            'Learners see the questions, never the answers. Whether '
            'passing the quiz is required is set for each lesson in Safety '
            'Requirements; an item with no questions has no quiz.',
            style: AppTextStyles.bodyMedium,
          ),
          if (!_isLoading && !_loadFailed && _questions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_savedSummary, style: AppTextStyles.label),
          ],
          const SizedBox(height: AppSpacing.md),
          if (_errorMessage != null) ...[
            AuthErrorBanner(message: _errorMessage!),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_loadFailed && !_isLoading) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, AppSpacing.minTouchTarget),
                ),
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (!_isLoading && !_loadFailed && _questions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Text(
                'No questions yet.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          for (final (index, question) in _questions.indexed) ...[
            _QuestionCard(
              number: index + 1,
              question: question,
              onEdit: _isSaving ? null : () => _openEditDialog(question),
              onRemove: _isSaving ? null : () => _remove(question),
              onMoveUp: _isSaving || index == 0 ? null : () => _move(index, -1),
              onMoveDown: _isSaving || index == _questions.length - 1
                  ? null
                  : () => _move(index, 1),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.md),
          ElevatedButton.icon(
            onPressed: _isSaving || _isLoading || _loadFailed
                ? null
                : _openAddDialog,
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
    required this.number,
    required this.question,
    required this.onEdit,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final int number;
  final KnowledgeCheckAdminQuestion question;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Question $number', style: AppTextStyles.label),
                const Spacer(),
                IconButton(
                  tooltip: 'Move up',
                  onPressed: onMoveUp,
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Move down',
                  onPressed: onMoveDown,
                  icon: const Icon(Icons.arrow_downward),
                ),
              ],
            ),
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
  const _QuestionFormDialog({
    required this.onSubmit,
    this.existing,
    this.nextOrder = 0,
  });

  final KnowledgeCheckAdminQuestion? existing;
  final int nextOrder;

  /// Saves the question; the dialog closes with `true` only when it succeeds.
  final Future<void> Function(_QuestionFormResult result) onSubmit;

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
  bool _isSaving = false;
  String? _saveError;

  int _optionCounter = 0;

  /// Saves from inside the dialog: on failure everything typed stays, with
  /// the reason; a second tap while saving does nothing.
  Future<void> _submit() async {
    if (_isSaving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final correctOptionId = _correctOptionId;
    if (correctOptionId == null) return;
    setState(() {
      _isSaving = true;
      _saveError = null;
    });
    try {
      await widget.onSubmit(
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
      if (mounted) Navigator.of(context).pop(true);
    } on AppException catch (e) {
      debugPrint('Knowledge check: could not save a question: ${e.message}');
      if (mounted) setState(() => _saveError = e.message);
    } on Object catch (e) {
      debugPrint('Knowledge check: could not save a question: $e');
      if (mounted) {
        setState(
          () => _saveError =
              'Could not save. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

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
    return PopScope(
      canPop: !_isSaving,
      child: AlertDialog(
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
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
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
                  if (_saveError != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    AuthErrorBanner(message: _saveError!),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _isSaving
                ? null
                : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: _isSaving ? null : _submit,
            child: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(isEditing ? 'Save' : 'Add'),
          ),
        ],
      ),
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
