// camera.dart 

import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class CameraService {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];

  CameraLensDirection _lensDirection = CameraLensDirection.front;

  bool _isDisposed = false;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;
  CameraLensDirection get lensDirection => _lensDirection;

  Future<void> initialize({
    CameraLensDirection preferred = CameraLensDirection.front,
  }) async {
    try {
      _cameras = await availableCameras();
      _lensDirection = preferred;

      final cam = _pickCamera(preferred) ?? _cameras.first;
      await _start(cam);
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  CameraDescription? _pickCamera(CameraLensDirection lens) {
    for (final c in _cameras) {
      if (c.lensDirection == lens) return c;
    }
    return null;
  }

  Future<void> _start(CameraDescription cam) async {
    try {
      await _controller?.dispose();

      _controller = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _controller!.initialize();

      try {
        await _controller!.setExposureMode(ExposureMode.auto);
        await _controller!.setFocusMode(FocusMode.auto);

        final maxExposure = await _controller!.getMaxExposureOffset();
        if (maxExposure > 0) {
          await _controller!.setExposureOffset(maxExposure * 0.3);
          debugPrint(
              'Camera: Exposure boosted (+${(maxExposure * 0.3).toStringAsFixed(2)})');
        }

        debugPrint('Camera optimized: high resolution + auto exposure');
      } catch (e) {
        debugPrint(' Camera settings failed: $e (continuing)');
      }
    } catch (e, st) {
      debugPrint(' Camera start failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> switchCamera() async {
    if (_cameras.isEmpty) return;

    try {
      _lensDirection =
          _lensDirection == CameraLensDirection.back
              ? CameraLensDirection.front
              : CameraLensDirection.back;

      final cam = _pickCamera(_lensDirection) ?? _cameras.first;
      await _start(cam);
    } catch (e) {
      debugPrint('Switch camera failed: $e');
    }
  }

  Future<XFile> takePicture() async {
    try {
      final c = _controller;

      if (c == null || !c.value.isInitialized) {
        throw Exception('Camera not initialized');
      }

      if (c.value.isTakingPicture) {
        debugPrint(' Camera busy, waiting...');
        await Future.delayed(const Duration(milliseconds: 100));
      }

      if (!c.value.isInitialized) {
        throw Exception('Camera not initialized after delay');
      }

      return c.takePicture();
    } catch (e, st) {
      debugPrint(' Take picture failed: $e\n$st');
      rethrow;
    }
  }

  // Image stream for YOLO detection
  Future<void> startStream(void Function(CameraImage image) onFrame) async {
    try {
      final c = _controller;

      if (c == null || !c.value.isInitialized) {
        throw Exception('Camera not initialized');
      }

      if (c.value.isStreamingImages) {
        debugPrint('Stream already running');
        return;
      }

      await c.startImageStream(onFrame);
      debugPrint(' Image stream started');
    } catch (e, st) {
      debugPrint(' Start stream failed: $e\n$st');
      rethrow;
    }
  }

  
  Future<void> stopStream() async {
    try {
      final c = _controller;

      if (c == null) {
        debugPrint(' Controller null when stopping stream');
        return;
      }

      if (!c.value.isInitialized) return;

      if (!c.value.isStreamingImages) {
        debugPrint(' Stream not running');
        return;
      }

      try {
        await c.stopImageStream();
      } catch (e) {
        debugPrint(' stopImageStream safe ignore: $e');
      }

      debugPrint('Image stream stopped');
    } catch (e) {
      debugPrint(' Stop stream error: $e (continuing)');
    }
  }

  Widget buildPreview() {
    final c = _controller;

    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return CameraPreview(c);
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      debugPrint(' Already disposed');
      return;
    }

    _isDisposed = true;

    try {
      await Future.delayed(const Duration(milliseconds: 50));

      await stopStream();
    } catch (e) {
      debugPrint(' Stop stream during dispose: $e');
    }

    try {
      await _controller?.dispose();
      _controller = null;
      debugPrint(' Camera disposed');
    } catch (e) {
      debugPrint(' Dispose error: $e');
    }
  }
}