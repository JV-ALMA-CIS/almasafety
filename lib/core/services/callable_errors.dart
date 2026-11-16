import 'package:cloud_functions/cloud_functions.dart';

import '../errors/app_exception.dart';

/// Recognises a call to a server function that the deployed server does not
/// have yet — the app was updated before the server was.
///
/// A missing function comes back as `not-found` (mobile) or `unimplemented`
/// with no message of its own, or — on the web, where the browser blocks the
/// request — as `internal` with no message. A function that exists and
/// refuses on purpose always sends its own message (for example "That
/// learning item is not available."), so it is never mistaken for this.
///
/// Returns null when [e] is anything else; callers then map it as usual.
/// [feature] names what failed, e.g. "Quiz counts".
ServerUpdateRequiredException? missingServerFunction(
  FirebaseFunctionsException e,
  String feature,
) {
  final generic = _isGenericMessage(e.message);
  if (e.code == 'unimplemented' || (e.code == 'not-found' && generic)) {
    return ServerUpdateRequiredException(
      '$feature needs the latest server update, which has not been '
      'deployed yet. Ask your administrator to deploy it.',
      cause: e,
    );
  }
  if (e.code == 'internal' && generic) {
    return ServerUpdateRequiredException(
      '$feature could not be reached on the server. The server may need the '
      'latest update — ask your administrator, or try again.',
      cause: e,
    );
  }
  return null;
}

/// True for an empty message or one that only repeats a status code
/// ("NOT_FOUND", "not-found", "internal", "Not Found").
bool _isGenericMessage(String? message) {
  if (message == null) return true;
  final letters = message.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  return const {'', 'notfound', 'internal', 'unimplemented'}.contains(letters);
}
