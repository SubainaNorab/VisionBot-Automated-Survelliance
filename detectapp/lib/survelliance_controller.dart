// surveillance_controller.dart
// Business logic coordinator for surveillance system

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

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
  Timer? _cacheCleanupTimer;

  // Alert state tracking
  bool _lastGroupState = false;
  bool _lastSmokeState = false;

  int _frameCount = 0;
  static const int _frameSkip = 5;

  // ✅ SOLUTION 1: Frame buffering flags
  bool _shouldVerifyNextCycle = false;
  bool _processingVerification = false;

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
      _startCacheCleanup();

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

  // ✅ SOLUTION 1: Modified _onFrame - triggers verification flag
  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized) return;

    _frameCount++;
    
    // YOLO detection (every 5 frames) - UNCHANGED
    if (_frameCount % _frameSkip == 0) {
      _multi.detectAllAsync(image);
    }
    
    // ✅ NEW: Set flag for face verification (every 90 frames ~3s)
    // Actual verification happens by stopping stream briefly
    if (_frameCount % 90 == 0 && _autoVerify && !_processingVerification) {
      _shouldVerifyNextCycle = true;
      _triggerBackgroundVerification();
    }
  }

  // ✅ SOLUTION 1 (REVISED): Background verification with brief stream pause
  // This is MORE RELIABLE than YUV conversion for face detection
  Future<void> _triggerBackgroundVerification() async {
    if (_processingVerification || !_shouldVerifyNextCycle) return;
    
    _shouldVerifyNextCycle = false;
    _processingVerification = true;
    
    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Quick verify...',
    ));
    
    try {
      // ✅ CRITICAL FIX: Briefly pause stream, take photo, resume
      // This is more reliable than YUV conversion for ML Kit
      await _camera.stopStream();
      
      // Small delay to ensure stream fully stopped
      await Future.delayed(const Duration(milliseconds: 50));
      
      // Capture photo
      final shot = await _camera.takePicture();
      
      // Immediately restart stream (minimize blind time)
      unawaited(_camera.startStream(_onFrame));
      
      debugPrint('📸 Background: Photo captured, stream restarting...');
      
      // Detect all faces
      final faces = await _detector.detectAndCropAllFaces(shot.path);
      
      debugPrint('📸 Background: Detected ${faces.length} face(s)');
      
      // Verify all faces
      final results = _verifier.verifyMultipleFaces(faces);
      
      // Process results with tracking
      _processVerificationResults(results);
      
      // Clean up photo file
      try {
        await File(shot.path).delete();
      } catch (_) {}
      
    } catch (e) {
      if (e.toString().contains('No face')) {
        _updateState(_state.copyWith(faceStatus: 'No faces detected'));
        debugPrint('⚠️ Background verify: No faces in frame');
      } else {
        debugPrint('⚠️ Background verification failed: $e');
        _updateState(_state.copyWith(faceStatus: 'Verify error'));
      }
      
      // Ensure stream is running even if error occurred
      try {
        if (!_camera.isInitialized || !(_camera.controller?.value.isStreamingImages ?? false)) {
          await _camera.startStream(_onFrame);
        }
      } catch (e) {
        debugPrint('❌ Failed to restart stream after error: $e');
      }
    } finally {
      _processingVerification = false;
      _updateState(_state.copyWith(processingFace: false));
    }
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

    // Timer is now just a safety fallback
    // Main verification happens in _onFrame
    _verifyTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      // Cleanup task
      _cleanVerificationCache();
    });
  }

  void setAutoVerify(bool enabled) {
    _autoVerify = enabled;
    _startAutoVerify();
    debugPrint('🔄 Auto verify ${enabled ? "enabled" : "disabled"}');
  }

  /// Manual face verification (stops stream - used by button press)
  Future<void> verifyFace() async {
    if (_processingVerification) {
      debugPrint('⚠️ Verification already in progress');
      return;
    }

    _processingVerification = true;
    
    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Capturing...',
    ));

    try {
      // Stop stream to capture photo
      await _camera.stopStream();
      
      await Future.delayed(const Duration(milliseconds: 50));

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
      
      // Clean up
      try {
        await File(shot.path).delete();
      } catch (_) {}

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

      _processingVerification = false;
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
      _recentlyVerified.clear();
      _processingVerification = false;
      _shouldVerifyNextCycle = false;

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
    _cacheCleanupTimer?.cancel();
    await _camera.dispose();
    await _detector.dispose();
    _verifier.dispose();
    _multi.dispose();
    await _stateController.close();
    _recentlyVerified.clear();
    debugPrint('🧹 SurveillanceController disposed');
  }
}