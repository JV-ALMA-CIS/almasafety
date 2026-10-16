/// Whether the device thinks it has a connection. Off the web there is no
/// cheap signal, so this is always true and a failed send is what tells the
/// outbox the signal has gone.
bool deviceIsOnline() => true;

/// Calls [onChange] whenever the connection drops or comes back. Not
/// available off the web; the outbox's retry timer covers it there.
void onConnectionChanged(void Function() onChange) {}
