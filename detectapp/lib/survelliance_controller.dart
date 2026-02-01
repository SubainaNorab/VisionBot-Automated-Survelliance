// lib/surveillance_controller.dart
// Business logic coordinator for surveillance system

import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

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

/// Main controller for surveillance operations
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

  bool _faceDetectedInVerification = false;
  DateTime _lastFaceDetectionTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Alert state tracking
  bool _lastGroupState = false;
  bool _lastSmokeState = false;

  int _frameCount = 0;
  static const int _frameSkip = 5;

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

  /// Start polling detection results
  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final det = _multi.lastResult;

      int totalPeople = det.personCount;
      final faceExpired =
          DateTime.now().difference(_lastFaceDetectionTime).inSeconds > 5;

      if (_faceDetectedInVerification && !faceExpired && det.personCount == 0) {
        totalPeople = 1; // Use face detection if YOLO sees nothing
      } else if (faceExpired) {
        _faceDetectedInVerification = false; // Reset after 5 seconds
      }

      bool isGroup = totalPeople >= _multi.groupThreshold;

      final status =
          'People: $totalPeople | Group: ${isGroup ? "YES" : "NO"} | Smoke: ${det.smokingDetected ? "YES" : "NO"} (${det.processingTimeMs}ms)';

      _updateState(_state.copyWith(
        detectionStatus: status,
        peopleCount: totalPeople,
        groupDetected: isGroup,
        smokingDetected: det.smokingDetected,
      ));

      _handleDetectionAlerts(det, totalPeople, isGroup);
    });
  }

  void _handleDetectionAlerts(
    DetectionResult det,
    int totalPeople,
    bool isGroup,
  ) {
    final lensName =
        _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

    if (isGroup && !_lastGroupState) {
      debugPrint('🚨 GROUP DETECTED: $totalPeople people');
      _alertService
          .createGroupAlert(
            personCount: totalPeople,
            lens: lensName,
          )
          .catchError((e) => debugPrint('Group alert error: $e'));
    }
    _lastGroupState = isGroup;

    if (det.smokingDetected && !_lastSmokeState) {
      debugPrint('🚨 SMOKING DETECTED');
      _alertService
          .createSmokingAlert(lens: lensName)
          .catchError((e) => debugPrint('Smoke alert error: $e'));
    }
    _lastSmokeState = det.smokingDetected;
  }

  void _onFrame(CameraImage image) {
    if (!_multi.isInitialized) return;

    _frameCount++;
    if (_frameCount % _frameSkip != 0) return;

    _multi.detectAllAsync(image);
  }

  void _startAutoVerify() {
    _verifyTimer?.cancel();
    if (!_autoVerify) return;

    _verifyTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_state.isBooting || _state.processingFace) return;
      await verifyFace();
    });
  }

  void setAutoVerify(bool enabled) {
    _autoVerify = enabled;
    _startAutoVerify();
    debugPrint('Auto verify ${enabled ? "enabled" : "disabled"}');
  }

 
  Future<void> verifyFace() async {
    if (_state.processingFace) return;

    _updateState(_state.copyWith(
      processingFace: true,
      faceStatus: 'Capturing face...',
    ));

    try {
      // Stop stream to avoid conflicts
      await _camera.stopStream();

      final shot = await _camera.takePicture();

      _updateState(_state.copyWith(faceStatus: 'Detecting face...'));
      final face = await _detector.detectAndCropFaceFromFile(shot.path);

     
      _faceDetectedInVerification = true;
      _lastFaceDetectionTime = DateTime.now();
      debugPrint('✅ Face detected via verification at $_lastFaceDetectionTime');

      _updateState(_state.copyWith(faceStatus: 'Verifying...'));
      final result = _verifier.verifyFace(face);

      // Create alert for unknown faces
      if (!result.verified) {
        final lensName = _camera.lensDirection == CameraLensDirection.front
            ? 'front'
            : 'back';

        _alertService
            .createUnknownAlert(
              threshold: FaceVerificationService.threshold,
              lens: lensName,
              note: 'Unknown face detected',
            )
            .catchError((_) {});
      }

      _updateState(_state.copyWith(
        faceStatus: result.message,
        lastMatch: result.verified ? (result.person?.name ?? '') : '',
      ));
    } catch (e) {
      _faceDetectedInVerification = false;
      _updateState(_state.copyWith(faceStatus: 'No face detected'));
      debugPrint('⚠️ Face detection failed: $e');
    } finally {
      // Resume stream
      try {
        await _camera.startStream(_onFrame);
      } catch (_) {}

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

      // Reset alert states
      _alertService.resetCooldowns();
      _lastGroupState = false;
      _lastSmokeState = false;
      _faceDetectedInVerification = false;

      _updateState(_state.copyWith(faceStatus: 'Ready'));
      _startAutoVerify();

      debugPrint('✅ Camera switched');
    } catch (e) {
      _updateState(_state.copyWith(faceStatus: 'Switch failed: $e'));
      debugPrint('❌ Camera switch failed: $e');
    }
  }

  void setGroupThreshold(int threshold) {
    _multi.setGroupThreshold(threshold);
    debugPrint('✅ Group threshold set to $threshold');
  }

  void _updateState(SurveillanceState newState) {
    _state = newState;
    _stateController.add(_state);
  }

  
  Future<void> dispose() async {
    _verifyTimer?.cancel();
    _statusTimer?.cancel();
    await _camera.dispose();
    await _detector.dispose();
    _verifier.dispose();
    _multi.dispose();
    await _stateController.close();
    debugPrint('✅ SurveillanceController disposed');
  }
}