// sm_grp.dart - FIXED: Lower thresholds, better debugging for YOLO

import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:math';

class DetectionResult {
  final bool smokingDetected;
  final bool groupDetected;
  final int personCount;
  final int processingTimeMs;
  final List<double> personConfidences;

  DetectionResult({
    required this.smokingDetected,
    required this.groupDetected,
    required this.personCount,
    this.processingTimeMs = 0,
    this.personConfidences = const [],
  });

  @override
  String toString() =>
      'Detection(people: $personCount, group: $groupDetected, smoke: $smokingDetected, ${processingTimeMs}ms)';
}

class _DetectionData {
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int width;
  final int height;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
  final Uint8List yoloModelData;
  final int groupThreshold;

  _DetectionData({
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
    required this.yoloModelData,
    required this.groupThreshold,
  });
}

class MultiDetectorService {
  Interpreter? _yolo;
  Uint8List? _yoloModelData;

  bool _isInitialized = false;
  bool _busy = false;

  int groupThreshold;
  
  // ✅ Debugging counters
  int _totalFramesProcessed = 0;
  int _totalDetectionsFound = 0;

  DetectionResult _last = DetectionResult(
    smokingDetected: false,
    groupDetected: false,
    personCount: 0,
  );

  MultiDetectorService({
    this.groupThreshold = 1,
  });

  bool get isInitialized => _isInitialized;
  DetectionResult get lastResult => _last;

  Future<void> initialize() async {
    try {
      debugPrint('');
      debugPrint('═══════════════════════════════════');
      debugPrint('🔧 MultiDetectorService: Loading YOLO');
      debugPrint('═══════════════════════════════════');

      final opt = InterpreterOptions()..threads = 2;

      try {
        _yolo = await Interpreter.fromAsset('assets/yolov8n.tflite', options: opt);
        
        final modelFile = await rootBundle.load('assets/yolov8n.tflite');
        _yoloModelData = modelFile.buffer.asUint8List();
        
        final inputShape = _yolo!.getInputTensor(0).shape;
        final outputShape = _yolo!.getOutputTensor(0).shape;
        
        debugPrint('✅ YOLO loaded (${_yoloModelData!.length} bytes)');
        debugPrint('   Input: ${inputShape[1]}x${inputShape[2]}');
        debugPrint('   Output: ${outputShape[1]}x${outputShape[2]}');
        debugPrint('');
        debugPrint('🔍 YOLO Configuration:');
        debugPrint('   • Confidence Threshold: 0.25 (LOW - catch more)');
        debugPrint('   • Min Face Size: 40px (RELAXED)');
        debugPrint('   • NMS IOU: 0.5 (MODERATE)');
        debugPrint('   • Frequency: Every 15 frames (~4 FPS)');
      } catch (e) {
        debugPrint('❌ YOLO load failed: $e');
        return;
      }

      _isInitialized = true;
      debugPrint('✅ MultiDetectorService ready');
      debugPrint('═══════════════════════════════════');
      debugPrint('');
    } catch (e) {
      debugPrint('❌ Init failed: $e');
    }
  }

  void setGroupThreshold(int threshold) {
    groupThreshold = threshold;
    debugPrint('📊 Group threshold: $threshold');
  }

  int _frameCount = 0;
  
  void detectAllAsync(CameraImage image) {
    if (!_isInitialized || _yoloModelData == null) {
      if (_frameCount % 300 == 0) {
        debugPrint('⚠️ YOLO not ready: init=$_isInitialized, model=${_yoloModelData != null}');
      }
      return;
    }
    if (_busy) {
      return;
    }

    _frameCount++;
    
    // ✅ Process every 15 frames (~4 FPS at 60 FPS camera) - MORE FREQUENT
    if (_frameCount % 15 != 0) return;

    _busy = true;
    _totalFramesProcessed++;

    compute(_runDetectionInCompute, _DetectionData(
      yPlane: image.planes[0].bytes,
      uPlane: image.planes[1].bytes,
      vPlane: image.planes[2].bytes,
      width: image.width,
      height: image.height,
      yRowStride: image.planes[0].bytesPerRow,
      uvRowStride: image.planes[1].bytesPerRow,
      uvPixelStride: image.planes[1].bytesPerPixel ?? 2,
      yoloModelData: _yoloModelData!,
      groupThreshold: groupThreshold,
    )).then((result) {
      if (result.personCount > 0) {
        _totalDetectionsFound++;
        debugPrint('🎯 YOLO DETECTED: ${result.personCount} person(s) - Confidences: ${result.personConfidences.map((c) => c.toStringAsFixed(2)).join(", ")}');
      } else {
        if (_totalFramesProcessed % 10 == 0) {
          debugPrint('❌ YOLO frame $_totalFramesProcessed: No detection');
        }
      }
      _last = result;
      _busy = false;
    }).catchError((e) {
      debugPrint('❌ Detection error: $e');
      _busy = false;
    });
  }

  void dispose() {
    _yolo?.close();
    _isInitialized = false;
    debugPrint('🧹 MultiDetectorService disposed');
    debugPrint('   Total frames: $_totalFramesProcessed');
    debugPrint('   Detections: $_totalDetectionsFound');
  }
}

