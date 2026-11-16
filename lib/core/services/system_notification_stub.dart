/// Outside the web the app does not show its own system notifications —
/// the caller shows its in-app notice instead.
Future<bool> showSystemNotification({
  required String title,
  required String body,
  required String route,
  required bool urgent,
}) async => false;
