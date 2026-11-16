import 'dart:collection';
import 'dart:convert';

/// Lets go_router's `extra` survive browser Back/Forward.
///
/// The drill-down screens (Projects → Sites → Activities → Workers) receive
/// their [Organization]/[Project]/[Site]/[Activity] context as `extra`.
/// go_router writes `extra` into the browser history entry, and without a
/// codec it drops anything that is not plain JSON — so Back or Forward onto
/// one of those screens lost its context and fell back to Projects.
///
/// This codec keeps the objects in memory and writes only a short token into
/// history. Nothing about the organization is stored in the browser. After a
/// page reload the token is unknown, `extra` decodes to null, and each route
/// falls back exactly as it did before (see `app_router.dart`).
class RouteExtraCodec extends Codec<Object?, Object?> {
  RouteExtraCodec({this.capacity = 200});

  /// How many recent extras are remembered.
  final int capacity;

  final LinkedHashMap<String, Object?> _byToken = LinkedHashMap();
  int _next = 0;

  static const _tokenKey = 'jvaExtra';

  @override
  Converter<Object?, Object?> get encoder => _Encoder(this);

  @override
  Converter<Object?, Object?> get decoder => _Decoder(this);

  String _tokenFor(Object value) {
    for (final entry in _byToken.entries) {
      if (identical(entry.value, value)) return entry.key;
    }
    final token = 'e${_next++}';
    _byToken[token] = value;
    while (_byToken.length > capacity) {
      _byToken.remove(_byToken.keys.first);
    }
    return token;
  }
}

class _Encoder extends Converter<Object?, Object?> {
  const _Encoder(this._codec);
  final RouteExtraCodec _codec;

  @override
  Object? convert(Object? input) {
    if (input == null) return null;
    return {RouteExtraCodec._tokenKey: _codec._tokenFor(input)};
  }
}

class _Decoder extends Converter<Object?, Object?> {
  const _Decoder(this._codec);
  final RouteExtraCodec _codec;

  @override
  Object? convert(Object? input) {
    if (input is! Map) return null;
    final token = input[RouteExtraCodec._tokenKey];
    return token is String ? _codec._byToken[token] : null;
  }
}
