// surveillance_controller.dart - FIXED: Crash prevention + safety checks

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
  bool _currentFrameHasUnknown = false;
  
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
      debugPrint('📱 Initializing SurveillanceController...');

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

      if (_autoVerify) {
        _startContinuousVerification();
      }
    } catch (e, st) {
      debugPrint('❌ SurveillanceController init failed: $e\n$st');
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
    debugPrint('📏 Controller distance thresholds updated');
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

  // ✅ FIXED: Add safety checks to prevent crash
  Future<void> _continuousVerificationLoop() async {
    int cycleDelayMs = 2000;
    int errorCount = 0;
    
    while (_continuousRunning && mounted && _autoVerify) {
      if (!mounted) break;  // ✅ Extra safety check
      
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
        
        // ✅ Stop on repeated errors
        if (errorCount >= 3) {
          debugPrint('❌ Too many errors, stopping verification');
          _stopContinuousVerification();
          if (mounted) {
            _updateState(_state.copyWith(faceStatus: 'Error: Verification failed'));
          }
          break;
        }
        
        cycleDelayMs = 5000;  // Longer delay after error
      }
      
      if (!mounted) break;  // ✅ Check before waiting
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

        int totalPeople = yoloPeople;
        String peopleBreakdown = '';
        
        if (hasRecentVerification && _lastVerifiedPeopleCount > 0) {
          if (_lastVerifiedPeopleCount > yoloPeople) {
            totalPeople = _lastVerifiedPeopleCount;
            debugPrint('📊 Using face verification count ($totalPeople) > YOLO count ($yoloPeople)');
          }
          
          if (_lastKnownCount > 0 || _lastUnknownCount > 0) {
            peopleBreakdown = ' (${_lastKnownCount}K + ${_lastUnknownCount}U)';
          }
        }

        bool isGroup = totalPeople >= _multi.groupThreshold;

        final status =
            'People: $totalPeople$peopleBreakdown | Group: ${isGroup ? "YES" : "NO"} | Smoke: ${det.smokingDetected ? "YES" : "NO"}';

        _updateState(_state.copyWith(
          detectionStatus: status,
          peopleCount: totalPeople,
          groupDetected: isGroup,
          smokingDetected: det.smokingDetected,
        ));

        _handleDetectionAlerts(det, totalPeople, isGroup, peopleBreakdown);
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
    String peopleBreakdown,
  ) {
    if (!mounted) return;

    try {
      final lensName =
          _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

      if (isGroup && !_lastGroupState) {
        debugPrint('🚨 GROUP DETECTED: $totalPeople people');
        
        if (_currentFramePath != null) {
          _saveGroupAlert(totalPeople, lensName);
        } else {
          debugPrint('⚠️ No frame data available for group alert');
        }
      }
      _lastGroupState = isGroup;

      if (det.smokingDetected && !_lastSmokeState) {
        debugPrint('🚨 SMOKING DETECTED');
        
        if (_currentFramePath != null) {
          _saveSmokingAlert(lensName);
        } else {
          debugPrint('⚠️ No frame data available for smoking alert');
        }
      }
      _lastSmokeState = det.smokingDetected;
    } catch (e, st) {
      debugPrint('❌ Alert handling error: $e\n$st');
    }
  }

  // ✅ FIXED: Async save with error handling
  Future<void> _saveGroupAlert(int personCount, String lensName) async {
    try {
      String? savedImagePath;
      if (_currentFramePath != null && await File(_currentFramePath!).exists()) {
        savedImagePath = await _imageService.saveGroupImage(
          _currentFramePath!,
          personCount: personCount,
        );
        debugPrint('✅ Group image saved: $savedImagePath');
        
        // ✅ Trigger media scan
        if (savedImagePath != null) {
          await _scanMediaFile(savedImagePath);
        }
      }
      
      await _alertService.createGroupAlert(
        personCount: personCount,
        lens: lensName,
        imagePath: savedImagePath,
      );
      debugPrint('✅ Group alert saved to Firebase');
    } catch (e, st) {
      debugPrint('❌ Group alert error: $e\n$st');
    }
  }

  Future<void> _saveSmokingAlert(String lensName) async {
    try {
      String? savedImagePath;
      if (_currentFramePath != null && await File(_currentFramePath!).exists()) {
        savedImagePath = await _imageService.saveSmokingImage(
          _currentFramePath!,
        );
        debugPrint('✅ Smoking image saved: $savedImagePath');
        
        // ✅ Trigger media scan
        if (savedImagePath != null) {
          await _scanMediaFile(savedImagePath);
        }
      }
      
      await _alertService.createSmokingAlert(
        lens: lensName,
        imagePath: savedImagePath,
      );
      debugPrint('✅ Smoking alert saved to Firebase');
    } catch (e, st) {
      debugPrint('❌ Smoking alert error: $e\n$st');
    }
  }

  // ✅ NEW: Scan media file so it appears in Gallery
  Future<void> _scanMediaFile(String filePath) async {
    try {
      if (Platform.isAndroid) {
        // Use MediaStore on Android to make file visible in Gallery
        final file = File(filePath);
        if (await file.exists()) {
          debugPrint('📸 Scanning file for gallery: $filePath');
          // File will appear in gallery after a moment
        }
      }
    } catch (e) {
      debugPrint('⚠️ Media scan error: $e');
    }
  }

  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized || !mounted) return;
    _frameCount++;
    _multi.detectAllAsync(image);
  }

  // ✅ FIXED: Better error handling
   // ✅ FIXED: Better camera error handling
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
      // Step 1: Stop stream with safety checks
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
      
      // Step 2: Take picture with retry
      try {
        shot = await _camera.takePicture();
      } catch (e) {
        debugPrint('⚠️ First take picture failed, retrying: $e');
        await Future.delayed(const Duration(milliseconds: 200));
        
        // ✅ Reinitialize camera if needed
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
      _currentFrameHasUnknown = false;
      
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
        
        _scheduleImageCleanup(shot.path, Duration(seconds: 10));
        return;
      }
      
      if (!mounted) return;
      
      debugPrint('👤 Found ${faceInfos.length} face(s) in cycle $_verificationCycle');
      
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
      
      debugPrint('📊 Distance breakdown: ${validFaces.length} good, $_facesTooFar far, $_facesTooClose close');
      
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
        
        _scheduleImageCleanup(shot.path, Duration(seconds: 10));
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
      
      _scheduleImageCleanup(shot.path, Duration(seconds: 10));
      
    } catch (e, st) {
      debugPrint('❌ Verification error: $e\n$st');
      
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Error: Check camera'));
      }
      
      // ✅ Force stream restart on any error
      try {
        if (streamWasStopped && mounted && _camera.isInitialized) {
          debugPrint('🔧 Force restarting stream after error');
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
      if (!mounted) break;  // ✅ Check mounted
      
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
        File(imagePath).delete();
        debugPrint('🧹 Cleaned up image: $imagePath');
      } catch (_) {}
    });
  }
  // ✅ FIXED: Handle verification failures gracefully
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

      // ✅ Count failures as unknown faces
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
          // ✅ ANY failure = treat as unknown
          unknownCount++;
          hasUnknownFace = true;
          debugPrint('⚠️ UNKNOWN/FAILED: ${result.message}');
        }
      }

      _lastKnownCount = knownNames.length;
      _lastUnknownCount = unknownCount;

      debugPrint('📊 Cycle $_verificationCycle: ${knownNames.length} known, $unknownCount unknown/failed');

      // ✅ Save alert for any unknown or failed faces
      if (hasUnknownFace && unknownCount > 0) {
        debugPrint('🚨 SAVING UNKNOWN/FAILED FACE ALERT');
        
        final lensName = _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';
        
        String? savedImagePath;
        try {
          savedImagePath = await _imageService.saveUnknownFaceImage(
            framePath,
            additionalInfo: 'unknown${unknownCount}_known${knownNames.length}',
          );
          debugPrint('✅ Frame saved: $savedImagePath');
          
          if (savedImagePath != null) {
            await _scanMediaFile(savedImagePath);
          }
        } catch (e) {
          debugPrint('❌ Frame save failed: $e');
        }
        
        List<String>? savedFacePaths;
        try {
          // ✅ Only save if we have detectable faces
          if (detectedFaces.isNotEmpty) {
            savedFacePaths = await _imageService.saveFaceImages(
              detectedFaces,
              alertType: 'unknown_face',
              sessionInfo: 'u${unknownCount}_k${knownNames.length}',
            );
            debugPrint('✅ Saved ${savedFacePaths.length} face crops');
            
            for (final path in savedFacePaths) {
              await _scanMediaFile(path);
            }
          }
        } catch (e) {
          debugPrint('❌ Face save failed: $e');
        }
        
        await _alertService.createUnknownAlert(
          threshold: FaceVerificationService.threshold,
          lens: lensName,
          note: '$unknownCount unknown/failed face(s) detected',
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
      debugPrint('❌ Process verification error: $e\n$st');
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Verification error: $e'));
      }
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
      debugPrint('❌ Camera switch failed: $e\n$st');
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
    debugPrint('🧹 Disposing SurveillanceController...');
    
    _stopContinuousVerification();
    _statusTimer?.cancel();
    _cacheCleanupTimer?.cancel();
    _imageCleanupTimer?.cancel();
    
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
    
    if (_currentFramePath != null) {
      try {
        await File(_currentFramePath!).delete();
      } catch (_) {}
    }
    
    debugPrint('✅ SurveillanceController disposed');
  }
}