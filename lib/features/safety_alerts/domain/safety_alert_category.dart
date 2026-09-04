/// The category of one `SafetyAlert`. Mirrors `MeetingConcernCategory`'s
/// style: a small fixed set for field use, not user-extensible at this
/// stage.
enum SafetyAlertCategory {
  safety,
  equipment,
  environment,
  weather,
  site,
  other;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    SafetyAlertCategory.safety => 'Safety',
    SafetyAlertCategory.equipment => 'Equipment',
    SafetyAlertCategory.environment => 'Environment',
    SafetyAlertCategory.weather => 'Weather',
    SafetyAlertCategory.site => 'Site',
    SafetyAlertCategory.other => 'Other',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any one category.
  static SafetyAlertCategory? tryFromId(String? id) {
    if (id == null) return null;
    for (final category in SafetyAlertCategory.values) {
      if (category.id == id) return category;
    }
    return null;
  }
}
