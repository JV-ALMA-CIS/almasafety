// Regenerates the PWA icons in web/ from the app's own mark — the shield on
// the amber tile over the brand gradient, as drawn in the sidebar header
// (lib/routing/app_shell.dart). Not part of the test suite; run on demand:
//
//   flutter test tool/generate_web_icons.dart
//
// Writes web/icons/Icon-{192,512}.png ("any": rounded, transparent corners),
// web/icons/Icon-maskable-{192,512}.png (full bleed, mark inside the 80%
// safe zone), web/icons/apple-touch-icon.png (180, full bleed) and
// web/favicon.png (32).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/theme/app_colors.dart';

Future<void> _loadMaterialIcons() async {
  // Walk up from the test runner to the Flutter SDK's bundled icon font.
  var dir = File(Platform.resolvedExecutable).parent;
  File? font;
  while (font == null) {
    final candidate = File(
      '${dir.path}/bin/cache/artifacts/material_fonts/'
      'materialicons-regular.otf',
    );
    if (candidate.existsSync()) {
      font = candidate;
    } else if (dir.parent.path == dir.path) {
      throw StateError('Material Icons font not found in the Flutter SDK.');
    } else {
      dir = dir.parent;
    }
  }
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
  await loader.load();
}

/// The mark at [size]. [fullBleed] fills the square (maskable, Apple);
/// otherwise the background is a rounded square. [tileFraction] is the
/// amber tile's share of the side.
Widget _icon(double size, {required bool fullBleed, double tileFraction = 0.6}) {
  final tile = size * tileFraction;
  return SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: fullBleed ? null : BorderRadius.circular(size * 0.22),
      ),
      child: Center(
        child: Container(
          width: tile,
          height: tile,
          decoration: BoxDecoration(
            color: AppColors.secondary,
            borderRadius: BorderRadius.circular(tile * 0.24),
          ),
          child: Icon(
            Icons.health_and_safety,
            size: tile * 0.72,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    ),
  );
}

Future<void> _render(
  WidgetTester tester,
  Widget icon,
  double size,
  String path,
) async {
  final key = GlobalKey();
  tester.view.physicalSize = Size(size, size);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(key: key, child: icon),
      ),
    ),
  );
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('generate web icons', (tester) async {
    await tester.runAsync(_loadMaterialIcons);
    addTearDown(tester.view.reset);
    for (final size in [192.0, 512.0]) {
      final n = size.toInt();
      await _render(
        tester,
        _icon(size, fullBleed: false),
        size,
        'web/icons/Icon-$n.png',
      );
      await _render(
        tester,
        // The tile stays well inside the maskable 80% safe circle.
        _icon(size, fullBleed: true, tileFraction: 0.5),
        size,
        'web/icons/Icon-maskable-$n.png',
      );
    }
    await _render(
      tester,
      _icon(180, fullBleed: true, tileFraction: 0.6),
      180,
      'web/icons/apple-touch-icon.png',
    );
    await _render(
      tester,
      _icon(32, fullBleed: false, tileFraction: 0.7),
      32,
      'web/favicon.png',
    );
  });
}
