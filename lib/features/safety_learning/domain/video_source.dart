/// Where a [SafetyLearningType.video] item's `contentReference` points, and
/// therefore how it may be played — worked out from the URL alone, so every
/// existing item gets a source with no new field and no migration.
///
/// The source says where a video is HOSTED, never who made it: "JVA video"
/// means a file in this organization's own JVA Safety Storage folder, not
/// necessarily one produced by JV ALMA CIS. It never decides whether a video
/// is required — that comes only from Safety Requirements and readiness.
///
/// Only four kinds are accepted: this organization's Storage, YouTube, Vimeo,
/// and a direct HTTPS video file elsewhere. Anything else (another
/// organization's Storage, another bucket, a non-HTTPS link, a plain web page)
/// is [VideoSourceKind.unsupported], so it is never played or opened.
///
/// Hosts are compared exactly, never by substring: `youtube.com.evil.example`
/// or `evil-youtube.com` are not YouTube.
library;

import 'package:mime/mime.dart';

import 'safety_learning_type.dart';

enum VideoSourceKind {
  /// A file in this organization's own JVA Safety Storage — plays in the app.
  jva,

  /// A YouTube video or playlist — opens in YouTube.
  youtube,

  /// A Vimeo video — opens in Vimeo.
  vimeo,

  /// A direct HTTPS video file hosted elsewhere — plays in the app when the
  /// host and browser allow it.
  externalFile,

  /// Missing, malformed, non-HTTPS, or not one of the kinds above.
  unsupported,
}

/// The largest file Storage accepts for an organization upload — mirrors
/// `request.resource.size < 25 * 1024 * 1024` in `storage.rules`.
const int maxLearningUploadBytes = 25 * 1024 * 1024;

/// The message to show when [bytes] is too large to upload, or null when the
/// file is small enough. Checked before uploading so an admin gets a clear
/// reason instead of Storage's generic refusal.
String? uploadSizeError(int bytes) {
  if (bytes < maxLearningUploadBytes) return null;
  return 'Files must be under 25 MB. Shorten or compress this one and try '
      'again — MP4 (H.264) works on every phone.';
}

/// The media types the library may upload — mirrors the `contentType`
/// allow-list on the Safety Learning folder in `storage.rules`.
final RegExp _uploadableTypes = RegExp(
  r'^(video/.*|image/(png|jpeg)|application/pdf|application/msword|'
  r'application/vnd\.ms-(powerpoint|excel)|'
  r'application/vnd\.openxmlformats-officedocument\..*)$',
);

/// The message to show when [fileName]'s type cannot be uploaded to the
/// library (by its extension, the same way the upload sets its
/// `contentType`), or null when it can. With [videoOnly], only video types.
String? uploadTypeError(String fileName, {bool videoOnly = false}) {
  final mimeType = lookupMimeType(fileName);
  final allowed =
      mimeType != null &&
      (videoOnly
          ? mimeType.startsWith('video/')
          : _uploadableTypes.hasMatch(mimeType));
  if (allowed) return null;
  return videoOnly
      ? 'This file is not a supported video. Choose an MP4, MOV, WEBM or '
            'M4V video.'
      : 'This file type cannot be uploaded. Use a video, PDF, Word, '
            'PowerPoint, Excel, PNG or JPEG file.';
}

/// The file extensions the in-app player is offered for an external file.
const List<String> directVideoExtensions = ['.mp4', '.m4v', '.webm', '.mov'];

/// Firebase Storage's production download host.
const String firebaseStorageOrigin = 'https://firebasestorage.googleapis.com';

class VideoSource {
  const VideoSource._(this.kind, {this.uri, this.domain, this.problem});

  final VideoSourceKind kind;

  /// The parsed link — null only when [kind] is
  /// [VideoSourceKind.unsupported] and the link could not be parsed at all.
  final Uri? uri;

  /// The host shown for an external file, without a leading `www.`.
  final String? domain;

  /// Why the link was rejected — an admin-facing message, set only for
  /// [VideoSourceKind.unsupported].
  final String? problem;

  static const _youtubeHosts = {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  };
  static const _youtubeShortHost = 'youtu.be';
  static const _vimeoHosts = {'vimeo.com', 'www.vimeo.com', 'player.vimeo.com'};
  static final _youtubeId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _digits = RegExp(r'^\d+$');
  static final _vimeoHash = RegExp(r'^[0-9a-f]+$');
  static final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  static const _needsHttps = 'Enter a full link starting with https://';
  static const _noPort = 'Remove the port number (":…") from the link.';
  static const _needsDomain =
      'Use a website address (like example.com), not a computer or network '
      'address.';
  static const _unsupportedSite =
      'Only YouTube, Vimeo or a direct video file (.mp4, .m4v, .webm, .mov) '
      'can be linked.';
  static const _notAVideo = 'This link is not to a single video.';
  static const _otherStorage =
      'This file is not in this organization\'s ALMASAFETY storage.';

