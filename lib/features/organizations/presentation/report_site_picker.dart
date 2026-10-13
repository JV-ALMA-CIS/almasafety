import 'package:flutter/material.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/domain/app_role.dart';
import '../data/site_repository.dart';
import '../domain/organization_record_status.dart';
import '../domain/site.dart';
import 'site_select_list.dart';

/// The sites [role] may file a report (hazard, near-miss, incident) at —
/// matching `functions/src/hazard_callable.ts`'s `requireReporterAtSite`:
/// every site of the organization for the System Administrator and an
/// org-wide role (Admin/Site Manager), otherwise only [assignedSiteIds].
///
/// Returns null when [role] may report at every site.
List<String>? reportableSiteIds({
  required bool isPlatformAdministrator,
  required AppRole? role,
  required List<String> assignedSiteIds,
}) {
  if (isPlatformAdministrator ||
      role == AppRole.admin ||
      role == AppRole.siteManager) {
    return null;
  }
  return assignedSiteIds;
}

/// The "Site" choice on a report form: loads the sites the reporter may
/// report at and shows them as a [SiteSelectList] (own colour and code per
/// site; tap the chosen one again to unselect). With a single site it is
/// chosen automatically, so nobody is asked a question with one answer.
///
/// Only OPEN sites are offered: a switched-off site (e.g. its project is
/// finished) is left out, unless it is the one already chosen.
class ReportSitePicker extends StatefulWidget {
  const ReportSitePicker({
    super.key,
    required this.organizationId,
    required this.siteIds,
    required this.selectedSiteId,
    required this.onChanged,
    this.siteRepository,
  });

  final String organizationId;

  /// The sites to offer, or null for every site of the organization — see
  /// [reportableSiteIds].
  final List<String>? siteIds;
  final String? selectedSiteId;

  /// Called with the chosen site's id, or null when it is unselected.
  final ValueChanged<String?> onChanged;

  /// Injected in tests.
  final SiteRepository? siteRepository;

  @override
  State<ReportSitePicker> createState() => _ReportSitePickerState();
}

class _ReportSitePickerState extends State<ReportSitePicker> {
  late Stream<List<Site>> _sites = _watch();

  Stream<List<Site>> _watch() {
    try {
      return _watchSites();
    } on Object catch (e) {
      // e.g. no Firebase connection — shown as "Could not load your sites"
      // rather than breaking the whole form.
      return Stream.error(e);
    }
  }

  Stream<List<Site>> _watchSites() {
    final repository =
        widget.siteRepository ??
        SiteRepository(
          firestoreService: FirestoreService(),
          organizationId: widget.organizationId,
        );
    final ids = widget.siteIds;
    return ids == null ? repository.watchAll() : repository.watchByIds(ids);
  }

  @override
  void didUpdateWidget(ReportSitePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.organizationId != widget.organizationId) {
      _sites = _watch();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Site>>(
      stream: _sites,
      builder: (context, snapshot) {
        final sites = [
          for (final site in snapshot.data ?? const <Site>[])
            if (site.status == OrganizationRecordStatus.active ||
                site.id == widget.selectedSiteId)
              site,
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        if (snapshot.hasError) {
          return const Text(
            'Could not load your sites. Please try again.',
            style: AppTextStyles.bodyMedium,
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting &&
            sites.isEmpty) {
          return const LinearProgressIndicator();
        }
        if (sites.isEmpty) {
          return const Text(
            'There are no sites to report at yet.',
            style: AppTextStyles.bodyMedium,
          );
        }
        if (sites.length == 1 && widget.selectedSiteId != sites.single.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onChanged(sites.single.id);
          });
        }
        return SiteSelectList(
          sites: sites,
          selectedSiteId: widget.selectedSiteId,
          onChanged: widget.onChanged,
        );
      },
    );
  }
}
