import 'package:flutter/material.dart';
import '../../../core/theme/app_spacing.dart';
import '../domain/pre_start_check.dart';

/// One picture tile under a Pre-Start question: a color emoji and a short
/// label, e.g. ⛑️ "Helmet".
typedef PreStartVisual = ({String emoji, String label});

/// The pictures shown with each Pre-Start question, so a worker sees what
/// is being asked about, not only reads it. Built into the app — nothing to
/// upload or configure, and identical on every phone.
///
/// The five standard questions have fixed pictures. A requirement question
/// ("Roofing: the controls for … are in place") gets pictures matched from
/// the hazard words in its text, falling back to a general warning sign.
List<PreStartVisual> visualsFor(PreStartQuestion question) {
  final standard = _standard[question.id];
  if (standard != null) return standard;

  final text = question.prompt.toLowerCase();
  final matched = <PreStartVisual>[
    for (final entry in _hazardWords)
      if (entry.words.any(text.contains)) entry.visual,
  ];
  return matched.isEmpty
      ? const [(emoji: '⚠️', label: 'Controls in place')]
      : matched.take(4).toList();
}

/// The single best hazard picture for any free text — an activity name
/// ("Roofing"), a meeting point ("Working at Height") — or a hard hat when
/// nothing matches. Shared with the Daily Safety Meeting screen.
String hazardEmojiFor(String text) {
  final lower = text.toLowerCase();
  for (final entry in _hazardWords) {
    if (entry.words.any(lower.contains)) return entry.visual.emoji;
  }
  if (lower.contains('ppe') || lower.contains('protective')) return '🦺';
  return '⛑️';
}

const Map<String, List<PreStartVisual>> _standard = {
  'std-ppe': [
    (emoji: '⛑️', label: 'Helmet'),
    (emoji: '🦺', label: 'Hi-vis vest'),
    (emoji: '🥾', label: 'Safety boots'),
    (emoji: '🧤', label: 'Gloves'),
    (emoji: '🥽', label: 'Eye protection'),
  ],
  'std-tools': [
    (emoji: '🔧', label: 'Tools checked'),
    (emoji: '🔌', label: 'Cables & plugs'),
    (emoji: '🪜', label: 'Ladders'),
  ],
  'std-area': [
    (emoji: '🚧', label: 'Barriers'),
    (emoji: '⚠️', label: 'Hazards'),
    (emoji: '🧹', label: 'Tidy area'),
  ],
  'std-emergency': [
    (emoji: '🚪', label: 'Exit route'),
    (emoji: '📍', label: 'Assembly point'),
    (emoji: '🧯', label: 'Extinguisher'),
    (emoji: '🩹', label: 'First aid'),
  ],
  'std-fit': [
    (emoji: '😴', label: 'Rested'),
    (emoji: '🤒', label: 'Not unwell'),
    (emoji: '🚫', label: 'No alcohol / drugs'),
  ],
};

const List<({List<String> words, PreStartVisual visual})> _hazardWords = [
  (
    words: ['height', 'fall', 'scaffold', 'roof', 'ladder', 'harness'],
    visual: (emoji: '🪜', label: 'Working at height'),
  ),
  (
    words: ['electric', 'power', 'wiring', 'isolation'],
    visual: (emoji: '⚡', label: 'Electrical'),
  ),
  (
    words: ['fire', 'hot work', 'weld', 'burn', 'flame'],
    visual: (emoji: '🔥', label: 'Fire / hot work'),
  ),
  (
    words: ['excavat', 'trench', 'dig', 'earthwork'],
    visual: (emoji: '🚜', label: 'Excavation'),
  ),
  (words: ['confined'], visual: (emoji: '🕳️', label: 'Confined space')),
  (
    words: ['lift', 'crane', 'hoist', 'rigging'],
    visual: (emoji: '🏗️', label: 'Lifting'),
  ),
  (
    words: ['chemical', 'hazardous', 'substance', 'asbestos', 'dust'],
    visual: (emoji: '☣️', label: 'Hazardous substances'),
  ),
  (
    words: ['noise', 'hearing'],
    visual: (emoji: '🎧', label: 'Hearing protection'),
  ),
  (
    words: ['traffic', 'vehicle', 'plant', 'machinery'],
    visual: (emoji: '🚧', label: 'Vehicles & plant'),
  ),
];

/// The row of picture tiles for one question.
class PreStartVisualStrip extends StatelessWidget {
  const PreStartVisualStrip({super.key, required this.visuals, this.color});

  final List<PreStartVisual> visuals;

  /// Tints the tiles; defaults to the theme's primary container.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final visual in visuals)
          Container(
            width: 84,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tint.withValues(alpha: 0.25)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(visual.emoji, style: const TextStyle(fontSize: 30)),
                const SizedBox(height: 4),
                Text(
                  visual.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
