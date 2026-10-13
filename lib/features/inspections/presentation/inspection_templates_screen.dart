import 'package:flutter/material.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/choice_list.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../hazards/domain/hazard_category.dart';
import '../../hazards/presentation/hazard_style.dart';
import '../data/inspection_repository.dart';
import '../data/inspection_service.dart';
import '../domain/inspection.dart';
import 'inspection_style.dart';

/// The inspection checklists (Site Manager/Admin): install the standard
/// ones from the Safety Plan, switch any on or off, edit them, or create a
/// new one (e.g. an environmental or welfare check). Editing never changes
/// past inspections — each keeps the items it was started with.
class InspectionTemplatesScreen extends StatefulWidget {
  const InspectionTemplatesScreen({
    super.key,
    required this.organizationId,
    required this.repository,
    required this.service,
  });

  final String organizationId;
  final InspectionRepository repository;
  final InspectionService service;

  @override
  State<InspectionTemplatesScreen> createState() =>
      _InspectionTemplatesScreenState();
}

class _InspectionTemplatesScreenState extends State<InspectionTemplatesScreen> {
  bool _isSaving = false;
  String? _errorMessage;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await action();
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _edit(InspectionTemplate? template) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _TemplateEditorScreen(
          organizationId: widget.organizationId,
          service: widget.service,
          template: template,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: LiveStreamBuilder<List<InspectionTemplate>>(
        streamKey: widget.organizationId,
        stream: () => widget.repository.watchTemplates(),
        builder: (context, snapshot) {
          final templates = snapshot.data ?? const <InspectionTemplate>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              96,
            ),
            children: [
              const FeatureHeader(
                title: 'Checklists',
                subtitle:
                    'What gets checked on each inspection. Changes apply to '
                    'new inspections only.',
                icon: Icons.checklist,
                color: AppColors.inspections,
              ),
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _isSaving
                      ? null
                      : () => _run(
                          () => widget.service.installDefaultTemplates(
                            widget.organizationId,
                          ),
                        ),
                  icon: const Icon(Icons.download),
                  label: const Text('Install standard checklists'),
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.md),
                AuthErrorBanner(message: _errorMessage!),
              ],
              const SizedBox(height: AppSpacing.md),
              for (final template in templates) ...[
                AccentCard(
                  color: template.kind.color,
                  icon: template.kind.icon,
                  title: template.name,
                  dimmed: !template.isActive,
                  onTap: () => _edit(template),
                  badges: [
                    AccentBadge(
                      label: template.isActive ? 'In use' : 'Switched off',
                      color: template.isActive
                          ? AppColors.success
                          : AppColors.textSecondary,
                    ),
                  ],
                  body: template.description,
                  details: [
                    AccentDetail(
                      icon: Icons.checklist,
                      text:
                          '${template.kind.label} · ${template.sections.length} '
                          'sections · ${template.itemCount} items',
                    ),
                  ],
                  actions: [
                    AccentButton(
                      label: 'Edit',
                      icon: Icons.edit,
                      color: AppColors.inspections,
                      outlined: true,
                      onPressed: () => _edit(template),
                    ),
                    AccentButton(
                      label: template.isActive ? 'Switch off' : 'Switch on',
                      icon: template.isActive
                          ? Icons.toggle_off_outlined
                          : Icons.toggle_on,
                      color: AppColors.textSecondary,
                      outlined: true,
                      onPressed: _isSaving
                          ? null
                          : () => _run(
                              () => widget.service.saveTemplate(
                                organizationId: widget.organizationId,
                                templateId: template.id,
                                name: template.name,
                                kind: template.kind,
                                description: template.description,
                                sections: template.sections,
                                active: !template.isActive,
                              ),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-checklist',
        backgroundColor: AppColors.inspections,
        foregroundColor: Colors.white,
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('New checklist'),
      ),
    );
  }
}

/// An editable section while editing.
class _EditSection {
  _EditSection(String title, this.items)
    : title = TextEditingController(text: title);

  final TextEditingController title;
  final List<_EditItem> items;
}

class _EditItem {
  _EditItem({this.id, String text = '', this.category = 'other'})
    : text = TextEditingController(text: text);

  final String? id;
  final TextEditingController text;
  String category;
}

class _TemplateEditorScreen extends StatefulWidget {
  const _TemplateEditorScreen({
    required this.organizationId,
    required this.service,
    this.template,
  });

  final String organizationId;
  final InspectionService service;
  final InspectionTemplate? template;

  @override
  State<_TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<_TemplateEditorScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.template?.name ?? '',
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.template?.description ?? '',
  );
  late InspectionKind _kind = widget.template?.kind ?? InspectionKind.other;
  late final List<_EditSection> _sections = [
    for (final section
        in widget.template?.sections ?? const <TemplateSection>[])
      _EditSection(section.title, [
        for (final item in section.items)
          _EditItem(
            id: item.id,
            text: item.text,
            category: item.hazardCategory,
          ),
      ]),
  ];
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (_sections.isEmpty) _sections.add(_EditSection('', [_EditItem()]));
  }

  Future<void> _pickCategory(_EditItem item) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: ChoiceList<String>(
            label: 'A "Not OK" on this item is filed as',
            items: [
              for (final category in HazardCategory.values)
                ChoiceItem(
                  value: category.id,
                  title: category.label,
                  badge: category.emoji,
                  color: category.color,
                ),
            ],
            selected: item.category,
            allowDeselect: false,
            onChanged: (value) => Navigator.of(context).pop(value),
          ),
        ),
      ),
    );
    if (picked != null) setState(() => item.category = picked);
  }

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await widget.service.saveTemplate(
        organizationId: widget.organizationId,
        templateId: widget.template?.id,
        name: _name.text.trim(),
        kind: _kind,
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        active: widget.template?.isActive ?? true,
        sections: [
          for (final section in _sections)
            TemplateSection(
              title: section.title.text.trim(),
              items: [
                for (final item in section.items)
                  if (item.text.text.trim().isNotEmpty)
                    TemplateItem(
                      id: item.id ?? '',
                      text: item.text.text.trim(),
                      hazardCategory: item.category,
                    ),
              ],
            ),
        ],
      );
      if (mounted) Navigator.of(context).pop();
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            title: widget.template == null ? 'New checklist' : 'Edit checklist',
            subtitle: 'Changes apply to inspections started from now on.',
            icon: Icons.edit_note,
            color: AppColors.inspections,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.md),
            AuthErrorBanner(message: _errorMessage!),
          ],
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _description,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          ChoiceList<InspectionKind>(
            label: 'Type',
            items: [
              for (final kind in InspectionKind.values)
                ChoiceItem(
                  value: kind,
                  title: kind.label,
                  icon: kind.icon,
                  color: kind.color,
                ),
            ],
            selected: _kind,
            allowDeselect: false,
            onChanged: (value) {
              if (value != null) setState(() => _kind = value);
            },
          ),
          for (final (sectionIndex, section) in _sections.indexed) ...[
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: section.title,
                    style: AppTextStyles.titleLarge,
                    decoration: InputDecoration(
                      labelText: 'Section ${sectionIndex + 1} title',
                    ),
                  ),
                ),
                if (_sections.length > 1)
                  IconButton(
                    tooltip: 'Remove section',
                    onPressed: () =>
                        setState(() => _sections.removeAt(sectionIndex)),
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            for (final (itemIndex, item) in section.items.indexed)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: item.text,
                            minLines: 1,
                            maxLines: 3,
                            decoration: InputDecoration(
                              labelText: 'Item ${itemIndex + 1}',
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => _pickCategory(item),
                            icon: Text(
                              (HazardCategory.tryFromId(item.category) ??
                                      HazardCategory.other)
                                  .emoji,
                            ),
                            label: Text(
                              'Filed as: '
                              '${(HazardCategory.tryFromId(item.category) ?? HazardCategory.other).label}',
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (section.items.length > 1)
                      IconButton(
                        tooltip: 'Remove item',
                        onPressed: () =>
                            setState(() => section.items.removeAt(itemIndex)),
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => section.items.add(_EditItem())),
                icon: const Icon(Icons.add),
                label: const Text('Add item'),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: () =>
                setState(() => _sections.add(_EditSection('', [_EditItem()]))),
            icon: const Icon(Icons.playlist_add),
            label: const Text('Add section'),
          ),
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: AppSpacing.minTouchTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.inspections,
                foregroundColor: Colors.white,
              ),
              onPressed: _isSaving ? null : _save,
              child: const Text('Save checklist'),
            ),
          ),
        ],
      ),
    );
  }
}
