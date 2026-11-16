import 'package:flutter/widgets.dart';

import 'history_port_stub.dart'
    if (dart.library.js_interop) 'history_port_web.dart';

/// The browser's session history, as [OverlayHistory] needs it.
abstract class HistoryPort {
  /// How many overlay steps the current history entry is above its page —
  /// 0 for a page's own entry.
  int get currentDepth;

  /// Adds an entry for the same address, [depth] steps above the page.
  void push(int depth);

  /// Moves [delta] entries through history (negative = back).
  void go(int delta);

  /// Calls [onPop] with the landing entry's depth on browser Back/Forward.
  void listen(void Function(int depth) onPop);
}

/// Makes browser and Android Back close the screen on top.
///
/// Forms, lessons, the quiz editor and other detail screens open with
/// `Navigator.push` (and dialogs with `showDialog`) — "pageless" routes that
/// go_router does not put in the browser history. Browser Back used to skip
/// them and leave the page underneath, often for the Dashboard.
///
/// Each pageless route now adds one history step for the same address,
/// tagged with its depth. Browser Back lands one step lower, and the screen
/// on top is closed with `maybePop` — so an unsaved-changes prompt
/// (`PopScope`) still asks first. Closing a screen in the app removes its
/// step. go_router's own pages are never touched: their entries carry no
/// depth, and moving between them stays go_router's job.
///
/// Attach one [observer] to each Navigator that screens are pushed on (the
/// root navigator and the shell navigator). Not a browser ([HistoryPort]
/// stub): nothing happens.
class OverlayHistory {
  OverlayHistory(this._port) {
    _port.listen(_onPopState);
  }

  /// The instance for the running platform.
  static final OverlayHistory instance = OverlayHistory(createHistoryPort());

  final HistoryPort _port;

  /// Open pageless routes, oldest first, across every observed navigator.
  final List<Route<dynamic>> _open = [];

  /// History moves made by this class whose popstate is still to come.
  /// While one is in flight no other move is made — it would be computed
  /// from a position the browser is about to leave.
  int _ownMoves = 0;

  /// Closing screens for a browser Back; their steps are already gone.
  bool _popping = false;

  /// The open overlay routes, oldest first — for tests.
  @visibleForTesting
  List<Route<dynamic>> get openRoutes => List.unmodifiable(_open);

  /// A new observer for one Navigator.
  NavigatorObserver observer() => _OverlayObserver(this);

  static bool _isOverlay(Route<dynamic> route) => route.settings is! Page;

  void _opened(Route<dynamic> route, {required bool first}) {
    // A navigator's first route is never on top of anything.
    if (first || !_isOverlay(route)) return;
    _open.add(route);
    // With a move in flight, its landing settles this step instead.
    if (_ownMoves == 0) _port.push(_open.length);
  }

  void _closed(Route<dynamic> route, {required bool byApp}) {
    if (!_open.remove(route)) return;
    // Closed in the app (back arrow, Save, Cancel): drop its step too, so
    // the next browser Back leaves the page as expected.
    if (byApp && !_popping) _settle();
  }

  void _replaced(Route<dynamic>? newRoute, Route<dynamic>? oldRoute) {
    final index = oldRoute == null ? -1 : _open.indexOf(oldRoute);
    if (index == -1) {
      if (newRoute != null) _opened(newRoute, first: false);
      return;
    }
    if (newRoute != null && _isOverlay(newRoute)) {
      _open[index] = newRoute;
    } else {
      _open.removeAt(index);
      _settle();
    }
  }

  /// Brings the browser's step count back in line with the open routes.
  void _settle() {
    if (_ownMoves > 0) return;
    final depth = _port.currentDepth;
    if (depth > _open.length) {
      _ownMoves++;
      _port.go(_open.length - depth);
    } else if (depth < _open.length) {
      for (var d = depth + 1; d <= _open.length; d++) {
        _port.push(d);
      }
    }
  }

  Future<void> _onPopState(int depth) async {
    if (_ownMoves > 0) {
      _ownMoves--;
      _settle();
      return;
    }
    // A step for a screen already closed (e.g. Forward): nothing to do.
    if (depth >= _open.length) return;
    // Back (possibly several steps at once): close from the top down.
    _popping = true;
    try {
      while (_open.length > depth) {
        final route = _open.last;
        final navigator = route.navigator;
        if (navigator == null || !route.isCurrent) {
          _open.removeLast();
          continue;
        }
        final closed = await navigator.maybePop();
        // Refused (an unsaved-changes prompt, or a screen that cannot be
        // left): keep it open, with its step restored below.
        if (!closed || _open.contains(route)) break;
      }
    } finally {
      _popping = false;
    }
    _settle();
  }
}

class _OverlayObserver extends NavigatorObserver {
  _OverlayObserver(this._history);

  final OverlayHistory _history;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _history._opened(route, first: previousRoute == null);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _history._closed(route, byApp: true);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _history._closed(route, byApp: false);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _history._replaced(newRoute, oldRoute);
}
