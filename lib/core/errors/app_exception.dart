/// Base type for handled application errors.
///
/// Feature-specific exceptions should extend this so presentation-layer code
/// can catch a single known type and show a consistent error UI, instead of
/// leaking raw Firebase/platform exceptions to the UI.
sealed class AppException implements Exception {
  const AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class AuthException extends AppException {
  const AuthException(super.message, {super.cause});
}

class DataException extends AppException {
  const DataException(super.message, {super.cause});
}

class PermissionDeniedException extends AppException {
  const PermissionDeniedException(super.message, {super.cause});
}

class NetworkException extends AppException {
  const NetworkException(super.message, {super.cause});
}

/// Not a failure: there was no signal, so the entry was saved on this phone
/// and will be sent automatically once the connection returns (see
/// `Outbox`). Screens catch it to show a "saved, waiting to send" state;
/// anything that doesn't still shows [message], which reads correctly.
class SavedOfflineException extends AppException {
  const SavedOfflineException([
    super.message =
        'No signal right now. This is saved on this phone and will be sent '
        'automatically when the connection comes back.',
  ]);
}
