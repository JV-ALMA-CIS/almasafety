import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// "Take photo" everywhere in the app (hazard, incident, meeting evidence,
/// corrective-action evidence).
///
/// - **Installed app (Android/iOS):** the phone's own camera, via
///   [ImagePicker] — that already opens the camera directly.
/// - **Web app (phone/tablet browser):** an in-app camera screen with a live
///   preview and a shutter button. The browser file picker only *hints*
///   "use the camera", and many browsers/tablets ignore that and open the
///   gallery instead — which is what workers saw.
///
/// Falls back to the picker when the browser has no camera or permission is
/// refused, so a photo can always be added. Returns null when cancelled.
Future<XFile?> takePhoto(
  BuildContext context, {
  required ImagePicker picker,
  double maxWidth = 1600,
  int imageQuality = 85,
}) async {
  if (!kIsWeb) {
    return picker.pickImage(
      source: ImageSource.camera,
      maxWidth: maxWidth,
      imageQuality: imageQuality,
    );
  }
  final result = await Navigator.of(context, rootNavigator: true)
      .push<_CaptureResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const _CameraCaptureScreen(),
        ),
      );
  if (result == null) return null;
  if (result.photo != null) return result.photo;
  // No usable camera in this browser: let them pick a photo instead.
  return picker.pickImage(
    source: ImageSource.camera,
    maxWidth: maxWidth,
    imageQuality: imageQuality,
  );
}

class _CaptureResult {
  const _CaptureResult.photo(XFile this.photo);
  const _CaptureResult.useFallback() : photo = null;

  final XFile? photo;
}

class _CameraCaptureScreen extends StatefulWidget {
  const _CameraCaptureScreen();

  @override
  State<_CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<_CameraCaptureScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  String? _error;
  bool _isTaking = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _error = 'No camera was found on this device.');
        return;
      }
      // Prefer the back camera — photos of the site, not of the worker.
      final back = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      _cameraIndex = back >= 0 ? back : 0;
      await _open(_cameras[_cameraIndex]);
    } on Object {
      if (!mounted) return;
      setState(
        () => _error =
            'The camera could not be opened. Allow camera access for this '
            'site in your browser, or choose a photo instead.',
      );
    }
  }

  Future<void> _open(CameraDescription camera) async {
    final previous = _controller;
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
    );
    setState(() => _controller = null);
    await previous?.dispose();
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _error = null;
    });
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    try {
      await _open(_cameras[_cameraIndex]);
    } on Object {
      if (mounted) setState(() => _error = 'Could not switch camera.');
    }
  }

  Future<void> _take() async {
    final controller = _controller;
    if (controller == null || _isTaking) return;
    setState(() => _isTaking = true);
    try {
      final photo = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(_CaptureResult.photo(photo));
    } on Object {
      if (mounted) {
        setState(() {
          _isTaking = false;
          _error = 'The photo could not be taken. Please try again.';
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (_cameras.length > 1)
            IconButton(
              tooltip: 'Switch camera',
              onPressed: _isTaking ? null : _switchCamera,
              icon: const Icon(Icons.cameraswitch),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.no_photography,
                              color: Colors.white,
                              size: 48,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            FilledButton.icon(
                              onPressed: () => Navigator.of(
                                context,
                              ).pop(const _CaptureResult.useFallback()),
                              icon: const Icon(Icons.photo_library_outlined),
                              label: const Text('Choose a photo instead'),
                            ),
                          ],
                        ),
                      )
                    : controller == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : CameraPreview(controller),
              ),
            ),
            if (_error == null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: SizedBox(
                  width: 76,
                  height: 76,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.textPrimary,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: controller == null || _isTaking ? null : _take,
                    child: _isTaking
                        ? const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          )
                        : const Icon(Icons.camera_alt, size: 34),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
