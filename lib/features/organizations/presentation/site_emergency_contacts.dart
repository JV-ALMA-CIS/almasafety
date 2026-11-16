import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/organization_admin_service.dart';
import '../data/site_repository.dart';
import '../domain/site.dart';
import '../domain/site_emergency_info.dart';
import '../../../core/widgets/mobile_title.dart';

/// Calls [number] with the phone's dialler. Injected in tests.
typedef PhoneCaller = Future<void> Function(String number);

Future<void> _dial(String number) async {
  final uri = Uri(scheme: 'tel', path: number.replaceAll(' ', ''));
  try {
    await launchUrl(uri);
  } on Object {
    // No dialler (e.g. a desktop browser): the number is on screen anyway.
  }
}

/// A site's emergency contacts as a bright red card: tap-to-call numbers
/// (ambulance first), the clinic, the assembly point, the first-aid kit and
/// the first-aiders. With nothing set it says so — and [onEdit], when given
/// (Site Managers/Admins), adds or changes them.
class EmergencyContactsCard extends StatelessWidget {
  const EmergencyContactsCard({
    super.key,
    required this.siteName,
    required this.info,
    this.onEdit,
    this.call,
  });

  final String siteName;
  final SiteEmergencyInfo? info;
  final VoidCallback? onEdit;
  final PhoneCaller? call;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    const color = AppColors.stop;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.08),
          Theme.of(context).colorScheme.surface,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.emergency, color: color),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'In an emergency — $siteName',
                  style: AppTextStyles.bodyLarge.copyWith(
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
              if (onEdit != null)
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit, size: 18),
                  label: Text(info == null ? 'Add' : 'Edit'),
                ),
            ],
          ),
          if (info == null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                onEdit != null
                    ? 'No emergency contacts yet. Add the nearest clinic, '
                          'ambulance and emergency numbers, the assembly point '
                          'and the first-aiders.'
                    : 'No emergency contacts set for this site yet — ask '
                          'your Site Manager.',
                style: AppTextStyles.bodyMedium,
              ),
            )
          else ...[
            if (info.callList.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final entry in info.callList)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: color,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => (call ?? _dial)(entry.number),
                      icon: const Icon(Icons.call, size: 18),
                      label: Text('${entry.label}: ${entry.number}'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            if (info.clinicName != null || info.clinicAddress != null)
              _Line(
                icon: Icons.local_hospital,
                text: [?info.clinicName, ?info.clinicAddress].join(' — '),
              ),
            if (info.assemblyPoint != null)
              _Line(
                icon: Icons.flag,
                text: 'Assembly point: ${info.assemblyPoint}',
              ),
            if (info.firstAidKitLocation != null)
              _Line(
                icon: Icons.medical_services,
                text: 'First-aid kit: ${info.firstAidKitLocation}',
              ),
            if (info.firstAiders.isNotEmpty)
              _Line(
                icon: Icons.health_and_safety,
                text: 'First-aiders: ${info.firstAiders.join(', ')}',
              ),
            if (info.notes != null)
              _Line(icon: Icons.info_outline, text: info.notes!),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.stop),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

/// [EmergencyContactsCard] for one site, loaded live by id (so it works for
/// Workers and Foremen, who can read only their own sites). Shows nothing
/// if the site cannot be loaded.
class SiteEmergencyContacts extends StatelessWidget {
  const SiteEmergencyContacts({
    super.key,
    required this.organizationId,
    required this.siteId,
    this.siteRepository,
    this.onEdit,
  });

  final String organizationId;
  final String siteId;

  /// Injected in tests.
  final SiteRepository? siteRepository;

  /// For Site Managers/Admins: opens the editor for the site.
  final void Function(Site site)? onEdit;

  Stream<List<Site>> _watch() {
    try {
      return (siteRepository ??
              SiteRepository(
                firestoreService: FirestoreService(),
                organizationId: organizationId,
              ))
          .watchByIds([siteId]);
    } on Object catch (e) {
      return Stream.error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LiveStreamBuilder<List<Site>>(
      streamKey: (organizationId, siteId),
      stream: _watch,
      builder: (context, snapshot) {
        final sites = snapshot.data ?? const <Site>[];
        if (snapshot.hasError || sites.isEmpty) return const SizedBox.shrink();
        final site = sites.first;
        return EmergencyContactsCard(
          siteName: site.name,
          info: site.emergency,
          onEdit: onEdit == null ? null : () => onEdit!(site),
        );
      },
    );
  }
}

/// Opens [SiteEmergencyEditorScreen] for [site].
Future<void> openSiteEmergencyEditor(
  BuildContext context, {
  required String organizationId,
  required Site site,
  OrganizationAdminService? service,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => SiteEmergencyEditorScreen(
        organizationId: organizationId,
        site: site,
        service: service,
      ),
    ),
  );
}

/// Edits a site's emergency contacts (Site Manager/Admin).
class SiteEmergencyEditorScreen extends StatefulWidget {
  const SiteEmergencyEditorScreen({
    super.key,
    required this.organizationId,
    required this.site,
    this.service,
  });

  final String organizationId;
  final Site site;

  /// Injected in tests.
  final OrganizationAdminService? service;

  @override
  State<SiteEmergencyEditorScreen> createState() =>
      _SiteEmergencyEditorScreenState();
}

class _SiteEmergencyEditorScreenState extends State<SiteEmergencyEditorScreen> {
  late final SiteEmergencyInfo _start =
      widget.site.emergency ?? const SiteEmergencyInfo();
  late final _clinicName = TextEditingController(text: _start.clinicName);
  late final _clinicAddress = TextEditingController(text: _start.clinicAddress);
  late final _clinicPhones = TextEditingController(
    text: _start.clinicPhones.join('\n'),
  );
  late final _ambulance = TextEditingController(text: _start.ambulancePhone);
  late final _other = TextEditingController(
    text: [
      for (final n in _start.otherNumbers) '${n.label}: ${n.number}',
    ].join('\n'),
  );
  late final _assembly = TextEditingController(text: _start.assemblyPoint);
  late final _firstAidKit = TextEditingController(
    text: _start.firstAidKitLocation,
  );
  late final _firstAiders = TextEditingController(
    text: _start.firstAiders.join('\n'),
  );
  late final _notes = TextEditingController(text: _start.notes);
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void dispose() {
    for (final c in [
      _clinicName,
      _clinicAddress,
      _clinicPhones,
      _ambulance,
      _other,
      _assembly,
      _firstAidKit,
      _firstAiders,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _value(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  List<String> _lines(TextEditingController c) => [
    for (final line in c.text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  /// "Label: number" per line; a line without a colon is just a number.
  List<EmergencyNumber> _otherNumbers() => [
    for (final line in _lines(_other))
      if (line.contains(':'))
        EmergencyNumber(
          label: line.substring(0, line.lastIndexOf(':')).trim(),
          number: line.substring(line.lastIndexOf(':') + 1).trim(),
        )
      else
        EmergencyNumber(label: 'Emergency', number: line),
  ];

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await (widget.service ?? OrganizationAdminService())
          .updateSiteEmergencyInfo(
            widget.organizationId,
            widget.site.id,
            SiteEmergencyInfo(
              clinicName: _value(_clinicName),
              clinicAddress: _value(_clinicAddress),
              clinicPhones: _lines(_clinicPhones),
              ambulancePhone: _value(_ambulance),
              otherNumbers: _otherNumbers(),
              assemblyPoint: _value(_assembly),
              firstAidKitLocation: _value(_firstAidKit),
              firstAiders: _lines(_firstAiders),
              notes: _value(_notes),
            ),
          );
      if (mounted) Navigator.of(context).pop();
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool multiline = false,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: TextField(
        controller: controller,
        minLines: multiline ? 2 : 1,
        maxLines: multiline ? 6 : 1,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: multiline ? 'One per line' : null,
          alignLabelWithHint: multiline,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Emergency Contacts')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            title: 'Emergency contacts',
            subtitle:
                '${widget.site.name} — shown to everyone on this site, with '
                'numbers they can tap to call.',
            icon: Icons.emergency,
            color: AppColors.stop,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.md),
            AuthErrorBanner(message: _errorMessage!),
          ],
          const SizedBox(height: AppSpacing.md),
          const FeatureSectionTitle(
            title: 'Medical help',
            icon: Icons.local_hospital,
            color: AppColors.stop,
          ),
          const SizedBox(height: AppSpacing.sm),
          _field(_ambulance, 'Ambulance number', keyboard: TextInputType.phone),
          _field(_clinicName, 'Nearest clinic / hospital'),
          _field(_clinicAddress, 'Its address'),
          _field(
            _clinicPhones,
            'Its phone numbers',
            multiline: true,
            keyboard: TextInputType.phone,
          ),
          _field(
            _other,
            'Other emergency numbers',
            hint: 'Fire brigade: 999\nPolice: 999',
            multiline: true,
          ),
          const SizedBox(height: AppSpacing.sm),
          const FeatureSectionTitle(
            title: 'On site',
            icon: Icons.location_city,
            color: AppColors.stop,
          ),
          const SizedBox(height: AppSpacing.sm),
          _field(_assembly, 'Assembly point', hint: 'e.g. Main gate'),
          _field(_firstAidKit, 'First-aid kit location'),
          _field(_firstAiders, 'Trained first-aiders', multiline: true),
          _field(_notes, 'Anything else (optional)', multiline: true),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: AppSpacing.minTouchTarget,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.stop,
                foregroundColor: Colors.white,
              ),
              onPressed: _isSaving ? null : _save,
              icon: const Icon(Icons.save),
              label: const Text('Save emergency contacts'),
            ),
          ),
        ],
      ),
    );
  }
}
