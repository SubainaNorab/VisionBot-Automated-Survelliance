// surveillance_controller.dart - UPDATED WITH GPS + NOTIFICATIONS
// ⚠️ All existing face detection, alert flow, and Firebase logic preserved.
// ✅ ADDED: Location fetching + push notifications on unknown face detection.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../camera.dart';
import '../face_Detector.dart';
import '../face_verification.dart';
import '../services/alert_service.dart';
import '../alert_image_service.dart';
import '../sm_grp.dart';
// ✅ NEW imports
import '../services/location_service.dart';
import '../services/notification_service.dart';

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
  // ✅ NEW: location and notification services
  final LocationService _locationService = LocationService.instance;
  final NotificationService _notificationService = NotificationService.instance;

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
      // ✅ Initialize all services — location & notification added alongside existing ones
      await Future.wait([
        _verifier.initialize(),
        _multi.initialize(),
        _camera.initialize(preferred: preferredLens),
        _imageService.initialize(),
        _locationService.initialize(), // ✅ NEW
        _notificationService.initialize(), // ✅ NEW
      ]);

      // ✅ Pre-fetch location so first alert is fast
      unawaited(_locationService.getCurrentLocation());

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
      debugPrint(
          '📏 Distance range: ${_detector.minFaceWidth}-${_detector.maxFaceWidth}px');
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

    // ✅ Group alert — now fetches location
    if (isGroup && !_lastGroupState) {
      debugPrint('🚨 GROUP DETECTED: $totalPeople people$peopleBreakdown');

      String? savedImagePath;
      if (_lastCapturedImagePath != null) {
        final cleanInfo = peopleBreakdown
            .replaceAll(' ', '')
            .replaceAll('(', '')
            .replaceAll(')', '');
        savedImagePath = await _imageService.saveGroupImage(
          _lastCapturedImagePath!,
          personCount: totalPeople,
          additionalInfo: cleanInfo,
        );
      }

      // ✅ Fetch location for group alert
      final location =
          await _locationService.getLocationFast(maxAgeSeconds: 60);

      _alertService
          .createGroupAlert(
            personCount: totalPeople,
            lens: lensName,
            imagePath: savedImagePath,
            latitude: location?.latitude,
            longitude: location?.longitude,
            placeName: location?.placeName,
            address: location?.address,
          )
          .catchError((e) => debugPrint('❌ Group alert error: $e'));

      // ✅ Send notification for group
      if (location != null) {
        unawaited(_notificationService.sendGroupNotification(
          personCount: totalPeople,
          latitude: location.latitude,
          longitude: location.longitude,
          placeName: location.placeName,
          timestamp: DateTime.now().toIso8601String(),
        ));
      }
    }
    _lastGroupState = isGroup;

    // ✅ Smoking alert — now fetches location
    if (det.smokingDetected && !_lastSmokeState) {
      debugPrint('🚨 SMOKING DETECTED');

      String? savedImagePath;
      if (_lastCapturedImagePath != null) {
        savedImagePath = await _imageService.saveSmokingImage(
          _lastCapturedImagePath!,
        );
      }

      // ✅ Fetch location for smoking alert
      final location =
          await _locationService.getLocationFast(maxAgeSeconds: 60);

      _alertService
          .createSmokingAlert(
            lens: lensName,
            imagePath: savedImagePath,
            latitude: location?.latitude,
            longitude: location?.longitude,
            placeName: location?.placeName,
            address: location?.address,
          )
          .catchError((e) => debugPrint('❌ Smoke alert error: $e'));

      // ✅ Send notification for smoking
      if (location != null) {
        unawaited(_notificationService.sendSmokingNotification(
          latitude: location.latitude,
          longitude: location.longitude,
          placeName: location.placeName,
          timestamp: DateTime.now().toIso8601String(),
        ));
      }
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
      if (_camera.controller?.value.isStreamingImages ?? false) {
        await _camera.stopStream();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      shot = await _camera.takePicture();
      _lastCapturedImagePath = shot.path;

      debugPrint('📸 Background: Photo captured, stream restarting...');

      if (mounted && _camera.isInitialized) {
        unawaited(_camera.startStream(_onFrame));
        await Future.delayed(const Duration(milliseconds: 50));
      }

      final faceInfos =
          await _detector.detectAndCropAllFacesWithDistance(shot.path);

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
          debugPrint(
              '⏭️ Skipping: Face too close (${faceInfo.originalWidth}px)');
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

        _scheduleImageCleanup(shot.path, Duration(seconds: 2));
        return;
      }

      debugPrint('📸 Verifying ${validFaces.length} face(s) in good range');

      _lastDetectedFaces = validFaces;

      final results = _verifier.verifyMultipleFaces(validFaces);

      if (mounted) {
        _processVerificationResults(
            results, validFaces.length, faceInfos.length);
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
      } else {
        debugPrint('⚠️ Background verification failed: $e');
        if (mounted) {
          _updateState(_state.copyWith(faceStatus: 'Verify error'));
        }
      }

      try {
        if (mounted &&
            _camera.isInitialized &&
            !(_camera.controller?.value.isStreamingImages ?? false)) {
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

    debugPrint('🔍 Processing ${results.length} verification results...');

    for (final result in results) {
      if (result.verified && result.person != null) {
        final name = result.person!.name;

        final lastVerified = _recentlyVerified[name];
        final isRecent = lastVerified != null &&
            DateTime.now().difference(lastVerified) <
                _verificationCacheDuration;

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

    if (unknownCount > 0) {
      debugPrint('');
      debugPrint('═══════════════════════════════════');
      debugPrint('🚨 UNKNOWN FACE(S) DETECTED');
      debugPrint('═══════════════════════════════════');

      final lensName =
          _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

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

      // ✅ STEP 1: Fetch GPS location CONCURRENTLY with image saving
      debugPrint('🌍 Step 0: Fetching GPS location...');
      final locationFuture =
          _locationService.getLocationFast(maxAgeSeconds: 30);

      // STEP 1: Save full frame image (existing logic preserved)
      if (_lastCapturedImagePath != null) {
        debugPrint('💾 Step 1: Saving full frame image...');
        final sourceFile = File(_lastCapturedImagePath!);
        final exists = await sourceFile.exists();

        if (exists) {
          savedImagePath = await _imageService.saveUnknownFaceImage(
            _lastCapturedImagePath!,
            additionalInfo: 'unknown${unknownCount}_known${knownCount}',
          );

          debugPrint('   ✅ Full frame saved to: $savedImagePath');
        }
      }

      // STEP 2: Save cropped face images (existing logic preserved)
      if (_lastDetectedFaces != null && _lastDetectedFaces!.isNotEmpty) {
        debugPrint(
            '💾 Step 2: Saving ${_lastDetectedFaces!.length} cropped face images...');
        savedFacePaths = await _imageService.saveFaceImages(
          _lastDetectedFaces!,
          alertType: 'unknown_face',
          sessionInfo: 'u${unknownCount}_k${knownCount}',
        );
        debugPrint('   ✅ Saved ${savedFacePaths.length} face images');
      }

      // ✅ STEP 3: Await location result
      final location = await locationFuture;
      if (location != null) {
        debugPrint('   📍 Location: ${location.placeName}');
        debugPrint('   📍 Coords: ${location.latitude}, ${location.longitude}');
      } else {
        debugPrint('   ⚠️ Location not available');
      }

      // STEP 4: Create Firestore alert with location (existing + new location fields)
      debugPrint('📝 Step 4: Creating Firestore alert...');
      await _alertService.createUnknownAlert(
        threshold: FaceVerificationService.threshold,
        lens: lens,
        note:
            '$unknownCount unknown face(s) detected${knownCount > 0 ? ', $knownCount known' : ''}$filteredInfo'
            '${location != null ? ' at ${location.placeName}' : ''}',
        imagePath: savedImagePath,
        faceImagePaths: savedFacePaths,
        // ✅ NEW: pass location data
        latitude: location?.latitude,
        longitude: location?.longitude,
        placeName: location?.placeName,
        address: location?.address,
      );

      // ✅ STEP 5: Send push notification with image + location
      debugPrint('🔔 Step 5: Sending push notification...');
      if (location != null) {
        await _notificationService.sendUnknownFaceNotification(
          latitude: location.latitude,
          longitude: location.longitude,
          placeName: location.placeName,
          timestamp: DateTime.now().toIso8601String(),
          imagePath: savedImagePath,
          unknownCount: unknownCount,
        );
      } else {
        // Send notification without location
        await _notificationService.sendUnknownFaceNotification(
          latitude: 0,
          longitude: 0,
          placeName: 'Location unavailable',
          timestamp: DateTime.now().toIso8601String(),
          imagePath: savedImagePath,
          unknownCount: unknownCount,
        );
      }

      debugPrint('✅ ALERT SAVED + NOTIFICATION SENT SUCCESSFULLY');
      debugPrint('   Full frame: ${savedImagePath ?? 'none'}');
      debugPrint('   Cropped faces: ${savedFacePaths?.length ?? 0}');
      debugPrint('   Location: ${location?.placeName ?? 'unavailable'}');
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

      final faceInfos =
          await _detector.detectAndCropAllFacesWithDistance(shot.path);

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
          reason =
              '$_facesTooFar too far, $_facesTooClose too close - adjust distance';
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
        _processVerificationResults(
            results, validFaces.length, faceInfos.length);
      }

      _scheduleImageCleanup(shot.path, Duration(seconds: 2));
    } catch (e) {
      final errorMsg =
          e.toString().contains('No face') ? 'No faces detected' : 'Error: $e';

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

    try {
      await _camera.stopStream();
    } catch (e) {
      debugPrint('   ⚠️ Camera stream stop error: $e');
    }

    try {
      await _camera.dispose();
    } catch (e) {
      debugPrint('   ⚠️ Camera dispose error: $e');
    }

    try {
      await _detector.dispose();
    } catch (e) {
      debugPrint('   ⚠️ Face detector dispose error: $e');
    }

    try {
      _verifier.dispose();
    } catch (e) {
      debugPrint('   ⚠️ Face verifier dispose error: $e');
    }

    try {
      _multi.dispose();
    } catch (e) {
      debugPrint('   ⚠️ Multi detector dispose error: $e');
    }

    try {
      await _stateController.close();
    } catch (e) {
      debugPrint('   ⚠️ State controller close error: $e');
    }

    _recentlyVerified.clear();

    if (_lastCapturedImagePath != null) {
      try {
        await File(_lastCapturedImagePath!).delete();
      } catch (e) {
        debugPrint('   ⚠️ Temp image cleanup error: $e');
      }
    }

    debugPrint('✅ SurveillanceController disposed successfully');
  }
}
