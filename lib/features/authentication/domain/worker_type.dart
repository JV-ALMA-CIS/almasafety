/// Workforce type (PROJECT_CONTEXT.md §13), distinct from [AppRole].
///
/// A worker type describes who employs the person, not what they are
/// authorized to do — a `contractor` electrician and a `jvaEmployee`
/// superintendent are both ordinary [AppRole] holders. It carries no
/// authorization weight and grants no privilege by itself.
enum WorkerType {
  jvaEmployee,
  contractor,
  subcontractor,
  other;

  /// The value stored in the Firestore `workerType` field.
  String get id => switch (this) {
    WorkerType.jvaEmployee => 'jva_employee',
    WorkerType.contractor => 'contractor',
    WorkerType.subcontractor => 'subcontractor',
    WorkerType.other => 'other',
  };

  String get label => switch (this) {
    WorkerType.jvaEmployee => 'JVA Employee',
    WorkerType.contractor => 'Contractor',
    WorkerType.subcontractor => 'Subcontractor',
    WorkerType.other => 'Other',
  };

  static WorkerType? tryFromId(String? id) {
    if (id == null) return null;
    for (final type in WorkerType.values) {
      if (type.id == id) return type;
    }
    return null;
  }
}
