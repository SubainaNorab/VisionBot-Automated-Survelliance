import 'dart:io';

import 'package:camera/camera.dart';

class CameraService {
  CameraController? controller;
  List<CameraDescription>? _cameras;

  Future<void> initialize() async {
    _cameras = await availableCameras();

    if (_cameras == null || _cameras!.isEmpty) {
      throw Exception("No cameras found");
    }

    controller = CameraController(
      _cameras!.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await controller!.initialize();
    // ignore: avoid_print
    print("✅ Camera initialized");
  }

  Future<File?> captureImage() async {
    if (controller == null || !controller!.value.isInitialized) return null;

    final picture = await controller!.takePicture();
    return File(picture.path);
  }

  void dispose() {
    controller?.dispose();
  }
}
