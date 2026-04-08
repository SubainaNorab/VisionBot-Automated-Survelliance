// sm_grp.dart - FIXED: Better multi-person detection

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
      debugPrint('🔧 MultiDetectorService: Loading YOLO...');

      final opt = InterpreterOptions()..threads = 2;

      try {
        _yolo = await Interpreter.fromAsset('assets/yolov8n.tflite', options: opt);
        
        final modelFile = await rootBundle.load('assets/yolov8n.tflite');
        _yoloModelData = modelFile.buffer.asUint8List();
        
        final inputShape = _yolo!.getInputTensor(0).shape;
        final outputShape = _yolo!.getOutputTensor(0).shape;
        debugPrint('✅ YOLO loaded (${_yoloModelData!.length} bytes)');
        debugPrint('   Input shape: $inputShape');
        debugPrint('   Output shape: $outputShape');
      } catch (e) {
        debugPrint('❌ YOLO load failed: $e');
        return;
      }

      _isInitialized = true;

      debugPrint('✅ MultiDetectorService ready (threshold: $groupThreshold)');
    } catch (e) {
      debugPrint('❌ Init failed: $e');
    }
  }

  void setGroupThreshold(int threshold) {
    groupThreshold = threshold;
  }

  int _frameCount = 0;
  
  void detectAllAsync(CameraImage image) {
    if (!_isInitialized || _yoloModelData == null) {
      if (_frameCount % 300 == 0) {
        debugPrint('⚠️ Cannot detect: initialized=$_isInitialized, modelData=${_yoloModelData != null}');
      }
      return;
    }
    if (_busy) {
      return;
    }

    _frameCount++;
    
    if (_frameCount % 60 == 0) {
      debugPrint('🎯 Frame $_frameCount - Starting YOLO detection');
    }
    
    if (_frameCount % 60 != 0) return;

    _busy = true;

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
      debugPrint('✅ YOLO completed: $result');
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

    for (int y = 0; y < inputSize; y += 4) {
      final srcY = (y * data.height ~/ inputSize).clamp(0, data.height - 1);
      
      for (int x = 0; x < inputSize; x += 4) {
        final srcX = (x * data.width ~/ inputSize).clamp(0, data.width - 1);

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

        for (int dy = 0; dy < 4 && y + dy < inputSize; dy++) {
          for (int dx = 0; dx < 4 && x + dx < inputSize; dx++) {
            input[0][y + dy][x + dx][0] = rNorm;
            input[0][y + dy][x + dx][1] = gNorm;
            input[0][y + dy][x + dx][2] = bNorm;
          }
        }
      }
    }

    final output = List.generate(
      1,
      (_) => List.generate(84, (_) => List.filled(8400, 0.0)),
    );

    interpreter.run(input, output);
    interpreter.close();

    int persons = _countPersons(output);
    bool groupDet = persons >= data.groupThreshold;

    final endTime = DateTime.now().millisecondsSinceEpoch;

    return DetectionResult(
      smokingDetected: false,
      groupDetected: groupDet,
      personCount: persons,
      processingTimeMs: endTime - startTime,
    );
  } catch (e) {
    debugPrint('⚠️ Compute error: $e');
    return DetectionResult(
      smokingDetected: false,
      groupDetected: false,
      personCount: 0,
      processingTimeMs: 0,
    );
  }
}

// ✅ FIXED: Lower NMS IOU threshold for better multi-person detection
int _countPersons(List output) {
  final preds = output[0] as List<List<double>>;

  const int inputSize = 640;

  double maxPersonScore = 0.0;
  int bestIdx = -1;
  
  for (int i = 0; i < 8400; i++) {
    final personScore = preds[4][i];
    if (personScore > maxPersonScore) {
      maxPersonScore = personScore;
      bestIdx = i;
    }
  }

  debugPrint('🔍 YOLO Raw Output Analysis:');
  debugPrint('   Max person (class 0) score: ${maxPersonScore.toStringAsFixed(4)}');
  
  if (bestIdx >= 0) {
    final rawCx = preds[0][bestIdx];
    final rawCy = preds[1][bestIdx];
    final rawBw = preds[2][bestIdx];
    final rawBh = preds[3][bestIdx];
    debugPrint('   Best person: score=${maxPersonScore.toStringAsFixed(4)}');
    
    if (rawCx <= 1.5 && rawCy <= 1.5 && rawBw <= 1.5 && rawBh <= 1.5) {
      debugPrint('   📐 Format: NORMALIZED (0-1)');
    } else {
      debugPrint('   📐 Format: PIXEL coordinates');
    }
  }
  
  final boxes = <_Box>[];
  int candidateCount = 0;
  int filteredSmall = 0;

  const double CONFIDENCE_THRESHOLD = 0.15;

  for (int i = 0; i < 8400; i++) {
    final personScore = preds[4][i];
    
    if (personScore < CONFIDENCE_THRESHOLD) continue;
    
    candidateCount++;

    double cx = preds[0][i];
    double cy = preds[1][i];
    double bw = preds[2][i];
    double bh = preds[3][i];

    if (cx < 2.0 && cy < 2.0 && bw < 2.0 && bh < 2.0) {
      cx *= inputSize;
      cy *= inputSize;
      bw *= inputSize;
      bh *= inputSize;
    }

    if (candidateCount <= 3) {
      debugPrint('   Candidate $candidateCount: score=${personScore.toStringAsFixed(3)}, size=${bw.toStringAsFixed(1)}x${bh.toStringAsFixed(1)}');
    }

    if (bh < 20 || bw < 10) {
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

  debugPrint('   Candidates: $candidateCount, filtered: $filteredSmall, kept: ${boxes.length}');

  // ✅ FIXED: Lower NMS threshold from 0.45 to 0.30 for better multi-person
  final count = _nms(boxes, 0.30);
  
  if (count > 0) {
    debugPrint('   🎯 DETECTED $count PERSON(S)!');
  } else {
    debugPrint('   ❌ No persons after NMS');
  }
  
  return count;
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