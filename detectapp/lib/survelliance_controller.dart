// surveillance_controller.dart
// Business logic coordinator for surveillance system

import 'dart:async';
import 'dart:collection'; // ✅ NEW import
import 'dart:io'; // ✅ NEW import
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart'; // ✅ NEW import
import 'package:image/image.dart' as img; // ✅ NEW import

import 'camera.dart';
import 'face_detector.dart';
import 'face_verification.dart';
import 'alert_service.dart';
import 'sm_grp.dart';

class SurveillanceState {
  final bool isBooting;
  final String faceStatus;
  final String lastMatch;
  final String detectionStatus;
  final bool processingFace;
  final int peopleCount;
  final bool groupDetected;
  final bool smokingDetected;

  const SurveillanceState({
    this.isBooting = true,
    this.faceStatus = 'Starting...',
    this.lastMatch = '',
    this.detectionStatus = 'People: - | Group: - | Smoking: -',
    this.processingFace = false,
    this.peopleCount = 0,
    this.groupDetected = false,
    this.smokingDetected = false,
  });

  SurveillanceState copyWith({
    bool? isBooting,
    String? faceStatus,
    String? lastMatch,
    String? detectionStatus,
    bool? processingFace,
    int? peopleCount,
    bool? groupDetected,
    bool? smokingDetected,
  }) {
    return SurveillanceState(
      isBooting: isBooting ?? this.isBooting,
      faceStatus: faceStatus ?? this.faceStatus,
      lastMatch: lastMatch ?? this.lastMatch,
      detectionStatus: detectionStatus ?? this.detectionStatus,
      processingFace: processingFace ?? this.processingFace,
      peopleCount: peopleCount ?? this.peopleCount,
      groupDetected: groupDetected ?? this.groupDetected,
      smokingDetected: smokingDetected ?? this.smokingDetected,
    );
  }
}

class SurveillanceController {
  // Services
  final CameraService _camera = CameraService();
  final FaceDetectionService _detector = FaceDetectionService();
  final FaceVerificationService _verifier = FaceVerificationService();
  final AlertService _alertService = AlertService();
  final MultiDetectorService _multi;

  final StreamController<SurveillanceState> _stateController =
      StreamController<SurveillanceState>.broadcast();
  
  SurveillanceState _state = const SurveillanceState();

  // Face verification
  bool _autoVerify = true;
  Timer? _verifyTimer;
  Timer? _statusTimer;
  Timer? _cacheCleanupTimer; // ✅ NEW

  // Alert state tracking
  bool _lastGroupState = false;
  bool _lastSmokeState = false;

  int _frameCount = 0;
  static const int _frameSkip = 5;

  // ✅ SOLUTION 1: Frame buffering for non-blocking face verification
  final Queue<CameraImage> _frameBuffer = Queue();
  bool _processingBuffer = false;
  static const int _maxBufferSize = 2; // Keep max 2 frames

  // ✅ SOLUTION 3: Face tracking cache to avoid re-verification
  final Map<String, DateTime> _recentlyVerified = {};
  final Duration _verificationCacheDuration = Duration(seconds: 30);

  Stream<SurveillanceState> get stateStream => _stateController.stream;
  SurveillanceState get currentState => _state;
  CameraService get camera => _camera;
  bool get autoVerify => _autoVerify;

  SurveillanceController({
    int groupThreshold = 1,
  }) : _multi = MultiDetectorService(groupThreshold: groupThreshold);

  Future<void> initialize({
    CameraLensDirection preferredLens = CameraLensDirection.front,
  }) async {
    _updateState(_state.copyWith(
      isBooting: true,
      faceStatus: 'Initializing...',
    ));

    try {
      await Future.wait([
        _verifier.initialize(),
        _multi.initialize(),
        _camera.initialize(preferred: preferredLens),
      ]);

      await _camera.startStream(_onFrame);

      _startStatusPolling();
      _startCacheCleanup(); // ✅ NEW

      _updateState(_state.copyWith(
        isBooting: false,
        faceStatus: 'Ready',
      ));

      _startAutoVerify();

      debugPrint('✅ SurveillanceController initialized');
    } catch (e) {
      _updateState(_state.copyWith(
        isBooting: false,
        faceStatus: 'Initialization failed: $e',
      ));
      debugPrint('❌ SurveillanceController init failed: $e');
    }
  }

