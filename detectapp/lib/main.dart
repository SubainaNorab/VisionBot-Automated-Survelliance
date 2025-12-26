import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:camera/camera.dart';

import 'camera.dart';
import 'face_detector.dart';
import 'face_verification.dart';
import 'model/person.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ignore: avoid_print
  print('🔥 Initializing Firebase...');
  await Firebase.initializeApp();
  // ignore: avoid_print
  print('✅ Firebase initialized');

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Car Face Recognition',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const FaceRecognitionScreen(),
    );
  }
}

class FaceRecognitionScreen extends StatefulWidget {
  const FaceRecognitionScreen({Key? key}) : super(key: key);

  @override
  _FaceRecognitionScreenState createState() => _FaceRecognitionScreenState();
}

class _FaceRecognitionScreenState extends State<FaceRecognitionScreen> {
  final CameraService _cameraService = CameraService();
  final FaceVerificationService _verificationService =
      FaceVerificationService();

  bool _isInitialized = false;
  bool _isProcessing = false;
  String _status = 'Initializing...';
  Color _statusColor = Colors.orange;

  Person? _verifiedPerson;
  double _confidence = 0.0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      setState(() {
        _status = 'Loading Face Recognition Model...';
      });

      await _verificationService.initialize();

      setState(() {
        _status = 'Starting Camera...';
      });

      await _cameraService.initialize();

      setState(() {
        _isInitialized = true;
        _status =
            'Ready. ${_verificationService.enrolledCount} people enrolled';
        _statusColor = Colors.green;
      });

      // ignore: avoid_print
      print('✅ App initialized successfully');
    } catch (e) {
      setState(() {
        _status = 'Initialization Error: $e';
        _statusColor = Colors.red;
      });

      // ignore: avoid_print
      print('❌ Initialization failed: $e');
    }
  }

  Future<void> _verifyFace() async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _status = 'Capturing image...';
      _statusColor = Colors.blue;
      _verifiedPerson = null;
      _confidence = 0.0;
    });

    try {
      final imageFile = await _cameraService.captureImage();
      if (imageFile == null) {
        throw Exception('Failed to capture image');
      }

      setState(() {
        _status = 'Detecting face...';
      });

      final face = await FaceDetectionService.detectAndCropFaceAsync(imageFile);
      if (face == null) {
        throw Exception('No face detected in image');
      }

      setState(() {
        _status = 'Verifying identity...';
      });

      final result = _verificationService.verifyFace(face);

      setState(() {
        _isProcessing = false;
        _confidence = result.confidence;

        if (result.verified) {
          _verifiedPerson = result.person;
          _status = '✅ ${result.message}';
          _statusColor = Colors.green;
        } else {
          _verifiedPerson = null;
          _status = '❌ ${result.message}';
          _statusColor = Colors.red;
        }
      });

      // ignore: avoid_print
      print(result);
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _status = 'Error: $e';
        _statusColor = Colors.red;
      });

      // ignore: avoid_print
      print('❌ Verification error: $e');
    }
  }

  Future<void> _reloadEnrolledPeople() async {
    setState(() {
      _status = 'Reloading enrolled people...';
      _statusColor = Colors.orange;
    });

    try {
      await _verificationService.loadEnrolledPeople();

      setState(() {
        _status =
            'Ready. ${_verificationService.enrolledCount} people enrolled';
        _statusColor = Colors.green;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Reloaded ${_verificationService.enrolledCount} enrolled people',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      setState(() {
        _status = 'Reload failed: $e';
        _statusColor = Colors.red;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Car Face Recognition System',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isInitialized ? _reloadEnrolledPeople : null,
            tooltip: 'Reload enrolled people',
          ),
        ],
      ),
      body:
          !_isInitialized
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _status,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
              : Column(
                children: [
                  Expanded(
                    child:
                        _cameraService.controller != null
                            ? Stack(
                              children: [
                                CameraPreview(_cameraService.controller!),
                                Center(
                                  child: Container(
                                    width: 250,
                                    height: 250,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: _statusColor,
                                        width: 3,
                                      ),
                                      borderRadius: BorderRadius.circular(125),
                                    ),
                                  ),
                                ),
                              ],
                            )
                            : const Center(
                              child: Text(
                                'Camera unavailable',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: _statusColor.withOpacity(0.9),
                      boxShadow: [
                        BoxShadow(
                          color: _statusColor.withOpacity(0.3),
                          blurRadius: 10,
                          offset: const Offset(0, -5),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Text(
                          _status,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (_verifiedPerson != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Person ID: ${_verifiedPerson!.id}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Confidence: ${(_confidence * 100).toStringAsFixed(1)}%',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          height: 70,
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing ? null : _verifyFace,
                            icon:
                                _isProcessing
                                    ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              Colors.white,
                                            ),
                                      ),
                                    )
                                    : const Icon(Icons.face_rounded, size: 32),
                            label: Text(
                              _isProcessing ? 'Processing...' : 'Verify Face',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${_verificationService.enrolledCount} people enrolled',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
    );
  }

  @override
  void dispose() {
    _cameraService.dispose();
    _verificationService.dispose();
    FaceDetectionService.dispose();
    super.dispose();
  }
}
