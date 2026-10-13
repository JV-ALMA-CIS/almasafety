import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';

/// What an inspection is for — matching `inspection_callable.ts`'s `KINDS`.
enum InspectionKind {
  daily,
  weekly,
  environmental,
  welfare,
  other;

  String get id => name;

  String get label => switch (this) {
    InspectionKind.daily => 'Daily inspection',
    InspectionKind.weekly => 'Weekly walk-down',
    InspectionKind.environmental => 'Environmental check',
    InspectionKind.welfare => 'Welfare check',
    InspectionKind.other => 'Other inspection',
  };

  static InspectionKind fromId(String? id) => InspectionKind.values.firstWhere(
    (kind) => kind.id == id,
    orElse: () => InspectionKind.other,
  );
}

/// The answer to one checklist item.
enum InspectionResult {
  ok,
  notOk,
  na;

  String get id => name;

  String get label => switch (this) {
    InspectionResult.ok => 'OK',
    InspectionResult.notOk => 'Not OK',
    InspectionResult.na => 'N/A',
  };

  static InspectionResult? tryFromId(String? id) {
    for (final value in values) {
      if (value.id == id) return value;
    }
    return null;
  }
}

/// `inProgress → submitted → signedOff`.
enum InspectionStatus {
  inProgress,
  submitted,
  signedOff;

  String get id => name;

  String get label => switch (this) {
    InspectionStatus.inProgress => 'In progress',
    InspectionStatus.submitted => 'Awaiting sign-off',
    InspectionStatus.signedOff => 'Signed off',
  };

  static InspectionStatus? tryFromId(String? id) {
    for (final value in values) {
      if (value.id == id) return value;
    }
    return null;
  }
}

/// One checklist item of an inspection, with its answer.
class InspectionItem {
  const InspectionItem({
    required this.id,
    required this.section,
    required this.text,
    this.result,
    this.note,
    this.photoUrl,
    this.hazardId,
  });

  final String id;
  final String section;
  final String text;
  final InspectionResult? result;

  /// What is wrong — required for "Not OK".
  final String? note;
  final String? photoUrl;

  /// The deficiency (hazard) raised from this item on submission.
  final String? hazardId;

  static InspectionItem fromMap(Map<String, dynamic> data) => InspectionItem(
    id: data['id'] as String? ?? '',
    section: data['section'] as String? ?? '',
    text: data['text'] as String? ?? '',
    result: InspectionResult.tryFromId(data['result'] as String?),
    note: data['note'] as String?,
    photoUrl: data['photoUrl'] as String?,
    hazardId: data['hazardId'] as String?,
  );
}

/// One site inspection — the daily site inspection or weekly HSE walk-down
/// from the Safety Plan, stored at
/// `organizations/{organizationId}/inspections/{id}` with a snapshot of its
/// template's items. Written only through `inspection_callable.ts`.
class Inspection {
  const Inspection({
    required this.id,
    required this.organizationId,
    required this.siteId,
    required this.templateId,
    required this.templateName,
    required this.kind,
    required this.items,
    required this.status,
    required this.inspectorUid,
    this.siteName,
    this.inspectorName,
    this.okCount = 0,
    this.notOkCount = 0,
    this.naCount = 0,
    this.startedAt,
    this.submittedAt,
    this.signedOffByName,
    this.signedOffAt,
    this.signOffNote,
  });

  final String id;
  final String organizationId;
  final String siteId;
  final String? siteName;
  final String templateId;
  final String templateName;
  final InspectionKind kind;
  final List<InspectionItem> items;
  final InspectionStatus status;
  final String inspectorUid;
  final String? inspectorName;
  final int okCount;
  final int notOkCount;
  final int naCount;
  final DateTime? startedAt;
  final DateTime? submittedAt;
  final String? signedOffByName;
  final DateTime? signedOffAt;
  final String? signOffNote;

  int get answeredCount => items.where((item) => item.result != null).length;

  /// Items checked (OK + Not OK) — N/A doesn't count either way.
  int get checkedCount => okCount + notOkCount;

