import 'risk_assessment.dart';

/// What a pasted AHA contained — see [parseAhaText].
class ParsedAha {
  const ParsedAha({
    this.featureOfWork,
    this.activity,
    this.steps = const [],
    this.equipment = const [],
    this.inspectionRequirements = const [],
    this.trainingRequirements = const [],
  });

  final String? featureOfWork;
  final String? activity;
  final List<AhaStep> steps;
  final List<String> equipment;
  final List<String> inspectionRequirements;
  final List<String> trainingRequirements;

  int get hazardCount => steps.fold(0, (n, s) => n + s.hazards.length);
  int get controlCount => steps.fold(0, (n, s) => n + s.controls.length);

  bool get isEmpty =>
      steps.isEmpty &&
      equipment.isEmpty &&
      inspectionRequirements.isEmpty &&
      trainingRequirements.isEmpty;
}

enum _Part { step, hazards, controls, equipment, inspections, training }

/// Headings (case-insensitive, optional trailing ":") and the part of the
/// AHA form the lines under them belong to.
const _headings = <String, _Part>{
  'hazards': _Part.hazards,
  'hazard': _Part.hazards,
  'potential hazards': _Part.hazards,
  'potential safety/health hazards': _Part.hazards,
  'potential safety / health hazards': _Part.hazards,
  'controls': _Part.controls,
  'control': _Part.controls,
  'control measures': _Part.controls,
  'recommended controls': _Part.controls,
  'equipment': _Part.equipment,
  'equipment to be used': _Part.equipment,
  'inspection': _Part.inspections,
  'inspections': _Part.inspections,
  'inspection requirements': _Part.inspections,
  'training': _Part.training,
  'training requirements': _Part.training,
};

final _numbered = RegExp(
  r'^(?:step\s*)?\d{1,3}\s*[.):\-]\s*',
  caseSensitive: false,
);
final _stepWord = RegExp(r'^step\s*[:\-]\s*', caseSensitive: false);
final _bullet = RegExp(r'^(?:[-*•▪◦·–]|\[\s?[xX]?\s?\]|[☐☑✓✔])\s*');

/// Reads an AHA pasted as text — e.g. copied from a company's Word or PDF
/// AHA — in the order of the paper form:
///
/// ```
/// Feature of work: Interior painting      (optional)
/// 1. Erect scaffold                         ← a numbered line = a step
/// Hazards:                                  ← lines below are hazards
/// - Falls from height
/// Controls: Guardrails fitted               ← content may follow the colon
/// - Inspected before each shift
/// 2. Paint walls
/// ...
/// Equipment:                                ← the three lists at the end
/// Inspection requirements:
/// Training requirements:
/// ```
///
/// A line starting "Step" or a number starts a new step, and a plain line
/// right after it continues that step's description. Plain lines before
/// any heading or numbered step are steps, one per line. Bullets and tick
/// boxes are removed.
ParsedAha parseAhaText(String text) {
  String? featureOfWork;
  String? activity;
  final steps = <_StepDraft>[];
  final equipment = <String>[];
  final inspections = <String>[];
  final training = <String>[];
  _Part? part;

  // True while steps come from plain (un-numbered) lines — each line is
  // then a step of its own rather than a continuation.
  var plainSteps = false;

  for (final raw in text.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty) continue;

    // "Feature of work: X" / "Activity: X".
    final field = RegExp(
      r'^(feature of work|phase of work|activity)\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (field != null) {
      final value = field.group(2)!.trim();
      if (value.isNotEmpty) {
        if (field.group(1)!.toLowerCase() == 'activity') {
          activity = value;
        } else {
          featureOfWork = value;
        }
      }
      continue;
    }

    // A heading, possibly with content after the colon.
    final colon = line.indexOf(':');
    final head = (colon >= 0 ? line.substring(0, colon) : line)
        .replaceFirst(_bullet, '')
        .trim()
        .toLowerCase();
    final heading = _headings[head];
    if (heading != null && (colon >= 0 || line.length == head.length)) {
      part = heading;
      line = colon >= 0 ? line.substring(colon + 1).trim() : '';
      if (line.isEmpty) continue;
    }

    // A new step.
    if (_numbered.hasMatch(line) || _stepWord.hasMatch(line)) {
      final stepText = line
          .replaceFirst(_numbered, '')
          .replaceFirst(_stepWord, '')
          .trim();
      steps.add(_StepDraft(stepText));
      part = _Part.step;
      plainSteps = false;
      continue;
    }

    final item = line.replaceFirst(_bullet, '').trim();
    if (item.isEmpty) continue;
    switch (part) {
      case null:
        steps.add(_StepDraft(item));
        part = _Part.step;
        plainSteps = true;
      case _Part.step:
        if (steps.isEmpty || plainSteps) {
          steps.add(_StepDraft(item));
        } else {
          steps.last.step = '${steps.last.step} $item'.trim();
        }
      case _Part.hazards:
        if (steps.isEmpty) steps.add(_StepDraft(''));
        steps.last.hazards.add(item);
      case _Part.controls:
        if (steps.isEmpty) steps.add(_StepDraft(''));
        steps.last.controls.add(item);
      case _Part.equipment:
        equipment.add(item);
      case _Part.inspections:
        inspections.add(item);
      case _Part.training:
        training.add(item);
    }
  }

  return ParsedAha(
    featureOfWork: featureOfWork,
    activity: activity,
    steps: [
      for (final s in steps)
        AhaStep(
          step: s.step.isEmpty ? 'Step' : s.step,
          hazards: s.hazards,
          controls: s.controls,
        ),
    ],
    equipment: equipment,
    inspectionRequirements: inspections,
    trainingRequirements: training,
  );
}

class _StepDraft {
  _StepDraft(this.step);

  String step;
  final hazards = <String>[];
  final controls = <String>[];
}
