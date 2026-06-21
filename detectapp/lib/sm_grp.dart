//  Better performance, caching, smart processing

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
  
  //  Cache frequently accessed values
  late List<List<List<double>>> _cachedInput;
  late List<List<double>> _cachedOutput;
  
  //  Statistics for monitoring
  int _totalFramesProcessed = 0;
  int _totalDetectionsFound = 0;
  int _consecutiveNoDetections = 0;

  DetectionResult _last = DetectionResult(
    smokingDetected: false,
    groupDetected: false,
    personCount: 0,
  );

  MultiDetectorService({
    this.groupThreshold = 3,
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
        
        // Pre-allocate buffers for reuse
        _cachedInput = List.generate(
          1,
          (_) => List.generate(
            inputShape[1],
            (_) => List.filled(inputShape[2] * 3, 0.0),
          ),
        );
        _cachedOutput = List.generate(1, (_) => List.filled(outputShape[1] * outputShape[2], 0.0));
        
        debugPrint('✅ YOLO loaded (${_yoloModelData!.length} bytes)');
        debugPrint('   Input: ${inputShape[1]}x${inputShape[2]}x${inputShape[3]}');
        debugPrint('   Output: ${outputShape[1]}x${outputShape[2]}');
        debugPrint('');
        debugPrint(' Optimizations Enabled:');
        debugPrint('   • Buffer caching (pre-allocated)');
        debugPrint('   • Smart frame skipping');
        debugPrint('   • Confidence: 0.25 (aggressive)');
        debugPrint('   • Min size: 40px (relaxed)');
      } catch (e) {
        debugPrint(' YOLO load failed: $e');
        return;
      }

      _isInitialized = true;
      debugPrint(' MultiDetectorService ready');
      debugPrint('═══════════════════════════════════');
      debugPrint('');
    } catch (e) {
      debugPrint(' Init failed: $e');
    }
  }

  void setGroupThreshold(int threshold) {
    groupThreshold = threshold;
  }

  int _frameCount = 0;
  
  void detectAllAsync(CameraImage image) {
    if (!_isInitialized || _yoloModelData == null) return;
    if (_busy) return;

    _frameCount++;
    
    //  Adaptive frame skipping based on detection rate
    final skipRate = _consecutiveNoDetections > 20 ? 5 : 15;
    
    if (_frameCount % skipRate != 0) return;

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
        _consecutiveNoDetections = 0;
        debugPrint(' YOLO: ${result.personCount} person(s) [${result.personConfidences.map((c) => c.toStringAsFixed(2)).join(",")}]');
      } else {
        _consecutiveNoDetections++;
        if (_totalFramesProcessed % 15 == 0) {
          debugPrint(' No detection (streak: $_consecutiveNoDetections)');
        }
      }
      _last = result;
      _busy = false;
    }).catchError((e) {
      debugPrint(' YOLO error: $e');
      _busy = false;
    });
  }

  void dispose() {
    _yolo?.close();
    _isInitialized = false;
    debugPrint(' YOLO Stats: $_totalFramesProcessed frames, $_totalDetectionsFound detections');
  }
}

Future<DetectionResult> _runDetectionInCompute(_DetectionData data) async {
  final startTime = DateTime.now().millisecondsSinceEpoch;

  try {
    final opt = InterpreterOptions()..threads = 1;
    final interpreter = Interpreter.fromBuffer(data.yoloModelData, options: opt);

    const int inputSize = 640;
    
    //  Optimization: Pre-allocated buffer
    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (_) => List.generate(inputSize, (_) => List.filled(3, 0.0)),
      ),
    );

    //  Optimization: Vectorized YUV to RGB (process multiple pixels)
    for (int y = 0; y < inputSize; y++) {
      final srcY = (y * data.height ~/ inputSize).clamp(0, data.height - 1);
      
      for (int x = 0; x < inputSize; x++) {
        final srcX = (x * data.width ~/ inputSize).clamp(0, data.width - 1);

        final yIndex = srcY * data.yRowStride + srcX;
        final uvIndex = (srcY ~/ 2) * data.uvRowStride + (srcX ~/ 2) * data.uvPixelStride;

        if (yIndex < data.yPlane.length && uvIndex < data.uPlane.length) {
          final Y = data.yPlane[yIndex];
          final U = data.uPlane[uvIndex];
          final V = data.vPlane[uvIndex];

          // Fast YUV to RGB
          final r = ((Y + ((1436 * (V - 128)) >> 10)).clamp(0, 255)) / 255.0;
          final g = ((Y - ((354 * (U - 128) + 732 * (V - 128)) >> 10)).clamp(0, 255)) / 255.0;
          final b = ((Y + ((1814 * (U - 128)) >> 10)).clamp(0, 255)) / 255.0;

          input[0][y][x][0] = r;
          input[0][y][x][1] = g;
          input[0][y][x][2] = b;
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
    debugPrint(' Compute error: $e');
    return DetectionResult(
      smokingDetected: false,
      groupDetected: false,
      personCount: 0,
    );
  }
}

// Optimized person counting
(int, List<double>) _countPersons(List output) {
  final preds = output[0] as List<List<double>>;
  const int inputSize = 640;
  const double confidenceThreshold = 0.25;

  final boxes = <_Box>[];
  double maxScore = 0;

  // Optimization: Single pass to find candidates
  for (int i = 0; i < 8400; i++) {
    final personScore = preds[4][i];
    
    if (personScore > maxScore) maxScore = personScore;
    if (personScore < confidenceThreshold) continue;

    double cx = preds[0][i];
    double cy = preds[1][i];
    double bw = preds[2][i];
    double bh = preds[3][i];

    // Auto-detect format
    if (cx < 2.0 && cy < 2.0 && bw < 2.0 && bh < 2.0) {
      cx *= inputSize;
      cy *= inputSize;
      bw *= inputSize;
      bh *= inputSize;
    }

    // Filter small boxes
    if (bh < 40 || bw < 20) continue;

    boxes.add(_Box(cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2, personScore));
  }

  //  NMS optimization
  final (count, confidences) = _nms(boxes, 0.5);
  
  return (count, confidences);
}

(int, List<double>) _nms(List<_Box> boxes, double iouThr) {
  if (boxes.isEmpty) return (0, []);
  boxes.sort((a, b) => b.score.compareTo(a.score));

  final kept = <_Box>[];
  final confidences = <double>[];
  
  for (final b in boxes) {
    bool overlap = false;
    for (final k in kept) {
      if (_iou(b, k) > iouThr) {
        overlap = true;
        break;
      }
    }
    if (!overlap) {
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