  factory Inspection.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That inspection could not be loaded.');
    }
    final status = InspectionStatus.tryFromId(data['status'] as String?);
    if (status == null) {
      throw const DataException('That inspection has an unrecognised status.');
    }
    return Inspection(
      id: doc.id,
      organizationId: data['organizationId'] as String? ?? '',
      siteId: data['siteId'] as String? ?? '',
      siteName: data['siteName'] as String?,
      templateId: data['templateId'] as String? ?? '',
      templateName: data['templateName'] as String? ?? 'Inspection',
      kind: InspectionKind.fromId(data['kind'] as String?),
      items: [
        for (final raw in (data['items'] as List?) ?? const [])
          if (raw is Map) InspectionItem.fromMap(raw.cast<String, dynamic>()),
      ],
      status: status,
      inspectorUid: data['inspectorUid'] as String? ?? '',
      inspectorName: data['inspectorName'] as String?,
      okCount: (data['okCount'] as num?)?.toInt() ?? 0,
      notOkCount: (data['notOkCount'] as num?)?.toInt() ?? 0,
      naCount: (data['naCount'] as num?)?.toInt() ?? 0,
      startedAt: (data['startedAt'] as Timestamp?)?.toDate(),
      submittedAt: (data['submittedAt'] as Timestamp?)?.toDate(),
      signedOffByName: data['signedOffByName'] as String?,
      signedOffAt: (data['signedOffAt'] as Timestamp?)?.toDate(),
      signOffNote: data['signOffNote'] as String?,
    );
  }
}

/// One item of a template.
class TemplateItem {
  const TemplateItem({
    required this.id,
    required this.text,
    this.hazardCategory = 'other',
  });

  final String id;
  final String text;

  /// The hazard category its deficiency is filed under.
  final String hazardCategory;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'hazardCategory': hazardCategory,
  };
}

/// A titled group of template items, e.g. "C. Fall protection & roof work".
class TemplateSection {
  const TemplateSection({required this.title, required this.items});

  final String title;
  final List<TemplateItem> items;

  Map<String, Object?> toJson() => {
    'title': title,
    'items': [for (final item in items) item.toJson()],
  };
}

/// An inspection checklist, stored at
/// `organizations/{organizationId}/inspection_templates/{id}`.
class InspectionTemplate {
  const InspectionTemplate({
    required this.id,
    required this.name,
    required this.kind,
    required this.sections,
    required this.isActive,
    this.description,
    this.siteIds = const [],
    this.defaultKey,
  });

  final String id;
  final String name;
  final InspectionKind kind;
  final String? description;
  final List<TemplateSection> sections;
  final bool isActive;

  /// The sites this checklist is used at; empty = every site. Lets a
  /// work-specific checklist (e.g. roof work) appear only where that work
  /// is done.
  final List<String> siteIds;

  /// Which standard checklist this was installed from, if any.
  final String? defaultKey;

  bool isUsedAt(String siteId) => siteIds.isEmpty || siteIds.contains(siteId);

  int get itemCount =>
      sections.fold(0, (total, section) => total + section.items.length);

  factory InspectionTemplate.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    return InspectionTemplate(
      id: doc.id,
      name: data['name'] as String? ?? 'Checklist',
      kind: InspectionKind.fromId(data['kind'] as String?),
      description: data['description'] as String?,
      isActive: (data['status'] as String? ?? 'active') == 'active',
      siteIds:
          (data['siteIds'] as List?)?.whereType<String>().toList() ?? const [],
      defaultKey: data['defaultKey'] as String?,
      sections: [
        for (final rawSection in (data['sections'] as List?) ?? const [])
          if (rawSection is Map)
            TemplateSection(
              title: rawSection['title'] as String? ?? '',
              items: [
                for (final rawItem
                    in (rawSection['items'] as List?) ?? const [])
                  if (rawItem is Map)
                    TemplateItem(
                      id: rawItem['id'] as String? ?? '',
                      text: rawItem['text'] as String? ?? '',
                      hazardCategory:
                          rawItem['hazardCategory'] as String? ?? 'other',
                    ),
              ],
            ),
      ],
    );
  }
}