  /// Works out the source of [reference] for [organizationId].
  ///
  /// [storageBucket] is the app's configured Firebase Storage bucket (read
  /// from the running Firebase app, never hard-coded); when null, no link
  /// can be recognised as a JVA video. [storageOrigin] is the Storage
  /// download origin — the production host by default; tests and emulator
  /// setups pass their own (e.g. `http://localhost:9199`), which is the only
  /// way a non-HTTPS link is ever accepted.
  static VideoSource classify(
    String reference, {
    required String organizationId,
    required String? storageBucket,
    String storageOrigin = firebaseStorageOrigin,
  }) {
    final uri = Uri.tryParse(reference.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        uri.host.isEmpty) {
      return const VideoSource._(
        VideoSourceKind.unsupported,
        problem: _needsHttps,
      );
    }
    // A link with a user name (`https://youtube.com@evil.example/`) reads as
    // one host but opens another.
    if (uri.userInfo.isNotEmpty) {
      return VideoSource._(
        VideoSourceKind.unsupported,
        uri: uri,
        problem: _needsHttps,
      );
    }

    final origin = Uri.tryParse(storageOrigin);
    if (origin != null && _sameOrigin(uri, origin)) {
      return _classifyStorage(uri, organizationId, storageBucket);
    }
    if (uri.scheme != 'https') {
      return VideoSource._(
        VideoSourceKind.unsupported,
        uri: uri,
        problem: _needsHttps,
      );
    }

    // An explicit, non-default port (`:443` is dropped by the parser) is
    // never needed by a real video host.
    if (uri.hasPort) {
      return VideoSource._(
        VideoSourceKind.unsupported,
        uri: uri,
        problem: _noPort,
      );
    }
    final host = uri.host.toLowerCase();
    // Only public domain names: no IP addresses, `localhost`, or bare
    // machine names.
    if (!host.contains('.') ||
        host.contains(':') ||
        _ipv4.hasMatch(host) ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.')) {
      return VideoSource._(
        VideoSourceKind.unsupported,
        uri: uri,
        problem: _needsDomain,
      );
    }
    // Any other Storage host is somebody else's files.
    if (host == Uri.parse(firebaseStorageOrigin).host ||
        host.endsWith('.firebasestorage.app') ||
        host == 'storage.googleapis.com') {
      return VideoSource._(
        VideoSourceKind.unsupported,
        uri: uri,
        problem: _otherStorage,
      );
    }
    if (_youtubeHosts.contains(host) || host == _youtubeShortHost) {
      return _isYoutubeVideo(uri, host)
          ? VideoSource._(VideoSourceKind.youtube, uri: uri)
          : VideoSource._(
              VideoSourceKind.unsupported,
              uri: uri,
              problem: _notAVideo,
            );
    }
    if (_vimeoHosts.contains(host)) {
      return _isVimeoVideo(uri, host)
          ? VideoSource._(VideoSourceKind.vimeo, uri: uri)
          : VideoSource._(
              VideoSourceKind.unsupported,
              uri: uri,
              problem: _notAVideo,
            );
    }
    if (_hasVideoExtension(uri.path)) {
      return VideoSource._(
        VideoSourceKind.externalFile,
        uri: uri,
        domain: host.startsWith('www.') ? host.substring(4) : host,
      );
    }
    return VideoSource._(
      VideoSourceKind.unsupported,
      uri: uri,
      problem: _unsupportedSite,
    );
  }

