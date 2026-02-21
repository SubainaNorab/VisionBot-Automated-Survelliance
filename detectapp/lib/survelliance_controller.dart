// surveillance_controller.dart

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

  // Frame buffering flags
  bool _shouldVerifyNextCycle = false;
  bool _processingVerification = false;

  // Face tracking cache
  final Map<String, DateTime> _recentlyVerified = {};
  final Duration _verificationCacheDuration = Duration(seconds: 30);

  // ✅ NEW: Track last verification results for group correlation
  int _lastVerifiedFaceCount = 0;
  int _lastKnownCount = 0;
  int _lastUnknownCount = 0;
  DateTime _lastVerificationTime = DateTime.fromMillisecondsSinceEpoch(0);

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

  /// ✅ UPDATED: Poll detection results with face correlation
  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final det = _multi.lastResult;

      // YOLO person count
      int yoloPeople = det.personCount;
      
      // ✅ NEW: Check if we have recent face verification data
      final timeSinceVerification = DateTime.now().difference(_lastVerificationTime);
      final hasRecentVerification = timeSinceVerification.inSeconds < 5;

      // ✅ NEW: Combine YOLO and face data if recent verification exists
      int totalPeople = yoloPeople;
      String peopleBreakdown = '';
      
      if (hasRecentVerification && _lastVerifiedFaceCount > 0) {
        // Use face count if YOLO missed people (faces are more accurate for count)
        if (_lastVerifiedFaceCount > yoloPeople) {
          totalPeople = _lastVerifiedFaceCount;
          debugPrint('📊 Using face count ($totalPeople) over YOLO count ($yoloPeople)');
        }
        
        // Add breakdown
        if (_lastKnownCount > 0 || _lastUnknownCount > 0) {
          peopleBreakdown = ' (${_lastKnownCount} known, ${_lastUnknownCount} unknown)';
        }
      }

      bool isGroup = totalPeople >= _multi.groupThreshold;

      final status =
          'People: $totalPeople$peopleBreakdown | Group: ${isGroup ? "YES" : "NO"} | Smoke: ${det.smokingDetected ? "YES" : "NO"} (${det.processingTimeMs}ms)';

      _updateState(_state.copyWith(
        detectionStatus: status,
        peopleCount: totalPeople,
        groupDetected: isGroup,
        smokingDetected: det.smokingDetected,
      ));

      _handleDetectionAlerts(det, totalPeople, isGroup, peopleBreakdown);
    });
  }

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

  /// ✅ UPDATED: Handle alerts with face breakdown
  void _handleDetectionAlerts(
    DetectionResult det,
    int totalPeople,
    bool isGroup,
    String peopleBreakdown,
  ) {
    final lensName =
        _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

    // Group alert with face details
    if (isGroup && !_lastGroupState) {
      debugPrint('🚨 GROUP DETECTED: $totalPeople people$peopleBreakdown');
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

  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized) return;

    _frameCount++;
    
    // YOLO detection (every 5 frames)
    if (_frameCount % _frameSkip == 0) {
      _multi.detectAllAsync(image);
    }
    
    // ✅ UPDATED: Trigger verification when YOLO detects people
    // Or every 90 frames as backup
    final det = _multi.lastResult;
    final hasPeople = det.personCount > 0;
    
    if (_frameCount % 90 == 0 && _autoVerify && !_processingVerification) {
      // Verify more frequently if people detected
      if (hasPeople || _frameCount % 90 == 0) {
        _shouldVerifyNextCycle = true;
        _triggerBackgroundVerification();
      }
    }
  }

  /// Background verification with brief stream pause
  Future<void> _triggerBackgroundVerification() async {
    if (_processingVerification || !_shouldVerifyNextCycle) return;
    
    _shouldVerifyNextCycle = false;
    _processingVerification = true;
    
    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Quick verify...',
    ));
    
    try {
      await _camera.stopStream();
      await Future.delayed(const Duration(milliseconds: 50));
      
      final shot = await _camera.takePicture();
      
      // Immediately restart stream
      unawaited(_camera.startStream(_onFrame));
      
      debugPrint('📸 Background: Photo captured, stream restarting...');
      
      // Detect all faces
      final faces = await _detector.detectAndCropAllFaces(shot.path);
      
      debugPrint('📸 Background: Detected ${faces.length} face(s)');
      
      // Verify all faces
      final results = _verifier.verifyMultipleFaces(faces);
      
      // Process results
      _processVerificationResults(results, faces.length);
      
      // Clean up
      try {
        await File(shot.path).delete();
      } catch (_) {}
      
    } catch (e) {
      if (e.toString().contains('No face')) {
        // ✅ NEW: Reset face count when no faces detected
        _lastVerifiedFaceCount = 0;
        _lastKnownCount = 0;
        _lastUnknownCount = 0;
        _lastVerificationTime = DateTime.now();
        
        _updateState(_state.copyWith(faceStatus: 'No faces detected'));
        debugPrint('⚠️ Background verify: No faces in frame');
      } else {
        debugPrint('⚠️ Background verification failed: $e');
        _updateState(_state.copyWith(faceStatus: 'Verify error'));
      }
      
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

  /// ✅ UPDATED: Process verification results and update counts
  void _processVerificationResults(List<VerificationResult> results, int totalFaces) {
    int knownCount = 0;
    int unknownCount = 0;
    final knownNames = <String>[];
    final newKnownNames = <String>[];

    for (final result in results) {
      if (result.verified && result.person != null) {
        final name = result.person!.name;
        
        final lastVerified = _recentlyVerified[name];
        final isRecent = lastVerified != null && 
            DateTime.now().difference(lastVerified) < _verificationCacheDuration;
        
        if (isRecent) {
          debugPrint('⏭️ Skipping alert for $name (verified ${DateTime.now().difference(lastVerified!).inSeconds}s ago)');
        } else {
          newKnownNames.add(name);
          debugPrint('✅ NEW verification: $name');
        }
        
        _recentlyVerified[name] = DateTime.now();
        
        knownCount++;
        if (!knownNames.contains(name)) {
          knownNames.add(name);
        }
      } else {
        unknownCount++;
      }
    }

    // ✅ NEW: Update tracked counts for group detection
    _lastVerifiedFaceCount = totalFaces;
    _lastKnownCount = knownCount;
    _lastUnknownCount = unknownCount;
    _lastVerificationTime = DateTime.now();

    debugPrint('📊 Verification: ${totalFaces} faces total ($knownCount known, $unknownCount unknown)');

    // Create alert for unknown faces
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

    // Update UI
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

    _verifyTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _cleanVerificationCache();
    });
  }

  void setAutoVerify(bool enabled) {
    _autoVerify = enabled;
    _startAutoVerify();
    debugPrint('🔄 Auto verify ${enabled ? "enabled" : "disabled"}');
  }

  /// Manual face verification
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
      await _camera.stopStream();
      await Future.delayed(const Duration(milliseconds: 50));

      final shot = await _camera.takePicture();

      _updateState(_state.copyWith(faceStatus: 'Detecting faces...'));
      
      final faces = await _detector.detectAndCropAllFaces(shot.path);
      
      debugPrint('📸 Manual: Detected ${faces.length} face(s) in frame');

      _updateState(_state.copyWith(
        faceStatus: 'Verifying ${faces.length} face(s)...',
      ));
      
      final results = _verifier.verifyMultipleFaces(faces);

      _processVerificationResults(results, faces.length);
      
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
      try {
        await _camera.startStream(_onFrame);
      } catch (e) {
        debugPrint('⚠️ Failed to restart stream: $e');
      }

      _processingVerification = false;
      _updateState(_state.copyWith(processingFace: false));
    }
  }

  Future<void> switchCamera() async {
    try {
      _updateState(_state.copyWith(faceStatus: 'Switching camera...'));

      _verifyTimer?.cancel();

      await _camera.stopStream();
      await _camera.switchCamera();
      await _camera.startStream(_onFrame);

      _alertService.resetCooldowns();
      _lastGroupState = false;
      _lastSmokeState = false;
      _recentlyVerified.clear();
      _processingVerification = false;
      _shouldVerifyNextCycle = false;
      
      // ✅ NEW: Reset face tracking
      _lastVerifiedFaceCount = 0;
      _lastKnownCount = 0;
      _lastUnknownCount = 0;

      _updateState(_state.copyWith(faceStatus: 'Ready'));
      _startAutoVerify();

      debugPrint('📷 Camera switched, all counters reset');
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