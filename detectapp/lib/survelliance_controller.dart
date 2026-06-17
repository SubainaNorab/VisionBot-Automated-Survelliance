// surveillance_controller.dart - OPTIMIZED: Parallel YOLO + Face detection

import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:geolocator/geolocator.dart';

import 'camera.dart';
import 'face_Detector.dart';
import 'face_verification.dart';
import 'alert_service.dart';
import 'sm_grp.dart';
import 'image_uploader_service.dart';

class SurveillanceState {
  final bool isBooting;
  final String faceStatus;
  final String lastMatch;
  final bool processingFace;
  final int yoloPeopleCount;
  final int verifiedPeopleCount;
  final int knownPeopleCount;
  final int unknownPeopleCount;
  final bool groupDetected;
  final bool smokingDetected;

  const SurveillanceState({
    this.isBooting = true,
    this.faceStatus = 'Starting...',
    this.lastMatch = '',
    this.processingFace = false,
    this.yoloPeopleCount = 0,
    this.verifiedPeopleCount = 0,
    this.knownPeopleCount = 0,
    this.unknownPeopleCount = 0,
    this.groupDetected = false,
    this.smokingDetected = false,
  });

  SurveillanceState copyWith({
    bool? isBooting,
    String? faceStatus,
    String? lastMatch,
    bool? processingFace,
    int? yoloPeopleCount,
    int? verifiedPeopleCount,
    int? knownPeopleCount,
    int? unknownPeopleCount,
    bool? groupDetected,
    bool? smokingDetected,
  }) {
    return SurveillanceState(
      isBooting: isBooting ?? this.isBooting,
      faceStatus: faceStatus ?? this.faceStatus,
      lastMatch: lastMatch ?? this.lastMatch,
      processingFace: processingFace ?? this.processingFace,
      yoloPeopleCount: yoloPeopleCount ?? this.yoloPeopleCount,
      verifiedPeopleCount: verifiedPeopleCount ?? this.verifiedPeopleCount,
      knownPeopleCount: knownPeopleCount ?? this.knownPeopleCount,
      unknownPeopleCount: unknownPeopleCount ?? this.unknownPeopleCount,
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
  final MultiDetectorService _multi;

  final StreamController<SurveillanceState> _stateController =
      StreamController<SurveillanceState>.broadcast();
  
  SurveillanceState _state = const SurveillanceState();

  bool _autoVerify = true;
  Timer? _statusTimer;
  Timer? _cacheCleanupTimer;
  Timer? _verificationTimer; // ✅ Separate timer for verification

  bool _processingVerification = false;

  final Map<String, DateTime> _recentlyVerified = {};
  static const Duration _verificationCacheDuration = Duration(seconds: 30);

  // ✅ Hybrid tracking
  int _lastYoloPeopleCount = 0;
  int _lastVerifiedPeopleCount = 0;
  int _lastKnownCount = 0;
  int _lastUnknownCount = 0;
  DateTime _lastGroupAlertTime = DateTime.fromMillisecondsSinceEpoch(0);

<<<<<<< HEAD
  String? _currentFramePath;
  Timer? _imageCleanupTimer;
=======
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
>>>>>>> origin/hadia

  Stream<SurveillanceState> get stateStream => _stateController.stream;
  SurveillanceState get currentState => _state;
  CameraService get camera => _camera;
  bool get autoVerify => _autoVerify;

  bool get mounted => !_stateController.isClosed;

  SurveillanceController({
    int groupThreshold = 1,
  }) : _multi = MultiDetectorService(groupThreshold: groupThreshold);

  Future<void> initialize({
    CameraLensDirection preferredLens = CameraLensDirection.front,
  }) async {
    _updateState(_state.copyWith(isBooting: true, faceStatus: 'Initializing...'));

    try {
      debugPrint('');
      debugPrint('═══════════════════════════════════');
      debugPrint('📱 Initializing SurveillanceController');
      debugPrint('═══════════════════════════════════');

      debugPrint('1️⃣ Loading face verifier...');
      await _verifier.initialize();
      debugPrint('   ✅ Verifier ready');

<<<<<<< HEAD
      debugPrint('2️⃣ Loading YOLO detector...');
      await _multi.initialize();
      debugPrint('   ✅ YOLO ready');

      debugPrint('3️⃣ Starting camera...');
      await _camera.initialize(preferred: preferredLens);
      debugPrint('   ✅ Camera ready');
=======
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
>>>>>>> origin/hadia

      await _camera.startStream(_onFrame);
      debugPrint('✅ Camera stream started');

      _startStatusPolling();
      _startCacheCleanup();
      _startVerificationLoop(); // ✅ Separate verification loop

      _updateState(_state.copyWith(isBooting: false, faceStatus: 'Ready'));

      debugPrint('');
      debugPrint('✅ SurveillanceController initialized');
<<<<<<< HEAD
      debugPrint('🎯 HYBRID PARALLEL MODE:');
      debugPrint('   • YOLO: 4 FPS (real-time people detection)');
      debugPrint('   • FACE: On-demand (identity verification)');
      debugPrint('   • GROUP: YOLO(>=1) + FACE-VERIFIED = ALERT ⚡');
=======
      debugPrint('📁 Alert path: ${_imageService.storagePath}');
      debugPrint(
          '📏 Face distance: ${_detector.minFaceWidth}-${_detector.maxFaceWidth}px');
      debugPrint('👥 People count: Based on FACE VERIFICATION');
      debugPrint('🎯 Group detection: 1+ person = GROUP');
>>>>>>> origin/hadia
      debugPrint('═══════════════════════════════════');
      debugPrint('');

      if (_autoVerify) {
        _startVerificationLoop();
      }
    } catch (e, st) {
<<<<<<< HEAD
      debugPrint('❌ Init failed: $e\n$st');
      _updateState(_state.copyWith(isBooting: false, faceStatus: 'Failed'));
=======
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
>>>>>>> origin/hadia
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
  }

<<<<<<< HEAD
  Future<Position?> _getCurrentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return null;
      }

      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );
=======
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
>>>>>>> origin/hadia
    } catch (e) {
      return null;
    }
  }