Future<DetectionResult> _runDetectionInCompute(_DetectionData data) async {
  final startTime = DateTime.now().millisecondsSinceEpoch;

  try {
    final opt = InterpreterOptions()..threads = 1;
    final interpreter = Interpreter.fromBuffer(data.yoloModelData, options: opt);

    const int inputSize = 640;
    
    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (_) => List.generate(inputSize, (_) => List.filled(3, 0.0)),
      ),
    );

    // ✅ YUV to RGB conversion with proper scaling
    for (int y = 0; y < inputSize; y++) {
      final srcY = (y * data.height ~/ inputSize).clamp(0, data.height - 1);
      
      for (int x = 0; x < inputSize; x++) {
        final srcX = (x * data.width ~/ inputSize).clamp(0, data.width - 1);

        final yIndex = srcY * data.yRowStride + srcX;
        final uvIndex = (srcY ~/ 2) * data.uvRowStride + (srcX ~/ 2) * data.uvPixelStride;

        if (yIndex < data.yPlane.length && uvIndex < data.uPlane.length) {
          final Y = data.yPlane[yIndex].toInt();
          final U = data.uPlane[uvIndex].toInt();
          final V = data.vPlane[uvIndex].toInt();

          // ✅ Standard YUV to RGB conversion
          final r = (Y + ((1436 * (V - 128)) >> 10)).clamp(0, 255);
          final g = (Y - ((354 * (U - 128) + 732 * (V - 128)) >> 10)).clamp(0, 255);
          final b = (Y + ((1814 * (U - 128)) >> 10)).clamp(0, 255);

          input[0][y][x][0] = r / 255.0;
          input[0][y][x][1] = g / 255.0;
          input[0][y][x][2] = b / 255.0;
        }
      }
    }

    final output = List.generate(
      1,
      (_) => List.generate(84, (_) => List.filled(8400, 0.0)),
    );

    interpreter.run(input, output);
    interpreter.close();

    final (personCount, confidences) = _countPersons(output);

    final endTime = DateTime.now().millisecondsSinceEpoch;

    return DetectionResult(
      smokingDetected: false,
      groupDetected: false,
      personCount: personCount,
      processingTimeMs: endTime - startTime,
      personConfidences: confidences,
    );
  } catch (e) {
    debugPrint('⚠️ Compute error: $e');
    return DetectionResult(
      smokingDetected: false,
      groupDetected: false,
      personCount: 0,
    );
  }
}

// ✅ FIXED: More aggressive detection
(int, List<double>) _countPersons(List output) {
  final preds = output[0] as List<List<double>>;
  const int inputSize = 640;

  final boxes = <_Box>[];
  int filteredLowConf = 0;
  int filteredSmall = 0;
  int analyzed = 0;

  // ✅ LOWERED confidence: 0.25 (was 0.40) - Catch more detections
  const double CONFIDENCE_THRESHOLD = 0.25;

  double maxScore = 0;

  for (int i = 0; i < 8400; i++) {
    final personScore = preds[4][i];
    
    if (personScore > maxScore) {
      maxScore = personScore;
    }
    
    if (personScore < CONFIDENCE_THRESHOLD) {
      filteredLowConf++;
      continue;
    }

    analyzed++;

    double cx = preds[0][i];
    double cy = preds[1][i];
    double bw = preds[2][i];
    double bh = preds[3][i];

    // ✅ Auto-detect format (normalized vs pixel)
    if (cx < 2.0 && cy < 2.0 && bw < 2.0 && bh < 2.0) {
      cx *= inputSize;
      cy *= inputSize;
      bw *= inputSize;
      bh *= inputSize;
    }

    // ✅ LOWERED minimum size: 40px (was 80px) - Detect smaller/far faces
    if (bh < 40 || bw < 20) {
      filteredSmall++;
      continue;
    }

    boxes.add(_Box(
      cx - bw / 2,
      cy - bh / 2,
      cx + bw / 2,
      cy + bh / 2,
      personScore,
    ));
  }

  // ✅ Debugging info
  debugPrint('🔍 YOLO Raw Analysis:');
  debugPrint('   Max score in 8400: ${maxScore.toStringAsFixed(4)}');
  debugPrint('   Analyzed (>${CONFIDENCE_THRESHOLD}): $analyzed');
  debugPrint('   Filtered (low conf): $filteredLowConf');
  debugPrint('   Filtered (small): $filteredSmall');
  debugPrint('   Valid boxes: ${boxes.length}');

  // ✅ NMS with moderate IOU
  final (count, confidences) = _nms(boxes, 0.5);
  
  if (count > 0) {
    debugPrint('   ✅ After NMS: $count person(s)');
  }
  
  return (count, confidences);
}

(int, List<double>) _nms(List<_Box> boxes, double iouThr) {
  if (boxes.isEmpty) return (0, []);
  boxes.sort((a, b) => b.score.compareTo(a.score));

  final kept = <_Box>[];
  final confidences = <double>[];
  
  for (final b in boxes) {
    bool ok = true;
    for (final k in kept) {
      if (_iou(b, k) > iouThr) {
        ok = false;
        break;
      }
    }
    if (ok) {
      kept.add(b);
      confidences.add(b.score);
    }
  }
  
  return (kept.length, confidences);
}

double _iou(_Box a, _Box b) {
  final ix1 = max(a.x1, b.x1);
  final iy1 = max(a.y1, b.y1);
  final ix2 = min(a.x2, b.x2);
  final iy2 = min(a.y2, b.y2);

  final iw = max(0.0, ix2 - ix1);
  final ih = max(0.0, iy2 - iy1);

  final inter = iw * ih;
  final areaA = (a.x2 - a.x1) * (a.y2 - a.y1);
  final areaB = (b.x2 - b.x1) * (b.y2 - b.y1);

  return inter / (areaA + areaB - inter + 1e-6);
}

class _Box {
  final double x1, y1, x2, y2, score;
  _Box(this.x1, this.y1, this.x2, this.y2, this.score);
}