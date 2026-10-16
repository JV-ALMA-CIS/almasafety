import 'package:flutter/material.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/offline/saved_on_phone_note.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/pre_start_check_service.dart';
import '../domain/pre_start_answer.dart';
import '../domain/pre_start_check.dart';
import '../domain/pre_start_outcome.dart';
import 'pre_start_outcome_style.dart';
import 'pre_start_visuals.dart';

/// The worker's Daily Pre-Start Check: one card per question with large
/// Yes / No buttons. A "No" asks whether the worker fixed it or cannot fix
/// it, and for a short note either way. Submitting shows the GO / GO
/// corrected / STOP result the SERVER decided, then pops with it.
///
/// The live "Your result so far" banner is only a preview of the same rule
/// the server applies — [PreStartCheckService.submitPreStartCheck]'s answer
/// is the one shown afterwards.
class PreStartCheckScreen extends StatefulWidget {
  const PreStartCheckScreen({
    super.key,
    required this.organizationId,
    required this.check,
    required this.service,
  });

  final String organizationId;
  final MyPreStartCheck check;
  final PreStartCheckService service;

  @override
  State<PreStartCheckScreen> createState() => _PreStartCheckScreenState();
}

class _PreStartCheckScreenState extends State<PreStartCheckScreen> {
  /// Each question's answer: null until the worker taps Yes or No; for a
  /// "No", [PreStartAnswer.fixed] or [PreStartAnswer.cannotFix] once chosen.
  final Map<String, PreStartAnswer?> _answers = {};

  /// Questions answered "No" but not yet marked fixed / cannot fix.
  final Set<String> _saidNo = {};
  final Map<String, TextEditingController> _notes = {};

  bool _isSubmitting = false;
  String? _error;
  PreStartOutcome? _result;

  /// True when there was no signal and the check was saved on this phone;
  /// [_result] is then this phone's own reading of the answers.
  bool _savedOffline = false;

  List<PreStartQuestion> get _questions => widget.check.questions;