<<<<<<< HEAD
  String? _formatLocation(Position? position) {
    if (position == null) return null;
    return '${position.latitude?.toStringAsFixed(4)}, ${position.longitude?.toStringAsFixed(4)}';
  }

  // ✅ NEW: Separate verification loop - runs independently
  void _startVerificationLoop() {
    _verificationTimer?.cancel();
    _verificationTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || !_autoVerify || _processingVerification) return;
      _runVerificationAsync(); // Fire and forget
    });
    debugPrint('🔄 Verification loop started (2s interval)');
  }

  void _stopVerificationLoop() {
    _verificationTimer?.cancel();
    debugPrint('⏹️ Verification loop stopped');
=======
void _onFrame(CameraImage image) {
    if (!_multi.isInitialized || !mounted) return;
    _multi.detectAllAsync(image);
>>>>>>> origin/hadia
  }

  // ✅ ASYNC verification - doesn't block YOLO detection
  void _runVerificationAsync() {
    if (_processingVerification) return;
    _processingVerification = true;

    _updateState(_state.copyWith(processingFace: true, faceStatus: 'Scanning...'));

    _runVerificationInternal().then((_) {
      if (mounted) {
        _processingVerification = false;
        _updateState(_state.copyWith(processingFace: false));
      }
    }).catchError((e) {
      debugPrint('❌ Verification error: $e');
      if (mounted) {
        _processingVerification = false;
        _updateState(_state.copyWith(processingFace: false));
      }
    });
  }

  Future<void> _runVerificationInternal() async {
    XFile? shot;
<<<<<<< HEAD
    bool streamWasStopped = false;

    try {
      // ✅ Stop stream BRIEFLY to take picture
      if (_camera.controller?.value.isStreamingImages ?? false) {
        await _camera.stopStream();
        streamWasStopped = true;
        await Future.delayed(const Duration(milliseconds: 50));
      }

      if (!mounted) return;
=======

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
>>>>>>> origin/hadia

      shot = await _camera.takePicture();
      _currentFramePath = shot.path;

      // ✅ Resume stream immediately
      if (mounted && _camera.isInitialized) {
        try {
          unawaited(_camera.startStream(_onFrame));
        } catch (e) {
          debugPrint('⚠️ Restart stream: $e');
        }
      }

      if (!mounted) return;

      // ✅ Face detection (fast - ~200ms)
      List<FaceInfo> faceInfos;
      try {
        faceInfos = await _detector.detectAndCropAllFacesWithDistance(shot.path);
      } catch (e) {
        _lastKnownCount = 0;
        _lastUnknownCount = 0;

        if (mounted) {
          _updateState(_state.copyWith(faceStatus: 'No face detected'));
        }

        _scheduleImageCleanup(shot.path);
        return;
      }

      if (!mounted) return;

      // ✅ Filter by distance
      final validFaces = faceInfos
          .where((f) => !f.isTooFar && !f.isTooClose)
          .map((f) => f.croppedFace)
          .toList();

      _lastVerifiedPeopleCount = validFaces.length;

      if (validFaces.isEmpty) {
        if (mounted) {
          _updateState(_state.copyWith(
<<<<<<< HEAD
            faceStatus: '${faceInfos.length} detected but distance invalid',
=======
            faceStatus: '${faceInfos.length} detected but $reason',
>>>>>>> origin/hadia
          ));
        }

        _scheduleImageCleanup(shot.path);
        return;
      }

      // ✅ Parallel verification - run all at once
      final results = _verifier.verifyMultipleFaces(validFaces);

      if (!mounted) return;

<<<<<<< HEAD
      await _processVerificationResults(results, shot.path, validFaces);
      _scheduleImageCleanup(shot.path);
    } catch (e, st) {
      debugPrint('❌ Verification: $e\n$st');
=======
      // Cleanup original (keep backup longer for alerts)
      _scheduleImageCleanup(shot.path, delay: const Duration(seconds: 3));
    } catch (e) {
      debugPrint('⚠️ Verification error: $e');
>>>>>>> origin/hadia

      if (streamWasStopped && mounted && _camera.isInitialized) {
        try {
          await _camera.startStream(_onFrame);
        } catch (e2) {
          debugPrint('⚠️ Force restart failed: $e2');
        }
      }
    }
  }

<<<<<<< HEAD
  void _startStatusPolling() {
    _statusTimer?.cancel();
    // ✅ Update UI more frequently to show real-time YOLO + Face sync
    _statusTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;

      try {
        final yoloPeopleCount = _multi.lastResult.personCount;
        final verifiedPeopleCount = _lastVerifiedPeopleCount;
        final knownCount = _lastKnownCount;
        final unknownCount = _lastUnknownCount;
        final hasSmoking = _multi.lastResult.smokingDetected;

        // ✅ GROUP LOGIC: YOLO detects + Face verified = ALERT
        final isGroup = yoloPeopleCount >= 1 && verifiedPeopleCount >= 1;

        _updateState(_state.copyWith(
          yoloPeopleCount: yoloPeopleCount,
          verifiedPeopleCount: verifiedPeopleCount,
          knownPeopleCount: knownCount,
          unknownPeopleCount: unknownCount,
          groupDetected: isGroup,
          smokingDetected: hasSmoking,
        ));

        _handleDetectionAlerts(
          yoloPeopleCount,
          verifiedPeopleCount,
          knownCount,
          unknownCount,
          isGroup,
          hasSmoking,
        );
      } catch (e) {
        debugPrint('⚠️ Polling error: $e');
      }
    });
  }

  void _startCacheCleanup() {
    _cacheCleanupTimer?.cancel();
    _cacheCleanupTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) _cleanVerificationCache();
    });
  }

  void _cleanVerificationCache() {
    final now = DateTime.now();
    _recentlyVerified.removeWhere((name, time) =>
        now.difference(time) > _verificationCacheDuration);
  }

  void _handleDetectionAlerts(
    int yoloPeopleCount,
    int verifiedPeopleCount,
    int knownCount,
    int unknownCount,
    bool isGroup,
    bool hasSmoking,
  ) {
    if (!mounted) return;

    final lensName =
        _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

    // ✅ GROUP ALERT: YOLO + Face verified (with rate limiting)
    if (isGroup && !_lastGroupState) {
      final now = DateTime.now();
      if (now.difference(_lastGroupAlertTime).inSeconds >= 5) {
        debugPrint('🚨 GROUP ALERT: YOLO($yoloPeopleCount) + FACE($verifiedPeopleCount)');

        if (_currentFramePath != null) {
          _saveGroupAlert(verifiedPeopleCount, knownCount, unknownCount, lensName);
        }

        _lastGroupAlertTime = now;
      }
    }
    _lastGroupState = isGroup;

    // ✅ SMOKING ALERT
    if (hasSmoking && !_lastSmokeState) {
      debugPrint('🚨 SMOKING ALERT');

      if (_currentFramePath != null) {
        _saveSmokingAlert(lensName);
      }
    }
    _lastSmokeState = hasSmoking;
  }

  Future<void> _saveGroupAlert(
    int personCount,
    int knownCount,
    int unknownCount,
    String lensName,
  ) async {
    try {
      String? imageUrl;

      if (_currentFramePath != null && await File(_currentFramePath!).exists()) {
        try {
          final result = await ImageUploaderService.saveAndUploadAlertImage(
            sourcePath: _currentFramePath!,
            alertType: 'group_detected',
            additionalInfo: 'face_${personCount}_k${knownCount}_u${unknownCount}',
          );

          imageUrl = result['remote'];

          if (imageUrl != null) {
            debugPrint('✅ Group image uploaded');
          }
        } catch (uploadError) {
          debugPrint('⚠️ Upload failed, continuing');
        }
      }

      final position = await _getCurrentLocation();

      await _alertService.createGroupAlert(
        personCount: personCount,
        lens: lensName,
        imagePath: imageUrl,
        latitude: position?.latitude,
        longitude: position?.longitude,
        locationName: _formatLocation(position),
      );

      debugPrint('✅ Group alert saved to Firebase');
    } catch (e, st) {
      debugPrint('❌ Group alert: $e\n$st');
    }
  }

  Future<void> _saveSmokingAlert(String lensName) async {
    try {
      String? imageUrl;

      if (_currentFramePath != null && await File(_currentFramePath!).exists()) {
        try {
          final result = await ImageUploaderService.saveAndUploadAlertImage(
            sourcePath: _currentFramePath!,
            alertType: 'smoking_detected',
            additionalInfo: '',
          );

          imageUrl = result['remote'];

          if (imageUrl != null) {
            debugPrint('✅ Smoking image uploaded');
          }
        } catch (uploadError) {
          debugPrint('⚠️ Upload failed, continuing');
        }
      }

      final position = await _getCurrentLocation();

      await _alertService.createSmokingAlert(
        lens: lensName,
        imagePath: imageUrl,
        latitude: position?.latitude,
        longitude: position?.longitude,
        locationName: _formatLocation(position),
      );

      debugPrint('✅ Smoking alert saved');
    } catch (e, st) {
      debugPrint('❌ Smoking alert: $e\n$st');
    }
  }

  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized || !mounted) return;
    _multi.detectAllAsync(image); // ✅ YOLO runs independently on every frame
  }

  void _scheduleImageCleanup(String imagePath) {
    _imageCleanupTimer?.cancel();
    _imageCleanupTimer = Timer(const Duration(seconds: 5), () {
      try {
        File(imagePath).deleteSync();
      } catch (_) {}
    });
=======
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
>>>>>>> origin/hadia
  }

  Future<void> _processVerificationResults(
    List<VerificationResult> results,
    String framePath,
    List<img.Image> detectedFaces,
  ) async {
    try {
      int knownCount = 0;
      int unknownCount = 0;
<<<<<<< HEAD
      final knownNames = <String>{};
      bool hasUnknownFace = false;
=======
      final knownNames = <String>[];
>>>>>>> origin/hadia

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
<<<<<<< HEAD
          knownNames.add(name);
=======

          if (!knownNames.contains(name)) {
            knownNames.add(name);
          }
          knownCount++;
>>>>>>> origin/hadia
        } else {
          unknownCount++;
          debugPrint('⚠️ UNKNOWN');
        }
      }

      _lastKnownCount = knownNames.length;
      _lastUnknownCount = unknownCount;
