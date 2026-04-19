// surveillance_controller.dart - FIXED: Use face verification for people count

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'camera.dart';
import 'face_Detector.dart';
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
    this.detectionStatus = 'Initializing...',
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

  bool _processingVerification = false;
  bool _continuousRunning = false;

  final Map<String, DateTime> _recentlyVerified = {};
  static const Duration _verificationCacheDuration = Duration(seconds: 30);

  int _lastVerifiedPeopleCount = 0;
  int _lastKnownCount = 0;
  int _lastUnknownCount = 0;
  DateTime _lastVerificationTime = DateTime.fromMillisecondsSinceEpoch(0);

  int _facesTooFar = 0;
  int _facesTooClose = 0;
  int _verificationCycle = 0;
  Timer? _imageCleanupTimer;

  String? _lastCapturedImagePath;
  String? get _currentFramePath => _lastCapturedImagePath;

  Position? _locationCache;
  DateTime? _locationCacheTime;
  static const Duration _locationCacheTtl = Duration(seconds: 45);
  Future<Position?>? _locationInFlight;

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
      debugPrint('📁 Alert path: ${_imageService.storagePath}');
      debugPrint(
          '📏 Face distance: ${_detector.minFaceWidth}-${_detector.maxFaceWidth}px');
      debugPrint('👥 People count: Based on FACE VERIFICATION');
      debugPrint('🎯 Group detection: 1+ person = GROUP');
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

  Future<Position?> _getCurrentLocation() async {
    final cached = _locationCache;
    final cacheAt = _locationCacheTime;
    if (cached != null &&
        cacheAt != null &&
        DateTime.now().difference(cacheAt) < _locationCacheTtl) {
      return cached;
    }

    if (_locationInFlight != null) {
      return _locationInFlight!;
    }

    _locationInFlight = _fetchGpsPosition();
    try {
      final pos = await _locationInFlight!;
      if (pos != null) {
        _locationCache = pos;
        _locationCacheTime = DateTime.now();
      }
      return pos;
    } finally {
      _locationInFlight = null;
    }
  }

  Future<Position?> _fetchGpsPosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('⚠️ Location services disabled');
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        debugPrint('⚠️ Location permission denied');
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 12),
      );

      debugPrint('📍 Location: ${position.latitude}, ${position.longitude}');
      return position;
    } catch (e, st) {
      debugPrint('❌ Location error: $e\n$st');
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
    debugPrint('📏 Distance thresholds: $minWidth-$maxWidth');
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
    while (_continuousRunning && mounted && _autoVerify) {
      if (!mounted) break;

      _verificationCycle++;

      debugPrint('');
      debugPrint('🔄 ══ Cycle $_verificationCycle ══');

      await _runVerification();

      // ✅ Small delay between cycles to prevent overload
      await Future.delayed(const Duration(milliseconds: 500));
    }

    _continuousRunning = false;
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

      if (hasRecentVerification && _lastVerifiedPeopleCount > 0) {
        totalPeople = max(yoloPeople, _lastVerifiedPeopleCount);

        if (_lastKnownCount > 0 || _lastUnknownCount > 0) {
          peopleBreakdown =
              ' ($_lastKnownCount known, $_lastUnknownCount unknown';

          if (yoloPeople > _lastVerifiedPeopleCount) {
            peopleBreakdown +=
                ', ${yoloPeople - _lastVerifiedPeopleCount} unverified';
          }

          peopleBreakdown += ')';
        }

        debugPrint('👥 Status: $totalPeople$peopleBreakdown');
      } else if (yoloPeople > 0) {
        String peopleBreakdown = ' (YOLO)';
        debugPrint('👥 Status: $yoloPeople$peopleBreakdown');
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
      _recentlyVerified.removeWhere(
          (name, time) => now.difference(time) > _verificationCacheDuration);
      final after = _recentlyVerified.length;
      if (before != after) {
        debugPrint('🧹 Cache: removed ${before - after} entries');
      }
    } catch (e) {
      debugPrint('⚠️ Cache error: $e');
    }
  }

