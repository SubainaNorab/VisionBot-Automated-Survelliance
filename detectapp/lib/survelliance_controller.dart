// surveillance_controller.dart - COMPLETE: Fixed group detection + image saving

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
  Timer? _statusTimer;
  Timer? _cacheCleanupTimer;

  bool _lastGroupState = false;
  bool _lastSmokeState = false;

  int _frameCount = 0;

  bool _processingVerification = false;
  bool _continuousRunning = false;

  final Map<String, DateTime> _recentlyVerified = {};
  final Duration _verificationCacheDuration = Duration(seconds: 30);

  int _lastVerifiedPeopleCount = 0;
  int _lastKnownCount = 0;
  int _lastUnknownCount = 0;
  DateTime _lastVerificationTime = DateTime.fromMillisecondsSinceEpoch(0);

  int _facesTooFar = 0;
  int _facesTooClose = 0;
  int _verificationCycle = 0;

  String? _currentFramePath;
  List<img.Image>? _currentDetectedFaces;
  
  Timer? _imageCleanupTimer;

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
      debugPrint('');
      debugPrint('═══════════════════════════════════');
      debugPrint('📱 Initializing SurveillanceController');
      debugPrint('═══════════════════════════════════');

      await Future.wait([
        _verifier.initialize(),
        _multi.initialize(),
        _camera.initialize(preferred: preferredLens),
        _imageService.initialize(),
      ]);

      debugPrint('✅ All services initialized');

      await _camera.startStream(_onFrame);
      debugPrint('✅ Camera stream started');

      _startStatusPolling();
      _startCacheCleanup();

      _updateState(_state.copyWith(
        isBooting: false,
        faceStatus: 'Ready - Auto-verify ON',
      ));

      debugPrint('✅ SurveillanceController initialized');
      debugPrint('📁 Alert images path: ${_imageService.storagePath}');
      debugPrint('📏 Distance range: ${_detector.minFaceWidth}-${_detector.maxFaceWidth}px');
      debugPrint('🔄 Auto-verify: $_autoVerify');
      debugPrint('═══════════════════════════════════');
      debugPrint('');

      if (_autoVerify) {
        _startContinuousVerification();
      }
    } catch (e, st) {
      debugPrint('❌ Init failed: $e');
      debugPrint('   Stack: $st');
      _updateState(_state.copyWith(
        isBooting: false,
        faceStatus: 'Initialization failed: $e',
      ));
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
    debugPrint('📏 Distance thresholds updated: $minWidth-$maxWidth');
  }

  void _startContinuousVerification() {
    if (_continuousRunning) return;
    _continuousRunning = true;
    debugPrint('🔄 CONTINUOUS VERIFICATION STARTED');
    _continuousVerificationLoop();
  }

  void _stopContinuousVerification() {
    _continuousRunning = false;
    debugPrint('⏹️ CONTINUOUS VERIFICATION STOPPED');
  }

  Future<void> _continuousVerificationLoop() async {
    int cycleDelayMs = 2000;
    int errorCount = 0;
    
    while (_continuousRunning && mounted && _autoVerify) {
      if (!mounted) break;
      
      _verificationCycle++;
      
      debugPrint('');
      debugPrint('🔄 ══ Cycle $_verificationCycle (delay: ${cycleDelayMs}ms) ══');
      
      try {
        final startTime = DateTime.now();
        await _runVerification();
        final duration = DateTime.now().difference(startTime).inMilliseconds;
        
        debugPrint('⏱️ Verification took ${duration}ms');
        errorCount = 0;  // ✅ Reset error count on success
        
        if (duration > 2000) {
          cycleDelayMs = 4000;
          debugPrint('⚠️ Slow verification, increasing delay to 4s');
        } else if (duration > 1000) {
          cycleDelayMs = 3000;
          debugPrint('⚠️ Medium speed, using 3s delay');
        } else {
          cycleDelayMs = 2000;
        }
      } catch (e, st) {
        errorCount++;
        debugPrint('❌ Verification error (attempt $errorCount): $e');
        debugPrint('   Stack: $st');
        
        if (errorCount >= 3) {
          debugPrint('❌ Too many errors, stopping verification');
          _stopContinuousVerification();
          if (mounted) {
            _updateState(_state.copyWith(faceStatus: 'Error: Verification failed'));
          }
          break;
        }
        
        cycleDelayMs = 5000;
      }
      
      if (!mounted) break;
      await Future.delayed(Duration(milliseconds: cycleDelayMs));
    }
    
    _continuousRunning = false;
    debugPrint('⏹️ Continuous loop ended');
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;

      try {
        final det = _multi.lastResult;
        int yoloPeople = det.personCount;
        
        final timeSinceVerification = DateTime.now().difference(_lastVerificationTime);
        final hasRecentVerification = timeSinceVerification.inSeconds < 10;

        // ✅ FIXED: Use YOLO for group detection, not face verification
        int totalPeople = yoloPeople;
        String peopleBreakdown = '';
        
        if (hasRecentVerification && _lastVerifiedPeopleCount > 0) {
          // If face verification found MORE people, use that (YOLO might miss some)
          if (_lastVerifiedPeopleCount > yoloPeople) {
            totalPeople = _lastVerifiedPeopleCount;
          }
          
          // Show breakdown
          if (_lastKnownCount > 0 || _lastUnknownCount > 0) {
            peopleBreakdown = ' (${_lastKnownCount}K + ${_lastUnknownCount}U)';
          }
        }

        // ✅ Group detection based on total people (YOLO + verified)
        bool isGroup = totalPeople >= _multi.groupThreshold;

        final status =
            'People: $totalPeople$peopleBreakdown | Group: ${isGroup ? "YES" : "NO"} | Smoke: ${det.smokingDetected ? "YES" : "NO"}';

        _updateState(_state.copyWith(
          detectionStatus: status,
          peopleCount: totalPeople,
          groupDetected: isGroup,
          smokingDetected: det.smokingDetected,
        ));

        _handleDetectionAlerts(det, totalPeople, isGroup);
      } catch (e) {
        debugPrint('⚠️ Status polling error: $e');
      }
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
    try {
      final now = DateTime.now();
      final before = _recentlyVerified.length;
      _recentlyVerified.removeWhere((name, time) => 
        now.difference(time) > _verificationCacheDuration
      );
      final after = _recentlyVerified.length;
      if (before != after) {
        debugPrint('🧹 Cache cleanup: removed ${before - after} entries');
      }
    } catch (e) {
      debugPrint('⚠️ Cache cleanup error: $e');
    }
  }

  void _handleDetectionAlerts(
    DetectionResult det,
    int totalPeople,
    bool isGroup,
  ) {
    if (!mounted) return;

    try {
      final lensName =
          _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

      if (isGroup && !_lastGroupState) {
        debugPrint('🚨 GROUP DETECTED: $totalPeople people');
        
        if (_currentFramePath != null) {
          // ✅ Fire async save in background, don't wait
          _saveGroupAlertAsync(totalPeople, lensName);
        } else {
          debugPrint('⚠️ No frame available for group alert');
        }
      }
      _lastGroupState = isGroup;

      if (det.smokingDetected && !_lastSmokeState) {
        debugPrint('🚨 SMOKING DETECTED');
        
        if (_currentFramePath != null) {
          // ✅ Fire async save in background, don't wait
          _saveSmokingAlertAsync(lensName);
        } else {
          debugPrint('⚠️ No frame available for smoking alert');
        }
      }
      _lastSmokeState = det.smokingDetected;
    } catch (e, st) {
      debugPrint('❌ Alert handling error: $e');
      debugPrint('   Stack: $st');
    }
  }

  // ✅ NEW: Background async save for group alert
  void _saveGroupAlertAsync(int personCount, String lensName) {
    // Fire and forget - save in background
    _saveGroupAlert(personCount, lensName).then((_) {
      debugPrint('✅ Group alert completed');
    }).catchError((e) {
      debugPrint('❌ Group alert error: $e');
    });
  }

  // ✅ NEW: Background async save for smoking alert
  void _saveSmokingAlertAsync(String lensName) {
    // Fire and forget - save in background
    _saveSmokingAlert(lensName).then((_) {
      debugPrint('✅ Smoking alert completed');
    }).catchError((e) {
      debugPrint('❌ Smoking alert error: $e');
    });
  }

  // ✅ FIXED: Proper group alert save
  Future<void> _saveGroupAlert(int personCount, String lensName) async {
    try {
      String? savedImagePath;
      
      if (_currentFramePath != null && await File(_currentFramePath!).exists()) {
        debugPrint('💾 Saving group image...');
        savedImagePath = await _imageService.saveGroupImage(
          _currentFramePath!,
          personCount: personCount,
        );
        
        if (savedImagePath != null) {
          debugPrint('✅ Group image saved: $savedImagePath');
        } else {
          debugPrint('⚠️ Group image save returned null');
        }
      } else {
        debugPrint('⚠️ Frame not available for group image');
      }
      
      debugPrint('📤 Creating Firebase alert...');
      await _alertService.createGroupAlert(
        personCount: personCount,
        lens: lensName,
        imagePath: savedImagePath,
      );
      debugPrint('✅ Group alert saved to Firebase');
    } catch (e, st) {
      debugPrint('❌ Group alert error: $e');
      debugPrint('   Stack: $st');
    }
  }

  // ✅ FIXED: Proper smoking alert save
  Future<void> _saveSmokingAlert(String lensName) async {
    try {
      String? savedImagePath;
      
      if (_currentFramePath != null && await File(_currentFramePath!).exists()) {
        debugPrint('💾 Saving smoking image...');
        savedImagePath = await _imageService.saveSmokingImage(
          _currentFramePath!,
        );
        
        if (savedImagePath != null) {
          debugPrint('✅ Smoking image saved: $savedImagePath');
        } else {
          debugPrint('⚠️ Smoking image save returned null');
        }
      } else {
        debugPrint('⚠️ Frame not available for smoking image');
      }
      
      debugPrint('📤 Creating Firebase alert...');
      await _alertService.createSmokingAlert(
        lens: lensName,
        imagePath: savedImagePath,
      );
      debugPrint('✅ Smoking alert saved to Firebase');
    } catch (e, st) {
      debugPrint('❌ Smoking alert error: $e');
      debugPrint('   Stack: $st');
    }
  }

  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized || !mounted) return;
    _frameCount++;
    _multi.detectAllAsync(image);
  }

  Future<void> _runVerification() async {
    if (_processingVerification || !mounted) return;
    
    _processingVerification = true;
    
    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Scanning...',
    ));
    
    XFile? shot;
    bool streamWasStopped = false;
    
    try {
      // Step 1: Stop stream
      try {
        if (_camera.controller?.value.isStreamingImages ?? false) {
          await _camera.stopStream();
          streamWasStopped = true;
          await Future.delayed(const Duration(milliseconds: 100));
        }
      } catch (e) {
        debugPrint('⚠️ Stop stream error: $e');
        streamWasStopped = true;
      }
      
      if (!mounted) return;
      
      // Step 2: Take picture
      try {
        shot = await _camera.takePicture();
      } catch (e) {
        debugPrint('⚠️ First take picture failed, retrying: $e');
        await Future.delayed(const Duration(milliseconds: 200));
        
        try {
          if (!(_camera.controller?.value.isInitialized ?? false)) {
            debugPrint('🔧 Re-initializing camera...');
            await _camera.initialize(preferred: _camera.lensDirection);
          }
        } catch (e2) {
          debugPrint('❌ Camera re-init failed: $e2');
          rethrow;
        }
        
        shot = await _camera.takePicture();
      }
      
      if (!mounted) return;
      
      _currentFramePath = shot.path;
      _currentDetectedFaces = null;
      
      // Step 3: Restart stream ASAP
      if (mounted && _camera.isInitialized) {
        try {
          unawaited(_camera.startStream(_onFrame));
          streamWasStopped = false;
        } catch (e) {
          debugPrint('⚠️ Restart stream failed: $e');
        }
      }
      
      if (!mounted) return;
      
      // Step 4: Detect faces
      List<FaceInfo> faceInfos;
      try {
        faceInfos = await _detector.detectAndCropAllFacesWithDistance(shot.path);
      } catch (e) {
        _lastVerifiedPeopleCount = 0;
        _lastKnownCount = 0;
        _lastUnknownCount = 0;
        _lastVerificationTime = DateTime.now();
        
        if (mounted) {
          _updateState(_state.copyWith(faceStatus: 'No face detected'));
        }
        
        _scheduleImageCleanup(shot.path, Duration(seconds: 30));
        return;
      }
      
      if (!mounted) return;
      
      debugPrint('👤 Found ${faceInfos.length} face(s)');
      
      int totalDetectedFaces = faceInfos.length;
      
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
      
      debugPrint('📊 Distance: ${validFaces.length} good, $_facesTooFar far, $_facesTooClose close');
      
      // ✅ FIXED: Count ALL detected faces, not just verified ones
      _lastVerifiedPeopleCount = totalDetectedFaces;
      _lastVerificationTime = DateTime.now();
      
      if (validFaces.isEmpty) {
        String reason = '';
        if (_facesTooFar > 0) reason = '$_facesTooFar too far';
        if (_facesTooClose > 0) reason += (reason.isNotEmpty ? ', ' : '') + '$_facesTooClose too close';
        if (reason.isEmpty) reason = 'No faces in range';
        
        if (mounted) {
          _updateState(_state.copyWith(
            faceStatus: '$totalDetectedFaces detected but $reason',
          ));
        }
        
        _scheduleImageCleanup(shot.path, Duration(seconds: 30));
        return;
      }
      
      debugPrint('🔍 Verifying ${validFaces.length} face(s)...');
      
      _currentDetectedFaces = validFaces;
      final results = await _verifyFacesWithYield(validFaces);
      
      if (!mounted) return;
      
      await _processVerificationResults(
        results, 
        validFaces.length, 
        totalDetectedFaces,
        shot.path,
        validFaces,
      );
      
      _scheduleImageCleanup(shot.path, Duration(seconds: 30));
      
    } catch (e, st) {
      debugPrint('❌ Verification error: $e');
      debugPrint('   Stack: $st');
      
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Error: Check camera'));
      }
      
      try {
        if (streamWasStopped && mounted && _camera.isInitialized) {
          debugPrint('🔧 Force restarting stream');
          await _camera.startStream(_onFrame);
        }
      } catch (e) {
        debugPrint('❌ Force restart failed: $e');
      }
    } finally {
      if (mounted) {
        _processingVerification = false;
        _updateState(_state.copyWith(processingFace: false));
      }
    }
  }

  Future<List<VerificationResult>> _verifyFacesWithYield(
    List<img.Image> faces,
  ) async {
    final results = <VerificationResult>[];
    
    for (int i = 0; i < faces.length; i++) {
      if (!mounted) break;
      
      final result = _verifier.verifyFace(faces[i]);
      results.add(result);
      await Future.delayed(Duration.zero);
    }
    
    return results;
  }

  void _scheduleImageCleanup(String imagePath, Duration delay) {
    _imageCleanupTimer?.cancel();
    _imageCleanupTimer = Timer(delay, () {
      try {
        File(imagePath).deleteSync();
        debugPrint('🧹 Cleaned up: $imagePath');
      } catch (_) {}
    });
  }

  Future<void> _processVerificationResults(
    List<VerificationResult> results,
    int verifiedFaceCount,
    int totalDetectedFaces,
    String framePath,
    List<img.Image> detectedFaces,
  ) async {
    try {
      int knownCount = 0;
      int unknownCount = 0;
      final knownNames = <String>{};
      bool hasUnknownFace = false;

      for (final result in results) {
        if (result.verified && result.person != null) {
          final name = result.person!.name;
          
          final lastVerified = _recentlyVerified[name];
          final isRecent = lastVerified != null && 
              DateTime.now().difference(lastVerified) < _verificationCacheDuration;
          
          if (!isRecent) {
            debugPrint('✅ KNOWN: $name');
          }
          
          _recentlyVerified[name] = DateTime.now();
          knownNames.add(name);
        } else {
          unknownCount++;
          hasUnknownFace = true;
          debugPrint('⚠️ UNKNOWN: ${result.message}');
        }
      }

      _lastKnownCount = knownNames.length;
      _lastUnknownCount = unknownCount;

      debugPrint('📊 Result: ${knownNames.length} known, $unknownCount unknown');

      // ✅ FIXED: Save unknown alert if any unknown faces
      if (hasUnknownFace && unknownCount > 0) {
        debugPrint('🚨 SAVING UNKNOWN FACE ALERT');
        
        final lensName = _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';
        
        String? savedImagePath;
        try {
          savedImagePath = await _imageService.saveUnknownFaceImage(
            framePath,
            additionalInfo: 'unknown${unknownCount}_known${knownNames.length}',
          );
          debugPrint('✅ Frame saved: $savedImagePath');
        } catch (e) {
          debugPrint('❌ Frame save failed: $e');
        }
        
        List<String>? savedFacePaths;
        try {
          if (detectedFaces.isNotEmpty) {
            savedFacePaths = await _imageService.saveFaceImages(
              detectedFaces,
              alertType: 'unknown_face',
              sessionInfo: 'u${unknownCount}_k${knownNames.length}',
            );
            debugPrint('✅ Saved ${savedFacePaths.length} face crops');
          }
        } catch (e) {
          debugPrint('❌ Face save failed: $e');
        }
        
        await _alertService.createUnknownAlert(
          threshold: FaceVerificationService.threshold,
          lens: lensName,
          note: '$unknownCount unknown face(s)',
          imagePath: savedImagePath,
          faceImagePaths: savedFacePaths,
        );
      }

      String statusMsg;
      final knownList = knownNames.toList();
      
      if (knownList.isNotEmpty && unknownCount > 0) {
        statusMsg = '✅ ${knownList.join(", ")} | ⚠️ $unknownCount unknown';
      } else if (knownList.isNotEmpty) {
        statusMsg = '✅ ${knownList.join(", ")}';
      } else if (unknownCount > 0) {
        statusMsg = '⚠️ $unknownCount unknown';
      } else {
        statusMsg = 'Scanning...';
      }

      if (mounted) {
        _updateState(_state.copyWith(
          faceStatus: statusMsg,
          lastMatch: knownList.isNotEmpty ? knownList.join(', ') : '',
        ));
      }
    } catch (e, st) {
      debugPrint('❌ Process verification error: $e');
      debugPrint('   Stack: $st');
    }
  }

  void setAutoVerify(bool enabled) {
    _autoVerify = enabled;
    debugPrint('🔄 Auto verify ${enabled ? "enabled" : "disabled"}');
    
    if (enabled) {
      _startContinuousVerification();
    } else {
      _stopContinuousVerification();
    }
    
    if (mounted) {
      _updateState(_state.copyWith(
        faceStatus: enabled ? 'Auto-verify ON' : 'Auto-verify OFF',
      ));
    }
  }

  Future<void> verifyFace() async {
    debugPrint('🔘 Manual verify');
    await _runVerification();
  }

  Future<void> switchCamera() async {
    if (!mounted) return;

    try {
      _updateState(_state.copyWith(faceStatus: 'Switching...'));

      _stopContinuousVerification();

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
      
      _lastVerifiedPeopleCount = 0;
      _lastKnownCount = 0;
      _lastUnknownCount = 0;

      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Ready'));
        
        if (_autoVerify) {
          _startContinuousVerification();
        }
      }

      debugPrint('📷 Camera switched');
    } catch (e, st) {
      debugPrint('❌ Camera switch failed: $e');
      debugPrint('   Stack: $st');
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Switch failed: $e'));
      }
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
    debugPrint('');
    debugPrint('═══════════════════════════════════');
    debugPrint('🧹 Disposing SurveillanceController');
    debugPrint('═══════════════════════════════════');
    
    _stopContinuousVerification();
    _statusTimer?.cancel();
    _cacheCleanupTimer?.cancel();
    _imageCleanupTimer?.cancel();
    
    try {
      await _camera.stopStream();
      await _camera.dispose();
    } catch (e) {
      debugPrint('⚠️ Camera disposal: $e');
    }
    
    try {
      await _detector.dispose();
      _verifier.dispose();
      _multi.dispose();
      await _stateController.close();
    } catch (e) {
      debugPrint('⚠️ Services disposal: $e');
    }
    
    _recentlyVerified.clear();
    
    if (_currentFramePath != null) {
      try {
        await File(_currentFramePath!).delete();
      } catch (_) {}
    }
    
    debugPrint('✅ SurveillanceController disposed');
    debugPrint('═══════════════════════════════════');
    debugPrint('');
  }
}