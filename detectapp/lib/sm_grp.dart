// sm_grp.dart - OPTIMIZED WITH COMPUTE ISOLATE

import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;
class DetectionResult {
  final bool smokingDetected;
  final bool groupDetected;
  final int personCount;
  final int processingTimeMs;

  DetectionResult({
    required this.smokingDetected,
    required this.groupDetected,
    required this.personCount,
    this.processingTimeMs = 0,
  });

  @override
  String toString() =>
      'Detection(people: $personCount, group: $groupDetected, smoke: $smokingDetected, ${processingTimeMs}ms)';
}

// ✅ Lightweight detection data class
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
      debugPrint('🔧 MultiDetectorService: Loading YOLO only...');

      final opt = InterpreterOptions()..threads = 2;

      // ✅ Load YOLO only (skip smoking for now)
      try {
        _yolo = await Interpreter.fromAsset('assets/yolov8n.tflite', options: opt);
        
        // Get model data for passing to compute
        final modelFile = await rootBundle.load('assets/yolov8n.tflite');
        _yoloModelData = modelFile.buffer.asUint8List();
        
        debugPrint('✅ YOLO loaded (${_yoloModelData!.length} bytes)');
      } catch (e) {
        debugPrint('❌ YOLO load failed: $e');
        return;
      }

      _isInitialized = true;

      debugPrint('✅ MultiDetectorService ready (threshold: $groupThreshold)');
    } catch (e, stackTrace) {
      _isInitialized = false;
      debugPrint('❌ Init failed: $e');
      debugPrint('Stack: $stackTrace');
    }
  }

  void setGroupThreshold(int threshold) {
    groupThreshold = threshold;
    debugPrint('👥 Group threshold: $threshold');
  }

  // ✅ SIMPLIFIED: Just count frames, don't process every frame
  int _frameCount = 0;
  
  void detectAllAsync(CameraImage image) {
    if (!_isInitialized || _yoloModelData == null) return;
    if (_busy) return;

    _frameCount++;
    
    // ✅ Only process every 30 frames (1 per second)
    if (_frameCount % 30 != 0) return;

    _busy = true;

    // Run in compute (lightweight isolate)
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
      _last = result;
      _busy = false;
    }).catchError((e) {
      debugPrint('⚠️ Detection error: $e');
      _busy = false;
    });
  }

  void dispose() {
    _yolo?.close();
    _isInitialized = false;
    debugPrint('🧹 MultiDetectorService disposed');
  }
}

// ✅ STATIC FUNCTION: Run in compute isolate
Future<DetectionResult> _runDetectionInCompute(_DetectionData data) async {
  final startTime = DateTime.now().millisecondsSinceEpoch;

  try {
    // Load model in compute isolate
    final opt = InterpreterOptions()..threads = 1;
    final interpreter = Interpreter.fromBuffer(data.yoloModelData, options: opt);

    // Prepare input (downsample to 320x320 for speed)
    const int inputSize = 320; // ✅ Reduced from 640 for performance
    
    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (_) => List.generate(inputSize, (_) => List.filled(3, 0.0)),
      ),
    );

    // Fill input from YUV
    for (int y = 0; y < inputSize; y += 2) {
      final srcY = (y * data.height / inputSize).floor();
      for (int x = 0; x < inputSize; x += 2) {
        final srcX = (x * data.width / inputSize).floor();

        final yIndex = srcY * data.yRowStride + srcX;
        final uvIndex = (srcY ~/ 2) * data.uvRowStride + (srcX ~/ 2) * data.uvPixelStride;

        final Y = data.yPlane[yIndex].toInt();
        final U = data.uPlane[uvIndex].toInt();
        final V = data.vPlane[uvIndex].toInt();

        final r = (Y + ((1436 * (V - 128)) >> 10)).clamp(0, 255);
        final g = (Y - ((354 * (U - 128) + 732 * (V - 128)) >> 10)).clamp(0, 255);
        final b = (Y + ((1814 * (U - 128)) >> 10)).clamp(0, 255);

        final rNorm = r / 255.0;
        final gNorm = g / 255.0;
        final bNorm = b / 255.0;

        for (int dy = 0; dy < 2 && y + dy < inputSize; dy++) {
          for (int dx = 0; dx < 2 && x + dx < inputSize; dx++) {
            input[0][y + dy][x + dx][0] = rNorm;
            input[0][y + dy][x + dx][1] = gNorm;
            input[0][y + dy][x + dx][2] = bNorm;
          }
        }
      }
    }

    // Run inference
    final output = List.generate(
      1,
      (_) => List.generate(84, (_) => List.filled(2100, 0.0)), // ✅ 320x320 = 2100 anchors
    );

    interpreter.run(input, output);
    interpreter.close();

    // Count persons
    int persons = _countPersons(output);
    bool groupDet = persons >= data.groupThreshold;

    final endTime = DateTime.now().millisecondsSinceEpoch;

    if (persons > 0) {
      debugPrint('🔍 Detection: people=$persons, group=$groupDet (${endTime - startTime}ms)');
    }

    return DetectionResult(
      smokingDetected: false,
      groupDetected: groupDet,
      personCount: persons,
      processingTimeMs: endTime - startTime,
    );
  } catch (e) {
    debugPrint('⚠️ Compute detection error: $e');
    return DetectionResult(
      smokingDetected: false,
      groupDetected: false,
      personCount: 0,
      processingTimeMs: 0,
    );
  }
}

int _countPersons(List output) {
  final preds = output[0] as List<List<double>>;
  final boxes = <_Box>[];

  for (int i = 0; i < 2100; i++) {
    final personScore = preds[4][i];
    if (personScore < 0.3) continue; // ✅ Slightly higher threshold

    final cx = preds[0][i];
    final cy = preds[1][i];
    final bw = preds[2][i];
    final bh = preds[3][i];

    if (bh < 40) continue;
    if ((bw * bh) < 1600) continue;

    boxes.add(_Box(
      cx - bw / 2,
      cy - bh / 2,
      cx + bw / 2,
      cy + bh / 2,
      personScore,
    ));
  }

  return _nms(boxes, 0.45);
}

int _nms(List<_Box> boxes, double iouThr) {
  if (boxes.isEmpty) return 0;
  boxes.sort((a, b) => b.score.compareTo(a.score));

  final kept = <_Box>[];
  for (final b in boxes) {
    bool ok = true;
    for (final k in kept) {
      if (_iou(b, k) > iouThr) {
        ok = false;
        break;
      }
    }
    if (ok) kept.add(b);
  }
  return kept.length;
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