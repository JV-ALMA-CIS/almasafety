import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning_type.dart';
import 'package:jva_safety/features/safety_learning/domain/video_source.dart';

const _bucket = 'jva-test.firebasestorage.app';
const _org = 'org-alpha';

String storageUrl({
  String origin = firebaseStorageOrigin,
  String bucket = _bucket,
  String objectPath = 'organizations/org-alpha/safety_learning/123/clip.mp4',
}) =>
    '$origin/v0/b/$bucket/o/${Uri.encodeComponent(objectPath)}'
    '?alt=media&token=abc';

VideoSource classify(
  String url, {
  String? bucket = _bucket,
  String origin = firebaseStorageOrigin,
}) => VideoSource.classify(
  url,
  organizationId: _org,
  storageBucket: bucket,
  storageOrigin: origin,
);

void main() {
  group('JVA Storage', () {
    test('this organization\'s safety_learning file is a JVA video', () {
      final source = classify(storageUrl());
      expect(source.kind, VideoSourceKind.jva);
      expect(source.label, 'JVA video');
      expect(source.playsInApp, isTrue);
    });

    test('a file without a video extension is still a JVA video', () {
      final source = classify(
        storageUrl(
          objectPath: 'organizations/org-alpha/safety_learning/123/IMG_0042',
        ),
      );
      expect(source.kind, VideoSourceKind.jva);
      expect(source.playsInApp, isTrue);
    });

    test('another organization\'s file is not labelled JVA', () {
      final source = classify(
        storageUrl(
          objectPath: 'organizations/org-beta/safety_learning/123/clip.mp4',
        ),
      );
      expect(source.kind, VideoSourceKind.unsupported);
      expect(source.label, 'Link problem');
      expect(source.problem, contains('organization'));
    });

    test('an organization id that only shares a prefix is not accepted', () {
      final source = classify(
        storageUrl(
          objectPath: 'organizations/org-alpha2/safety_learning/1/clip.mp4',
        ),
      );
      expect(source.kind, VideoSourceKind.unsupported);
    });

    test('another folder of this organization is not a JVA video', () {
      final source = classify(
        storageUrl(objectPath: 'organizations/org-alpha/hazards/1/clip.mp4'),
      );
      expect(source.kind, VideoSourceKind.unsupported);
    });

    test('path traversal out of the folder is rejected', () {
      final source = classify(
        storageUrl(
          objectPath:
              'organizations/org-alpha/safety_learning/../../org-beta/x.mp4',
        ),
      );
      expect(source.kind, VideoSourceKind.unsupported);
    });

    test('another bucket is rejected', () {
      final source = classify(storageUrl(bucket: 'someone-else.appspot.com'));
      expect(source.kind, VideoSourceKind.unsupported);
    });

    test('with no configured bucket nothing is a JVA video', () {
      expect(
        classify(storageUrl(), bucket: null).kind,
        VideoSourceKind.unsupported,
      );
    });

    test('other Google Storage hosts are not treated as external files', () {
      final source = classify(
        'https://storage.googleapis.com/$_bucket/organizations/org-alpha/'
        'safety_learning/1/clip.mp4',
      );
      expect(source.kind, VideoSourceKind.unsupported);
    });

    test('an emulator origin is accepted only when configured', () {
      const emulator = 'http://localhost:9199';
      final url = storageUrl(origin: emulator);
      expect(classify(url, origin: emulator).kind, VideoSourceKind.jva);
      expect(classify(url).kind, VideoSourceKind.unsupported);
    });

    test('plain http to the production Storage host is rejected', () {
      final url = storageUrl(origin: 'http://firebasestorage.googleapis.com');
      expect(classify(url).kind, VideoSourceKind.unsupported);
    });
  });

  group('YouTube', () {
    for (final url in [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtube.com/watch?v=dQw4w9WgXcQ&t=30s',
      'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtu.be/dQw4w9WgXcQ',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
      'https://www.youtube.com/embed/dQw4w9WgXcQ',
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
      'https://www.youtube.com/playlist?list=PL1234',
      'https://WWW.YOUTUBE.COM/watch?v=dQw4w9WgXcQ',
    ]) {
      test('recognises $url', () {
        final source = classify(url);
        expect(source.kind, VideoSourceKind.youtube);
        expect(source.label, 'External · YouTube');
        expect(source.openLabel, 'Watch on YouTube');
        expect(source.playsInApp, isFalse);
      });
    }

    test('a channel page is not a video', () {
      expect(
        classify('https://www.youtube.com/@SafetyChannel').kind,
        VideoSourceKind.unsupported,
      );
    });

    test('a watch page without a video id is rejected', () {
      expect(
        classify('https://www.youtube.com/watch').kind,
        VideoSourceKind.unsupported,
      );
    });

    test('look-alike hosts are not YouTube', () {
      for (final url in [
        'https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ',
        'https://evil-youtube.com/watch?v=dQw4w9WgXcQ',
        'https://notyoutu.be/dQw4w9WgXcQ',
        'https://evil.example/youtube.com/watch?v=dQw4w9WgXcQ',
      ]) {
        expect(classify(url).kind, VideoSourceKind.unsupported, reason: url);
      }
    });

    test('a user-info prefix cannot disguise the real host', () {
      expect(
        classify(
          'https://www.youtube.com@evil.example/watch?v=dQw4w9WgXcQ',
        ).kind,
        VideoSourceKind.unsupported,
      );
    });

    test('http YouTube is rejected', () {
      expect(
        classify('http://www.youtube.com/watch?v=dQw4w9WgXcQ').kind,
        VideoSourceKind.unsupported,
      );
    });
  });

  group('thumbnailUri', () {
    for (final url in [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtu.be/dQw4w9WgXcQ',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
      'https://WWW.YOUTUBE.COM/watch?v=dQw4w9WgXcQ',
    ]) {
      test('a YouTube video has its still: $url', () {
        expect(
          classify(url).thumbnailUri.toString(),
          'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
        );
      });
    }

    test('a playlist, Vimeo, a file or a bad link has none', () {
      for (final url in [
        'https://www.youtube.com/playlist?list=PL1234',
        'https://vimeo.com/76979871',
        'https://cdn.example.org/clip.mp4',
        'not a link',
      ]) {
        expect(classify(url).thumbnailUri, isNull, reason: url);
      }
    });
  });

  group('Vimeo', () {
    for (final url in [
      'https://vimeo.com/76979871',
      'https://www.vimeo.com/76979871',
      'https://player.vimeo.com/video/76979871',
      'https://vimeo.com/channels/staffpicks/76979871',
    ]) {
      test('recognises $url', () {
        final source = classify(url);
        expect(source.kind, VideoSourceKind.vimeo);
        expect(source.label, 'External · Vimeo');
        expect(source.openLabel, 'Open video on Vimeo');
        expect(source.playsInApp, isFalse);
      });
    }

    test('a Vimeo profile page is not a video', () {
      expect(
        classify('https://vimeo.com/someuser').kind,
        VideoSourceKind.unsupported,
      );
    });

    test('look-alike hosts are not Vimeo', () {
      expect(
        classify('https://vimeo.com.evil.example/76979871').kind,
        VideoSourceKind.unsupported,
      );
    });
  });

  group('direct external files', () {
    test('an https .mp4 elsewhere plays in the app with its domain', () {
      final source = classify('https://www.example.org/media/ladder.mp4');
      expect(source.kind, VideoSourceKind.externalFile);
      expect(source.label, 'External · example.org');
      expect(source.playsInApp, isTrue);
    });

    test('every supported extension is accepted, in any case', () {
      for (final ext in ['mp4', 'M4V', 'webm', 'MOV']) {
        expect(
          classify('https://cdn.example.org/a.$ext').kind,
          VideoSourceKind.externalFile,
          reason: ext,
        );
      }
    });

    test('an http video file is rejected', () {
      expect(
        classify('http://example.org/a.mp4').kind,
        VideoSourceKind.unsupported,
      );
    });

    test('a query string ending in .mp4 is not a video file', () {
      expect(
        classify('https://example.org/page?file=a.mp4').kind,
        VideoSourceKind.unsupported,
      );
    });
  });

  group('invalid and unsupported links', () {
    for (final url in [
      '',
      'not a url',
      'www.youtube.com/watch?v=dQw4w9WgXcQ',
      'javascript:alert(1)',
      'file:///C:/videos/a.mp4',
      'ftp://example.org/a.mp4',
      'intent://scan/#Intent;scheme=zxing;end',
      'mailto:safety@example.org',
    ]) {
      test('rejects "$url"', () {
        final source = classify(url);
        expect(source.kind, VideoSourceKind.unsupported);
        expect(source.playsInApp, isFalse);
        expect(source.problem, isNotNull);
      });
    }

    test('an ordinary web page is rejected with the approved-list message', () {
      final source = classify('https://example.org/safety/ladders');
      expect(source.kind, VideoSourceKind.unsupported);
      expect(source.problem, contains('YouTube, Vimeo'));
    });
  });

  group('videoSourceFor', () {
    test('returns null for non-video learning types', () {
      expect(
        videoSourceFor(
          type: SafetyLearningType.document,
          reference: 'https://example.org/a.pdf',
          organizationId: _org,
          storageBucket: _bucket,
        ),
        isNull,
      );
    });
  });

  group('uploadSizeError', () {
    test('accepts files under 25 MB', () {
      expect(uploadSizeError(0), isNull);
      expect(uploadSizeError(maxLearningUploadBytes - 1), isNull);
    });

    test('rejects 25 MB and above, matching storage.rules', () {
      expect(uploadSizeError(maxLearningUploadBytes), contains('25 MB'));
      expect(uploadSizeError(100 * 1024 * 1024), contains('MP4'));
    });

    test(
      'the exact boundary: 26,214,399 bytes passes, 26,214,400 does not',
      () {
        expect(maxLearningUploadBytes, 26214400);
        expect(uploadSizeError(26214399), isNull);
        expect(
          uploadSizeError(26214400),
          startsWith('Files must be under 25 MB.'),
        );
      },
    );
  });

  group('uploadTypeError (matches storage.rules)', () {
    test('a video upload accepts video files only', () {
      for (final name in ['clip.mp4', 'CLIP.MOV', 'a.webm', 'a.m4v']) {
        expect(uploadTypeError(name, videoOnly: true), isNull, reason: name);
      }
      for (final name in ['handbook.pdf', 'page.html', 'noextension']) {
        expect(
          uploadTypeError(name, videoOnly: true),
          contains('supported video'),
          reason: name,
        );
      }
    });

    test('a library upload accepts the documented document types', () {
      for (final name in [
        'a.pdf',
        'a.doc',
        'a.docx',
        'a.ppt',
        'a.pptx',
        'a.xls',
        'a.xlsx',
        'a.png',
        'a.jpg',
        'a.jpeg',
        'a.mp4',
        'a.mov',
      ]) {
        expect(uploadTypeError(name), isNull, reason: name);
      }
    });

    test('other types are refused before upload', () {
      for (final name in ['page.html', 'script.js', 'a.exe', 'noextension']) {
        expect(
          uploadTypeError(name),
          contains('cannot be uploaded'),
          reason: name,
        );
      }
    });
  });

  group('the manual YouTube test candidate', () {
    test('is accepted as YouTube and opens externally', () {
      final source = classify('https://www.youtube.com/watch?v=jfKfPfyJRdk');
      expect(source.kind, VideoSourceKind.youtube);
      expect(source.label, 'External · YouTube');
      expect(source.playsInApp, isFalse);
      expect(source.openLabel, 'Watch on YouTube');
    });
  });

  group('tightened host checks', () {
    test('an explicit non-default port is rejected', () {
      for (final url in [
        'https://www.youtube.com:8443/watch?v=dQw4w9WgXcQ',
        'https://vimeo.com:444/76979871',
        'https://cdn.example.org:8080/a.mp4',
      ]) {
        final source = classify(url);
        expect(source.kind, VideoSourceKind.unsupported, reason: url);
        expect(source.problem, contains('port'), reason: url);
      }
    });

    test('the default https port is accepted', () {
      expect(
        classify('https://www.youtube.com:443/watch?v=dQw4w9WgXcQ').kind,
        VideoSourceKind.youtube,
      );
    });

    test('IP addresses, localhost and bare machine names are rejected', () {
      for (final url in [
        'https://10.0.0.5/a.mp4',
        'https://192.168.1.10/media/a.mp4',
        'https://[::1]/a.mp4',
        'https://localhost/a.mp4',
        'https://videos.localhost/a.mp4',
        'https://fileserver/a.mp4',
      ]) {
        final source = classify(url);
        expect(source.kind, VideoSourceKind.unsupported, reason: url);
        expect(source.problem, contains('website address'), reason: url);
      }
    });

    test('Vimeo accepts only single-video link shapes', () {
      for (final url in [
        'https://vimeo.com/76979871',
        'https://vimeo.com/76979871/a1b2c3d4e5',
        'https://vimeo.com/channels/staffpicks/76979871',
        'https://vimeo.com/groups/safety/videos/76979871',
        'https://player.vimeo.com/video/76979871',
      ]) {
        expect(classify(url).kind, VideoSourceKind.vimeo, reason: url);
      }
      for (final url in [
        'https://vimeo.com/showcase/123',
        'https://vimeo.com/album/123',
        'https://vimeo.com/groups/123',
        'https://vimeo.com/channels/123',
        'https://vimeo.com/user/123',
        'https://player.vimeo.com/123',
      ]) {
        expect(classify(url).kind, VideoSourceKind.unsupported, reason: url);
      }
    });
  });
}
