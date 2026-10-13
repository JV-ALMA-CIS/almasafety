import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/choice_list.dart';
import '../../../core/widgets/feature_header.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/domain/membership.dart';
import '../../authentication/domain/organization_user.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/presentation/report_site_picker.dart';
import '../data/safety_meeting_service.dart';
import '../domain/safety_meeting.dart';
import 'safety_meeting_style.dart';

/// Loads the organization's people for the attendee list. Injected in
/// tests.
typedef PeopleLoader =
    Future<List<OrganizationUser>> Function(String organizationId);

/// Records a weekly employee or monthly supervisory safety meeting after it
/// has been held: when, which site, the subjects covered (the Safety Plan's
/// checklist, plus any others), who attended, concerns and notes. The person
/// recording it is the facilitator. Pops `true` once recorded.
class RecordSafetyMeetingScreen extends StatefulWidget {
  const RecordSafetyMeetingScreen({
    super.key,
    required this.organizationId,
    required this.kind,
    this.service,
    this.siteRepository,
    this.loadPeople,
    this.now,
  });

  final String organizationId;
  final SafetyMeetingKind kind;

  /// Injected in tests.
  final SafetyMeetingService? service;
  final SiteRepository? siteRepository;
  final PeopleLoader? loadPeople;
  final DateTime Function()? now;

  @override
  State<RecordSafetyMeetingScreen> createState() =>
      _RecordSafetyMeetingScreenState();
}

class _RecordSafetyMeetingScreenState extends State<RecordSafetyMeetingScreen> {
  late final SafetyMeetingService _service =
      widget.service ?? SafetyMeetingService();
  late final DateTime _today = _dayOf((widget.now ?? DateTime.now)());
  late DateTime _date = _today;
  late final Future<List<OrganizationUser>> _people =
      (widget.loadPeople ??
              (id) => AccountApprovalService().listUsers(organizationId: id))(
            widget.organizationId,
          )
          .catchError((Object _) => const <OrganizationUser>[]);

  /// For a monthly supervisory meeting: true = every site.
  bool _allSites = true;
  String? _siteId;
  final Set<String> _topics = {};
  final List<String> _extraTopics = [];
  final Set<String> _attendees = {};
  bool _showEveryone = false;
  final List<String> _otherAttendees = [];
  final List<String> _concerns = [];
  final _notes = TextEditingController();
  bool _isSaving = false;
  String? _errorMessage;

  bool get _isMonthly => widget.kind == SafetyMeetingKind.monthlySupervisory;
  String? get _effectiveSiteId => _isMonthly && _allSites ? null : _siteId;
  bool get _hasSite => _isMonthly && _allSites || _siteId != null;
  int get _attendeeCount => _attendees.length + _otherAttendees.length;

  /// What is still needed before the meeting can be recorded.
  List<String> get _missing => [
    if (!_hasSite) 'choose the site',
    if (_topics.isEmpty && _extraTopics.isEmpty) 'tick at least one subject',
    if (_attendeeCount == 0) 'add who attended',
  ];
  bool get _canSave => _missing.isEmpty && !_isSaving;