  /// Poll detection results and update UI
  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final det = _multi.lastResult;

      // Use YOLO person count directly (no workarounds)
      int totalPeople = det.personCount;

      bool isGroup = totalPeople >= _multi.groupThreshold;

      final status =
          'People: $totalPeople | Group: ${isGroup ? "YES" : "NO"} | Smoke: ${det.smokingDetected ? "YES" : "NO"} (${det.processingTimeMs}ms)';

      _updateState(_state.copyWith(
        detectionStatus: status,
        peopleCount: totalPeople,
        groupDetected: isGroup,
        smokingDetected: det.smokingDetected,
      ));

      _handleDetectionAlerts(det, totalPeople, isGroup);
    });
  }

  // ✅ SOLUTION 3: Clean up old cache entries every minute
  void _startCacheCleanup() {
    _cacheCleanupTimer?.cancel();
    _cacheCleanupTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _cleanVerificationCache();
    });
  }

  void _cleanVerificationCache() {
    final now = DateTime.now();
    final before = _recentlyVerified.length;
    _recentlyVerified.removeWhere((name, time) => 
      now.difference(time) > _verificationCacheDuration
    );
    final after = _recentlyVerified.length;
    if (before != after) {
      debugPrint('🧹 Cache cleanup: removed ${before - after} entries');
    }
  }

  void _handleDetectionAlerts(
    DetectionResult det,
    int totalPeople,
    bool isGroup,
  ) {
    final lensName =
        _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

    // Group alert
    if (isGroup && !_lastGroupState) {
      debugPrint('🚨 GROUP DETECTED: $totalPeople people');
      _alertService
          .createGroupAlert(
            personCount: totalPeople,
            lens: lensName,
          )
          .catchError((e) => debugPrint('❌ Group alert error: $e'));
    }
    _lastGroupState = isGroup;

    // Smoking alert
    if (det.smokingDetected && !_lastSmokeState) {
      debugPrint('🚨 SMOKING DETECTED');
      _alertService
          .createSmokingAlert(lens: lensName)
          .catchError((e) => debugPrint('❌ Smoke alert error: $e'));
    }
    _lastSmokeState = det.smokingDetected;
  }

  // ✅ SOLUTION 1: Modified _onFrame - adds buffering for face verification
  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized) return;

    _frameCount++;
    
    // YOLO detection (every 5 frames) - UNCHANGED
    if (_frameCount % _frameSkip == 0) {
      _multi.detectAllAsync(image);
    }
    
    // ✅ NEW: Buffer frames for face verification WITHOUT stopping stream
    // Every 90 frames (~3 seconds at 30fps)
    if (_frameCount % 90 == 0 && _autoVerify && !_processingBuffer) {
      // Add frame to buffer (limit buffer size)
      if (_frameBuffer.length < _maxBufferSize) {
        _frameBuffer.add(image);
        _processBufferedFrame();
      } else {
        debugPrint('⚠️ Frame buffer full, skipping verification');
      }
    }
  }

  // ✅ SOLUTION 1: Process buffered frames asynchronously
  Future<void> _processBufferedFrame() async {
    if (_frameBuffer.isEmpty || _processingBuffer) return;
    
    _processingBuffer = true;
    final image = _frameBuffer.removeFirst();
    
    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Verifying (buffered)...',
    ));
    
    try {
      // Convert CameraImage to temporary file
      final tempPath = await _saveCameraImageToFile(image);
      
      // Detect all faces
      final faces = await _detector.detectAndCropAllFaces(tempPath);
      
      debugPrint('📸 Buffered frame: Detected ${faces.length} face(s)');
      
      // Verify all faces
      final results = _verifier.verifyMultipleFaces(faces);
      
      // Process results with tracking
      _processVerificationResults(results);
      
      // Clean up temp file
      try {
        await File(tempPath).delete();
      } catch (_) {}
      
    } catch (e) {
      if (e.toString().contains('No face')) {
        _updateState(_state.copyWith(faceStatus: 'No faces in frame'));
      } else {
        debugPrint('⚠️ Buffer processing failed: $e');
        _updateState(_state.copyWith(faceStatus: 'Verification error'));
      }
    } finally {
      _processingBuffer = false;
      _updateState(_state.copyWith(processingFace: false));
    }
  }

  // ✅ SOLUTION 1: Convert CameraImage to JPEG file
  Future<String> _saveCameraImageToFile(CameraImage image) async {
    // Convert YUV420 to RGB Image
    final img.Image? convertedImage = _convertYUV420ToImage(image);
    if (convertedImage == null) throw Exception('Image conversion failed');
    
    // Save to temporary file
    final tempDir = await getTemporaryDirectory();
    final filePath = '${tempDir.path}/face_verify_${DateTime.now().millisecondsSinceEpoch}.jpg';
    
    final file = File(filePath);
    await file.writeAsBytes(img.encodeJpg(convertedImage, quality: 85));
    
    return filePath;
  }

  // ✅ SOLUTION 1: YUV420 to RGB conversion
  // NOTE: Preprocessing for FaceNet model happens in face_verification.dart (_preprocess)
  // This conversion is ONLY to create a file for ML Kit face detection
  img.Image? _convertYUV420ToImage(CameraImage image) {
    final width = image.width;
    final height = image.height;
    
    final imgImage = img.Image(width: width, height: height);
    
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * yPlane.bytesPerRow + x;
        final uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2) * (uPlane.bytesPerPixel ?? 1);
        
        final Y = yPlane.bytes[yIndex];
        final U = uPlane.bytes[uvIndex];
        final V = vPlane.bytes[uvIndex];
        
        // YUV to RGB conversion (standard formula)
        int r = (Y + 1.402 * (V - 128)).round().clamp(0, 255);
        int g = (Y - 0.344136 * (U - 128) - 0.714136 * (V - 128)).round().clamp(0, 255);
        int b = (Y + 1.772 * (U - 128)).round().clamp(0, 255);
        
        imgImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    
    return imgImage;
  }

  // ✅ SOLUTION 3: Process verification results with tracking cache
  void _processVerificationResults(List<VerificationResult> results) {
    int knownCount = 0;
    int unknownCount = 0;
    final knownNames = <String>[];
    final newKnownNames = <String>[]; // Names not recently verified

    for (final result in results) {
      if (result.verified && result.person != null) {
        final name = result.person!.name;
        
        // ✅ SOLUTION 3: Check if recently verified (within 30 seconds)
        final lastVerified = _recentlyVerified[name];
        final isRecent = lastVerified != null && 
            DateTime.now().difference(lastVerified) < _verificationCacheDuration;
        
        if (isRecent) {
          debugPrint('⏭️ Skipping alert for $name (verified ${DateTime.now().difference(lastVerified!).inSeconds}s ago)');
        } else {
          newKnownNames.add(name);
          debugPrint('✅ NEW verification: $name');
        }
        
        // ✅ SOLUTION 3: Update cache
        _recentlyVerified[name] = DateTime.now();
        
        knownCount++;
        if (!knownNames.contains(name)) {
          knownNames.add(name);
        }
      } else {
        unknownCount++;
      }
    }

    debugPrint('📊 Verification results: $knownCount known (${newKnownNames.length} new), $unknownCount unknown');

    // Create alert ONLY for unknown faces (known faces already tracked)
    if (unknownCount > 0) {
      final lensName = _camera.lensDirection == CameraLensDirection.front
          ? 'front'
          : 'back';

      _alertService.createUnknownAlert(
        threshold: FaceVerificationService.threshold,
        lens: lensName,
        note: '$unknownCount unknown face(s) detected${knownCount > 0 ? ', $knownCount known' : ''}',
      );
    }

    // Update UI with results
    String statusMsg;
    if (knownCount > 0 && unknownCount > 0) {
      statusMsg = '✅ ${knownNames.join(", ")} | ⚠️ $unknownCount unknown';
    } else if (knownCount > 0) {
      statusMsg = '✅ Verified: ${knownNames.join(", ")}';
    } else {
      statusMsg = '⚠️ All unknown ($unknownCount face(s))';
    }

    _updateState(_state.copyWith(
      faceStatus: statusMsg,
      lastMatch: knownNames.isNotEmpty ? knownNames.join(', ') : 'Unknown',
    ));
  }

  void _startAutoVerify() {
    _verifyTimer?.cancel();
    if (!_autoVerify) return;

    // Note: Manual timer is now redundant since _onFrame handles buffering
    // Kept for compatibility with manual verify button
    _verifyTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      // This is now a fallback - actual verification happens in _onFrame
      if (_state.isBooting || _state.processingFace) return;
      // Manual verify still uses old method (stops stream)
      // await verifyFace();
    });
  }

  void setAutoVerify(bool enabled) {
    _autoVerify = enabled;
    _startAutoVerify();
    debugPrint('🔄 Auto verify ${enabled ? "enabled" : "disabled"}');
  }

  /// Manual face verification (stops stream - used by button press)
  /// This is the OLD method - kept for manual verification button
  Future<void> verifyFace() async {
    if (_state.processingFace) return;

    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Capturing...',
    ));

    try {
      // Stop stream to capture photo
      await _camera.stopStream();

      final shot = await _camera.takePicture();

      _updateState(_state.copyWith(faceStatus: 'Detecting faces...'));
      
      // Detect ALL faces in the image
      final faces = await _detector.detectAndCropAllFaces(shot.path);
      
      debugPrint('📸 Manual: Detected ${faces.length} face(s) in frame');

      _updateState(_state.copyWith(
        faceStatus: 'Verifying ${faces.length} face(s)...',
      ));
      
      // Verify all detected faces
      final results = _verifier.verifyMultipleFaces(faces);

      // Process results with tracking
      _processVerificationResults(results);

    } catch (e) {
      final errorMsg = e.toString().contains('No face')
          ? 'No faces detected'
          : 'Error: $e';
      
      _updateState(_state.copyWith(faceStatus: errorMsg));
      debugPrint('⚠️ Manual verification failed: $e');
    } finally {
      // Restart stream
      try {
        await _camera.startStream(_onFrame);
      } catch (e) {
        debugPrint('⚠️ Failed to restart stream: $e');
      }

      _updateState(_state.copyWith(processingFace: false));
    }
  }

  /// Switch between front and back camera
  Future<void> switchCamera() async {
    try {
      _updateState(_state.copyWith(faceStatus: 'Switching camera...'));

      _verifyTimer?.cancel();

      await _camera.stopStream();
      await _camera.switchCamera();
      await _camera.startStream(_onFrame);

      // Reset cooldowns and cache
      _alertService.resetCooldowns();
      _lastGroupState = false;
      _lastSmokeState = false;
      _recentlyVerified.clear(); // ✅ NEW: Clear face tracking cache
      _frameBuffer.clear(); // ✅ NEW: Clear frame buffer

      _updateState(_state.copyWith(faceStatus: 'Ready'));
      _startAutoVerify();

      debugPrint('📷 Camera switched, cache cleared');
    } catch (e) {
      _updateState(_state.copyWith(faceStatus: 'Switch failed: $e'));
      debugPrint('❌ Camera switch failed: $e');
    }
  }

  void setGroupThreshold(int threshold) {
    _multi.setGroupThreshold(threshold);
    debugPrint('👥 Group threshold set to $threshold');
  }

  void _updateState(SurveillanceState newState) {
    _state = newState;
    _stateController.add(_state);
  }

  /// Clean up all resources
  Future<void> dispose() async {
    _verifyTimer?.cancel();
    _statusTimer?.cancel();
    _cacheCleanupTimer?.cancel(); // ✅ NEW
    await _camera.dispose();
    await _detector.dispose();
    _verifier.dispose();
    _multi.dispose();
    await _stateController.close();
    _frameBuffer.clear(); // ✅ NEW
    _recentlyVerified.clear(); // ✅ NEW
    debugPrint('🧹 SurveillanceController disposed');
  }
}