import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/routing/route_extra_codec.dart';

void main() {
  test('round-trips the same object through a token, never the data', () {
    final codec = RouteExtraCodec();
    final extra = (name: 'Site A', secret: 'not in history');
    final encoded = codec.encode(extra);
    expect(encoded.toString(), isNot(contains('Site A')));
    expect(identical(codec.decode(encoded), extra), isTrue);
    // The same object keeps one token.
    expect(codec.encode(extra), encoded);
  });

  test('null stays null; an unknown or foreign token decodes to null (the '
      'route then falls back as before)', () {
    final codec = RouteExtraCodec();
    expect(codec.encode(null), isNull);
    expect(codec.decode(null), isNull);
    expect(codec.decode({'jvaExtra': 'e999'}), isNull);
    expect(codec.decode('something else'), isNull);
  });

  test('keeps only the most recent extras', () {
    final codec = RouteExtraCodec(capacity: 2);
    final first = codec.encode(Object());
    codec.encode(Object());
    codec.encode(Object());
    expect(codec.decode(first), isNull);
  });
}