void _onFrame(CameraImage image) {
    if (!_multi.isInitialized || !mounted) return;
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

    try {
      try {
        if (_camera.controller?.value.isStreamingImages ?? false) {
          await _camera.stopStream();
          await Future.delayed(const Duration(milliseconds: 100));
        }
      } catch (e) {
        debugPrint('⚠️ Stop stream: $e');
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

      shot = await _camera.takePicture();

      // Step 2: Backup image
      final backupPath = '${shot.path}_backup.jpg';
      await File(shot.path).copy(backupPath);
      _lastCapturedImagePath = backupPath;

      // Step 3: Restart stream immediately
      if (mounted && _camera.isInitialized) {
        try {
          unawaited(_camera.startStream(_onFrame));
        } catch (e) {
          debugPrint('⚠️ Restart stream: $e');
        }
      }

      // Step 4: Detect faces
      List<FaceInfo> faceInfos;
      try {
        faceInfos =
            await _detector.detectAndCropAllFacesWithDistance(shot.path);
      } catch (e) {
        _lastKnownCount = 0;
        _lastUnknownCount = 0;
        _lastVerificationTime = DateTime.now();

        if (mounted) {
          _updateState(_state.copyWith(faceStatus: 'No face'));
        }

        _scheduleImageCleanup(shot.path);
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
          _updateState(_state.copyWith(
            faceStatus: '${faceInfos.length} detected but $reason',
          ));
        }

        _scheduleImageCleanup(shot.path);
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
      _scheduleImageCleanup(shot.path, delay: const Duration(seconds: 3));
    } catch (e) {
      debugPrint('⚠️ Verification error: $e');

      if (mounted) {
        _updateState(_state.copyWith(faceStatus: 'Error'));
      }

      // Ensure stream is restarted
      try {
        if (mounted &&
            _camera.isInitialized &&
            !(_camera.controller?.value.isStreamingImages ?? false)) {
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

  void _scheduleImageCleanup(
    String imagePath, {
    Duration delay = const Duration(seconds: 30),
  }) {
    _imageCleanupTimer?.cancel();
    _imageCleanupTimer = Timer(delay, () {
    try {
      File(imagePath).deleteSync();
    } catch (_) {}
    });
  }

  void _cleanupImage(String imagePath) {
    try {
      File(imagePath).deleteSync();
    } catch (_) {}
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

          if (!knownNames.contains(name)) {
            knownNames.add(name);
          }
          knownCount++;
        } else {
          unknownCount++;
          debugPrint('⚠️ UNKNOWN');
        }
      }

      _lastKnownCount = knownNames.length;
      _lastUnknownCount = unknownCount;
      _lastVerifiedPeopleCount = knownNames.length + unknownCount;
      _lastVerificationTime = DateTime.now();

      debugPrint(
          '📊 Cycle $_verificationCycle: $knownCount known, $unknownCount unknown');

      if (unknownCount > 0) {
        final lensName = _camera.lensDirection == CameraLensDirection.front
            ? 'front'
            : 'back';
        final savedImagePath = _lastCapturedImagePath;
        final position = await _getCurrentLocation();

        List<String>? savedFacePaths;
        try {
          savedFacePaths = await _imageService.saveFaceImages(
            detectedFaces,
            alertType: 'unknown_face',
            sessionInfo: 'u${unknownCount}_k$knownCount',
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

      if (mounted) {
        _updateState(_state.copyWith(
          faceStatus: unknownCount > 0
              ? '⚠️ $unknownCount unknown'
              : '✅ $knownCount verified',
          lastMatch: knownNames.isNotEmpty ? knownNames.join(', ') : '',
        ));
      }
    } catch (e) {
      debugPrint('❌ Process results: $e');
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

  /// Stops ML + camera stream before the Location tab mounts Google Maps.
  /// Camera preview + Maps platform view together commonly crash Android GPUs.
  Future<void> pauseForMapTab() async {
    _stopContinuousVerification();
    try {
      if (_camera.controller?.value.isStreamingImages ?? false) {
        await _camera.stopStream();
      }
    } catch (e) {
      debugPrint('⚠️ pauseForMapTab stopStream: $e');
    }
    await Future.delayed(const Duration(milliseconds: 280));
  }

  /// Restores surveillance after leaving the Location tab.
  Future<void> resumeFromMapTab() async {
    try {
      if (_camera.isInitialized &&
          !(_camera.controller?.value.isStreamingImages ?? false)) {
        await _camera.startStream(_onFrame);
      }
    } catch (e) {
      debugPrint('⚠️ resumeFromMapTab startStream: $e');
    }
    if (_autoVerify && mounted) {
      _startContinuousVerification();
    }
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

    if (_lastCapturedImagePath != null) {
      try {
        await File(_lastCapturedImagePath!).delete();
      } catch (_) {}
    }

    debugPrint('✅ SurveillanceController disposed');
  }
}
