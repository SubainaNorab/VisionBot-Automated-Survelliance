// lib/sm_grp.dart
// Smoking + Group detection using 2x TFLite models (YOLO + Smoking)

import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
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
  String toString() {
    return 'DetectionResult(smoking: $smokingDetected, group: $groupDetected, people: $personCount)';
  }
}

class _DetBox {
  final double x1, y1, x2, y2;
  final double score;
  final int cls;
  _DetBox(this.x1, this.y1, this.x2, this.y2, this.score, this.cls);
}

class MultiDetectorService {
  // === Update paths if your filenames differ ===
  static const String yoloModelPath = 'assets/yolov8n.tflite';
  static const String smokeModelPath = 'assets/smoking.tflite';

  // YOLO expects 640x640x3 float32 (as you printed)
  static const int inputSize = 640;

  // thresholds (tune later)
  final double personConf = 0.35;
  final double smokeConf = 0.35;
  final double iouThresh = 0.45;

  bool _isInitialized = false;

  Interpreter? _yolo;
  Interpreter? _smoke;

  Future<void> initialize() async {
    try {
      _yolo = await Interpreter.fromAsset(yoloModelPath);
      _smoke = await Interpreter.fromAsset(smokeModelPath);
      _isInitialized = true;

      debugPrint('✅ MultiDetectorService initialized');
      debugPrint('   YOLO:  $yoloModelPath');
      debugPrint('   Smoke: $smokeModelPath');
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

  bool get isInitialized => _isInitialized;


  /// Recommended: if you already take a picture and decode using `image` package,
  /// call this.
  Future<DetectionResult> detectAllFromImage(img.Image rgb) async {
    if (!_isInitialized || _yolo == null || _smoke == null) {
      return DetectionResult(smokingDetected: false, groupDetected: false, personCount: 0);
    }

    final input = _preprocess(rgb);

    // YOLO output: [1, 84, 8400]
    final yoloOut = List.generate(1, (_) => List.generate(84, (_) => List.filled(8400, 0.0)));

    // smoking output: [1, 5, 8400]  (4 box + 1 score/class)
    final smokeOut = List.generate(1, (_) => List.generate(5, (_) => List.filled(8400, 0.0)));

    _yolo!.run(input, yoloOut);
    _smoke!.run(input, smokeOut);

    final personCount = _countPersonsFromYolo(yoloOut);
    final groupDetected = personCount >= 3;

    final smokingDetected = _detectSmoking(smokeOut);

    return DetectionResult(
      smokingDetected: smokingDetected,
      groupDetected: groupDetected,
      personCount: personCount,
    );
  }

  /// If later you want true realtime CameraImage stream, use this.
  /// (This does YUV->RGB conversion, which is heavier.)
  Future<DetectionResult> detectAll(CameraImage image) async {
    final rgb = _cameraImageToImage(image);
    if (rgb == null) {
      return DetectionResult(smokingDetected: false, groupDetected: false, personCount: 0);
    }
    return detectAllFromImage(rgb);
  }

  // ============================================================
  // PREPROCESS (NHWC float32 0..1)
  // ============================================================

  List<List<List<List<double>>>> _preprocess(img.Image rgb) {
    final resized = img.copyResize(rgb, width: inputSize, height: inputSize);

    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (_) => List.generate(inputSize, (_) => List.filled(3, 0.0)),
      ),
    );

    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final p = resized.getPixel(x, y);
        input[0][y][x][0] = p.r / 255.0;
        input[0][y][x][1] = p.g / 255.0;
        input[0][y][x][2] = p.b / 255.0;
      }
    }
    return input;
  }

  // ============================================================
  // YOLO PARSE -> PERSON COUNT
  // Output shape: [1, 84, 8400] (x,y,w,h + 80 class scores)
  // Person class in COCO is class 0.
  // ============================================================

  int _countPersonsFromYolo(List yoloOut) {
    final boxes = _parseYolo84(yoloOut, targetClass: 0, confThresh: personConf);
    final kept = _nms(boxes, iouThresh);
    return kept.length;
  }

  List<_DetBox> _parseYolo84(List yoloOut, {required int targetClass, required double confThresh}) {
    // yoloOut[0][feat][i]
    final List<_DetBox> dets = [];

    for (int i = 0; i < 8400; i++) {
      final cx = (yoloOut[0][0][i] as num).toDouble();
      final cy = (yoloOut[0][1][i] as num).toDouble();
      final w  = (yoloOut[0][2][i] as num).toDouble();
      final h  = (yoloOut[0][3][i] as num).toDouble();

      // class score for targetClass is at index 4 + cls
      final score = (yoloOut[0][4 + targetClass][i] as num).toDouble();
      if (score < confThresh) continue;

      final x1 = (cx - w / 2);
      final y1 = (cy - h / 2);
      final x2 = (cx + w / 2);
      final y2 = (cy + h / 2);

      dets.add(_DetBox(x1, y1, x2, y2, score, targetClass));
    }

    dets.sort((a, b) => b.score.compareTo(a.score));
    return dets;
  }

  // ============================================================
  // SMOKING PARSE
  // Output shape: [1, 5, 8400] (x,y,w,h + score)
  // We assume single-class detector (smoke/cigarette).
  // ============================================================

  bool _detectSmoking(List smokeOut) {
    final boxes = _parseSmoke5(smokeOut, confThresh: smokeConf);
    final kept = _nms(boxes, iouThresh);
    return kept.isNotEmpty;
  }

  List<_DetBox> _parseSmoke5(List smokeOut, {required double confThresh}) {
    final List<_DetBox> dets = [];

    for (int i = 0; i < 8400; i++) {
      final cx = (smokeOut[0][0][i] as num).toDouble();
      final cy = (smokeOut[0][1][i] as num).toDouble();
      final w  = (smokeOut[0][2][i] as num).toDouble();
      final h  = (smokeOut[0][3][i] as num).toDouble();

      final score = (smokeOut[0][4][i] as num).toDouble();
      if (score < confThresh) continue;

      final x1 = (cx - w / 2);
      final y1 = (cy - h / 2);
      final x2 = (cx + w / 2);
      final y2 = (cy + h / 2);

      dets.add(_DetBox(x1, y1, x2, y2, score, 0));
    }

    dets.sort((a, b) => b.score.compareTo(a.score));
    return dets;
  }

  // ============================================================
  // NMS + IOU
  // ============================================================

  List<_DetBox> _nms(List<_DetBox> dets, double iouThreshold) {
    final List<_DetBox> keep = [];
    final List<_DetBox> work = List<_DetBox>.from(dets);

    while (work.isNotEmpty) {
      final best = work.removeAt(0);
      keep.add(best);

      work.removeWhere((d) => _iou(best, d) > iouThreshold);
    }
    return keep;
  }

  double _iou(_DetBox a, _DetBox b) {
    final ax1 = a.x1, ay1 = a.y1, ax2 = a.x2, ay2 = a.y2;
    final bx1 = b.x1, by1 = b.y1, bx2 = b.x2, by2 = b.y2;

    final interX1 = max(ax1, bx1);
    final interY1 = max(ay1, by1);
    final interX2 = min(ax2, bx2);
    final interY2 = min(ay2, by2);

    final interW = max(0.0, interX2 - interX1);
    final interH = max(0.0, interY2 - interY1);
    final interArea = interW * interH;

    final areaA = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1);
    final areaB = max(0.0, bx2 - bx1) * max(0.0, by2 - by1);

    final union = areaA + areaB - interArea;
    if (union <= 0) return 0.0;
    return interArea / union;
  }

  // ============================================================
  // CameraImage (YUV420) -> img.Image (RGB)
  // (Used only if you do realtime stream mode)
  // ============================================================

  img.Image? _cameraImageToImage(CameraImage cameraImage) {
    try {
      if (cameraImage.format.group != ImageFormatGroup.yuv420) return null;

      final int width = cameraImage.width;
      final int height = cameraImage.height;

      final uvRowStride = cameraImage.planes[1].bytesPerRow;
      final uvPixelStride = cameraImage.planes[1].bytesPerPixel ?? 2;

      final image = img.Image(width: width, height: height);

      final yPlane = cameraImage.planes[0].bytes;
      final uPlane = cameraImage.planes[1].bytes;
      final vPlane = cameraImage.planes[2].bytes;

      for (int y = 0; y < height; y++) {
        final int yRow = y * cameraImage.planes[0].bytesPerRow;
        final int uvRow = (y >> 1) * uvRowStride;

        for (int x = 0; x < width; x++) {
          final int yIndex = yRow + x;
          final int uvIndex = uvRow + (x >> 1) * uvPixelStride;

          final int Y = yPlane[yIndex];
          final int U = uPlane[uvIndex];
          final int V = vPlane[uvIndex];

          // YUV -> RGB
          final double yf = Y.toDouble();
          final double uf = U.toDouble() - 128.0;
          final double vf = V.toDouble() - 128.0;

          int r = (yf + 1.402 * vf).round();
          int g = (yf - 0.344136 * uf - 0.714136 * vf).round();
          int b = (yf + 1.772 * uf).round();

          r = r.clamp(0, 255);
          g = g.clamp(0, 255);
          b = b.clamp(0, 255);

          image.setPixelRgba(x, y, r, g, b, 255);
        }
      }
      return image;
    } catch (e) {
      debugPrint('⚠️ cameraImageToImage failed: $e');
      return null;
    }
  }
}
