// main.dart with simplified alerts + smoke/group detection

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:image/image.dart' as img;

import 'camera.dart';
import 'face_detector.dart';
import 'face_verification.dart';
import 'firebase_options.dart';
import 'alert_service.dart';
import 'sm_grp.dart'; // ✅ ADDED

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

  final MultiDetectorService _multi = MultiDetectorService(); // ✅ ADDED

  bool _booting = true;
  bool _processing = false;

  bool _autoVerify = true;
  Timer? _timer;

  String _status = 'Starting...';
  String _lastMatch = '';

  // ✅ ADDED: show smoke/group result in UI
  String _smokeGroupStatus = '';

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
      await _multi.initialize(); // ✅ ADDED
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

  Future<void> _verifyOnce() async {
    setState(() {
      _processing = true;
      _status = 'Capturing... ';
    });

    try {
      final shot = await _camera.takePicture();

      // ✅ ADDED: run smoke/group on SAME captured image (non-breaking)
      try {
        final bytes = await shot.readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded != null && _multi.isInitialized) {
          final det = await _multi.detectAllFromImage(decoded);
          setState(() {
            _smokeGroupStatus =
                'People: ${det.personCount} | Group: ${det.groupDetected ? "YES" : "NO"} | Smoking: ${det.smokingDetected ? "YES" : "NO"}';
          });
          print('🧯👥 $det');
        } else {
          setState(() => _smokeGroupStatus = 'Smoke/Group: image decode failed');
        }
      } catch (e) {
        setState(() => _smokeGroupStatus = 'Smoke/Group error: $e');
      }

      setState(() {
        _status = 'Detecting face...';
      });

      final face = await _detector.detectAndCropFaceFromFile(shot.path);

      setState(() {
        _status = 'Verifying...';
      });

      final result = _verifier.verifyFace(face);

      // ========== NON-BLOCKING ALERT (UNKNOWN FACE ONLY) ==========
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

  Future<void> _toggleCamera() async {
    try {
      setState(() {
        _status = 'Switching camera...';
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
    _multi.dispose(); // ✅ ADDED
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
                const SizedBox(height: 6),
                Text(_smokeGroupStatus), // ✅ ADDED
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
