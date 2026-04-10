// main.dart - FIXED UI WITH VISIBLE AUTO-VERIFY TOGGLE

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:permission_handler/permission_handler.dart';

import 'firebase_options.dart';
import 'survelliance_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  
  await _requestAllPermissions();
  
  runApp(const VisionBot());
}

Future<void> _requestAllPermissions() async {
  try {
    debugPrint('🔐 Requesting all permissions...');
    
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.storage,
      Permission.photos,
      Permission.location,   
    ].request();
    
    debugPrint('📋 Permission results:');
    statuses.forEach((permission, status) {
      debugPrint('   ${permission.toString()}: $status');
    });
    
    if (statuses[Permission.camera] != PermissionStatus.granted) {
      debugPrint('⚠️ Camera permission not granted!');
    }
    
  } catch (e) {
    debugPrint('❌ Permission request failed: $e');
  }
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

class _SurveillanceScreenState extends State<SurveillanceScreen> with WidgetsBindingObserver {
  late final SurveillanceController _controller;

  @override
  void initState() {
    super.initState();
    
    WidgetsBinding.instance.addObserver(this);
    
    _controller = SurveillanceController(groupThreshold: 1);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.initialize();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('📱 App lifecycle: $state');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
            title: const Text('VisionBot Surveillance', style: TextStyle(fontSize: 16)),
            backgroundColor: Colors.black87,
            toolbarHeight: 48,
            actions: [
              IconButton(
                onPressed: () => _showDetectionSettings(context),
                icon: const Icon(Icons.settings, size: 20),
                tooltip: 'Detection Settings',
                padding: EdgeInsets.all(8),
              ),
              IconButton(
                onPressed: _controller.switchCamera,
                icon: const Icon(Icons.cameraswitch, size: 20),
                tooltip: 'Switch Camera',
                padding: EdgeInsets.all(8),
              ),
              IconButton(
                onPressed: state.processingFace ? null : _controller.verifyFace,
                icon: const Icon(Icons.face, size: 20),
                tooltip: 'Verify Face Now',
                padding: EdgeInsets.all(8),
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
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    // Live indicator
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _LiveIndicator(),
                    ),
                    // ✅ ADDED: Auto-verify status overlay
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _controller.autoVerify ? Colors.green : Colors.grey,
                            width: 2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _controller.autoVerify ? Icons.check_circle : Icons.cancel,
                              color: _controller.autoVerify ? Colors.green : Colors.grey,
                              size: 16,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Auto: ${_controller.autoVerify ? "ON" : "OFF"}',
                              style: TextStyle(
                                color: _controller.autoVerify ? Colors.green : Colors.grey,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Status Panel
              _CompactStatusPanel(
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

  void _showDetectionSettings(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Detection Range Settings'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Adjust detection distance:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 16),
              
              ListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                title: const Text('Close Range (1-2m)', style: TextStyle(fontSize: 14)),
                subtitle: const Text('Face: 100-400px', style: TextStyle(fontSize: 11)),
                leading: const Icon(Icons.person, color: Colors.orange, size: 20),
                onTap: () {
                  _controller.setDistanceThresholds(
                    minWidth: 100,
                    maxWidth: 400,
                    idealMin: 150,
                    idealMax: 350,
                  );
                  Navigator.pop(context);
                  _showSnackbar('✅ Close range (1-2m)');
                },
              ),
              
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.green, width: 2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListTile(
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  title: const Text('Medium Range (2-4m)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  subtitle: const Text('Face: 50-500px | RECOMMENDED', style: TextStyle(fontSize: 11, color: Colors.green)),
                  leading: const Icon(Icons.groups, color: Colors.green, size: 20),
                  onTap: () {
                    _controller.setDistanceThresholds(
                      minWidth: 50,
                      maxWidth: 500,
                      idealMin: 80,
                      idealMax: 450,
                    );
                    Navigator.pop(context);
                    _showSnackbar('✅ Medium range (2-4m)');
                  },
                ),
              ),
              
              ListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                title: const Text('Long Range (3-6m)', style: TextStyle(fontSize: 14)),
                subtitle: const Text('Face: 30-600px', style: TextStyle(fontSize: 11)),
                leading: const Icon(Icons.visibility, color: Colors.blue, size: 20),
                onTap: () {
                  _controller.setDistanceThresholds(
                    minWidth: 30,
                    maxWidth: 600,
                    idealMin: 50,
                    idealMax: 550,
                  );
                  Navigator.pop(context);
                  _showSnackbar('✅ Long range (3-6m)');
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _LiveIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withOpacity(0.5), width: 1),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, color: Colors.red, size: 10),
          SizedBox(width: 4),
          Text(
            'LIVE',
            style: TextStyle(
              color: Colors.greenAccent,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactStatusPanel extends StatelessWidget {
  final SurveillanceState state;
  final bool autoVerify;
  final ValueChanged<bool> onAutoVerifyChanged;
  final VoidCallback onVerifyPressed;

  const _CompactStatusPanel({
    required this.state,
    required this.autoVerify,
    required this.onAutoVerifyChanged,
    required this.onVerifyPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Face status
          Row(
            children: [
              Icon(Icons.face, color: Colors.blueAccent, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  state.faceStatus,
                  style: TextStyle(color: Colors.blueAccent, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Detection status
          _CompactDetectionStatus(detectionStatus: state.detectionStatus),
          const SizedBox(height: 8),

          // ✅ FIXED: Make toggle MORE VISIBLE
          Row(
            children: [
              // Toggle with label
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: autoVerify ? Colors.green.withOpacity(0.2) : Colors.grey.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: autoVerify ? Colors.green : Colors.grey,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.scale(
                      scale: 1.0,  // ✅ Normal size (was 0.8)
                      child: Switch(
                        value: autoVerify,
                        onChanged: onAutoVerifyChanged,
                        activeColor: Colors.green,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Auto Verify',
                      style: TextStyle(
                        color: autoVerify ? Colors.green : Colors.grey,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,  // ✅ Larger text
                      ),
                    ),
                  ],
                ),
              ),
              
              const Spacer(),
              
              // Manual verify button
              SizedBox(
                height: 40,  // ✅ Taller button
                child: ElevatedButton.icon(
                  onPressed: state.processingFace ? null : onVerifyPressed,
                  icon: const Icon(Icons.face, size: 16),
                  label: Text(
                    state.processingFace ? 'Processing...' : 'Verify Now',
                    style: TextStyle(fontSize: 12),
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    visualDensity: VisualDensity.comfortable,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompactDetectionStatus extends StatelessWidget {
  final String detectionStatus;

  const _CompactDetectionStatus({required this.detectionStatus});

  @override
  Widget build(BuildContext context) {
    final parts = detectionStatus.split('|').map((e) => e.trim()).toList();
    
    String peoplePart = '';
    String groupPart = '';
    String smokePart = '';
    
    for (final part in parts) {
      if (part.startsWith('People:')) {
        peoplePart = part;
      } else if (part.startsWith('Group:')) {
        groupPart = part;
      } else if (part.startsWith('Smoke:')) {
        smokePart = part;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.orangeAccent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (peoplePart.isNotEmpty)
            Text(
              peoplePart,
              style: TextStyle(color: Colors.orangeAccent, fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          
          const SizedBox(height: 2),
          
          Row(
            children: [
              if (groupPart.isNotEmpty)
                Expanded(
                  child: Text(
                    groupPart,
                    style: TextStyle(
                      color: groupPart.contains('YES') 
                          ? Colors.redAccent 
                          : Colors.grey,
                      fontSize: 9,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              if (smokePart.isNotEmpty)
                Expanded(
                  child: Text(
                    smokePart,
                    style: TextStyle(
                      color: smokePart.contains('YES') 
                          ? Colors.redAccent 
                          : Colors.grey,
                      fontSize: 9,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}