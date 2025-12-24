import "package:camera/camera.dart";
import "package:image/image.dart" as img;

class CameraService {
  CameraController? _controller;
  List<CameraDescription>? _cameras;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  Future<void> initialize() async {
    _cameras = await availableCameras();

    final back = _cameras!.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras!.first,
    );

    _controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
  }

  Future<XFile?> captureXFile() async {
    final c = _controller;
    if (c == null) return null;
    if (!c.value.isInitialized) return null;
    if (c.value.isTakingPicture) return null;

    return c.takePicture();
  }

  Future<img.Image?> captureDecodedImage() async {
    final xf = await captureXFile();
    if (xf == null) return null;

    final bytes = await xf.readAsBytes();
    return img.decodeImage(bytes);
  }

  Future<void> switchCamera() async {
    if (_cameras == null) return;
    if (_cameras!.length < 2) return;
    final c = _controller;
    if (c == null) return;

    final currentIndex = _cameras!.indexOf(c.description);
    final nextIndex = (currentIndex + 1) % _cameras!.length;

    await c.dispose();

    _controller = CameraController(
      _cameras![nextIndex],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
  }

  Future<void> setFlash(bool on) async {
    final c = _controller;
    if (c == null) return;
    if (!c.value.isInitialized) return;

    await c.setFlashMode(on ? FlashMode.torch : FlashMode.off);
  }

  void dispose() {
    _controller?.dispose();
    _controller = null;
  }
}
