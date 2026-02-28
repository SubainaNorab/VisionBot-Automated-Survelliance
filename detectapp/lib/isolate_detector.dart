// sm_grp.dart - FIXED INITIALIZATION

import 'dart:async';
import 'dart:isolate';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class DetectionRequest {
  final SendPort resultPort;
  final List<int> yPlane;
  final List<int> uPlane;
  final List<int> vPlane;
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

void detectionIsolateEntryPoint(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  receivePort.listen((message) {
    if (message is DetectionRequest) {
      // Perform detection logic here
      final response = DetectionResponse(
        smokingDetected: false,
        groupDetected: false,
        personCount: 0,
        processingTimeMs: 0,
      );
      message.resultPort.send(response);
    } else if (message == 'shutdown') {
      receivePort.close();
    }
  });
}

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
    this.groupThreshold = 1,
  });

  bool get isInitialized => _isInitialized;
  DetectionResult get lastResult => _last;

  Future<void> initialize() async {
    try {
      debugPrint('🔧 MultiDetectorService: Starting isolate initialization...');
      
      _receivePort = ReceivePort();

      // ✅ Spawn isolate
      _isolate = await Isolate.spawn(
        detectionIsolateEntryPoint,
        _receivePort!.sendPort,
      );

      debugPrint('✅ Isolate spawned successfully');

      // Wait for SendPort from isolate
      final completer = Completer<SendPort>();
      
      _receivePort!.listen((message) {
        if (message is SendPort) {
          debugPrint('✅ Received SendPort from isolate');
          if (!completer.isCompleted) {
            completer.complete(message);
          }
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

      // ✅ Wait for isolate to be ready (with timeout)
      _isolateSendPort = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Isolate did not respond within 10 seconds');
        },
      );
      
      _isInitialized = true;

      debugPrint('✅ MultiDetectorService isolate ready (group threshold: $groupThreshold)');
    } catch (e, stackTrace) {
      _isInitialized = false;
      debugPrint('❌ Isolate initialization failed: $e');
      debugPrint('   Stack trace: $stackTrace');
      
      // Cleanup on failure
      _receivePort?.close();
      _isolate?.kill(priority: Isolate.immediate);
    }
  }

  void setGroupThreshold(int threshold) {
    groupThreshold = threshold;
    debugPrint('👥 Group threshold updated to: $threshold');
  }

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
      debugPrint("❌ Detection request failed: $e");
    }
  }

  void dispose() {
    _isolateSendPort?.send('shutdown');
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    _isInitialized = false;
    debugPrint('🧹 MultiDetectorService disposed');
  }
}