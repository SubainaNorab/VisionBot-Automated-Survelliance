// surveillance_controller.dart - OPTIMIZED FOR MOVING ROBOT & PERSON

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'camera.dart';
import 'face_detector.dart';
import 'face_verification.dart';
import 'alert_service.dart';
import 'alert_image_service.dart';
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
  final CameraService _camera = CameraService();
  final FaceDetectionService _detector = FaceDetectionService();
  final FaceVerificationService _verifier = FaceVerificationService();
  final AlertService _alertService = AlertService();
  final AlertImageService _imageService = AlertImageService();
  final MultiDetectorService _multi;

  final StreamController<SurveillanceState> _stateController =
      StreamController<SurveillanceState>.broadcast();
  
  SurveillanceState _state = const SurveillanceState();

  bool _autoVerify = true;
  Timer? _verifyTimer;
  Timer? _statusTimer;
  Timer? _cacheCleanupTimer;

  bool _lastGroupState = false;
  bool _lastSmokeState = false;

  int _frameCount = 0;
  static const int _frameSkip = 5;

  bool _shouldVerifyNextCycle = false;
  bool _processingVerification = false;

  final Map<String, DateTime> _recentlyVerified = {};
  final Duration _verificationCacheDuration = Duration(seconds: 30);

  int _lastVerifiedFaceCount = 0;
  int _lastKnownCount = 0;
  int _lastUnknownCount = 0;
  DateTime _lastVerificationTime = DateTime.fromMillisecondsSinceEpoch(0);

  int _facesTooFar = 0;
  int _facesTooClose = 0;

  // ✅ NEW: Track last YOLO detection to trigger immediate capture
  int _lastYoloPersonCount = 0;
  DateTime _lastYoloDetectionTime = DateTime.now();

  Stream<SurveillanceState> get stateStream => _stateController.stream;
  SurveillanceState get currentState => _state;
  CameraService get camera => _camera;
  bool get autoVerify => _autoVerify;
  FaceDetectionService get faceDetector => _detector;

  bool get mounted => !_stateController.isClosed;

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
        _imageService.initialize(),
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
      debugPrint('📁 Alert images path: ${_imageService.storagePath}');
      debugPrint('📏 Distance range: ${_detector.minFaceWidth}-${_detector.maxFaceWidth}px');
    } catch (e) {
      _updateState(_state.copyWith(
        isBooting: false,
        faceStatus: 'Initialization failed: $e',
      ));
      debugPrint('❌ SurveillanceController init failed: $e');
    }
  }

  void setDistanceThresholds({
    required int minWidth,
    required int maxWidth,
    required int idealMin,
    required int idealMax,
  }) {
    _detector.setDistanceThresholds(
      minWidth: minWidth,
      maxWidth: maxWidth,
      idealMin: idealMin,
      idealMax: idealMax,
    );
    debugPrint('📏 Controller distance thresholds updated');
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;

      final det = _multi.lastResult;
      int yoloPeople = det.personCount;
      
      final timeSinceVerification = DateTime.now().difference(_lastVerificationTime);
      final hasRecentVerification = timeSinceVerification.inSeconds < 10;

      int totalPeople = yoloPeople;
      String peopleBreakdown = '';
      
      if (hasRecentVerification && _lastVerifiedFaceCount > 0) {
        totalPeople = max(yoloPeople, _lastVerifiedFaceCount);
        
        if (_lastKnownCount > 0 || _lastUnknownCount > 0) {
          peopleBreakdown = ' (${_lastKnownCount} known, ${_lastUnknownCount} unknown';
          
          if (yoloPeople > _lastVerifiedFaceCount) {
            peopleBreakdown += ', ${yoloPeople - _lastVerifiedFaceCount} unverified';
          }
          
          peopleBreakdown += ')';
        }
      } else if (yoloPeople > 0) {
        peopleBreakdown = ' (detected by YOLO, awaiting verification)';
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
      if (mounted) {
        _cleanVerificationCache();
      }
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
    String peopleBreakdown,
  ) async {
    if (!mounted) return;

    final lensName =
        _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

    // ✅ Group alert - NO IMAGE SAVE HERE (will be saved during verification)
    if (isGroup && !_lastGroupState) {
      debugPrint('🚨 GROUP DETECTED: $totalPeople people$peopleBreakdown');
      
      _alertService
          .createGroupAlert(
            personCount: totalPeople,
            lens: lensName,
            imagePath: null, // Will be added during verification
          )
          .catchError((e) => debugPrint('❌ Group alert error: $e'));
    }
    _lastGroupState = isGroup;

    // Smoking alert
    if (det.smokingDetected && !_lastSmokeState) {
      debugPrint('🚨 SMOKING DETECTED');
      
      _alertService
          .createSmokingAlert(
            lens: lensName,
            imagePath: null,
          )
          .catchError((e) => debugPrint('❌ Smoke alert error: $e'));
    }
    _lastSmokeState = det.smokingDetected;
  }

  // ✅ UPDATED: Immediate capture when person detected
  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized || !mounted) return;

    _frameCount++;
    
    if (_frameCount % _frameSkip == 0) {
      _multi.detectAllAsync(image);
    }
    
    final det = _multi.lastResult;
    final yoloPeople = det.personCount;
    
    // ✅ NEW: Immediate verification when person first detected
    if (yoloPeople > 0 && _lastYoloPersonCount == 0) {
      // Person just appeared!
      debugPrint('👤 NEW PERSON DETECTED - Triggering immediate capture');
      _lastYoloDetectionTime = DateTime.now();
      
      if (_autoVerify && !_processingVerification) {
        _shouldVerifyNextCycle = true;
        _triggerBackgroundVerification();
      }
    }
    
    // ✅ Also verify periodically (every 3 seconds) if person still there
    if (_frameCount % 90 == 0 && _autoVerify && !_processingVerification && yoloPeople > 0) {
      final timeSinceLastDetection = DateTime.now().difference(_lastYoloDetectionTime);
      if (timeSinceLastDetection.inSeconds > 2) {
        _shouldVerifyNextCycle = true;
        _triggerBackgroundVerification();
      }
    }
    
    _lastYoloPersonCount = yoloPeople;
  }

  // ✅ UPDATED: Capture multiple frames and pick best
  Future<void> _triggerBackgroundVerification() async {
    if (_processingVerification || !_shouldVerifyNextCycle || !mounted) return;
    
    _shouldVerifyNextCycle = false;
    _processingVerification = true;
    
    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Quick verify...',
    ));
    
    List<XFile> capturedFrames = [];
    
    try {
      if (_camera.controller?.value.isStreamingImages ?? false) {
        await _camera.stopStream();
        await Future.delayed(const Duration(milliseconds: 50));
      }
      
      // ✅ NEW: Capture 3 frames (for moving scenarios)
      debugPrint('📸 Capturing 3 frames for best selection...');
      for (int i = 0; i < 3; i++) {
        capturedFrames.add(await _camera.takePicture());
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      if (mounted && _camera.isInitialized) {
        unawaited(_camera.startStream(_onFrame));
      }
      
      // ✅ NEW: Pick best frame (most faces detected)
      XFile? bestFrame;
      int maxFaces = 0;
      List<FaceInfo>? bestFaceInfos;
      
      for (final frame in capturedFrames) {
        try {
          final faceInfos = await _detector.detectAndCropAllFacesWithDistance(frame.path);
          
          if (faceInfos.length > maxFaces) {
            maxFaces = faceInfos.length;
            bestFrame = frame;
            bestFaceInfos = faceInfos;
          }
        } catch (e) {
          debugPrint('   Frame analysis failed: $e');
        }
      }
      
      if (bestFrame == null || bestFaceInfos == null || bestFaceInfos.isEmpty) {
        debugPrint('⚠️ No faces detected in any of the 3 frames');
        
        // Cleanup all frames
        for (final frame in capturedFrames) {
          try {
            await File(frame.path).delete();
          } catch (_) {}
        }
        
        if (mounted) {
          _updateState(_state.copyWith(faceStatus: 'No faces detected'));
        }
        return;
      }
      
      debugPrint('✅ Best frame has ${bestFaceInfos.length} face(s)');
      
      // ✅ Cleanup other frames
      for (final frame in capturedFrames) {
        if (frame.path != bestFrame.path) {
          try {
            await File(frame.path).delete();
          } catch (_) {}
        }
      }
      
      // Process best frame
      final validFaces = <img.Image>[];
      _facesTooFar = 0;
      _facesTooClose = 0;
      
      for (final faceInfo in bestFaceInfos) {
        if (faceInfo.isTooFar) {
          _facesTooFar++;
        } else if (faceInfo.isTooClose) {
          _facesTooClose++;
        } else if (faceInfo.isGoodDistance) {
          validFaces.add(faceInfo.croppedFace);
        }
      }
      
      if (validFaces.isEmpty) {
        String reason = 'No faces in valid range';
        if (_facesTooFar > 0) reason = '$_facesTooFar face(s) too far';
        if (_facesTooClose > 0) reason = '$_facesTooClose face(s) too close';
        
        if (mounted) {
          _updateState(_state.copyWith(faceStatus: reason));
        }
        
        try {
          await File(bestFrame.path).delete();
        } catch (_) {}
        
        return;
      }
      
      debugPrint('📸 Verifying ${validFaces.length} face(s)...');
      
      final results = _verifier.verifyMultipleFaces(validFaces);
      
      if (mounted) {
        await _processVerificationResults(
          results, 
          validFaces.length, 
          bestFaceInfos.length,
          bestFrame.path, // ✅ Pass frame path for saving
          validFaces, // ✅ Pass cropped faces
        );
      }
      
      // ✅ Cleanup after saving (if needed)
      Future.delayed(Duration(seconds: 5), () {
        try {
          File(bestFrame!.path).delete();
        } catch (_) {}
      });
      
    } catch (e) {
      debugPrint('⚠️ Verification failed: $e');
      
      // Cleanup all frames on error
      for (final frame in capturedFrames) {
        try {
          await File(frame.path).delete();
        } catch (_) {}
      }
      
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Verify error'));
      }
      
      try {
        if (mounted && _camera.isInitialized && !(_camera.controller?.value.isStreamingImages ?? false)) {
          await _camera.startStream(_onFrame);
        }
      } catch (e) {
        debugPrint('❌ Failed to restart stream: $e');
      }
    } finally {
      if (mounted) {
        _processingVerification = false;
        _updateState(_state.copyWith(processingFace: false));
      }
    }
  }

  // ✅ UPDATED: Save frame immediately with results
  Future<void> _processVerificationResults(
    List<VerificationResult> results,
    int verifiedFaceCount,
    int totalDetectedFaces,
    String framePath, // ✅ NEW: Frame to save
    List<img.Image> detectedFaces, // ✅ NEW: Cropped faces
  ) async {
    int knownCount = 0;
    int unknownCount = 0;
    final knownNames = <String>[];

    for (final result in results) {
      if (result.verified && result.person != null) {
        final name = result.person!.name;
        
        final lastVerified = _recentlyVerified[name];
        final isRecent = lastVerified != null && 
            DateTime.now().difference(lastVerified) < _verificationCacheDuration;
        
        if (!isRecent) {
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

    _lastVerifiedFaceCount = verifiedFaceCount;
    _lastKnownCount = knownCount;
    _lastUnknownCount = unknownCount;
    _lastVerificationTime = DateTime.now();

    debugPrint('📊 Verification: $verifiedFaceCount faces ($knownCount known, $unknownCount unknown)');

    // ✅ SAVE FRAME IMMEDIATELY if unknown detected
    if (unknownCount > 0) {
      debugPrint('');
      debugPrint('═══════════════════════════════════');
      debugPrint('🚨 UNKNOWN DETECTED - SAVING FRAME');
      debugPrint('═══════════════════════════════════');
      
      final lensName = _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';
      
      // Save full frame
      String? savedImagePath;
      try {
        savedImagePath = await _imageService.saveUnknownFaceImage(
          framePath,
          additionalInfo: 'unknown${unknownCount}_known${knownCount}',
        );
        debugPrint('✅ Full frame saved: $savedImagePath');
      } catch (e) {
        debugPrint('❌ Frame save failed: $e');
      }
      
      // Save cropped faces
      List<String>? savedFacePaths;
      try {
        savedFacePaths = await _imageService.saveFaceImages(
          detectedFaces,
          alertType: 'unknown_face',
          sessionInfo: 'u${unknownCount}_k${knownCount}',
        );
        debugPrint('✅ Saved ${savedFacePaths.length} cropped faces');
      } catch (e) {
        debugPrint('❌ Face save failed: $e');
      }
      
      // Create alert
      await _alertService.createUnknownAlert(
        threshold: FaceVerificationService.threshold,
        lens: lensName,
        note: '$unknownCount unknown face(s) detected',
        imagePath: savedImagePath,
        faceImagePaths: savedFacePaths,
      );
      
      debugPrint('═══════════════════════════════════');
    }

    String statusMsg;
    if (knownCount > 0 && unknownCount > 0) {
      statusMsg = '✅ ${knownNames.join(", ")} | ⚠️ $unknownCount unknown';
    } else if (knownCount > 0) {
      statusMsg = '✅ Verified: ${knownNames.join(", ")}';
    } else {
      statusMsg = '⚠️ All unknown ($unknownCount face(s))';
    }

    if (mounted) {
      _updateState(_state.copyWith(
        faceStatus: statusMsg,
        lastMatch: knownNames.isNotEmpty ? knownNames.join(', ') : 'Unknown',
      ));
    }
  }

  void _startAutoVerify() {
    _verifyTimer?.cancel();
    if (!_autoVerify) return;

    _verifyTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) {
        _cleanVerificationCache();
      }
    });
  }

  void setAutoVerify(bool enabled) {
    _autoVerify = enabled;
    _startAutoVerify();
    debugPrint('🔄 Auto verify ${enabled ? "enabled" : "disabled"}');
  }

  Future<void> verifyFace() async {
    // Manual verification - same logic but immediate
    if (_processingVerification || !mounted) return;
    
    _shouldVerifyNextCycle = true;
    await _triggerBackgroundVerification();
  }

  Future<void> switchCamera() async {
    if (!mounted) return;

    try {
      _updateState(_state.copyWith(faceStatus: 'Switching camera...'));

      _verifyTimer?.cancel();

      if (_camera.controller?.value.isStreamingImages ?? false) {
        await _camera.stopStream();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      await _camera.switchCamera();
      
      if (mounted && _camera.isInitialized) {
        await _camera.startStream(_onFrame);
      }

      _alertService.resetCooldowns();
      _lastGroupState = false;
      _lastSmokeState = false;
      _recentlyVerified.clear();
      _processingVerification = false;
      _shouldVerifyNextCycle = false;
      
      _lastVerifiedFaceCount = 0;
      _lastKnownCount = 0;
      _lastUnknownCount = 0;
      _lastYoloPersonCount = 0;

      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Ready'));
        _startAutoVerify();
      }

      debugPrint('📷 Camera switched');
    } catch (e) {
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Switch failed: $e'));
      }
      debugPrint('❌ Camera switch failed: $e');
    }
  }

  void setGroupThreshold(int threshold) {
    _multi.setGroupThreshold(threshold);
  }

  void _updateState(SurveillanceState newState) {
    if (mounted) {
      _state = newState;
      _stateController.add(_state);
    }
  }

  Future<void> dispose() async {
    debugPrint('🧹 Disposing SurveillanceController...');
    
    _verifyTimer?.cancel();
    _statusTimer?.cancel();
    _cacheCleanupTimer?.cancel();
    
    try {
      await _camera.stopStream();
      await _camera.dispose();
    } catch (e) {
      debugPrint('⚠️ Camera disposal error: $e');
    }
    
    try {
      await _detector.dispose();
      _verifier.dispose();
      _multi.dispose();
      await _stateController.close();
    } catch (e) {
      debugPrint('⚠️ Services disposal error: $e');
    }
    
    _recentlyVerified.clear();
    
    debugPrint('✅ SurveillanceController disposed');
  }
}