import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';

class CameraService {
  CameraController? _controller;
  List<CameraDescription>? _cameras;

  bool get isInitialized => _controller?.value.isInitialized ?? false;
  CameraController? get controller => _controller;

  /// Initialize camera
  Future<void> initialize() async {
    print('📷 Initializing camera...');

    try {
      // Get available cameras
      _cameras = await availableCameras();

      if (_cameras == null || _cameras!.isEmpty) {
        throw Exception('No cameras found on device');
      }

      print('   Found ${_cameras!.length} camera(s)');
      for (var i = 0; i < _cameras!.length; i++) {
        print(
            '   Camera $i: ${_cameras![i].name} (${_cameras![i].lensDirection})');
      }

      // Use first camera (usually back camera)
      // For car system, this should be the front-facing camera
      final cameraToUse = _cameras!.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras!.first,
      );

      print('   Using:  ${cameraToUse.name}');

      // Initialize controller
      _controller = CameraController(
        cameraToUse,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();

      print('✅ Camera initialized successfully');
      print('   Resolution: ${_controller!.value.previewSize}');
    } catch (e) {
      print('❌ Camera initialization failed: $e');
      rethrow;
    }
  }

  /// Capture image from camera
  Future<img.Image?> captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      print('❌ Camera not initialized');
      return null;
    }

    try {
      print('📸 Capturing image...');

      // Take picture
      final XFile imageFile = await _controller!.takePicture();

      // Read bytes
      final Uint8List bytes = await imageFile.readAsBytes();

      print('   Image size: ${bytes.length} bytes');

      // Decode image
      final image = img.decodeImage(bytes);

      if (image == null) {
        print('❌ Failed to decode image');
        return null;
      }

      print('✅ Image captured:  ${image.width}x${image.height}');

      return image;
    } catch (e) {
      print('❌ Image capture failed:  $e');
      return null;
    }
  }

  /// Switch to next available camera
  Future<void> switchCamera() async {
    if (_cameras == null || _cameras!.length < 2) {
      print('⚠️ No other cameras available');
      return;
    }

    try {
      final currentIndex = _cameras!.indexOf(_controller!.description);
      final nextIndex = (currentIndex + 1) % _cameras!.length;

      await _controller?.dispose();

      _controller = CameraController(
        _cameras![nextIndex],
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _controller!.initialize();

      print('✅ Switched to camera:  ${_cameras![nextIndex].name}');
    } catch (e) {
      print('❌ Camera switch failed: $e');
    }
  }

  /// Dispose camera resources
  void dispose() {
    _controller?.dispose();
    _controller = null;
    print('🗑️ Camera disposed');
  }
}
