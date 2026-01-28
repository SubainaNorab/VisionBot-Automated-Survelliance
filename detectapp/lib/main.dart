// lib/main.dart
// Face verification + real-time YOLO people/group detection + Firebase alerts

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';

import 'camera.dart';
import 'face_detector.dart';
import 'face_verification.dart';
import 'firebase_options.dart';
import 'alert_service.dart';
import 'sm_grp.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Recognition',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: const FaceRecognitionScreen(),
    );
  }
}

class FaceRecognitionScreen extends StatefulWidget {
  const FaceRecognitionScreen({super.key});

  @override
  State<FaceRecognitionScreen> createState() => _FaceRecognitionScreenState();
}

class _FaceRecognitionScreenState extends State<FaceRecognitionScreen> {
  final CameraService _camera = CameraService();
  final FaceDetectionService _detector = FaceDetectionService();
  final FaceVerificationService _verifier = FaceVerificationService();
  final AlertService _alertService = AlertService();
  final MultiDetectorService _multi = MultiDetectorService();

  bool _booting = true;

  // Face verify (photo-based)
  bool _processingFace = false;
  bool _autoVerify = true;
  Timer? _timer;

  String _status = 'Starting...';
  String _lastMatch = '';

  // YOLO / Smoking / Group (stream-based)
  String _smokeGroupStatus = 'People: - | Group: - | Smoking: -';
  bool _processingStream = false;
  int _frameSkip = 0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _booting = true;
      _status = 'Initializing...';
    });

    try {
      await _verifier.initialize();
      await _multi.initialize();
      await _camera.initialize(preferred: CameraLensDirection.front);

      // ✅ start stream for YOLO/group/smoke detection
      await _camera.startStream(_onFrame);

      if (!mounted) return;
      setState(() {
        _booting = false;
        _status = 'Ready';
      });

      _startAutoLoop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _status = 'Boot failed: $e';
      });
    }
  }

  // ✅ REAL-TIME FRAME HANDLER (YOLO + smoke)
  Future<void> _onFrame(CameraImage image) async {
    if (!mounted) return;
    if (_processingStream) return;
    if (!_multi.isInitialized) return;

    // ✅ process only every Nth frame to avoid lag (adjust 4~10)
    _frameSkip++;
    if (_frameSkip % 6 != 0) return;

    _processingStream = true;
    try {
      final det = await _multi.detectAll(image);
      if (!mounted) return;

      setState(() {
        _smokeGroupStatus =
            'People: ${det.personCount} | Group: ${det.groupDetected ? "YES" : "NO"} | Smoking: ${det.smokingDetected ? "YES" : "NO"}';
      });
    } catch (_) {
      // keep silent to avoid log spam
    } finally {
      _processingStream = false;
    }
  }

  void _startAutoLoop() {
    _timer?.cancel();
    if (!_autoVerify) return;

    _timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      if (_booting) return;
      if (_processingFace) return;
      await _verifyOnce();
    });
  }

  Future<void> _verifyOnce() async {
    if (_processingFace) return;

    setState(() {
      _processingFace = true;
      _status = 'Capturing face...';
    });

    try {
      // Important: taking picture pauses stream on some devices,
      // but your CameraService uses stream + takePicture together.
      // If it causes issues, we will stop stream before capture then restart.
      final shot = await _camera.takePicture();

      if (!mounted) return;
      setState(() => _status = 'Detecting face...');

      final face = await _detector.detectAndCropFaceFromFile(shot.path);

      if (!mounted) return;
      setState(() => _status = 'Verifying...');

      final result = _verifier.verifyFace(face);

      // ✅ Unknown alert (non-blocking)
      if (!result.verified) {
        final lensName =
            _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

        _alertService.createUnknownAlert(
          threshold: FaceVerificationService.threshold,
          lens: lensName,
          note: 'Unknown face detected',
        ).catchError((_) {});
      }

      if (!mounted) return;
      setState(() {
        _status = result.message;
        _lastMatch = result.verified ? (result.person?.name ?? '') : '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Verification error: $e');
    } finally {
      if (!mounted) return;
      setState(() => _processingFace = false);
    }
  }

  Future<void> _toggleCamera() async {
    try {
      setState(() => _status = 'Switching camera...');

      await _camera.stopStream();
      await _camera.switchCamera();
      await _camera.startStream(_onFrame);

      if (!mounted) return;
      setState(() => _status = 'Ready');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Camera switch failed: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _camera.dispose();
    _detector.dispose();
    _verifier.dispose();
    _multi.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Face Recognition'),
        actions: [
          IconButton(
            onPressed: _toggleCamera,
            icon: const Icon(Icons.cameraswitch),
          ),
          IconButton(
            onPressed: _processingFace ? null : _verifyOnce,
            icon: const Icon(Icons.play_arrow),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _camera.buildPreview()),
                if (_booting)
                  const Positioned.fill(
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_status),
                const SizedBox(height: 6),
                Text('Last match: $_lastMatch'),
                const SizedBox(height: 6),
                Text(_smokeGroupStatus),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Switch(
                      value: _autoVerify,
                      onChanged: (v) {
                        setState(() => _autoVerify = v);
                        _startAutoLoop();
                      },
                    ),
                    const SizedBox(width: 8),
                    const Text('Auto verify'),
                  ],
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _processingFace ? null : _verifyOnce,
                  child: Text(_processingFace ? 'Processing...' : 'Verify Now'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
