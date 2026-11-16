import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Width and height from a PNG file's IHDR chunk.
(int, int) _pngSize(File file) {
  final bytes = file.readAsBytesSync();
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  expect(bytes.sublist(0, 8), signature, reason: '${file.path} is not a PNG');
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}

void main() {
  final manifest =
      jsonDecode(File('web/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  final index = File('web/index.html').readAsStringSync();

  group('web/manifest.json', () {
    test('names and describes ALMASAFETY', () {
      expect(manifest['name'], 'ALMASAFETY');
      expect(manifest['short_name'], 'ALMASAFETY');
      expect(manifest['description'], contains('safety'));
      expect(manifest['description'], isNot(contains('Flutter project')));
    });

    test('is installable: standalone, start URL inside its scope', () {
      expect(manifest['display'], 'standalone');
      final scope = Uri.parse(
        'https://app.example/',
      ).resolve(manifest['scope'] as String);
      final start = Uri.parse(
        'https://app.example/',
      ).resolve(manifest['start_url'] as String);
      expect(start.toString(), startsWith(scope.toString()));
      expect(manifest['prefer_related_applications'], isFalse);
      // Rotation is allowed — a tablet or a split window is not locked.
      expect(manifest['orientation'], anyOf(isNull, 'any'));
    });

    test('brand colours', () {
      expect(manifest['theme_color'], '#0B4F6C');
      expect(manifest['background_color'], '#0B4F6C');
    });

    test('every icon exists, is a PNG of its declared size; 192 and 512 '
        'for both "any" and "maskable"', () {
      final icons = (manifest['icons'] as List).cast<Map<String, dynamic>>();
      final have = <String>{};
      for (final icon in icons) {
        final file = File('web/${icon['src']}');
        expect(file.existsSync(), isTrue, reason: '${icon['src']} missing');
        final (width, height) = _pngSize(file);
        expect('${width}x$height', icon['sizes'], reason: icon['src']);
        expect(icon['type'], 'image/png');
        have.add('${icon['sizes']} ${icon['purpose'] ?? 'any'}');
      }
      expect(
        have,
        containsAll([
          '192x192 any',
          '512x512 any',
          '192x192 maskable',
          '512x512 maskable',
        ]),
      );
    });
  });

  group('web/index.html', () {
    test('links the manifest, titles the page, and has a real Apple icon', () {
      expect(index, contains('<link rel="manifest" href="manifest.json">'));
      expect(index, contains('<title>ALMASAFETY</title>'));
      expect(index, contains('content="ALMASAFETY"'));
      final apple = RegExp(
        r'rel="apple-touch-icon" href="([^"]+)"',
      ).firstMatch(index)!.group(1)!;
      final (width, height) = _pngSize(File('web/$apple'));
      expect(width, 180);
      expect(height, 180);
    });

    test('leaves installing to the browser — its own address-bar icon or '
        'Install prompt is never suppressed', () {
      expect(index, isNot(contains('beforeinstallprompt')));
      expect(index, isNot(contains('preventDefault')));
    });
  });

  group('service workers', () {
    test('only offline_sw.js is registered by the page; Flutter\'s own is not '
        'configured; the messaging worker is separate', () {
      final registrations = RegExp(
        r"serviceWorker\.register\('([^']+)'",
      ).allMatches(index).map((m) => m.group(1)).toList();
      expect(registrations, ['offline_sw.js']);
      final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();
      // Loaded with no configuration: no serviceWorkerSettings.
      expect(bootstrap, contains('_flutter.loader.load();'));
    });

    test('the offline worker never answers Firebase or other third-party '
        'traffic, nor anything but GET', () {
      final worker = File('web/offline_sw.js').readAsStringSync();
      expect(worker, contains("if (request.method !== 'GET') return;"));
      expect(worker, contains('url.origin === self.location.origin'));
      // Only the versioned Google font/engine hosts are cached cross-origin.
      expect(
        worker,
        contains(
          "const VERSIONED_HOSTS = ['www.gstatic.com', 'fonts.gstatic.com', "
          "'fonts.googleapis.com'];",
        ),
      );
      for (final host in [
        'firestore.googleapis.com',
        'identitytoolkit',
        'securetoken',
        'firebasestorage',
        'cloudfunctions',
      ]) {
        expect(worker, isNot(contains(host)));
      }
    });
  });

  group('firebase.json hosting', () {
    final hosting =
        (jsonDecode(File('firebase.json').readAsStringSync())
                as Map<String, dynamic>)['hosting']
            as Map<String, dynamic>;

    test('serves the web build with SPA rewrites to index.html', () {
      expect(hosting['public'], 'build/web');
      expect(hosting['rewrites'], [
        {'source': '**', 'destination': '/index.html'},
      ]);
    });

    test('the app\'s code is revalidated on every load, so a release is '
        'picked up', () {
      final headers = (hosting['headers'] as List).cast<Map<String, dynamic>>();
      String? cacheControlFor(String source) {
        final rule = headers.firstWhere((h) => h['source'] == source);
        final list = (rule['headers'] as List).cast<Map<String, dynamic>>();
        return list.firstWhere((h) => h['key'] == 'Cache-Control')['value']
            as String?;
      }

      expect(cacheControlFor('/'), 'no-cache');
      expect(cacheControlFor('**/*.@(html|js|mjs|json|wasm)'), 'no-cache');
    });
  });
}
