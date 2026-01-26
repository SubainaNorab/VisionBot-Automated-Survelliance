// main.dart with simplified alerts + sm_grp stub integration

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';

import 'camera.dart';
import 'face_detector.dart';
import 'face_verification.dart';
import 'firebase_options.dart';
import 'alert_service.dart';
import 'sm_grp.dart'; // ✅ add this

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  print('Initializing Firebase...');
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  print('✅ Firebase initialized');

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

  // ✅ NEW
  final MultiDetectorService _multi = MultiDetectorService();
  DetectionResult? _lastDetections;

  bool _booting = true;
  bool _processing = false;

  bool _autoVerify = true;
  Timer? _timer;

  String _status = 'Starting...';
  String _lastMatch = '';

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
      await _multi.initialize(); // ✅ init stub detector
      await _camera.initialize(preferred: CameraLensDirection.front);

      if (!mounted) return;

      setState(() {
        _booting = false;
        _status = 'Ready';
      });

      _startAutoLoop();
      print('✅ App initialized successfully');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _status = 'Boot failed: $e';
      });
      print('❌ Boot failed: $e');
    }
  }

  void _startAutoLoop() {
    _timer?.cancel();
    if (!_autoVerify) return;

    _timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      if (_booting) return;
      if (_processing) return;
      await _verifyOnce();
    });
  }

  Future<void> _verifyOnce() async {
    setState(() {
      _processing = true;
      _status = 'Capturing...';
    });

    try {
      final shot = await _camera.takePicture();

      if (!mounted) return;
      setState(() {
        _status = 'Detecting face...';
      });

      final face = await _detector.detectAndCropFaceFromFile(shot.path);

      if (!mounted) return;
      setState(() {
        _status = 'Verifying...';
      });

      final result = _verifier.verifyFace(face);

      // ✅ OPTIONAL: run sm/group stub after verification (non-breaking)
      // NOTE: Stub needs CameraImage; we don't have it from takePicture().
      // So for now we just keep stub initialized and show "not available".
      // Later, when you switch to startImageStream, we’ll pass real frames here.

      // ========== NON-BLOCKING ALERT (UNKNOWN FACE) ==========
      if (!result.verified) {
        final lensName =
            _camera.lensDirection == CameraLensDirection.front ? 'front' : 'back';

        _alertService
            .createUnknownAlert(
              threshold: FaceVerificationService.threshold,
              lens: lensName,
              note: 'Unknown face detected',
            )
            .then((_) => print('🚨 Alert sent to Firebase'))
            .catchError((error) => print('⚠️ Alert send failed: $error'));

        print('🚨 Alert queued (background)');
      } else {
        print('✅ Verified: ${result.person?.name}');
      }
      // =====================================================

      if (!mounted) return;
      setState(() {
        _status = result.message;
        _lastMatch = result.verified ? (result.person?.name ?? '') : '';
      });

      print(result.toString());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Verification error: $e';
      });
      print('❌ Verification error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
        });
      }
    }
  }

  Future<void> _toggleCamera() async {
    try {
      setState(() {
        _status = 'Switching camera...';
      });
      await _camera.switchCamera();
      if (!mounted) return;
      setState(() {
        _status = 'Ready';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Camera switch failed: $e';
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _camera.dispose();
    _detector.dispose();
    _verifier.dispose();
    _multi.dispose(); // ✅ NEW
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final det = _lastDetections;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Face Recognition'),
        actions: [
          IconButton(
            onPressed: _toggleCamera,
            icon: const Icon(Icons.cameraswitch),
          ),
          IconButton(
            onPressed: _processing ? null : _verifyOnce,
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

                // ✅ NEW: show smoke/group/person status (stub for now)
                Text(
                  det == null
                      ? 'Smoke/Group: (not running yet — needs camera stream)'
                      : 'Smoke: ${det.smokingDetected} | Group: ${det.groupDetected} | People: ${det.personCount}',
                ),

                const SizedBox(height: 12),

                Row(
                  children: [
                    Switch(
                      value: _autoVerify,
                      onChanged: (v) {
                        setState(() {
                          _autoVerify = v;
                        });
                        _startAutoLoop();
                      },
                    ),
                    const SizedBox(width: 8),
                    const Text('Auto verify'),
                  ],
                ),

                const SizedBox(height: 8),

                ElevatedButton(
                  onPressed: _processing ? null : _verifyOnce,
                  child: Text(_processing ? 'Processing...' : 'Verify Now'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