  static DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: _today.subtract(const Duration(days: 31)),
      lastDate: _today,
    );
    if (picked != null) setState(() => _date = _dayOf(picked));
  }

  Future<void> _save() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Record this meeting?'),
        content: Text(
          '${widget.kind.label} on ${formatMeetingDay(_date)}, '
          '$_attendeeCount attended. A recorded meeting is part of the '
          "safety record and can't be changed afterwards.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Check again'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Record'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final notes = _notes.text.trim();
      await _service.record(
        organizationId: widget.organizationId,
        kind: widget.kind,
        siteId: _effectiveSiteId,
        date: _date,
        topics: [
          for (final topic in widget.kind.defaultTopics)
            if (_topics.contains(topic)) topic,
          ..._extraTopics,
        ],
        attendeeUids: _attendees.toList(),
        otherAttendees: _otherAttendees,
        concerns: _concerns,
        notes: notes.isEmpty ? null : notes,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Whether [person] is offered as an attendee by default: for the weekly
  /// meeting, people at the chosen site (plus the org-wide managers); for
  /// the supervisory one, the supervisory roles.
  bool _isSuggested(OrganizationUser person) {
    final role = person.role;
    final isManager = role == AppRole.admin || role == AppRole.siteManager;
    if (_isMonthly) return isManager || role == AppRole.foreman;
    final siteId = _siteId;
    return isManager || (siteId != null && person.siteIds.contains(siteId));
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final myUid = session.profile?.uid;
    final color = widget.kind.color;
    final siteIds = reportableSiteIds(
      isPlatformAdministrator:
          session.profile?.isPlatformAdministrator ?? false,
      role: session.activeMembership?.role,
      assignedSiteIds: session.activeMembership?.siteIds ?? const [],
    );

    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        children: [
          FeatureHeader(
            title: 'Record ${widget.kind.label.toLowerCase()}',
            subtitle:
                '${widget.kind.schedule} · ${widget.kind.audience}. You are '
                'recorded as the person who ran it.',
            icon: widget.kind.icon,
            color: color,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.md),
            AuthErrorBanner(message: _errorMessage!),
          ],

          // ---- When ----
          const SizedBox(height: AppSpacing.md),
          FeatureSectionTitle(
            title: 'When was it held?',
            icon: Icons.event,
            color: color,
          ),
          const SizedBox(height: AppSpacing.sm),
          ChoiceTile(
            title: formatMeetingDay(_date),
            subtitle: _date == _today
                ? 'Today · tap to change'
                : 'Tap to change',
            icon: Icons.event,
            color: color,
            selected: true,
            onTap: _pickDate,
          ),

          // ---- Where ----
          const SizedBox(height: AppSpacing.md),
          const FeatureSectionTitle(
            title: 'Site',
            icon: Icons.location_city,
            color: AppColors.projects,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_isMonthly) ...[
            ChoiceTile(
              title: 'All sites',
              subtitle: 'Supervisors from every site',
              icon: Icons.domain,
              color: AppColors.projects,
              selected: _allSites,
              onTap: () => setState(() => _allSites = true),
            ),
            ChoiceTile(
              title: 'One site',
              icon: Icons.location_city,
              color: AppColors.projects,
              selected: !_allSites,
              onTap: () => setState(() => _allSites = false),
            ),
          ],
          if (!_isMonthly || !_allSites) ...[
            if (_isMonthly) const SizedBox(height: AppSpacing.sm),
            ReportSitePicker(
              organizationId: widget.organizationId,
              siteIds: siteIds,
              selectedSiteId: _siteId,
              onChanged: (id) => setState(() => _siteId = id),
              siteRepository: widget.siteRepository,
            ),
          ],

          // ---- Subjects ----
          const SizedBox(height: AppSpacing.md),
          FeatureSectionTitle(
            title: 'Subjects covered',
            icon: Icons.checklist,
            color: color,
            count: _topics.length + _extraTopics.length,
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Tap each subject you talked about.',
            style: AppTextStyles.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          MultiChoiceList<String>(
            items: [
              for (final topic in widget.kind.defaultTopics)
                ChoiceItem(
                  value: topic,
                  title: topic,
                  icon: Icons.record_voice_over,
                  color: color,
                ),
            ],
            selected: _topics,
            searchThreshold: 1000,
            onChanged: (value) => setState(() {
              _topics
                ..clear()
                ..addAll(value);
            }),
          ),
          _EntryList(
            entries: _extraTopics,
            icon: Icons.add_comment,
            color: color,
            hint: 'Another subject',
            addLabel: 'Add subject',
            onChanged: () => setState(() {}),
          ),

          // ---- Attendees ----
          const SizedBox(height: AppSpacing.md),
          FeatureSectionTitle(
            title: 'Who attended?',
            icon: Icons.groups,
            color: AppColors.people,
            count: _attendeeCount,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (!_isMonthly && _siteId == null)
            const Text(
              'Choose the site first to see its people.',
              style: AppTextStyles.bodyMedium,
            )
          else
            FutureBuilder<List<OrganizationUser>>(
              future: _people,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final everyone = [
                  for (final person
                      in snapshot.data ?? const <OrganizationUser>[])
                    if (person.uid != myUid &&
                        person.organizationId != null &&
                        person.organizationId == widget.organizationId &&
                        person.membershipStatus != MembershipStatus.suspended)
                      person,
                ]..sort((a, b) => a.name.compareTo(b.name));
                final shown = [
                  for (final person in everyone)
                    if (_showEveryone ||
                        _isSuggested(person) ||
                        _attendees.contains(person.uid))
                      person,
                ];
                final hidden = everyone.length - shown.length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (shown.isEmpty)
                      const Text(
                        'Nobody to list here — add people below by name.',
                        style: AppTextStyles.bodyMedium,
                      )
                    else ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() {
                            final uids = shown.map((p) => p.uid);
                            if (uids.every(_attendees.contains)) {
                              _attendees.removeAll(uids);
                            } else {
                              _attendees.addAll(uids);
                            }
                          }),
                          icon: const Icon(Icons.done_all),
                          label: Text(
                            shown.every((p) => _attendees.contains(p.uid))
                                ? 'Clear all'
                                : 'Everyone listed attended',
                          ),
                        ),
                      ),
                      MultiChoiceList<String>(
                        items: [
                          for (final person in shown)
                            ChoiceItem(
                              value: person.uid,
                              title: person.name.trim().isEmpty
                                  ? 'Unknown person'
                                  : person.name,
                              subtitle: [
                                if (person.role != null) person.role!.label,
                                if (person.trade != null) person.trade!,
                              ].join(' · '),
                              icon: Icons.person,
                              color: AppColors.people,
                            ),
                        ],
                        selected: _attendees,
                        searchHint: 'Search by name',
                        onChanged: (value) => setState(() {
                          _attendees
                            ..clear()
                            ..addAll(value);
                        }),
                      ),
                    ],
                    if (hidden > 0)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() => _showEveryone = true),
                          icon: const Icon(Icons.person_search),
                          label: Text(
                            'Show $hidden more from the organization',
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'People without an account (visitors, subcontractors):',
            style: AppTextStyles.bodyMedium,
          ),
          _EntryList(
            entries: _otherAttendees,
            icon: Icons.person_add_alt,
            color: AppColors.people,
            hint: 'Name',
            addLabel: 'Add person',
            onChanged: () => setState(() {}),
          ),

          // ---- Concerns & notes ----
          const SizedBox(height: AppSpacing.md),
          const FeatureSectionTitle(
            title: 'Concerns raised',
            icon: Icons.report_problem,
            color: AppColors.hazards,
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Anything people raised. If something on site needs fixing, '
            'also report it with "Report a Safety Issue" so it is tracked.',
            style: AppTextStyles.bodyMedium,
          ),
          _EntryList(
            entries: _concerns,
            icon: Icons.report_problem,
            color: AppColors.hazards,
            hint: 'Concern',
            addLabel: 'Add concern',
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: 'Notes (optional)',
              alignLabelWithHint: true,
            ),
          ),

          const SizedBox(height: AppSpacing.md),
          if (_missing.isNotEmpty && !_isSaving)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                'To record it: ${_missing.join(', ')}.',
                style: AppTextStyles.bodyMedium,
              ),
            ),
          SizedBox(
            height: AppSpacing.minTouchTarget,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: color,
                foregroundColor: Colors.white,
              ),
              onPressed: _canSave ? _save : null,
              icon: const Icon(Icons.save),
              label: const Text('Record meeting'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A short list of typed entries (extra subjects, people without an
/// account, concerns): each shown with a remove button, plus a text box to
/// add another. Edits [entries] in place and calls [onChanged].
class _EntryList extends StatefulWidget {
  const _EntryList({
    required this.entries,
    required this.icon,
    required this.color,
    required this.hint,
    required this.addLabel,
    required this.onChanged,
  });

  final List<String> entries;
  final IconData icon;
  final Color color;
  final String hint;
  final String addLabel;
  final VoidCallback onChanged;

  @override
  State<_EntryList> createState() => _EntryListState();
}

class _EntryListState extends State<_EntryList> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    if (!widget.entries.contains(value)) widget.entries.add(value);
    _controller.clear();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in widget.entries)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: ChoiceTile(
              title: entry,
              icon: widget.icon,
              color: widget.color,
              selected: true,
              multi: true,
              trailingLabel: 'Remove',
              onTap: () {
                widget.entries.remove(entry);
                widget.onChanged();
              },
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  counterText: '',
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              height: AppSpacing.minTouchTarget,
              child: OutlinedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: Text(widget.addLabel),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