  @override
  void dispose() {
    for (final controller in _notes.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _noteFor(String id) =>
      _notes.putIfAbsent(id, TextEditingController.new);

  bool _isComplete(PreStartQuestion question) {
    final answer = _answers[question.id];
    if (answer == null) return false;
    return !answer.needsNote || _noteFor(question.id).text.trim().isNotEmpty;
  }

  int get _completeCount => _questions.where(_isComplete).length;

  bool get _canSubmit => !_isSubmitting && _completeCount == _questions.length;

  /// Preview of the server's rule: any "can't fix" is STOP, any "fixed" is
  /// GO corrected, otherwise GO.
  PreStartOutcome get _preview {
    final answers = _answers.values;
    if (answers.contains(PreStartAnswer.cannotFix)) return PreStartOutcome.stop;
    if (answers.contains(PreStartAnswer.fixed) || _saidNo.isNotEmpty) {
      return PreStartOutcome.goCorrected;
    }
    return PreStartOutcome.go;
  }

  void _answerYes(String id) => setState(() {
    _answers[id] = PreStartAnswer.yes;
    _saidNo.remove(id);
  });

  void _answerNo(String id) => setState(() {
    _answers.remove(id);
    _saidNo.add(id);
  });

  void _chooseNoKind(String id, PreStartAnswer kind) => setState(() {
    _answers[id] = kind;
  });

  Future<void> _submit() async {
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      final outcome = await widget.service.submitPreStartCheck(
        organizationId: widget.organizationId,
        forDate: widget.check.date.isEmpty ? null : widget.check.date,
        answers: {
          for (final question in _questions)
            question.id: (
              answer: _answers[question.id]!,
              note: _answers[question.id]!.needsNote
                  ? _noteFor(question.id).text.trim()
                  : null,
            ),
        },
      );
      if (!mounted) return;
      setState(() => _result = outcome);
    } on SavedOfflineException {
      if (!mounted) return;
      setState(() {
        _savedOffline = true;
        _result = _preview;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Daily Pre-Start Check')),
      body: result != null ? _resultView(result) : _form(),
    );
  }

  Widget _resultView(PreStartOutcome outcome) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        PreStartOutcomePanel(outcome: outcome),
        const SizedBox(height: AppSpacing.md),
        if (_savedOffline) ...[
          const SavedOnPhoneNote(
            text:
                'No signal - your check is saved on this phone and will be '
                'sent automatically when the signal comes back.',
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (outcome == PreStartOutcome.stop && _savedOffline)
          const Text(
            'There is no signal, so your Foreman has NOT been told yet. Go '
            'and tell them in person now. Do not start this work until they '
            'have spoken with you.',
            style: AppTextStyles.bodyLarge,
          )
        else if (outcome == PreStartOutcome.stop)
          const Text(
            'Your Foreman has been told. Do not start this work until they '
            'have spoken with you.',
            style: AppTextStyles.bodyLarge,
          ),
        const SizedBox(height: AppSpacing.lg),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(outcome),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _form() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Text(
                widget.check.siteName.isEmpty
                    ? 'Before you start work today'
                    : 'Before you start work at ${widget.check.siteName}',
                style: AppTextStyles.titleLarge,
              ),
              const SizedBox(height: AppSpacing.xs),
              const Text(
                'Answer every question honestly. If something is not '
                'right, say whether you fixed it.',
                style: AppTextStyles.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              for (final (index, question) in _questions.indexed) ...[
                _QuestionCard(
                  number: index + 1,
                  question: question,
                  answer: _answers[question.id],
                  saidNo: _saidNo.contains(question.id),
                  note: _noteFor(question.id),
                  onYes: () => _answerYes(question.id),
                  onNo: () => _answerNo(question.id),
                  onNoKind: (kind) => _chooseNoKind(question.id, kind),
                  onNoteChanged: () => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          ),
        ),
        _SubmitBar(
          answered: _completeCount,
          total: _questions.length,
          preview: _preview,
          error: _error,
          isSubmitting: _isSubmitting,
          onSubmit: _canSubmit ? _submit : null,
        ),
      ],
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.number,
    required this.question,
    required this.answer,
    required this.saidNo,
    required this.note,
    required this.onYes,
    required this.onNo,
    required this.onNoKind,
    required this.onNoteChanged,
  });

  final int number;
  final PreStartQuestion question;
  final PreStartAnswer? answer;
  final bool saidNo;
  final TextEditingController note;
  final VoidCallback onYes;
  final VoidCallback onNo;
  final ValueChanged<PreStartAnswer> onNoKind;
  final VoidCallback onNoteChanged;

  @override
  Widget build(BuildContext context) {
    final isYes = answer == PreStartAnswer.yes;
    final isNo = saidNo || (answer != null && answer!.needsNote);
    final accent = isYes
        ? AppColors.go
        : isNo
        ? AppColors.stop
        : AppColors.primaryBright;

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: accent.withValues(alpha: isYes || isNo ? 0.8 : 0.25),
          width: isYes || isNo ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: accent,
                  child: Text(
                    '$number',
                    style: TextStyle(
                      color: AppColors.onColor(accent),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (question.isHighRisk)
                        Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.danger,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'HIGH RISK',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      Text(question.prompt, style: AppTextStyles.bodyLarge),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            PreStartVisualStrip(
              visuals: visualsFor(question),
              color: question.isHighRisk ? AppColors.danger : null,
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _ChoiceButton(
                    label: 'Yes',
                    icon: Icons.check,
                    color: AppColors.go,
                    selected: isYes,
                    onTap: onYes,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _ChoiceButton(
                    label: 'No',
                    icon: Icons.close,
                    color: AppColors.stop,
                    selected: isNo,
                    onTap: onNo,
                  ),
                ),
              ],
            ),
            if (isNo) ...[
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final kind in const [
                    PreStartAnswer.fixed,
                    PreStartAnswer.cannotFix,
                  ])
                    ChoiceChip(
                      label: Text(kind.label),
                      selected: answer == kind,
                      selectedColor: kind == PreStartAnswer.fixed
                          ? AppColors.goCorrected
                          : AppColors.stop,
                      labelStyle: TextStyle(
                        color: answer == kind ? Colors.white : null,
                        fontWeight: FontWeight.w600,
                      ),
                      onSelected: (_) => onNoKind(kind),
                    ),
                ],
              ),
              if (answer != null && answer!.needsNote) ...[
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: note,
                  maxLength: 500,
                  maxLines: 2,
                  onChanged: (_) => onNoteChanged(),
                  decoration: InputDecoration(
                    labelText: answer == PreStartAnswer.fixed
                        ? 'What did you fix?'
                        : 'What is wrong?',
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: selected
          ? ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 52),
              ),
              onPressed: onTap,
              icon: Icon(icon),
              label: Text(label),
            )
          : OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.readable(
                  color,
                  Theme.of(context).brightness,
                ),
                side: BorderSide(color: color, width: 1.5),
                minimumSize: const Size(0, 52),
              ),
              onPressed: onTap,
              icon: Icon(icon),
              label: Text(label),
            ),
    );
  }
}

class _SubmitBar extends StatelessWidget {
  const _SubmitBar({
    required this.answered,
    required this.total,
    required this.preview,
    required this.error,
    required this.isSubmitting,
    required this.onSubmit,
  });

  final int answered;
  final int total;
  final PreStartOutcome preview;
  final String? error;
  final bool isSubmitting;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$answered of $total answered',
                      style: AppTextStyles.bodyMedium,
                    ),
                  ),
                  if (answered > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: preview.color,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'So far: ${preview.label}',
                        style: AppTextStyles.label.copyWith(
                          color: AppColors.onColor(preview.color),
                        ),
                      ),
                    ),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  error!,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.danger,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              ElevatedButton.icon(
                onPressed: onSubmit,
                icon: isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                label: const Text('Submit Check'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
