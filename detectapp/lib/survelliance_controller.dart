// surveillance_controller.dart - COMPLETE WITH PROPER CLEANUP & ERROR HANDLING

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
  // Services
  final CameraService _camera = CameraService();
  final FaceDetectionService _detector = FaceDetectionService();
  final FaceVerificationService _verifier = FaceVerificationService();
  final AlertService _alertService = AlertService();
  final AlertImageService _imageService = AlertImageService();
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

  // Face verification tracking
  int _lastVerifiedFaceCount = 0;
  int _lastKnownCount = 0;
  int _lastUnknownCount = 0;
  DateTime _lastVerificationTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Distance filtering stats
  int _facesTooFar = 0;
  int _facesTooClose = 0;

  // Image capture for alerts
  String? _lastCapturedImagePath;
  List<img.Image>? _lastDetectedFaces;

  Stream<SurveillanceState> get stateStream => _stateController.stream;
  SurveillanceState get currentState => _state;
  CameraService get camera => _camera;
  bool get autoVerify => _autoVerify;
  FaceDetectionService get faceDetector => _detector;

  // ✅ Helper to check if controller is still active
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
      debugPrint('📏 Distance range: ${_detector.minFaceWidth}-${_detector.maxFaceWidth}px (ideal: ${_detector.idealMinWidth}-${_detector.idealMaxWidth}px)');
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
      
      // ✅ Combine YOLO + Face counts intelligently
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

    // Group alert with image
    if (isGroup && !_lastGroupState) {
      debugPrint('🚨 GROUP DETECTED: $totalPeople people$peopleBreakdown');
      
      String? savedImagePath;
      if (_lastCapturedImagePath != null) {
        final cleanInfo = peopleBreakdown.replaceAll(' ', '').replaceAll('(', '').replaceAll(')', '');
        savedImagePath = await _imageService.saveGroupImage(
          _lastCapturedImagePath!,
          personCount: totalPeople,
          additionalInfo: cleanInfo,
        );
      }
      
      _alertService
          .createGroupAlert(
            personCount: totalPeople,
            lens: lensName,
            imagePath: savedImagePath,
          )
          .catchError((e) => debugPrint('❌ Group alert error: $e'));
    }
    _lastGroupState = isGroup;

    // Smoking alert with image
    if (det.smokingDetected && !_lastSmokeState) {
      debugPrint('🚨 SMOKING DETECTED');
      
      String? savedImagePath;
      if (_lastCapturedImagePath != null) {
        savedImagePath = await _imageService.saveSmokingImage(
          _lastCapturedImagePath!,
        );
      }
      
      _alertService
          .createSmokingAlert(
            lens: lensName,
            imagePath: savedImagePath,
          )
          .catchError((e) => debugPrint('❌ Smoke alert error: $e'));
    }
    _lastSmokeState = det.smokingDetected;
  }

  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized || !mounted) return;

    _frameCount++;
    
    if (_frameCount % _frameSkip == 0) {
      _multi.detectAllAsync(image);
    }
    
    final det = _multi.lastResult;
    final hasPeople = det.personCount > 0;
    
    if (_frameCount % 90 == 0 && _autoVerify && !_processingVerification) {
      if (hasPeople || _frameCount % 90 == 0) {
        _shouldVerifyNextCycle = true;
        _triggerBackgroundVerification();
      }
    }
  }

  Future<void> _triggerBackgroundVerification() async {
    if (_processingVerification || !_shouldVerifyNextCycle || !mounted) return;
    
    _shouldVerifyNextCycle = false;
    _processingVerification = true;
    
    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Quick verify...',
    ));
    
    XFile? shot;
    
    try {
      // Stop stream
      if (_camera.controller?.value.isStreamingImages ?? false) {
        await _camera.stopStream();
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      shot = await _camera.takePicture();
      
      _lastCapturedImagePath = shot.path;
      
      debugPrint('📸 Background: Photo captured, stream restarting...');
      
      // Restart stream BEFORE processing
      if (mounted && _camera.isInitialized) {
        unawaited(_camera.startStream(_onFrame));
        await Future.delayed(const Duration(milliseconds: 50));
      }
      
      final faceInfos = await _detector.detectAndCropAllFacesWithDistance(shot.path);
      
      debugPrint('📸 Background: Detected ${faceInfos.length} face(s)');
      
      final validFaces = <img.Image>[];
      _facesTooFar = 0;
      _facesTooClose = 0;
      
      for (final faceInfo in faceInfos) {
        if (faceInfo.isTooFar) {
          _facesTooFar++;
          debugPrint('⏭️ Skipping: Face too far (${faceInfo.originalWidth}px)');
        } else if (faceInfo.isTooClose) {
          _facesTooClose++;
          debugPrint('⏭️ Skipping: Face too close (${faceInfo.originalWidth}px)');
        } else if (faceInfo.isGoodDistance) {
          validFaces.add(faceInfo.croppedFace);
          debugPrint('✅ Face in good range: ${faceInfo.distanceStatus}');
        }
      }
      
      if (validFaces.isEmpty) {
        String reason;
        if (_facesTooFar > 0 && _facesTooClose > 0) {
          reason = '$_facesTooFar too far, $_facesTooClose too close';
        } else if (_facesTooFar > 0) {
          reason = 'All $_facesTooFar face(s) too far';
        } else if (_facesTooClose > 0) {
          reason = 'All $_facesTooClose face(s) too close';
        } else {
          reason = 'No faces in valid range';
        }
        
        if (mounted) {
          _updateState(_state.copyWith(faceStatus: reason));
        }
        debugPrint('⚠️ Background verify: $reason');
        
        _scheduleImageCleanup(shot.path, Duration(seconds: 2));
        
        return;
      }
      
      debugPrint('📸 Verifying ${validFaces.length} face(s) in good range');
      
      _lastDetectedFaces = validFaces;
      
      final results = _verifier.verifyMultipleFaces(validFaces);
      
      if (mounted) {
        _processVerificationResults(results, validFaces.length, faceInfos.length);
      }
      
      _scheduleImageCleanup(shot.path, Duration(seconds: 3));
      
    } catch (e) {
      if (e.toString().contains('No face')) {
        _lastVerifiedFaceCount = 0;
        _lastKnownCount = 0;
        _lastUnknownCount = 0;
        _lastVerificationTime = DateTime.now();
        
        if (mounted) {
          _updateState(_state.copyWith(faceStatus: 'No faces detected'));
        }
        debugPrint('⚠️ Background verify: No faces in frame');
      } else {
        debugPrint('⚠️ Background verification failed: $e');
        if (mounted) {
          _updateState(_state.copyWith(faceStatus: 'Verify error'));
        }
      }
      
      try {
        if (mounted && _camera.isInitialized && !(_camera.controller?.value.isStreamingImages ?? false)) {
          await _camera.startStream(_onFrame);
        }
      } catch (e) {
        debugPrint('❌ Failed to restart stream after error: $e');
      }
    } finally {
      if (mounted) {
        _processingVerification = false;
        _updateState(_state.copyWith(processingFace: false));
      }
    }
  }

  // ✅ Schedule image cleanup
  void _scheduleImageCleanup(String imagePath, Duration delay) {
    Future.delayed(delay, () {
      if (_lastCapturedImagePath == imagePath) {
        try {
          File(imagePath).delete();
          _lastCapturedImagePath = null;
          _lastDetectedFaces = null;
        } catch (e) {
          debugPrint('⚠️ Failed to delete temp image: $e');
        }
      }
    });
  }

  void _processVerificationResults(
    List<VerificationResult> results,
    int verifiedFaceCount,
    int totalDetectedFaces,
  ) {
    int knownCount = 0;
    int unknownCount = 0;
    final knownNames = <String>[];
    final newKnownNames = <String>[];

    debugPrint('🔍 Processing ${results.length} verification results...');

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
        debugPrint('❌ Unknown face detected');
      }
    }

    _lastVerifiedFaceCount = verifiedFaceCount;
    _lastKnownCount = knownCount;
    _lastUnknownCount = unknownCount;
    _lastVerificationTime = DateTime.now();

    final filteredInfo = totalDetectedFaces > verifiedFaceCount
        ? ' (${totalDetectedFaces - verifiedFaceCount} filtered by distance)'
        : '';

    debugPrint('📊 Verification: ${verifiedFaceCount} faces verified$filteredInfo ($knownCount known, $unknownCount unknown)');

    if (unknownCount > 0) {
      debugPrint('');
      debugPrint('═══════════════════════════════════');
      debugPrint('🚨 UNKNOWN FACE(S) DETECTED');
      debugPrint('═══════════════════════════════════');
      debugPrint('   Unknown count: $unknownCount');
      debugPrint('   Known count: $knownCount');
      debugPrint('   Last captured image: $_lastCapturedImagePath');
      
      if (_lastCapturedImagePath != null) {
        final imgFile = File(_lastCapturedImagePath!);
        debugPrint('   Image file exists: ${imgFile.existsSync()}');
        if (imgFile.existsSync()) {
          debugPrint('   Image file size: ${imgFile.lengthSync()} bytes');
        }
      } else {
        debugPrint('   ❌ No captured image path!');
      }
      
      debugPrint('   Last detected faces: ${_lastDetectedFaces?.length ?? 0}');
      debugPrint('═══════════════════════════════════');
      debugPrint('');
      
      final lensName = _camera.lensDirection == CameraLensDirection.front
          ? 'front'
          : 'back';

      _saveUnknownFaceAlert(
        unknownCount: unknownCount,
        knownCount: knownCount,
        lens: lensName,
        filteredInfo: filteredInfo,
      );
    } else {
      debugPrint('✅ All faces are known - no unknown face alert');
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

  Future<void> _saveUnknownFaceAlert({
    required int unknownCount,
    required int knownCount,
    required String lens,
    required String filteredInfo,
  }) async {
    debugPrint('');
    debugPrint('═══════════════════════════════════');
    debugPrint('📸 SAVING UNKNOWN FACE ALERT');
    debugPrint('═══════════════════════════════════');
    
    try {
      String? savedImagePath;
      List<String>? savedFacePaths;

      if (_lastCapturedImagePath != null) {
        debugPrint('💾 Step 1: Saving full frame image...');
        debugPrint('   Source: $_lastCapturedImagePath');
        
        final sourceFile = File(_lastCapturedImagePath!);
        final exists = await sourceFile.exists();
        debugPrint('   File exists: $exists');
        
        if (exists) {
          final size = await sourceFile.length();
          debugPrint('   File size: $size bytes');
          
          savedImagePath = await _imageService.saveUnknownFaceImage(
            _lastCapturedImagePath!,
            additionalInfo: 'unknown${unknownCount}_known${knownCount}',
          );
          
          if (savedImagePath != null) {
            debugPrint('   ✅ Full frame saved to: $savedImagePath');
          } else {
            debugPrint('   ❌ Full frame save returned null');
          }
        } else {
          debugPrint('   ❌ Source file does not exist!');
        }
      } else {
        debugPrint('⚠️ Step 1: No captured image path available');
      }

      if (_lastDetectedFaces != null && _lastDetectedFaces!.isNotEmpty) {
        debugPrint('💾 Step 2: Saving ${_lastDetectedFaces!.length} cropped face images...');
        
        savedFacePaths = await _imageService.saveFaceImages(
          _lastDetectedFaces!,
          alertType: 'unknown_face',
          sessionInfo: 'u${unknownCount}_k${knownCount}',
        );
        
        debugPrint('   ✅ Saved ${savedFacePaths.length} face images');
        for (int i = 0; i < savedFacePaths.length; i++) {
          debugPrint('      Face ${i + 1}: ${savedFacePaths[i]}');
        }
      } else {
        debugPrint('⚠️ Step 2: No detected faces available to save');
        if (_lastDetectedFaces == null) {
          debugPrint('      _lastDetectedFaces is null');
        } else {
          debugPrint('      _lastDetectedFaces is empty');
        }
      }

      debugPrint('📝 Step 3: Creating Firestore alert...');
      
      await _alertService.createUnknownAlert(
        threshold: FaceVerificationService.threshold,
        lens: lens,
        note: '$unknownCount unknown face(s) detected${knownCount > 0 ? ', $knownCount known' : ''}$filteredInfo',
        imagePath: savedImagePath,
        faceImagePaths: savedFacePaths,
      );

      debugPrint('✅ ALERT SAVED SUCCESSFULLY');
      debugPrint('   Full frame: ${savedImagePath ?? 'none'}');
      debugPrint('   Cropped faces: ${savedFacePaths?.length ?? 0}');
      debugPrint('═══════════════════════════════════');
      debugPrint('');
    } catch (e, stackTrace) {
      debugPrint('❌ FAILED TO SAVE UNKNOWN FACE ALERT');
      debugPrint('   Error: $e');
      debugPrint('   Stack trace: $stackTrace');
      debugPrint('═══════════════════════════════════');
      debugPrint('');
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
    if (_processingVerification) {
      debugPrint('⚠️ Verification already in progress');
      return;
    }

    if (!mounted) return;

    _processingVerification = true;
    
    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Capturing...',
    ));

    XFile? shot;

    try {
      if (_camera.controller?.value.isStreamingImages ?? false) {
        await _camera.stopStream();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      shot = await _camera.takePicture();
      _lastCapturedImagePath = shot.path;

      if (!mounted) return;

      _updateState(_state.copyWith(faceStatus: 'Detecting faces...'));
      
      final faceInfos = await _detector.detectAndCropAllFacesWithDistance(shot.path);
      
      debugPrint('📸 Manual: Detected ${faceInfos.length} face(s) in frame');

      final validFaces = <img.Image>[];
      _facesTooFar = 0;
      _facesTooClose = 0;
      
      for (final faceInfo in faceInfos) {
        if (faceInfo.isTooFar) {
          _facesTooFar++;
        } else if (faceInfo.isTooClose) {
          _facesTooClose++;
        } else if (faceInfo.isGoodDistance) {
          validFaces.add(faceInfo.croppedFace);
        }
      }

      if (validFaces.isEmpty) {
        String reason;
        if (_facesTooFar > 0 && _facesTooClose > 0) {
          reason = '$_facesTooFar too far, $_facesTooClose too close - adjust distance';
        } else if (_facesTooFar > 0) {
          reason = 'All $_facesTooFar face(s) too far - move closer';
        } else if (_facesTooClose > 0) {
          reason = 'All $_facesTooClose face(s) too close - step back';
        } else {
          reason = 'No faces in valid range';
        }
        
        if (mounted) {
          _updateState(_state.copyWith(faceStatus: reason));
        }
        debugPrint('⚠️ Manual verify: $reason');
        
        _scheduleImageCleanup(shot.path, Duration(seconds: 1));
        
        return;
      }

      if (!mounted) return;

      _updateState(_state.copyWith(
        faceStatus: 'Verifying ${validFaces.length} face(s)...',
      ));
      
      _lastDetectedFaces = validFaces;
      final results = _verifier.verifyMultipleFaces(validFaces);

      if (mounted) {
        _processVerificationResults(results, validFaces.length, faceInfos.length);
      }
      
      _scheduleImageCleanup(shot.path, Duration(seconds: 2));

    } catch (e) {
      final errorMsg = e.toString().contains('No face')
          ? 'No faces detected'
          : 'Error: $e';
      
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: errorMsg));
      }
      debugPrint('⚠️ Manual verification failed: $e');
    } finally {
      try {
        if (mounted && _camera.isInitialized) {
          await _camera.startStream(_onFrame);
        }
      } catch (e) {
        debugPrint('⚠️ Failed to restart stream: $e');
      }

      if (mounted) {
        _processingVerification = false;
        _updateState(_state.copyWith(processingFace: false));
      }
    }
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
      _facesTooFar = 0;
      _facesTooClose = 0;
      _lastCapturedImagePath = null;
      _lastDetectedFaces = null;

      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Ready'));
        _startAutoVerify();
      }

      debugPrint('📷 Camera switched, all counters reset');
    } catch (e) {
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Switch failed: $e'));
      }
      debugPrint('❌ Camera switch failed: $e');
    }
  }

  void setGroupThreshold(int threshold) {
    _multi.setGroupThreshold(threshold);
    debugPrint('👥 Group threshold set to $threshold');
  }

  void _updateState(SurveillanceState newState) {
    if (mounted) {
      _state = newState;
      _stateController.add(_state);
    }
  }

  Future<void> dispose() async {
    debugPrint('🧹 Starting SurveillanceController disposal...');
    
    _verifyTimer?.cancel();
    _statusTimer?.cancel();
    _cacheCleanupTimer?.cancel();
    
    debugPrint('   Timers cancelled');
    
    try {
      await _camera.stopStream();
      debugPrint('   Camera stream stopped');
    } catch (e) {
      debugPrint('   ⚠️ Camera stream stop error: $e');
    }
    
    try {
      await _camera.dispose();
      debugPrint('   Camera disposed');
    } catch (e) {
      debugPrint('   ⚠️ Camera dispose error: $e');
    }
    
    try {
      await _detector.dispose();
      debugPrint('   Face detector disposed');
    } catch (e) {
      debugPrint('   ⚠️ Face detector dispose error: $e');
    }
    
    try {
      _verifier.dispose();
      debugPrint('   Face verifier disposed');
    } catch (e) {
      debugPrint('   ⚠️ Face verifier dispose error: $e');
    }
    
    try {
      _multi.dispose();
      debugPrint('   Multi detector disposed');
    } catch (e) {
      debugPrint('   ⚠️ Multi detector dispose error: $e');
    }
    
    try {
      await _stateController.close();
      debugPrint('   State controller closed');
    } catch (e) {
      debugPrint('   ⚠️ State controller close error: $e');
    }
    
    _recentlyVerified.clear();
    
    if (_lastCapturedImagePath != null) {
      try {
        await File(_lastCapturedImagePath!).delete();
        debugPrint('   Temp image cleaned up');
      } catch (e) {
        debugPrint('   ⚠️ Temp image cleanup error: $e');
      }
    }
    
    debugPrint('✅ SurveillanceController disposed successfully');
  }
}