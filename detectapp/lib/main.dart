// lib/main.dart (CLEAN - UI only)

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'survelliance_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const VisionBot());
}

class VisionBot extends StatelessWidget {
  const VisionBot({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VisionBot Surveillance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const SurveillanceScreen(),
    );
  }
}

class SurveillanceScreen extends StatefulWidget {
  const SurveillanceScreen({super.key});

  @override
  State<SurveillanceScreen> createState() => _SurveillanceScreenState();
}

class _SurveillanceScreenState extends State<SurveillanceScreen> {
  late final SurveillanceController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SurveillanceController(groupThreshold: 1);
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SurveillanceState>(
      stream: _controller.stateStream,
      initialData: _controller.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? _controller.currentState;

        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: const Text('VisionBot Surveillance'),
            backgroundColor: Colors.black87,
            actions: [
              // Group threshold indicator
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: Text(
                    'Group: 1+',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ),
              // Switch camera
              IconButton(
                onPressed: _controller.switchCamera,
                icon: const Icon(Icons.cameraswitch),
                tooltip: 'Switch Camera',
              ),
              // Manual verify
              IconButton(
                onPressed: state.processingFace ? null : _controller.verifyFace,
                icon: const Icon(Icons.face),
                tooltip: 'Verify Face Now',
              ),
            ],
          ),
          body: Column(
            children: [
              // Camera Preview
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _controller.camera.buildPreview()),
                    if (state.isBooting)
                      const Positioned.fill(
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    // Live indicator
                    Positioned(
                      top: 16,
                      right: 16,
                      child: _LiveIndicator(),
                    ),
                  ],
                ),
              ),

              // Status Panel
              _StatusPanel(
                state: state,
                autoVerify: _controller.autoVerify,
                onAutoVerifyChanged: _controller.setAutoVerify,
                onVerifyPressed: _controller.verifyFace,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ========================
// UI COMPONENTS
// ========================

class _LiveIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          color: Colors.greenAccent,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  final SurveillanceState state;
  final bool autoVerify;
  final ValueChanged<bool> onAutoVerifyChanged;
  final VoidCallback onVerifyPressed;

  const _StatusPanel({
    required this.state,
    required this.autoVerify,
    required this.onAutoVerifyChanged,
    required this.onVerifyPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Face status
          _StatusRow(
            icon: Icons.face,
            label: 'Face:',
            value: state.faceStatus,
            color: Colors.blueAccent,
          ),
          const SizedBox(height: 8),

          // Last match
          _StatusRow(
            icon: Icons.person,
            label: 'Match:',
            value: state.lastMatch.isEmpty ? 'None' : state.lastMatch,
            color: Colors.greenAccent,
          ),
          const SizedBox(height: 8),

          // Detection status
          _StatusRow(
            icon: Icons.people,
            label: 'Detection:',
            value: state.detectionStatus,
            color: Colors.orangeAccent,
          ),
          const SizedBox(height: 16),

          // Auto verify toggle
          Row(
            children: [
              Switch(
                value: autoVerify,
                onChanged: onAutoVerifyChanged,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Auto verify face (every 3s)',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Manual verify button
          ElevatedButton.icon(
            onPressed: state.processingFace ? null : onVerifyPressed,
            icon: const Icon(Icons.face),
            label: Text(state.processingFace ? 'Processing...' : 'Verify Face Now'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatusRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}