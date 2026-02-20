import 'dart:async';
import 'dart:isolate';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'isolate_detector.dart';

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

class MultiDetectorService {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  ReceivePort? _receivePort;
  
  bool _isInitialized = false;
  bool _busy = false;

  
  int groupThreshold;

  DetectionResult _last = DetectionResult(
    smokingDetected: false,
    groupDetected: false,
    personCount: 0,
  );

  MultiDetectorService({
    this.groupThreshold =  1, 
  });

  bool get isInitialized => _isInitialized;
  DetectionResult get lastResult => _last;

  
  Future<void> initialize() async {
    try {
      _receivePort = ReceivePort();

     
      _isolate = await Isolate.spawn(
        detectionIsolateEntryPoint,
        _receivePort!.sendPort,
      );

      
      final completer = Completer<SendPort>();
      _receivePort!.listen((message) {
        if (message is SendPort) {
          completer.complete(message);
        } else if (message is DetectionResponse) {
          _busy = false;
          _last = DetectionResult(
            smokingDetected: message.smokingDetected,
            groupDetected: message.groupDetected,
            personCount: message.personCount,
            processingTimeMs: message.processingTimeMs,
          );
        }
      });

      _isolateSendPort = await completer.future;
      _isInitialized = true;

      debugPrint('MultiDetectorService isolate ready (group threshold: $groupThreshold)');
    } catch (e) {
      _isInitialized = false;
      debugPrint(' Isolate initialization failed: $e');
    }
  }

  /// Update group threshold dynamically
  void setGroupThreshold(int threshold) {
    groupThreshold = threshold;
    debugPrint('Group threshold updated to: $threshold');
  }

  /// Send frame to isolate 
  void detectAllAsync(CameraImage image) {
    if (!_isInitialized || _isolateSendPort == null) return;
    if (_busy) return; 

    _busy = true;

    try {
      final resultPort = ReceivePort();

     
      _isolateSendPort!.send(DetectionRequest(
        resultPort: resultPort.sendPort,
        yPlane: image.planes[0].bytes,
        uPlane: image.planes[1].bytes,
        vPlane: image.planes[2].bytes,
        width: image.width,
        height: image.height,
        yRowStride: image.planes[0].bytesPerRow,
        uvRowStride: image.planes[1].bytesPerRow,
        uvPixelStride: image.planes[1].bytesPerPixel ?? 2,
        groupThreshold: groupThreshold, 
      ));

      
      resultPort.listen((response) {
        if (response is DetectionResponse) {
          _busy = false;
          _last = DetectionResult(
            smokingDetected: response.smokingDetected,
            groupDetected: response.groupDetected,
            personCount: response.personCount,
            processingTimeMs: response.processingTimeMs,
          );
        }
        resultPort.close();
      });
    } catch (e) {
      _busy = false;
      debugPrint(" Detection request failed: $e");
    }
  }

  void dispose() {
    _isolateSendPort?.send('shutdown');
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    _isInitialized = false;
  }
}