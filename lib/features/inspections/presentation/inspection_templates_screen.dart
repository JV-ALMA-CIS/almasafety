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
import '../../../core/services/firestore_service.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../../organizations/domain/site.dart';
import '../data/inspection_repository.dart';
import '../data/inspection_service.dart';
import '../domain/checklist_text.dart';
import '../domain/inspection.dart';
import 'inspection_style.dart';

/// The inspection checklists (Site Manager/Admin): install the standard
/// ones from the Safety Plan, switch any on or off, edit them, choose which
/// sites each is used at, or create a new one (e.g. for a kind of work
/// only some sites do). Editing never changes past inspections — each
/// keeps the items it was started with.
class InspectionTemplatesScreen extends StatefulWidget {
  const InspectionTemplatesScreen({
    super.key,
    required this.organizationId,
    required this.repository,
    required this.service,
    this.siteRepository,
  });

  final String organizationId;
  final InspectionRepository repository;
  final InspectionService service;

  /// Injected in tests.
  final SiteRepository? siteRepository;

  @override
  State<InspectionTemplatesScreen> createState() =>
      _InspectionTemplatesScreenState();
}

class _InspectionTemplatesScreenState extends State<InspectionTemplatesScreen> {
  late final SiteRepository _sites =
      widget.siteRepository ??
      SiteRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organizationId,
      );
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

  Future<void> _edit(
    InspectionTemplate? template, {
    InspectionTemplate? copyFrom,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _TemplateEditorScreen(
          organizationId: widget.organizationId,
          service: widget.service,
          sites: _sites,
          template: template,
          copyFrom: copyFrom,
        ),
      ),
    );
  }

  Future<void> _openLibrary() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChecklistLibraryScreen(
          organizationId: widget.organizationId,
          service: widget.service,
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
          return LiveStreamBuilder<List<Site>>(
            streamKey: _sites,
            stream: () => _sites.watchAll(),
            builder: (context, siteSnapshot) {
              final siteNames = {
                for (final site in siteSnapshot.data ?? const <Site>[])
                  site.id: site.name,
              };
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
                      onPressed: _isSaving ? null : _openLibrary,
                      icon: const Icon(Icons.library_add),
                      label: const Text('Checklist library'),
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
                        AccentDetail(
                          icon: Icons.location_city,
                          text: template.siteIds.isEmpty
                              ? 'Used at: all sites'
                              : 'Used at: '
                                    '${template.siteIds.map((id) => siteNames[id] ?? 'Unknown site').join(', ')}',
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
                          label: 'Duplicate',
                          icon: Icons.copy,
                          color: AppColors.inspections,
                          outlined: true,
                          onPressed: () => _edit(null, copyFrom: template),
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
                                    siteIds: template.siteIds,
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
    required this.sites,
    this.template,
    this.copyFrom,
  });

  final String organizationId;
  final InspectionService service;
  final SiteRepository sites;

  /// The checklist being edited; null for a new one.
  final InspectionTemplate? template;

  /// For a new checklist: one to start from (Duplicate).
  final InspectionTemplate? copyFrom;

  @override
  State<_TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<_TemplateEditorScreen> {
  late final InspectionTemplate? _source = widget.template ?? widget.copyFrom;
  late final bool _isCopy = widget.template == null && widget.copyFrom != null;
  late final TextEditingController _name = TextEditingController(
    text: _isCopy ? 'Copy of ${_source!.name}' : _source?.name ?? '',
  );
  late final TextEditingController _description = TextEditingController(
    text: _source?.description ?? '',
  );
  late InspectionKind _kind = _source?.kind ?? InspectionKind.other;

  /// Empty = used at every site.
  late final Set<String> _siteIds = {...?widget.template?.siteIds};
  late final List<_EditSection> _sections = [
    for (final section in _source?.sections ?? const <TemplateSection>[])
      _EditSection(section.title, [
        for (final item in section.items)
          _EditItem(
            // A copy gets fresh item ids.
            id: _isCopy ? null : item.id,
            text: item.text,
            category: item.hazardCategory,
          ),
      ]),
  ];

  /// Adds the sections typed or pasted in [_PasteDialog]. Replaces the
  /// form's sections when they are still empty.
  Future<void> _paste() async {
    final sections = await showDialog<List<TemplateSection>>(
      context: context,
      builder: (_) => const _PasteDialog(),
    );
    if (sections == null || sections.isEmpty || !mounted) return;
    setState(() {
      final untouched = _sections.every(
        (s) =>
            s.title.text.trim().isEmpty &&
            s.items.every((i) => i.text.text.trim().isEmpty),
      );
      if (untouched) _sections.clear();
      for (final section in sections) {
        _sections.add(
          _EditSection(section.title, [
            for (final item in section.items)
              _EditItem(text: item.text, category: item.hazardCategory),
          ]),
        );
      }
    });
  }

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
        siteIds: _siteIds.toList(),
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
            title: widget.template != null
                ? 'Edit checklist'
                : _isCopy
                ? 'Duplicate checklist'
                : 'New checklist',
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
          const SizedBox(height: AppSpacing.md),
          const FeatureSectionTitle(
            title: 'Used at',
            icon: Icons.location_city,
            color: AppColors.projects,
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Every site, or only the sites doing this kind of work.',
            style: AppTextStyles.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          ChoiceTile(
            title: 'All sites',
            icon: Icons.domain,
            color: AppColors.projects,
            selected: _siteIds.isEmpty,
            onTap: () => setState(_siteIds.clear),
          ),
          const SizedBox(height: AppSpacing.sm),
          LiveStreamBuilder<List<Site>>(
            streamKey: widget.sites,
            stream: () => widget.sites.watchAll(),
            builder: (context, snapshot) {
              // Open sites, plus any closed one already chosen.
              final sites = [
                for (final site in snapshot.data ?? const <Site>[])
                  if (site.status == OrganizationRecordStatus.active ||
                      _siteIds.contains(site.id))
                    site,
              ]..sort((a, b) => a.name.compareTo(b.name));
              return MultiChoiceList<String>(
                items: [
                  for (final site in sites)
                    ChoiceItem(
                      value: site.id,
                      title: site.name,
                      subtitle: site.location,
                      badge: site.code,
                    ),
                ],
                selected: _siteIds,
                onChanged: (value) => setState(() {
                  _siteIds
                    ..clear()
                    ..addAll(value);
                }),
              );
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: _paste,
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste a list'),
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Paste or type a whole checklist at once — e.g. copied from a '
            'Word or PDF checklist.',
            style: AppTextStyles.bodyMedium,
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

/// Paste or type a checklist: one item per line; a line starting with "#"
/// or ending with ":" starts a new section. Pops the parsed sections.
class _PasteDialog extends StatefulWidget {
  const _PasteDialog();

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sections = parseChecklistText(_text.text);
    final itemCount = sections.fold(0, (n, s) => n + s.items.length);
    return AlertDialog(
      title: const Text('Paste a list'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'One item per line. A line ending with ":" (or starting '
                'with "#") starts a new section. Bullets and numbers are '
                'removed, and each item\'s hazard category is guessed — you '
                'can change it afterwards.',
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _text,
                minLines: 8,
                maxLines: 16,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText:
                      'Scaffolds:\n'
                      '- Scaffold tagged by a competent person\n'
                      '- Guardrails on open sides\n'
                      'Electrical:\n'
                      '- GFCI on temporary power',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '$itemCount item${itemCount == 1 ? '' : 's'} in '
                '${sections.length} section${sections.length == 1 ? '' : 's'}',
                style: AppTextStyles.bodyMedium,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: itemCount == 0
              ? null
              : () => Navigator.of(context).pop(sections),
          child: const Text('Add to checklist'),
        ),
      ],
    );
  }
}

/// The checklist library: the standard checklists, each added on its own
/// (then limited to the sites doing that work under "Used at").
class ChecklistLibraryScreen extends StatefulWidget {
  const ChecklistLibraryScreen({
    super.key,
    required this.organizationId,
    required this.service,
  });

  final String organizationId;
  final InspectionService service;

  @override
  State<ChecklistLibraryScreen> createState() => _ChecklistLibraryScreenState();
}

class _ChecklistLibraryScreenState extends State<ChecklistLibraryScreen> {
  late Future<List<StandardChecklist>> _library = _load();
  String? _adding;
  String? _errorMessage;

  Future<List<StandardChecklist>> _load() =>
      widget.service.listStandardTemplates(widget.organizationId);

  Future<void> _add(StandardChecklist checklist) async {
    setState(() {
      _adding = checklist.key;
      _errorMessage = null;
    });
    try {
      await widget.service.installDefaultTemplates(
        widget.organizationId,
        keys: [checklist.key],
      );
      if (!mounted) return;
      setState(() {
        _library = _load();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '"${checklist.name}" added. Open it under Checklists to choose '
            'the sites it is used at.',
          ),
        ),
      );
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _adding = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: FutureBuilder<List<StandardChecklist>>(
        future: _library,
        builder: (context, snapshot) {
          final library = snapshot.data ?? const <StandardChecklist>[];
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              const FeatureHeader(
                title: 'Checklist library',
                subtitle:
                    'Ready-made checklists for common kinds of work. Add the '
                    'ones you need, limit each to the sites doing that work, '
                    'and edit them to match your own.',
                icon: Icons.library_add,
                color: AppColors.inspections,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.md),
                AuthErrorBanner(message: _errorMessage!),
              ],
              const SizedBox(height: AppSpacing.md),
              if (snapshot.connectionState != ConnectionState.done)
                const Center(child: CircularProgressIndicator())
              else if (snapshot.hasError)
                const Text(
                  'Could not load the library. Please try again.',
                  style: AppTextStyles.bodyMedium,
                ),
              for (final checklist in library) ...[
                AccentCard(
                  color: checklist.kind.color,
                  icon: checklist.kind.icon,
                  title: checklist.name,
                  body: checklist.description,
                  badges: [
                    if (checklist.installed)
                      const AccentBadge(
                        label: 'Added',
                        color: AppColors.success,
                      ),
                    if (checklist.core)
                      const AccentBadge(
                        label: 'General',
                        color: AppColors.inspections,
                      ),
                  ],
                  details: [
                    AccentDetail(
                      icon: Icons.checklist,
                      text:
                          '${checklist.kind.label} · '
                          '${checklist.itemCount} items',
                    ),
                  ],
                  actions: [
                    if (!checklist.installed)
                      AccentButton(
                        label: _adding == checklist.key ? 'Adding…' : 'Add',
                        icon: Icons.add,
                        color: AppColors.inspections,
                        onPressed: _adding == null
                            ? () => _add(checklist)
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          );
        },
      ),
    );
  }
}
