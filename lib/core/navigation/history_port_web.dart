import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'overlay_history.dart';

HistoryPort createHistoryPort() => _BrowserHistoryPort();

/// The key [OverlayHistory] adds to a history entry's state. Flutter's own
/// state (`serialCount`, go_router's location) is copied unchanged, so an
/// overlay step reads to the router as the same page.
const _depthKey = 'jvaOverlayDepth';

class _BrowserHistoryPort implements HistoryPort {
  static int _depthOf(JSAny? state) {
    final value = state?.dartify();
    if (value is! Map) return 0;
    final depth = value[_depthKey];
    return depth is num ? depth.toInt() : 0;
  }

  @override
  int get currentDepth => _depthOf(web.window.history.state);

  @override
  void push(int depth) {
    final current = web.window.history.state?.dartify();
    final state = <Object?, Object?>{
      if (current is Map) ...current,
      _depthKey: depth,
    };
    // No URL: the entry keeps the current address.
    web.window.history.pushState(state.jsify(), '');
  }

  @override
  void go(int delta) => web.window.history.go(delta);

  @override
  void listen(void Function(int depth) onPop) {
    web.window.addEventListener(
      'popstate',
      ((web.PopStateEvent event) => onPop(_depthOf(event.state))).toJS,
    );
  }
}
