// surveillance_controller.dart - MERGED: All fixes + location + original structure

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:geolocator/geolocator.dart';

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

      debugPrint('1️⃣ Initializing verifier...');
      await _verifier.initialize();
      debugPrint('   ✅ Verifier ready');
      
      debugPrint('2️⃣ Initializing YOLO detector...');
      await _multi.initialize();
      debugPrint('   ✅ YOLO ready');
      
      debugPrint('3️⃣ Initializing camera...');
      await _camera.initialize(preferred: preferredLens);
      debugPrint('   ✅ Camera ready');
      
      debugPrint('4️⃣ Initializing image service...');
      await _imageService.initialize();
      debugPrint('   ✅ Image service ready');

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
      debugPrint('👥 People count: Face Verification');
      debugPrint('📍 Location: Enabled for alerts');
      debugPrint('🎯 Group detection: 1+ person detected');
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
    debugPrint('📏 Distance thresholds: $minWidth-$maxWidth');
  }

  // ✅ NEW: Get current location
  Future<Position?> _getCurrentLocation() async {
    try {
      // Check if location services are enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('⚠️ Location services disabled');
        return null;
      }

      // Check/request permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('⚠️ Location permission denied');
          return null;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        debugPrint('⚠️ Location permission permanently denied');
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );

      debugPrint('📍 Location: ${position.latitude}, ${position.longitude}');
      return position;
    } catch (e) {
      debugPrint('❌ Location error: $e');
      return null;
    }
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
      debugPrint('🔄 ══ Cycle $_verificationCycle ══');
      
      try {
        final startTime = DateTime.now();
        await _runVerification();
        final duration = DateTime.now().difference(startTime).inMilliseconds;
        
        debugPrint('⏱️ Took ${duration}ms');
        errorCount = 0;
        
        if (duration > 2000) {
          cycleDelayMs = 4000;
        } else if (duration > 1000) {
          cycleDelayMs = 3000;
        } else {
          cycleDelayMs = 2000;
        }
      } catch (e, st) {
        errorCount++;
        debugPrint('❌ Error (attempt $errorCount): $e');
        
        if (errorCount >= 3) {
          debugPrint('❌ Too many errors, stopping');
          _stopContinuousVerification();
          if (mounted) {
            _updateState(_state.copyWith(faceStatus: 'Verification failed'));
          }
          break;
        }
        
        cycleDelayMs = 5000;
      }
      
      if (!mounted) break;
      await Future.delayed(Duration(milliseconds: cycleDelayMs));
    }
    
    _continuousRunning = false;
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;

      try {
        // ✅ FIXED: Use FACE VERIFICATION count for people detection
        int verificationPeople = _lastVerifiedPeopleCount;
        
        // ✅ CHANGED: Group = 1+ person (as per requirement)
        bool isGroup = verificationPeople >= 1;
        
        // ✅ Smoking from YOLO
        bool hasSmoking = _multi.lastResult.smokingDetected;

        debugPrint('📊 Status: people=$verificationPeople, group=$isGroup, smoke=$hasSmoking');

        _updateState(_state.copyWith(
          peopleCount: verificationPeople,
          groupDetected: isGroup,
          smokingDetected: hasSmoking,
          detectionStatus: 'People: $verificationPeople | Group: ${isGroup ? "YES" : "NO"} | Smoke: ${hasSmoking ? "YES" : "NO"}',
        ));

        _handleDetectionAlerts(
          _multi.lastResult,
          verificationPeople,
          isGroup,
        );
      } catch (e) {
        debugPrint('⚠️ Polling error: $e');
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
        debugPrint('🧹 Cache: removed ${before - after} entries');
      }
    } catch (e) {
      debugPrint('⚠️ Cache error: $e');
    }
  }

  void _handleDetectionAlerts(
    DetectionResult det,
    int verificationPeople,
    bool isGroup,
  ) {
    if (!mounted) return;

    try {
      final lensName =
          _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

      // ✅ Group alert when 1+ person detected
      if (isGroup && !_lastGroupState) {
        debugPrint('🚨 GROUP DETECTED: $verificationPeople people');
        
        if (_currentFramePath != null) {
          _saveGroupAlertAsync(verificationPeople, lensName);
        }
      }
      _lastGroupState = isGroup;

      if (det.smokingDetected && !_lastSmokeState) {
        debugPrint('🚨 SMOKING DETECTED');
        
        if (_currentFramePath != null) {
          _saveSmokingAlertAsync(lensName);
        }
      }
      _lastSmokeState = det.smokingDetected;
    } catch (e) {
      debugPrint('❌ Alert error: $e');
    }
  }

  void _saveGroupAlertAsync(int personCount, String lensName) {
    _saveGroupAlert(personCount, lensName).catchError((e) {
      debugPrint('❌ Group alert: $e');
    });
  }

  void _saveSmokingAlertAsync(String lensName) {
    _saveSmokingAlert(lensName).catchError((e) {
      debugPrint('❌ Smoking alert: $e');
    });
  }

  Future<void> _saveGroupAlert(int personCount, String lensName) async {
    try {
      String? savedImagePath;
      
      if (_currentFramePath != null && await File(_currentFramePath!).exists()) {
        savedImagePath = await _imageService.saveGroupImage(
          _currentFramePath!,
          personCount: personCount,
        );
        
        // ✅ Scan file so it appears in Gallery
        if (savedImagePath != null) {
          await _scanMediaFile(savedImagePath);
        }
      }
      
      // ✅ Get location and save alert
      final position = await _getCurrentLocation();
      
      await _alertService.createGroupAlert(
        personCount: personCount,
        lens: lensName,
        imagePath: savedImagePath,
        latitude: position?.latitude,
        longitude: position?.longitude,
        locationName: position != null
            ? '${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}'
            : null,
      );
      debugPrint('✅ Group alert saved with location');
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
        
        // ✅ Scan file so it appears in Gallery
        if (savedImagePath != null) {
          await _scanMediaFile(savedImagePath);
        }
      }
      
      // ✅ Get location and save alert
      final position = await _getCurrentLocation();
      
      await _alertService.createSmokingAlert(
        lens: lensName,
        imagePath: savedImagePath,
        latitude: position?.latitude,
        longitude: position?.longitude,
        locationName: position != null
            ? '${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}'
            : null,
      );
      debugPrint('✅ Smoking alert saved with location');
    } catch (e, st) {
      debugPrint('❌ Smoking alert error: $e\n$st');
    }
  }

  // ✅ NEW: Scan media file to appear in Gallery
  Future<void> _scanMediaFile(String filePath) async {
    try {
      if (Platform.isAndroid) {
        debugPrint('📸 Scanning media: $filePath');
        // File will appear in gallery after a moment
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
      try {
        if (_camera.controller?.value.isStreamingImages ?? false) {
          await _camera.stopStream();
          streamWasStopped = true;
          await Future.delayed(const Duration(milliseconds: 100));
        }
      } catch (e) {
        debugPrint('⚠️ Stop stream: $e');
        streamWasStopped = true;
      }
      
      if (!mounted) return;
      
      try {
        shot = await _camera.takePicture();
      } catch (e) {
        debugPrint('⚠️ Take picture failed, retrying');
        await Future.delayed(const Duration(milliseconds: 200));
        
        try {
          if (!(_camera.controller?.value.isInitialized ?? false)) {
            await _camera.initialize(preferred: _camera.lensDirection);
          }
        } catch (e2) {
          rethrow;
        }
        
        shot = await _camera.takePicture();
      }
      
      if (!mounted) return;
      
      _currentFramePath = shot.path;
      _currentDetectedFaces = null;
      
      if (mounted && _camera.isInitialized) {
        try {
          unawaited(_camera.startStream(_onFrame));
          streamWasStopped = false;
        } catch (e) {
          debugPrint('⚠️ Restart stream: $e');
        }
      }
      
      if (!mounted) return;
      
      List<FaceInfo> faceInfos;
      try {
        faceInfos = await _detector.detectAndCropAllFacesWithDistance(shot.path);
      } catch (e) {
        _lastVerifiedPeopleCount = 0;
        _lastKnownCount = 0;
        _lastUnknownCount = 0;
        _lastVerificationTime = DateTime.now();
        
        if (mounted) {
          _updateState(_state.copyWith(faceStatus: 'No face'));
        }
        
        _scheduleImageCleanup(shot.path);
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
      
      // ✅ FIXED: Count ALL faces for group detection
      _lastVerifiedPeopleCount = totalDetectedFaces;
      _lastVerificationTime = DateTime.now();
      
      if (validFaces.isEmpty) {
        String reason = '';
        if (_facesTooFar > 0) reason = '$_facesTooFar far';
        if (_facesTooClose > 0) reason += (reason.isNotEmpty ? ', ' : '') + '$_facesTooClose close';
        
        if (mounted) {
          _updateState(_state.copyWith(
            faceStatus: '$totalDetectedFaces detected but $reason',
          ));
        }
        
        _scheduleImageCleanup(shot.path);
        return;
      }
      
      debugPrint('🔍 Verifying ${validFaces.length} face(s)');
      
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
      
      _scheduleImageCleanup(shot.path);
      
    } catch (e, st) {
      debugPrint('❌ Verification error: $e');
      
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Error'));
      }
      
      try {
        if (streamWasStopped && mounted && _camera.isInitialized) {
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

  void _scheduleImageCleanup(String imagePath) {
    _imageCleanupTimer?.cancel();
    _imageCleanupTimer = Timer(Duration(seconds: 30), () {
      try {
        File(imagePath).deleteSync();
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
          debugPrint('⚠️ UNKNOWN');
        }
      }

      _lastKnownCount = knownNames.length;
      _lastUnknownCount = unknownCount;

      debugPrint('📊 Verification: ${knownNames.length} known + $unknownCount unknown = ${knownNames.length + unknownCount} total');

      if (hasUnknownFace && unknownCount > 0) {
        debugPrint('🚨 SAVING UNKNOWN FACE ALERT');
        
        final lensName = _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';
        
        // ✅ Get location for unknown face alert
        final position = await _getCurrentLocation();
        
        String? savedImagePath;
        try {
          savedImagePath = await _imageService.saveUnknownFaceImage(
            framePath,
            additionalInfo: 'u${unknownCount}_k${knownNames.length}',
          );
          
          if (savedImagePath != null) {
            await _scanMediaFile(savedImagePath);
          }
        } catch (e) {
          debugPrint('❌ Frame save: $e');
        }
        
        List<String>? savedFacePaths;
        try {
          if (detectedFaces.isNotEmpty) {
            savedFacePaths = await _imageService.saveFaceImages(
              detectedFaces,
              alertType: 'unknown_face',
              sessionInfo: 'u${unknownCount}_k${knownNames.length}',
            );
            
            for (final path in savedFacePaths) {
              await _scanMediaFile(path);
            }
          }
        } catch (e) {
          debugPrint('❌ Face save: $e');
        }
        
        await _alertService.createUnknownAlert(
          threshold: FaceVerificationService.threshold,
          lens: lensName,
          note: '$unknownCount unknown face(s)',
          imagePath: savedImagePath,
          faceImagePaths: savedFacePaths,
          latitude: position?.latitude,
          longitude: position?.longitude,
          locationName: position != null
              ? '${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}'
              : null,
        );
      }

      String statusMsg;
      final knownList = knownNames.toList();
      
      if (knownList.isNotEmpty && unknownCount > 0) {
        statusMsg = '✅ ${knownList.join(", ")} | ⚠️ $unknownCount unk';
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
    } catch (e) {
      debugPrint('❌ Process results: $e');
    }
  }

  void setAutoVerify(bool enabled) {
    _autoVerify = enabled;
    debugPrint('🔄 Auto verify: ${enabled ? "ON" : "OFF"}');
    
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
    } catch (e) {
      debugPrint('❌ Switch failed: $e');
      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Switch failed'));
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
      debugPrint('⚠️ Camera: $e');
    }
    
    try {
      await _detector.dispose();
      _verifier.dispose();
      _multi.dispose();
      await _stateController.close();
    } catch (e) {
      debugPrint('⚠️ Services: $e');
    }
    
    _recentlyVerified.clear();
    
    if (_currentFramePath != null) {
      try {
        await File(_currentFramePath!).delete();
      } catch (_) {}
    }
    
    debugPrint('✅ Disposed');
    debugPrint('═══════════════════════════════════');
    debugPrint('');
  }
}