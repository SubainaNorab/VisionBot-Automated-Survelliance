

import 'dart:isolate';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
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

/// Entry point for background isolate
void detectionIsolateEntryPoint(SendPort mainSendPort) async {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  Interpreter? yolo;
  Interpreter? smoke;
  
  const int inputSize = 640;
  

  final input = List.generate(
    1,
    (_) => List.generate(
      inputSize,
      (_) => List.generate(inputSize, (_) => List.filled(3, 0.0)),
    ),
  );
  
  final yoloOut = List.generate(
    1, (_) => List.generate(84, (_) => List.filled(8400, 0.0))
  );
  
  final smokeOut = List.generate(
    1, (_) => List.generate(5, (_) => List.filled(8400, 0.0))
  );

  try {
    
    final opt = InterpreterOptions()..threads = 2;
    yolo = await Interpreter.fromAsset('assets/yolov8n.tflite', options: opt);
    smoke = await Interpreter.fromAsset('assets/smoking.tflite', options: opt);
    
    debugPrint(' Isolate models loaded');
  } catch (e) {
    debugPrint(' Isolate model load failed: $e');
    return;
  }


  await for (final message in receivePort) {
    if (message is DetectionRequest) {
      final startTime = DateTime.now().millisecondsSinceEpoch;

      try {
        
        _fillInputFromYuvData(
          input,
          message.yPlane,
          message.uPlane,
          message.vPlane,
          message.width,
          message.height,
          message.yRowStride,
          message.uvRowStride,
          message.uvPixelStride,
          inputSize,
        );

       
        yolo!.run(input, yoloOut);
        smoke!.run(input, smokeOut);

        final persons = _countPersons(yoloOut);
        final smokeDet = _detectSmoke(smokeOut);
        final groupDet = persons >= message.groupThreshold; // ✅ FIXED

        final endTime = DateTime.now().millisecondsSinceEpoch;

        debugPrint('🔍 Detection: people=$persons, group=$groupDet (threshold=${message.groupThreshold}), smoke=$smokeDet');

        message.resultPort.send(DetectionResponse(
          smokingDetected: smokeDet,
          groupDetected: groupDet,
          personCount: persons,
          processingTimeMs: endTime - startTime,
        ));
      } catch (e) {
        debugPrint('⚠️ Isolate detection error: $e');
      }
    } else if (message == 'shutdown') {
      yolo?.close();
      smoke?.close();
      receivePort.close();
      break;
    }
  }
}

void _fillInputFromYuvData(
  List<List<List<List<double>>>> input,
  Uint8List yPlane,
  Uint8List uPlane,
  Uint8List vPlane,
  int width,
  int height,
  int yRowStride,
  int uvRowStride,
  int uvPixelStride,
  int inputSize,
) {
  for (int y = 0; y < inputSize; y += 2) {
    final srcY = (y * height / inputSize).floor();
    for (int x = 0; x < inputSize; x += 2) {
      final srcX = (x * width / inputSize).floor();

      final yIndex = srcY * yRowStride + srcX;
      final uvIndex = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

      final Y = yPlane[yIndex].toInt();
      final U = uPlane[uvIndex].toInt();
      final V = vPlane[uvIndex].toInt();

      
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
}

int _countPersons(List yoloOutput) {
  final preds = yoloOutput[0] as List<List<double>>;
  final boxes = <_Box>[];

  for (int i = 0; i < 8400; i++) {
    final personScore = preds[4][i];
    if (personScore < 0.35) continue;

    final cx = preds[0][i];
    final cy = preds[1][i];
    final bw = preds[2][i];
    final bh = preds[3][i];

    if (bh < 115) continue;
    if ((bw * bh) < 8192) continue; 

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

bool _detectSmoke(List smokeOutput) {
  final preds = smokeOutput[0] as List<List<double>>;
  final boxes = <_Box>[];

  for (int i = 0; i < 8400; i++) {
    final conf = preds[4][i];
    if (conf < 0.45) continue;

    final cx = preds[0][i];
    final cy = preds[1][i];
    final bw = preds[2][i];
    final bh = preds[3][i];

    boxes.add(_Box(
      cx - bw / 2,
      cy - bh / 2,
      cx + bw / 2,
      cy + bh / 2,
      conf,
    ));
  }

  return _nms(boxes, 0.45) > 0;
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