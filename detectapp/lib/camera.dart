// camera
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class CameraService {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];

  CameraLensDirection _lensDirection = CameraLensDirection.front;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;
  CameraLensDirection get lensDirection => _lensDirection;

  Future<void> initialize({
    CameraLensDirection preferred = CameraLensDirection.front,
  }) async {
    _cameras = await availableCameras();
    _lensDirection = preferred;

    final cam = _pickCamera(preferred) ?? _cameras.first;
    await _start(cam);
  }

  CameraDescription? _pickCamera(CameraLensDirection lens) {
    for (final c in _cameras) {
      if (c.lensDirection == lens) return c;
    }
    return null;
  }

  Future<void> _start(CameraDescription cam) async {
    await _controller?.dispose();

    _controller = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
  }

  Future<void> switchCamera() async {
    if (_cameras.isEmpty) return;

    _lensDirection =
        _lensDirection == CameraLensDirection.back
            ? CameraLensDirection.front
            : CameraLensDirection.back;

    final cam = _pickCamera(_lensDirection) ?? _cameras.first;
    await _start(cam);
  }

  Future<XFile> takePicture() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      throw Exception('Camera not initialized');
    }
    if (c.value.isTakingPicture) {
      throw Exception('Camera is busy');
    }
    return c.takePicture();
  }

  /// ✅ REAL-TIME STREAM
  Future<void> startStream(
    Future<void> Function(CameraImage image) onFrame,
  ) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      throw Exception('Camera not initialized');
    }
    if (c.value.isStreamingImages) return;

    await c.startImageStream((image) async {
      await onFrame(image);
    });
  }

  Future<void> stopStream() async {
    final c = _controller;
    if (c == null) return;
    if (!c.value.isStreamingImages) return;
    await c.stopImageStream();
  }

  Widget buildPreview() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return CameraPreview(c);
  }

  Future<void> dispose() async {
    await stopStream();
    await _controller?.dispose();
    _controller = null;
  }
}
