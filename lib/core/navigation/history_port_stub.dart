import 'overlay_history.dart';

/// Not a browser: there is no session history to keep in step.
HistoryPort createHistoryPort() => _NoHistoryPort();

class _NoHistoryPort implements HistoryPort {
  @override
  int get currentDepth => 0;

  @override
  void push(int depth) {}

  @override
  void go(int delta) {}

  @override
  void listen(void Function(int depth) onPop) {}
}
