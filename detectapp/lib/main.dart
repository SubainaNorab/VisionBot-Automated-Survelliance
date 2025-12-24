import "dart:async";
import "package:flutter/material.dart";
import "package:camera/camera.dart";
import "package:firebase_core/firebase_core.dart";

import "camera.dart";
import "face_Detector.dart";
import "face_verification.dart";
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

  bool _autoScan = true;
  bool _busy = false;
  Timer? _scanTimer;

  String _status = "Starting";
  String _lastMatch = "";

  void _log(String msg) {
    print(msg);
  }

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _log("🚀 App boot started");
    try {
      setState(() => _status = "📷 Initializing camera");
      await _camera.initialize();
      _log("✅ Camera initialized");

      setState(() => _status = "🧠 Loading FaceNet model");
      await _verifier.initialize();
      _log("✅ FaceNet initialized");

      setState(() {
        _loading = false;
        _status = "✅ Ready";
      });

      _startAutoScan();
    } catch (e) {
      _log("🔥 Boot failed: $e");
      setState(() {
        _loading = false;
        _status = "❌ Init failed: $e";
      });
    }
  }

  void _startAutoScan() {
    _scanTimer?.cancel();
    if (!_autoScan) return;

    _log("🔁 Auto scan started");
    _scanTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      if (!mounted) return;
      if (_busy) return;
      await _verifyOnce();
    });
  }

  void _stopAutoScan() {
    _log("🛑 Auto scan stopped");
    _scanTimer?.cancel();
    _scanTimer = null;
  }

  Future<void> _toggleFlash() async {
    _flashOn = !_flashOn;
    await _camera.setFlash(_flashOn);
    setState(() {});
  }

  Future<void> _toggleAuto() async {
    setState(() {
      _autoScan = !_autoScan;
      _status = _autoScan ? "🔁 Auto scan ON" : "🛑 Auto scan OFF";
    });

    if (_autoScan) {
      _startAutoScan();
    } else {
      _stopAutoScan();
    }
  }

  Future<void> _reloadFaces() async {
    setState(() => _status = "📥 Reloading enrolled_faces");
    await _verifier.loadEnrolledPeople();
    setState(() => _status = "✅ Reloaded enrolled_faces");
  }

  Future<void> _verifyOnce() async {
    if (_busy) return;
    _busy = true;

    try {
      setState(() => _status = "📸 Capturing");

      final xf = await _camera.captureXFile();
      if (xf == null) {
        setState(() => _status = "❌ Capture failed");
        return;
      }

      setState(() => _status = "🙂 Detecting face");
      final face = await _faceDetector.detectAndCropFaceFromFile(xf.path);

      if (face == null) {
        setState(() {
          _status = "⚠️ No face";
          _lastMatch = "";
        });
        return;
      }

      setState(() => _status = "🧠 Verifying");
      final result = await _verifier.verifyFace(face);

      setState(() {
        _status = result.message;
        _lastMatch = result.verified ? (result.person?.name ?? "") : "";
      });
    } catch (e) {
      _log("🔥 Verify failed: $e");
      setState(() => _status = "❌ Error: $e");
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _stopAutoScan();
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
                Expanded(
                  child: Container(
                    width: double.infinity,
                    color: Colors.black,
                    child:
                        (controller != null && controller.value.isInitialized)
                            ? CameraPreview(controller)
                            : const Center(
                                child: Text(
                                  "Camera not ready",
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.grey.shade200,
                        ),
                        child: Text("Status: $_status"),
                      ),
                      const SizedBox(height: 10),
                      if (_lastMatch.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: Colors.green.shade50,
                            border: Border.all(color: Colors.green.shade200),
                          ),
                          child: Text("Matched: $_lastMatch"),
                        ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _verifyOnce,
                              child: const Text("Verify"),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _toggleAuto,
                              child: Text(_autoScan ? "Auto ON" : "Auto OFF"),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: _reloadFaces,
                        child: const Text("Reload enrolled_faces"),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