<<<<<<< HEAD

      if (hasUnknownFace && unknownCount > 0) {
        debugPrint('🚨 UNKNOWN FACE: $unknownCount');

        final lensName =
            _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';
        final position = await _getCurrentLocation();

        String? frameUrl;
        try {
          final result = await ImageUploaderService.saveAndUploadAlertImage(
            sourcePath: framePath,
            alertType: 'unknown_face',
            additionalInfo: 'u${unknownCount}_k${knownNames.length}',
          );
          frameUrl = result['remote'];
        } catch (e) {
          debugPrint('⚠️ Frame upload failed');
        }

        List<String> faceUrls = [];
        try {
          if (detectedFaces.isNotEmpty) {
            faceUrls = await ImageUploaderService.saveAndUploadFaceImages(
              faces: detectedFaces,
              alertType: 'unknown_face',
              sessionInfo: 'u${unknownCount}_k${knownNames.length}',
            );
          }
        } catch (e) {
          debugPrint('⚠️ Face upload failed');
=======
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
>>>>>>> origin/hadia
        }

        await _alertService.createUnknownAlert(
          threshold: FaceVerificationService.threshold,
          lens: lensName,
<<<<<<< HEAD
          note: '$unknownCount unknown face(s)',
          imagePath: frameUrl,
          faceImagePaths: faceUrls,
          latitude: position?.latitude,
          longitude: position?.longitude,
          locationName: _formatLocation(position),
        );
      }

      final knownList = knownNames.toList();
      String statusMsg;

      if (knownList.isNotEmpty && unknownCount > 0) {
        statusMsg = '✅ ${knownList.join(", ")} | ⚠️ $unknownCount unk';
      } else if (knownList.isNotEmpty) {
        statusMsg = '✅ ${knownList.join(", ")}';
      } else if (unknownCount > 0) {
        statusMsg = '⚠️ $unknownCount unknown';
      } else {
        statusMsg = 'Scanning...';
      }

