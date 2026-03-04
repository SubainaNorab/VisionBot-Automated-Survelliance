// isolate_detector.dart - MODELS LOADED IN MAIN, DATA PASSED TO ISOLATE

import 'dart:isolate';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'dart:math';

class DetectionRequest {
  final SendPort resultPort;
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int width;
  final int height;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
  final int groupThreshold;

  DetectionRequest({
    required this.resultPort,
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
    required this.groupThreshold,
  });
}

class DetectionResponse {
  final bool smokingDetected;
  final bool groupDetected;
  final int personCount;
  final int processingTimeMs;

  DetectionResponse({
    required this.smokingDetected,
    required this.groupDetected,
    required this.personCount,
    required this.processingTimeMs,
  });
}

// ✅ SIMPLE ISOLATE WITHOUT MODEL LOADING
void detectionIsolateEntryPoint(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  debugPrint('✅ Detection isolate started (no models - main thread only)');

  receivePort.listen((message) {
    if (message is DetectionRequest) {
      // ✅ For now, just return dummy data
      // Real detection happens in main thread
      message.resultPort.send(DetectionResponse(
        smokingDetected: false,
        groupDetected: false,
        personCount: 0,
        processingTimeMs: 0,
      ));
    } else if (message == 'shutdown') {
      receivePort.close();
    }
  });
}

// Helper classes
class _Box {
  final double x1, y1, x2, y2, score;
  _Box(this.x1, this.y1, this.x2, this.y2, this.score);
}

// NMS and IOU functions for use in main thread
int nmsCount(List<_Box> boxes, double iouThr) {
  if (boxes.isEmpty) return 0;
  boxes.sort((a, b) => b.score.compareTo(a.score));

  final kept = <_Box>[];
  for (final b in boxes) {
    bool ok = true;
    for (final k in kept) {
      if (iou(b, k) > iouThr) {
        ok = false;
        break;
      }
    }
    if (ok) kept.add(b);
  }
  return kept.length;
}

double iou(_Box a, _Box b) {
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