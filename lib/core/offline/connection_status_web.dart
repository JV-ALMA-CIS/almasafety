import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The browser's own online/offline flag. False means definitely offline;
/// true only means "maybe" — a weak signal still reports online.
bool deviceIsOnline() => web.window.navigator.onLine;

/// Calls [onChange] whenever the browser loses or regains its connection.
void onConnectionChanged(void Function() onChange) {
  final listener = ((web.Event _) => onChange()).toJS;
  web.window.addEventListener('online', listener);
  web.window.addEventListener('offline', listener);
}