  /// A Storage download URL is
  /// `{origin}/v0/b/{bucket}/o/{url-encoded object path}`; it is a JVA video
  /// only when the bucket is the app's own and the object sits in this
  /// organization's `safety_learning/` folder.
  static VideoSource _classifyStorage(
    Uri uri,
    String organizationId,
    String? storageBucket,
  ) {
    final segments = uri.pathSegments;
    final objectPath =
        segments.length == 5 &&
            segments[0] == 'v0' &&
            segments[1] == 'b' &&
            segments[3] == 'o'
        ? segments[4]
        : null;
    final prefix = 'organizations/$organizationId/safety_learning/';
    final objectParts = objectPath?.split('/') ?? const <String>[];
    final isOwn =
        storageBucket != null &&
        storageBucket.isNotEmpty &&
        organizationId.isNotEmpty &&
        segments.length == 5 &&
        segments[2] == storageBucket &&
        objectPath != null &&
        objectPath.startsWith(prefix) &&
        objectPath.length > prefix.length &&
        !objectParts.any((part) => part.isEmpty || part == '..' || part == '.');
    return isOwn
        ? VideoSource._(VideoSourceKind.jva, uri: uri)
        : VideoSource._(
            VideoSourceKind.unsupported,
            uri: uri,
            problem: _otherStorage,
          );
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  static bool _hasVideoExtension(String path) {
    final lower = path.toLowerCase();
    return directVideoExtensions.any(lower.endsWith);
  }

  /// Vimeo's single-video links only: `vimeo.com/{id}` (optionally with a
  /// private-link hash), `vimeo.com/channels/{name}/{id}`,
  /// `vimeo.com/groups/{name}/videos/{id}` and
  /// `player.vimeo.com/video/{id}`. Showcases, albums, groups, profiles and
  /// channel pages are not single videos.
  static bool _isVimeoVideo(Uri uri, String host) {
    final s = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (host == 'player.vimeo.com') {
      return s.length == 2 && s[0] == 'video' && _digits.hasMatch(s[1]);
    }
    if (s.length == 1) return _digits.hasMatch(s[0]);
    if (s.length == 2) {
      return _digits.hasMatch(s[0]) && _vimeoHash.hasMatch(s[1]);
    }
    if (s.length == 3 && s[0] == 'channels') return _digits.hasMatch(s[2]);
    if (s.length == 4 && s[0] == 'groups' && s[2] == 'videos') {
      return _digits.hasMatch(s[3]);
    }
    return false;
  }

  static bool _isYoutubeVideo(Uri uri, String host) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (host == _youtubeShortHost) {
      return segments.length == 1 && _youtubeId.hasMatch(segments.first);
    }
    if (segments.length == 1 && segments.first == 'watch') {
      return _youtubeId.hasMatch(uri.queryParameters['v'] ?? '');
    }
    if (segments.length == 1 && segments.first == 'playlist') {
      return (uri.queryParameters['list'] ?? '').isNotEmpty;
    }
    if (segments.length == 2 &&
        const {'shorts', 'embed', 'live'}.contains(segments.first)) {
      return _youtubeId.hasMatch(segments[1]);
    }
    return false;
  }

  /// A YouTube video's own still image — the public image YouTube serves
  /// for every video, derived from its id. Null for anything else (no other
  /// source exposes one, and nothing is stored), and for a playlist.
  Uri? get thumbnailUri {
    final link = uri;
    if (kind != VideoSourceKind.youtube || link == null) return null;
    final segments = link.pathSegments.where((s) => s.isNotEmpty).toList();
    final String? id;
    if (link.host.toLowerCase() == _youtubeShortHost) {
      id = segments.isEmpty ? null : segments.first;
    } else if (segments.length == 1 && segments.first == 'watch') {
      id = link.queryParameters['v'];
    } else if (segments.length == 2) {
      id = segments[1];
    } else {
      id = null;
    }
    if (id == null || !_youtubeId.hasMatch(id)) return null;
    return Uri.https('i.ytimg.com', '/vi/$id/hqdefault.jpg');
  }

  bool get isJva => kind == VideoSourceKind.jva;
  bool get isExternal =>
      kind == VideoSourceKind.youtube ||
      kind == VideoSourceKind.vimeo ||
      kind == VideoSourceKind.externalFile;
  bool get isUnsupported => kind == VideoSourceKind.unsupported;

  /// Whether the generic in-app video-file player is offered. Never true for
  /// a YouTube or Vimeo page, which that player cannot play.
  bool get playsInApp =>
      kind == VideoSourceKind.jva || kind == VideoSourceKind.externalFile;

  /// The short source label shown on cards and in the library.
  String get label => switch (kind) {
    VideoSourceKind.jva => 'JVA video',
    VideoSourceKind.youtube => 'External · YouTube',
    VideoSourceKind.vimeo => 'External · Vimeo',
    VideoSourceKind.externalFile => 'External · $domain',
    VideoSourceKind.unsupported => 'Link problem',
  };

  /// The button label for opening this video outside the app.
  String get openLabel => switch (kind) {
    VideoSourceKind.youtube => 'Watch on YouTube',
    VideoSourceKind.vimeo => 'Open video on Vimeo',
    VideoSourceKind.externalFile => 'Open video on $domain',
    _ => 'Open video',
  };
}

/// The source of [type]/[reference], or null when the item is not a video.
VideoSource? videoSourceFor({
  required SafetyLearningType type,
  required String reference,
  required String organizationId,
  required String? storageBucket,
  String storageOrigin = firebaseStorageOrigin,
}) {
  if (type != SafetyLearningType.video) return null;
  return VideoSource.classify(
    reference,
    organizationId: organizationId,
    storageBucket: storageBucket,
    storageOrigin: storageOrigin,
  );
}
