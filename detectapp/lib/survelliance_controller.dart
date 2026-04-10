// surveillance_controller.dart - CONTINUOUS VERIFICATION ON EVERY CAPTURE

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
import 'package:geolocator/geolocator.dart';

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

  bool _processingVerification = false;
  bool _continuousRunning = false;

  final Map<String, DateTime> _recentlyVerified = {};
  final Duration _verificationCacheDuration = Duration(seconds: 30);

  int _lastVerifiedFaceCount = 0;
  int _lastKnownCount = 0;
  int _lastUnknownCount = 0;
  DateTime _lastVerificationTime = DateTime.fromMillisecondsSinceEpoch(0);

  int _facesTooFar = 0;
  int _facesTooClose = 0;
  int _verificationCycle = 0;

  String? _lastCapturedImagePath;

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
      debugPrint(
          '📏 Distance range: ${_detector.minFaceWidth}-${_detector.maxFaceWidth}px');
      debugPrint('🔄 Auto-verify: $_autoVerify');

      // ✅ START CONTINUOUS VERIFICATION LOOP
      if (_autoVerify) {
        _startContinuousVerification();
      }
    } catch (e) {
      _updateState(_state.copyWith(
        isBooting: false,
        faceStatus: 'Initialization failed: $e',
      ));
      debugPrint('❌ SurveillanceController init failed: $e');
    }
  }

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

  // ✅ CONTINUOUS LOOP: Capture → Detect → Verify → Repeat
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
    while (_continuousRunning && mounted && _autoVerify) {
      _verificationCycle++;

      debugPrint('');
      debugPrint('🔄 ══ Cycle $_verificationCycle ══');

      await _runVerification();

      // ✅ Small delay between cycles to prevent overload
      await Future.delayed(const Duration(milliseconds: 500));
    }

    _continuousRunning = false;
    debugPrint('⏹️ Continuous loop ended');
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;

      final det = _multi.lastResult;
      int yoloPeople = det.personCount;

      final timeSinceVerification =
          DateTime.now().difference(_lastVerificationTime);
      final hasRecentVerification = timeSinceVerification.inSeconds < 10;

      int totalPeople = yoloPeople;
      String peopleBreakdown = '';

      if (hasRecentVerification && _lastVerifiedFaceCount > 0) {
        totalPeople = max(yoloPeople, _lastVerifiedFaceCount);

        if (_lastKnownCount > 0 || _lastUnknownCount > 0) {
          peopleBreakdown =
              ' (${_lastKnownCount} known, ${_lastUnknownCount} unknown';

          if (yoloPeople > _lastVerifiedFaceCount) {
            peopleBreakdown +=
                ', ${yoloPeople - _lastVerifiedFaceCount} unverified';
          }

          peopleBreakdown += ')';
        }
      } else if (yoloPeople > 0) {
        peopleBreakdown = ' (YOLO)';
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
    _recentlyVerified.removeWhere(
        (name, time) => now.difference(time) > _verificationCacheDuration);
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

    if (isGroup && !_lastGroupState) {
      debugPrint('🚨 GROUP DETECTED: $totalPeople people');

      String? savedImagePath;
      if (_lastCapturedImagePath != null) {
        savedImagePath = await _imageService.saveGroupImage(
          _lastCapturedImagePath!,
          personCount: totalPeople,
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

  // ✅ Just send frames to YOLO in background
  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized || !mounted) return;
    _multi.detectAllAsync(image);
  }

  // ✅ CORE: Capture → Detect Face → Verify → Return
  Future<void> _runVerification() async {
    if (_processingVerification || !mounted) return;

    _processingVerification = true;

    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Scanning...',
    ));

    XFile? shot;

    try {
      // Step 1: Stop stream and capture
      if (_camera.controller?.value.isStreamingImages ?? false) {
        await _camera.stopStream();
        await Future.delayed(const Duration(milliseconds: 50));
      }

      shot = await _camera.takePicture();

      // Step 2: Backup image
      final backupPath = '${shot.path}_backup.jpg';
      await File(shot.path).copy(backupPath);
      _lastCapturedImagePath = backupPath;

      // Step 3: Restart stream immediately
      if (mounted && _camera.isInitialized) {
        unawaited(_camera.startStream(_onFrame));
      }

      // Step 4: Detect faces
      List<FaceInfo> faceInfos;
      try {
        faceInfos =
            await _detector.detectAndCropAllFacesWithDistance(shot.path);
      } catch (e) {
        // No face found - this is normal when nobody is in frame
        _lastVerifiedFaceCount = 0;
        _lastKnownCount = 0;
        _lastUnknownCount = 0;
        _lastVerificationTime = DateTime.now();

        if (mounted) {
          _updateState(_state.copyWith(faceStatus: 'No face in frame'));
        }

        _cleanupImage(shot.path);
        return;
      }

      debugPrint(
          '👤 Found ${faceInfos.length} face(s) in cycle $_verificationCycle');

      // Step 5: Filter by distance
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
        String reason = 'No faces in valid range';
        if (_facesTooFar > 0) reason = '$_facesTooFar too far';
        if (_facesTooClose > 0) reason = '$_facesTooClose too close';

        if (mounted) {
          _updateState(_state.copyWith(faceStatus: reason));
        }

        _cleanupImage(shot.path);
        return;
      }

      // Step 6: Verify faces
      debugPrint('🔍 Verifying ${validFaces.length} face(s)...');

      final results = _verifier.verifyMultipleFaces(validFaces);

      // Step 7: Process results
      if (mounted) {
        await _processVerificationResults(
          results,
          validFaces.length,
          faceInfos.length,
          backupPath,
          validFaces,
        );
      }

      // Cleanup original (keep backup longer for alerts)
      _scheduleImageCleanup(shot.path, Duration(seconds: 3));
    } catch (e) {
      debugPrint('⚠️ Verification error: $e');

      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Error: $e'));
      }

      // Ensure stream is restarted
      try {
        if (mounted &&
            _camera.isInitialized &&
            !(_camera.controller?.value.isStreamingImages ?? false)) {
          await _camera.startStream(_onFrame);
        }
      } catch (e) {
        debugPrint('❌ Stream restart failed: $e');
      }
    } finally {
      if (mounted) {
        _processingVerification = false;
        _updateState(_state.copyWith(processingFace: false));
      }
    }
  }

  void _cleanupImage(String imagePath) {
    Future.delayed(Duration(seconds: 1), () {
      try {
        File(imagePath).delete();
        File('${imagePath}_backup.jpg').delete();
      } catch (_) {}
    });
  }

  void _scheduleImageCleanup(String imagePath, Duration delay) {
    Future.delayed(delay, () {
      try {
        File(imagePath).delete();
        File('${imagePath}_backup.jpg').delete();
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
    int knownCount = 0;
    int unknownCount = 0;
    final knownNames = <String>[];

    for (final result in results) {
      if (result.verified && result.person != null) {
        final name = result.person!.name;

        final lastVerified = _recentlyVerified[name];
        final isRecent = lastVerified != null &&
            DateTime.now().difference(lastVerified) <
                _verificationCacheDuration;

        if (!isRecent) {
          debugPrint('✅ KNOWN: $name');
        }

        _recentlyVerified[name] = DateTime.now();

        knownCount++;
        if (!knownNames.contains(name)) {
          knownNames.add(name);
        }
      } else {
        unknownCount++;
        debugPrint('⚠️ UNKNOWN face detected!');
      }
    }

    _lastVerifiedFaceCount = verifiedFaceCount;
    _lastKnownCount = knownCount;
    _lastUnknownCount = unknownCount;
    _lastVerificationTime = DateTime.now();

    debugPrint(
        '📊 Cycle $_verificationCycle: $knownCount known, $unknownCount unknown');

    if (unknownCount > 0) {
      final lensName =
          _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';
      final savedImagePath = _lastCapturedImagePath;
      final position = await _getCurrentLocation();

      List<String>? savedFacePaths;
      try {
        savedFacePaths = await _imageService.saveFaceImages(
          detectedFaces,
          alertType: 'unknown_face',
          sessionInfo: 'u${unknownCount}_k${knownCount}',
        );
        debugPrint('✅ Saved ${savedFacePaths.length} face crops');
      } catch (e) {
        debugPrint('❌ Face save failed: $e');
      }

      await _alertService.createUnknownAlert(
        threshold: FaceVerificationService.threshold,
        lens: lensName,
        note: '$unknownCount unknown face(s) detected',
        imagePath: savedImagePath,
        faceImagePaths: savedFacePaths,
        latitude: position?.latitude,
        longitude: position?.longitude,
        locationName: position != null
            ? '${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}'
            : null,
      );
    }

    // ✅ Update UI
    String statusMsg;
    if (knownCount > 0 && unknownCount > 0) {
      statusMsg = '✅ ${knownNames.join(", ")} | ⚠️ $unknownCount unknown';
    } else if (knownCount > 0) {
      statusMsg = '✅ ${knownNames.join(", ")}';
    } else if (unknownCount > 0) {
      statusMsg = '⚠️ $unknownCount unknown';
    } else {
      statusMsg = 'Scanning...';
    }

    if (mounted) {
      _updateState(_state.copyWith(
        faceStatus: statusMsg,
        lastMatch: knownNames.isNotEmpty ? knownNames.join(', ') : '',
      ));
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

      _lastVerifiedFaceCount = 0;
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

    _stopContinuousVerification();
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

    if (_lastCapturedImagePath != null) {
      try {
        await File(_lastCapturedImagePath!).delete();
      } catch (_) {}
    }

    debugPrint('✅ SurveillanceController disposed');
  }
}
