import 'inspection.dart';

/// Turns a pasted or typed checklist — e.g. copied from a company Word or
/// PDF checklist — into sections of items, so a long checklist is entered
/// in one go instead of item by item.
///
/// - Each non-blank line is an item. Bullets, numbering and tick boxes at
///   the start ("-", "•", "1.", "2)", "a)", "☐", "[ ]") are removed.
/// - A line starting with "#" or ending with ":" starts a new SECTION
///   titled by that line.
/// - Items before any heading go in a section titled [defaultSection].
///
/// Each item's hazard category is guessed from its wording
/// ([guessHazardCategory]); it can be changed afterwards.
List<TemplateSection> parseChecklistText(
  String text, {
  String defaultSection = 'Checks',
}) {
  final sections = <TemplateSection>[];
  String? title;
  var items = <TemplateItem>[];

  void close() {
    if (items.isNotEmpty) {
      sections.add(
        TemplateSection(title: title ?? defaultSection, items: items),
      );
    }
    items = <TemplateItem>[];
  }

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final isHeading =
        line.startsWith('#') || (line.endsWith(':') && line.length > 1);
    if (isHeading) {
      close();
      title = line
          .replaceAll(RegExp(r'^#+\s*'), '')
          .replaceAll(RegExp(r':$'), '')
          .trim();
      continue;
    }
    final itemText = _stripMarker(line);
    if (itemText.isEmpty) continue;
    items.add(
      TemplateItem(
        id: '',
        text: itemText,
        hazardCategory: guessHazardCategory(itemText),
      ),
    );
  }
  close();
  return sections;
}

final _marker = RegExp(
  r'^(?:[-*•▪◦·–]|\[\s?[xX]?\s?\]|[☐☑✓✔]|\(?\d{1,3}[.)]|\(?[a-zA-Z][.)])\s+',
);

String _stripMarker(String line) {
  var text = line;
  // Up to two markers, e.g. "1. ☐ Check the scaffold".
  for (var i = 0; i < 2; i++) {
    final stripped = text.replaceFirst(_marker, '');
    if (stripped == text) break;
    text = stripped.trim();
  }
  return text;
}

const _keywords = <String, List<String>>{
  'workingAtHeight': [
    'height',
    'fall',
    'scaffold',
    'ladder',
    'harness',
    'lanyard',
    'roof',
    'guardrail',
    'guard rail',
    'edge',
    'opening',
    'platform',
    'anchor',
  ],
  'electrical': [
    'electric',
    'cord',
    'cable',
    'gfci',
    'rcd',
    'socket',
    'plug',
    'wiring',
    'power line',
    'generator',
    'lockout',
    'breaker',
    'panel',
  ],
  'ppe': [
    'ppe',
    'hard hat',
    'helmet',
    'glasses',
    'goggles',
    'gloves',
    'boots',
    'vest',
    'hi-vis',
    'hearing',
    'respirator',
    'mask',
  ],
  'fire': [
    'fire',
    'extinguisher',
    'hot work',
    'welding',
    'cutting',
    'flammable',
    'smoking',
    'gas cylinder',
  ],
  'chemical': [
    'chemical',
    'hazardous substance',
    'asbestos',
    'lead',
    'paint',
    'solvent',
    'msds',
    'sds',
    'fuel',
  ],
  'environment': [
    'spill',
    'dust',
    'noise',
    'waste water',
    'environment',
    'pollution',
    'drain',
  ],
  'housekeeping': [
    'housekeeping',
    'debris',
    'walkway',
    'tidy',
    'clean',
    'stack',
    'storage',
    'rubbish',
    'waste',
    'trip',
  ],
  'equipment': [
    'tool',
    'machine',
    'machinery',
    'equipment',
    'crane',
    'vehicle',
    'plant',
    'excavator',
    'forklift',
    'hoist',
    'guard',
    'rigging',
  ],
};

/// A best guess at the hazard category a "Not OK" on [itemText] belongs
/// to, from its wording (words matched at their start); "other" when
/// nothing matches. The first category
/// (in a fixed order) with a matching word wins.
String guessHazardCategory(String itemText) {
  final text = itemText.toLowerCase();
  for (final entry in _keywords.entries) {
    // Matched at the start of a word: "cord" finds "cords", not "record".
    if (entry.value.any(
      (word) => RegExp(r'\b' + RegExp.escape(word)).hasMatch(text),
    )) {
      return entry.key;
    }
  }
  return 'other';
}

/// A standard checklist in the library — see
/// `functions/src/inspection_templates.ts`.
class StandardChecklist {
  const StandardChecklist({
    required this.key,
    required this.name,
    required this.kind,
    required this.description,
    required this.core,
    required this.itemCount,
    required this.installed,
  });

  final String key;
  final String name;
  final InspectionKind kind;
  final String description;

  /// One of the general checklists every organization starts with.
  final bool core;
  final int itemCount;

  /// Whether the organization already has it.
  final bool installed;

  factory StandardChecklist.fromMap(Map<Object?, Object?> data) =>
      StandardChecklist(
        key: data['key'] as String? ?? '',
        name: data['name'] as String? ?? '',
        kind: InspectionKind.fromId(data['kind'] as String?),
        description: data['description'] as String? ?? '',
        core: data['core'] == true,
        itemCount: (data['itemCount'] as num?)?.toInt() ?? 0,
        installed: data['installed'] == true,
      );
}
