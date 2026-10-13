import 'package:flutter/widgets.dart';

/// A [StreamBuilder] that keeps ONE live stream across rebuilds.
///
/// Repository `watch…()` calls return a brand-new Firestore stream each
/// time. Passed straight to a [StreamBuilder] inside `build`, every rebuild
/// of the screen (a tick, a filter tap, a "saving…" spinner) handed it a new
/// stream, which restarts at "waiting" with no data: lists flashed empty or
/// were swapped for a spinner, and the page jumped back to the top.
///
/// This creates the stream once with [stream] and reuses it until
/// [streamKey] changes — so pass as the key whatever the stream depends on
/// (e.g. `(repository, siteId)`). Records compare by value, so a record of
/// the inputs is the usual key.
class LiveStreamBuilder<T> extends StatefulWidget {
  const LiveStreamBuilder({
    super.key,
    required this.streamKey,
    required this.stream,
    required this.builder,
    this.initialData,
  });

  /// What the stream depends on; a new stream is created only when this
  /// changes (compared with `==`).
  final Object? streamKey;

  /// Creates the stream. Called once, and again only when [streamKey]
  /// changes.
  final Stream<T> Function() stream;
  final AsyncWidgetBuilder<T> builder;
  final T? initialData;

  @override
  State<LiveStreamBuilder<T>> createState() => _LiveStreamBuilderState<T>();
}

class _LiveStreamBuilderState<T> extends State<LiveStreamBuilder<T>> {
  late Stream<T> _stream = widget.stream();

  @override
  void didUpdateWidget(LiveStreamBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamKey != widget.streamKey) _stream = widget.stream();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<T>(
      stream: _stream,
      initialData: widget.initialData,
      builder: widget.builder,
    );
  }
}
