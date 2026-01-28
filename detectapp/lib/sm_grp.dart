// lib/sm_grp.dart
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class DetectionResult {
  final bool smokingDetected;
  final bool groupDetected;
  final int personCount;

  DetectionResult({
    required this.smokingDetected,
    required this.groupDetected,
    required this.personCount,
  });

  @override
  String toString() =>
      'DetectionResult(smoking: $smokingDetected, group: $groupDetected, people: $personCount)';
}

class MultiDetectorService {
  // ✅ assets paths
  static const String yoloPeopleModel = 'assets/yolov8n.tflite';     // [1,84,8400]
  static const String smokingModel = 'assets/smoking.tflite';       // [1,5,8400]
  static const int inputSize = 640;

  Interpreter? _yolo;
  Interpreter? _smoke;
  bool _isInitialized = false;

  final double confThreshold;
  final double iouThreshold;

  MultiDetectorService({
    this.confThreshold = 0.40,
    this.iouThreshold = 0.45,
  });

  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    try {
      _yolo = await Interpreter.fromAsset(yoloPeopleModel);
      _smoke = await Interpreter.fromAsset(smokingModel);
      _isInitialized = true;
      debugPrint('✅ MultiDetectorService initialized (YOLO + Smoking loaded)');
    } catch (e) {
      _isInitialized = false;
      debugPrint('❌ MultiDetectorService init failed: $e');
    }
  }

  void dispose() {
    _yolo?.close();
    _smoke?.close();
    _yolo = null;
    _smoke = null;
    _isInitialized = false;
    debugPrint('✅ MultiDetectorService disposed');
  }

  Future<DetectionResult> detectAll(CameraImage image) async {
    if (!_isInitialized || _yolo == null || _smoke == null) {
      return DetectionResult(smokingDetected: false, groupDetected: false, personCount: 0);
    }

    // ✅ preprocess ONCE
    final input = _yuvToFloat32(image);

    // ------------------------
    // PEOPLE YOLO (84,8400)
    // ------------------------
    final outPeople = List.generate(
      1,
      (_) => List.generate(84, (_) => List.filled(8400, 0.0)),
    );
    _yolo!.run(input, outPeople);
    final personCount = _countPersonsFromYolo84(outPeople);

    // ------------------------
    // SMOKING YOLO (5,8400)
    // ------------------------
    final outSmoke = List.generate(
      1,
      (_) => List.generate(5, (_) => List.filled(8400, 0.0)),
    );
    _smoke!.run(input, outSmoke);
    final smokingDetected = _detectSmokingFromYolo5(outSmoke);

    return DetectionResult(
      smokingDetected: smokingDetected,
      groupDetected: personCount >= 2,
      personCount: personCount,
    );
  }

  // =========================
  // HELPERS
  // =========================

  /// Converts YUV420 camera image to normalized float32 [1,640,640,3]
  List<List<List<List<double>>>> _yuvToFloat32(CameraImage image) {
    final w = image.width;
    final h = image.height;

    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;

    final yRowStride = image.planes[0].bytesPerRow;
    final uvRowStride = image.planes[1].bytesPerRow;
    final uvPixelStride = image.planes[1].bytesPerPixel ?? 2;

    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (_) => List.generate(inputSize, (_) => List.filled(3, 0.0)),
      ),
    );

    for (int y = 0; y < inputSize; y++) {
      final srcY = (y * h / inputSize).floor();
      for (int x = 0; x < inputSize; x++) {
        final srcX = (x * w / inputSize).floor();

        final yIndex = srcY * yRowStride + srcX;
        final uvIndex = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

        final Y = yPlane[yIndex].toDouble();
        final U = uPlane[uvIndex].toDouble();
        final V = vPlane[uvIndex].toDouble();

        final r = (Y + 1.402 * (V - 128)).clamp(0, 255);
        final g = (Y - 0.344136 * (U - 128) - 0.714136 * (V - 128)).clamp(0, 255);
        final b = (Y + 1.772 * (U - 128)).clamp(0, 255);

        input[0][y][x][0] = r / 255.0;
        input[0][y][x][1] = g / 255.0;
        input[0][y][x][2] = b / 255.0;
      }
    }
    return input;
  }

  // YOLOv8 COCO head: [84, 8400] => xywh + 80 class scores
  int _countPersonsFromYolo84(List output) {
    final preds = output[0] as List<List<double>>; // [84][8400]
    final boxes = <_Box>[];

    for (int i = 0; i < 8400; i++) {
      final cx = preds[0][i];
      final cy = preds[1][i];
      final bw = preds[2][i];
      final bh = preds[3][i];

      // ✅ person is class 0 => index 4
      final personScore = preds[4][i];
      if (personScore < confThreshold) continue;

      final x1 = cx - bw / 2;
      final y1 = cy - bh / 2;
      final x2 = cx + bw / 2;
      final y2 = cy + bh / 2;

      boxes.add(_Box(x1, y1, x2, y2, personScore));
    }

    boxes.sort((a, b) => b.score.compareTo(a.score));
    final kept = <_Box>[];

    for (final b in boxes) {
      bool ok = true;
      for (final k in kept) {
        if (_iou(b, k) > iouThreshold) {
          ok = false;
          break;
        }
      }
      if (ok) kept.add(b);
    }

    return kept.length;
  }

  // Smoking head: [5, 8400] => likely xywh + 1 class score (smoking)
  bool _detectSmokingFromYolo5(List output) {
    final preds = output[0] as List<List<double>>; // [5][8400]

    for (int i = 0; i < 8400; i++) {
      final score = preds[4][i]; // single class score
      if (score >= confThreshold) {
        return true;
      }
    }
    return false;
  }

  double _iou(_Box a, _Box b) {
    final ix1 = max(a.x1, b.x1);
    final iy1 = max(a.y1, b.y1);
    final ix2 = min(a.x2, b.x2);
    final iy2 = min(a.y2, b.y2);

    final iw = max(0.0, ix2 - ix1);
    final ih = max(0.0, iy2 - iy1);

    final inter = iw * ih;
    final areaA = max(0.0, a.x2 - a.x1) * max(0.0, a.y2 - a.y1);
    final areaB = max(0.0, b.x2 - b.x1) * max(0.0, b.y2 - b.y1);

    return inter / (areaA + areaB - inter + 1e-6);
  }
}

class _Box {
  final double x1, y1, x2, y2;
  final double score;
  _Box(this.x1, this.y1, this.x2, this.y2, this.score);
}
