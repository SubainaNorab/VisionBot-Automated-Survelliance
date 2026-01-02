// main.dart with alert integration

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';

import 'camera.dart';
import 'face_detector.dart';
import 'face_verification.dart';
import 'firebase_options.dart';
import 'alert_service.dart';

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
  final AlertService _alertService = AlertService(); // ← ADD THIS LINE

  bool _booting = true;
  bool _processing = false;

  bool _autoVerify = true;
  Timer? _timer;

<<<<<<< HEAD
=======
  // double _threshold = FaceVerificationService.defaultThreshold;

>>>>>>> bd8890b140c39af11933fb94682dd474b101df7c
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
      _status = 'Initializing... ';
    });

    try {
      await _verifier.initialize();
      await _camera.initialize(preferred: CameraLensDirection.front);

      setState(() {
        _booting = false;
        _status = 'Ready';
      });

      _startAutoLoop();
      print('✅ App initialized successfully');
    } catch (e) {
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

  // ========== THIS IS THE UPDATED METHOD ==========
  Future<void> _verifyOnce() async {
    setState(() {
      _processing = true;
      _status = 'Capturing... ';
    });

    try {
      final shot = await _camera.takePicture();

      setState(() {
        _status = 'Detecting face...';
      });

      final face = await _detector.detectAndCropFaceFromFile(shot.path);

      setState(() {
        _status = 'Verifying...';
      });

<<<<<<< HEAD
      // Your original verification call
      final result = _verifier.verifyFace(face);

      // ========== ALERT INTEGRATION - ADDED HERE ==========
      if (!result.verified) {
        // Get camera lens direction
        final lensName =
            _camera.lensDirection == CameraLensDirection.front
                ? 'front'
                : 'back';

        // Send alert to Firebase
        try {
          await _alertService.createUnknownAlert(
            distance: 0.0, // Your original result doesn't have this
            threshold: FaceVerificationService.threshold,
            lens: lensName,
            bestCandidate: '', // Your original result doesn't have this
            enrolledCount: 0, // Your original doesn't expose this
            note: 'Unknown face detected: ${result.message}',
          );

          print('🚨 Alert sent to Firebase:  Unknown face detected! ');
        } catch (alertError) {
          print('⚠️ Failed to send alert:  $alertError');
        }
      } else {
        print('✅ Verified:  ${result.person?.name}');
      }
      // ====================================================
=======
      final result = await _verifier.verifyFace(face);
>>>>>>> bd8890b140c39af11933fb94682dd474b101df7c

      setState(() {
        _status = result.message;
        _lastMatch = result.verified ? (result.person?.name ?? '') : '';
      });

      print(result.toString());
    } catch (e) {
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
  // =================================================

  Future<void> _toggleCamera() async {
    try {
      setState(() {
        _status = 'Switching camera... ';
      });
      await _camera.switchCamera();
      setState(() {
        _status = 'Ready';
      });
    } catch (e) {
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

<<<<<<< HEAD
=======
                // Text('Threshold: ${_threshold.toStringAsFixed(2)}'),
                // Slider(
                //   min: 0.60,
                //   max: 1.20,
                //   divisions: 60,
                //   value: _threshold,
                //   onChanged: (v) {
                //     setState(() {
                //       _threshold = v;
                //     });
                //   },
                // ),
                const SizedBox(height: 8),
>>>>>>> bd8890b140c39af11933fb94682dd474b101df7c
                ElevatedButton(
                  onPressed: _processing ? null : _verifyOnce,
                  child: Text(_processing ? 'Processing.. .' : 'Verify Now'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
