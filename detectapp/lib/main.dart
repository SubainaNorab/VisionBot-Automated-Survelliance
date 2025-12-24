import "package:flutter/material.dart";
import "package:firebase_core/firebase_core.dart";
import "camera.dart";
import "face_Detector.dart";
import "face_verification.dart";
import "package:camera/camera.dart";
import "firebase_options.dart";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "VisionBot",
      theme: ThemeData(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final CameraService _camera = CameraService();
  final FaceDetectionService _faceDetector = FaceDetectionService();
  final FaceVerificationService _verifier = FaceVerificationService();

  bool _loading = true;
  bool _flashOn = false;
  String _status = "Starting";
  String _lastMatch = "";

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _camera.initialize();
      await _verifier.initialize();

      setState(() {
        _loading = false;
        _status = "Ready";
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _status = "Init failed: $e";
      });
    }
  }

  Future<void> _toggleFlash() async {
    _flashOn = !_flashOn;
    await _camera.setFlash(_flashOn);
    setState(() {});
  }

  Future<void> _reloadPeople() async {
    setState(() {
      _status = "Reloading";
    });
    await _verifier.loadEnrolledPeople();
    setState(() {
      _status = "Reloaded";
    });
  }

  Future<void> _verifyOnce() async {
    setState(() {
      _status = "Capturing";
    });

    final xf = await _camera.captureXFile();
    if (xf == null) {
      setState(() {
        _status = "Capture failed";
      });
      return;
    }

    setState(() {
      _status = "Detecting face";
    });

    final face = await _faceDetector.detectAndCropFaceFromFile(xf.path);
    if (face == null) {
      setState(() {
        _status = "No face detected";
        _lastMatch = "";
      });
      return;
    }

    setState(() {
      _status = "Verifying";
    });

    final result = await _verifier.verifyFace(face);

    setState(() {
      _status = result.message;
      _lastMatch = result.verified ? (result.person?.name ?? "") : "";
    });
  }

  @override
  void dispose() {
    _camera.dispose();
    _verifier.dispose();
    _faceDetector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _camera.controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text("VisionBot"),
        actions: [
          IconButton(
            onPressed: _loading ? null : _toggleFlash,
            icon: Icon(_flashOn ? Icons.flash_on : Icons.flash_off),
          ),
          IconButton(
            onPressed: _loading
                ? null
                : () async {
                    await _camera.switchCamera();
                    setState(() {});
                  },
            icon: const Icon(Icons.cameraswitch),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (controller != null && controller.value.isInitialized)
                  AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: CameraPreview(controller),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text("Camera not ready"),
                  ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _verifyOnce,
                          child: const Text("Verify now"),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _reloadPeople,
                          child: const Text("Reload people"),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(child: Text("Status: $_status")),
                    ],
                  ),
                ),
                if (_lastMatch.isNotEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(
                      children: [
                        Expanded(child: Text("Matched: $_lastMatch")),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