=======
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

>>>>>>> origin/hadia
      if (mounted) {
        _updateState(_state.copyWith(
          faceStatus: unknownCount > 0
              ? '⚠️ $unknownCount unknown'
              : '✅ $knownCount verified',
          lastMatch: knownNames.isNotEmpty ? knownNames.join(', ') : '',
        ));
      }
    } catch (e, st) {
      debugPrint('❌ Process results: $e\n$st');
    }
  }

  void setAutoVerify(bool enabled) {
    _autoVerify = enabled;
    debugPrint('🔄 Auto verify: ${enabled ? "ON" : "OFF"}');

    if (enabled) {
      _startVerificationLoop();
    } else {
      _stopVerificationLoop();
    }

    if (mounted) {
      _updateState(_state.copyWith(
        faceStatus: enabled ? 'Auto-verify ON' : 'Auto-verify OFF',
      ));
    }
  }

  Future<void> verifyFace() async {
    debugPrint('🔘 Manual verify');
    _runVerificationAsync();
  }

  Future<void> switchCamera() async {
    if (!mounted) return;

    try {
      _updateState(_state.copyWith(faceStatus: 'Switching...'));

      _stopVerificationLoop();

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
          _startVerificationLoop();
        }
      }

      debugPrint('📷 Camera switched');
    } catch (e, st) {
      debugPrint('❌ Switch failed: $e\n$st');
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
    debugPrint('');
    debugPrint('═══════════════════════════════════');
    debugPrint('🧹 Disposing SurveillanceController');
    debugPrint('═══════════════════════════════════');

    _stopVerificationLoop();
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
        await File(_lastCapturedImagePath!).delete();
      } catch (_) {}
    }

    debugPrint('✅ Disposed');
    debugPrint('═══════════════════════════════════');
    debugPrint('');
  }
}