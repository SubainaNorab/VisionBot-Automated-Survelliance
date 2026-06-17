// main.dart - Hybrid Detection System with Complete Optimizations

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';

import 'firebase_options.dart';
<<<<<<< HEAD
import 'supabase_service.dart';
=======
import 'geojson_map_view.dart';
>>>>>>> origin/hadia
import 'survelliance_controller.dart';
import 'custom_app_bar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
<<<<<<< HEAD
  
  debugPrint('');
  debugPrint('╔═══════════════════════════════════╗');
  debugPrint('║  VisionBot - Loading Credentials   ║');
  debugPrint('╚═══════════════════════════════════╝');
  debugPrint('');

  try {
    // ✅ Step 1: Load .env file
    debugPrint('1️⃣ Loading environment variables...');
    await dotenv.load(fileName: ".env");
    debugPrint('   ✅ Environment loaded');

    // ✅ Step 2: Get Supabase credentials from .env
    debugPrint('');
    debugPrint('2️⃣ Reading Supabase credentials...');
    
    final supabaseUrl = dotenv.env['SUPABASE_URL'];
    final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];

    if (supabaseUrl == null || supabaseAnonKey == null) {
      throw Exception(
        '❌ Missing Supabase credentials!\n'
        '   Please create .env file with SUPABASE_URL and SUPABASE_ANON_KEY\n'
        '   See .env.example for template'
      );
    }

    debugPrint('   ✅ Credentials loaded securely');
    debugPrint('   URL: ${supabaseUrl.substring(0, 20)}...');

    // ✅ Step 3: Initialize Firebase
    debugPrint('');
    debugPrint('3️⃣ Initializing Firebase...');
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('   ✅ Firebase ready');

    // ✅ Step 4: Initialize Supabase with loaded credentials
    debugPrint('');
    debugPrint('4️⃣ Initializing Supabase Storage...');
    await SupabaseService.initialize(
      supabaseUrl: supabaseUrl,
      supabaseAnonKey: supabaseAnonKey,
    );
    debugPrint('   ✅ Supabase ready');

    // ✅ Step 5: Request Permissions
    debugPrint('');
    debugPrint('5️⃣ Requesting permissions...');
    await _requestAllPermissions();
    debugPrint('   ✅ Permissions handled');

    debugPrint('');
    debugPrint('╔═══════════════════════════════════╗');
    debugPrint('║   App Ready - Starting VisionBot   ║');
    debugPrint('║      HYBRID DETECTION MODE 🚀      ║');
    debugPrint('╚═══════════════════════════════════╝');
    debugPrint('');

    runApp(const VisionBot());
  } catch (e, st) {
    debugPrint('');
    debugPrint('╔��══════════════════════════════════╗');
    debugPrint('║  ❌ STARTUP FAILED                 ║');
    debugPrint('╚═══════════════════════════════════╝');
    debugPrint('');
    debugPrint('❌ Error: $e');
    debugPrint('   Stack: $st');
    debugPrint('');
    runApp(ErrorApp(error: e.toString()));
  }
}

Future<void> _requestAllPermissions() async {
  try {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.storage,
      Permission.photos,
      Permission.location,
    ].request();
    
    debugPrint('📋 Permission Results:');
    statuses.forEach((permission, status) {
      final emoji = status.isGranted ? '✅' : '⚠️';
      debugPrint('   $emoji ${permission.toString().split('.').last}: $status');
    });
    
  } catch (e) {
    debugPrint('❌ Permission request failed: $e');
=======

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await _requestAllPermissions();

  runApp(const VisionBot());
}

Future<void> _requestAllPermissions() async {
  debugPrint('🔐 Requesting permissions...');

  Future<void> one(Permission p) async {
    try {
      final status = await p.request();
      debugPrint('   ${p.toString().split('.').last}: $status');
    } catch (e) {
      debugPrint('   ${p.toString().split('.').last}: failed ($e)');
    }
  }

  await one(Permission.camera);
  await one(Permission.locationWhenInUse);
  await one(Permission.storage);
  await one(Permission.photos);
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await one(Permission.bluetoothScan);
    await one(Permission.bluetoothConnect);
>>>>>>> origin/hadia
  }
}

class VisionBot extends StatelessWidget {
  const VisionBot({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VisionBot Surveillance',
      debugShowCheckedModeBanner: false,
<<<<<<< HEAD
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.orange,
      ),
=======
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      routes: {'/debug/geojson-map': (_) => const GeoJSONMapView()},
>>>>>>> origin/hadia
      home: const SurveillanceScreen(),
    );
  }
}

class SurveillanceScreen extends StatefulWidget {
  const SurveillanceScreen({super.key});

  @override
  State<SurveillanceScreen> createState() => _SurveillanceScreenState();
}

<<<<<<< HEAD
class _SurveillanceScreenState extends State<SurveillanceScreen> 
    with WidgetsBindingObserver {
  late final SurveillanceController _controller;
  
  // ✅ Optimization: Cache last state to avoid unnecessary rebuilds
  late SurveillanceState _lastState;
=======
class _SurveillanceScreenState extends State<SurveillanceScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final SurveillanceController _controller;
  late final TabController _tabController;

  /// Map widget mounts only after the camera image stream is stopped (Android stability).
  bool _mapContentReady = false;
>>>>>>> origin/hadia

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onMainTabChanged);

    _controller = SurveillanceController(groupThreshold: 1);
<<<<<<< HEAD
    _lastState = _controller.currentState;
    
=======

>>>>>>> origin/hadia
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controller.initialize();
      }
    });
  }

  void _onMainTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == 1) {
      _prepareMapTab();
    } else {
      _prepareSurveillanceTab();
    }
  }

  Future<void> _prepareMapTab() async {
    if (!mounted) return;
    setState(() => _mapContentReady = false);
    await _controller.pauseForMapTab();
    if (!mounted || _tabController.index != 1) return;
    setState(() => _mapContentReady = true);
  }

  Future<void> _prepareSurveillanceTab() async {
    if (!mounted) return;
    setState(() => _mapContentReady = false);
    await _controller.resumeFromMapTab();
    if (!mounted || _tabController.index != 0) return;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('📱 App lifecycle: $state');
    
    // ✅ Optimization: Pause camera on app suspend
    if (state == AppLifecycleState.paused) {
      _controller.setAutoVerify(false);
      debugPrint('⏸️ Auto-verify paused');
    } else if (state == AppLifecycleState.resumed) {
      _controller.setAutoVerify(true);
      debugPrint('▶️ Auto-verify resumed');
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onMainTabChanged);
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SurveillanceState>(
      stream: _controller.stateStream,
      initialData: _controller.currentState,
      // ✅ Optimization: Use buildWhen to avoid rebuilds
      builder: (context, snapshot) {
        final state = snapshot.data ?? _controller.currentState;
        _lastState = state;

        return Scaffold(
          backgroundColor: Colors.black,
<<<<<<< HEAD
          appBar: AppBar(
            title: const Text(
              'VisionBot Surveillance',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            backgroundColor: Colors.black87,
            toolbarHeight: 48,
            elevation: 0,
            actions: [
              IconButton(
                onPressed: () => _showDetectionSettings(context),
                icon: const Icon(Icons.settings, size: 20),
                tooltip: 'Detection Settings',
                padding: const EdgeInsets.all(8),
              ),
              IconButton(
                onPressed: _controller.switchCamera,
                icon: const Icon(Icons.cameraswitch, size: 20),
                tooltip: 'Switch Camera',
                padding: const EdgeInsets.all(8),
              ),
              IconButton(
                onPressed: state.processingFace ? null : _controller.verifyFace,
                icon: const Icon(Icons.face, size: 20),
                tooltip: 'Verify Face Now',
                padding: const EdgeInsets.all(8),
              ),
            ],
          ),
          body: Column(
            children: [
              // ✅ Camera Preview with optimized stack
              Expanded(
                child: Stack(
                  children: [
                    // Camera feed
                    Positioned.fill(
                      child: _controller.camera.buildPreview(),
                    ),
                    
                    // ✅ Loading indicator
                    if (state.isBooting)
                      const Positioned.fill(
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    
                    // ✅ Live indicator (top right)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _buildLiveIndicator(),
                    ),
                    
                    // ✅ Auto-verify status (top left)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _buildAutoVerifyStatus(),
=======
          appBar: VisionBotAppBar(
            tabController: _tabController,
            onSettingsPressed: () => _showDetectionSettings(context),
            onSwitchCameraPressed: _controller.switchCamera,
            onVerifyFacePressed: _controller.verifyFace,
            isProcessingFace: state.processingFace,
          ),
          // TabBarView keeps every child alive → camera + Google Map often crash Android.
          // Show exactly one heavy surface at a time; pause camera before mounting the map.
          body: AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              final onLocation = _tabController.index == 1;
              if (!onLocation) {
                return Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: _controller.camera.buildPreview(),
                          ),
                          if (state.isBooting)
                            const Positioned.fill(
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          Positioned(
                              top: 8, right: 8, child: _LiveIndicator()),
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: _controller.autoVerify
                                      ? Colors.green
                                      : Colors.grey,
                                  width: 2,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _controller.autoVerify
                                        ? Icons.check_circle
                                        : Icons.cancel,
                                    color: _controller.autoVerify
                                        ? Colors.green
                                        : Colors.grey,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Auto: ${_controller.autoVerify ? "ON" : "OFF"}',
                                    style: TextStyle(
                                      color: _controller.autoVerify
                                          ? Colors.green
                                          : Colors.grey,
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
>>>>>>> origin/hadia
                    ),
                    _CompactStatusPanel(
                      state: state,
                      autoVerify: _controller.autoVerify,
                      onAutoVerifyChanged: _controller.setAutoVerify,
                      onVerifyPressed: _controller.verifyFace,
                    ),
                  ],
<<<<<<< HEAD
                ),
              ),

              // ✅ Optimized status panel
              _buildStatusPanel(state),
            ],
=======
                );
              }
              if (!_mapContentReady) {
                return const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text(
                        'Preparing map…',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                );
              }
              return const GeoJSONMapView();
            },
>>>>>>> origin/hadia
          ),
        );
      },
    );
  }

  // ✅ Extracted widget for live indicator
  Widget _buildLiveIndicator() {
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

  // ✅ Extracted widget for auto-verify status
  Widget _buildAutoVerifyStatus() {
    final isOn = _controller.autoVerify;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isOn ? Colors.green : Colors.grey,
          width: 2,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isOn ? Icons.check_circle : Icons.cancel,
            color: isOn ? Colors.green : Colors.grey,
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(
            'Auto: ${isOn ? "ON" : "OFF"}',
            style: TextStyle(
              color: isOn ? Colors.green : Colors.grey,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ✅ Extracted widget for status panel
  Widget _buildStatusPanel(SurveillanceState state) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ✅ Face verification status
          Row(
            children: [
              Icon(Icons.face, color: Colors.blueAccent, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  state.faceStatus,
                  style: const TextStyle(
                    color: Colors.blueAccent,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ✅ HYBRID Detection Display
          _HybridDetectionDisplay(
            yoloPeopleCount: state.yoloPeopleCount,
            verifiedPeopleCount: state.verifiedPeopleCount,
            knownCount: state.knownPeopleCount,
            unknownCount: state.unknownPeopleCount,
            groupDetected: state.groupDetected,
            smokingDetected: state.smokingDetected,
          ),
          const SizedBox(height: 8),

          // ✅ Auto verify toggle + Manual verify button
          Row(
            children: [
              _buildAutoVerifyToggle(),
              const Spacer(),
              _buildVerifyButton(state),
            ],
          ),
        ],
      ),
    );
  }

  // ✅ Extracted auto-verify toggle
  Widget _buildAutoVerifyToggle() {
    final isOn = _controller.autoVerify;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isOn
            ? Colors.green.withOpacity(0.2)
            : Colors.grey.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isOn ? Colors.green : Colors.grey,
          width: 2,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: isOn,
            onChanged: _controller.setAutoVerify,
            activeColor: Colors.green,
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
          const SizedBox(width: 8),
          Text(
            'Auto Verify',
            style: TextStyle(
              color: isOn ? Colors.green : Colors.grey,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ✅ Extracted verify button
  Widget _buildVerifyButton(SurveillanceState state) {
    return SizedBox(
      height: 36,
      child: ElevatedButton.icon(
        onPressed: state.processingFace ? null : _controller.verifyFace,
        icon: const Icon(Icons.face, size: 14),
        label: Text(
          state.processingFace ? 'Processing...' : 'Verify',
          style: const TextStyle(fontSize: 11),
        ),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          visualDensity: VisualDensity.comfortable,
        ),
      ),
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
                'Adjust face detection distance:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 16),
<<<<<<< HEAD
              
              // ✅ Close Range
=======
>>>>>>> origin/hadia
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                title: const Text(
                  'Close Range (1-2m)',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: const Text(
                  'Face: 100-400px',
                  style: TextStyle(fontSize: 11),
                ),
                leading: const Icon(
                  Icons.person,
                  color: Colors.orange,
                  size: 20,
                ),
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
<<<<<<< HEAD
              
              // ✅ Medium Range (Recommended)
=======
>>>>>>> origin/hadia
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.green, width: 2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListTile(
<<<<<<< HEAD
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
=======
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
>>>>>>> origin/hadia
                  title: const Text(
                    'Medium Range (2-4m)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Face: 50-500px | RECOMMENDED',
                    style: TextStyle(fontSize: 11, color: Colors.green),
                  ),
<<<<<<< HEAD
                  leading: const Icon(Icons.groups, color: Colors.green, size: 20),
=======
                  leading: const Icon(
                    Icons.groups,
                    color: Colors.green,
                    size: 20,
                  ),
>>>>>>> origin/hadia
                  onTap: () {
                    _controller.setDistanceThresholds(
                      minWidth: 50,
                      maxWidth: 500,
                      idealMin: 80,
                      idealMax: 450,
                    );
                    Navigator.pop(context);
                    _showSnackbar('✅ Medium range (2-4m) - RECOMMENDED');
                  },
                ),
              ),
<<<<<<< HEAD
              
              const SizedBox(height: 8),
              
              // ✅ Long Range
=======
>>>>>>> origin/hadia
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                title: const Text(
                  'Long Range (3-6m)',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: const Text(
                  'Face: 30-600px',
                  style: TextStyle(fontSize: 11),
                ),
                leading: const Icon(
                  Icons.visibility,
                  color: Colors.blue,
                  size: 20,
                ),
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
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }
}

<<<<<<< HEAD
// ✅ HYBRID Detection Display Widget
class _HybridDetectionDisplay extends StatelessWidget {
  final int yoloPeopleCount;
  final int verifiedPeopleCount;
  final int knownCount;
  final int unknownCount;
=======
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
          // Face verification status
          Row(
            children: [
              const Icon(Icons.face, color: Colors.blueAccent, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  state.faceStatus,
                  style: const TextStyle(
                    color: Colors.blueAccent,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ✅ YOLO Detection status (People + Group + Smoke)
          _YoloDetectionDisplay(
            peopleCount: state.peopleCount,
            groupDetected: state.groupDetected,
            smokingDetected: state.smokingDetected,
          ),
          const SizedBox(height: 8),

          // Auto verify toggle
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: autoVerify
                      ? Colors.green.withOpacity(0.2)
                      : Colors.grey.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: autoVerify ? Colors.green : Colors.grey,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: autoVerify,
                      onChanged: onAutoVerifyChanged,
                      activeThumbColor: Colors.green,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Auto Verify',
                      style: TextStyle(
                        color: autoVerify ? Colors.green : Colors.grey,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // Manual verify button
              SizedBox(
                height: 36,
                child: ElevatedButton.icon(
                  onPressed: state.processingFace ? null : onVerifyPressed,
                  icon: const Icon(Icons.face, size: 14),
                  label: Text(
                    state.processingFace ? 'Processing...' : 'Verify',
                    style: const TextStyle(fontSize: 11),
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
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

class _YoloDetectionDisplay extends StatelessWidget {
  final int peopleCount;
>>>>>>> origin/hadia
  final bool groupDetected;
  final bool smokingDetected;

  const _HybridDetectionDisplay({
    required this.yoloPeopleCount,
    required this.verifiedPeopleCount,
    required this.knownCount,
    required this.unknownCount,
    required this.groupDetected,
    required this.smokingDetected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.orangeAccent.withOpacity(0.5),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ✅ HYBRID: Show both YOLO and verified counts
          Row(
            children: [
              const Icon(Icons.people, color: Colors.orangeAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'YOLO: $yoloPeopleCount | Verified: $verifiedPeopleCount',
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    if (verifiedPeopleCount > 0)
                      Text(
                        '($knownCount known + $unknownCount unknown)',
                        style: const TextStyle(
                          color: Colors.orange,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ✅ Group + Smoke status
          Row(
            children: [
              // Group detection: YOLO + FACE
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: groupDetected
                        ? Colors.red.withOpacity(0.2)
                        : Colors.grey.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: groupDetected ? Colors.redAccent : Colors.grey,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.groups,
                        color: groupDetected ? Colors.redAccent : Colors.grey,
                        size: 16,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          groupDetected ? 'Group: YES' : 'Group: NO',
                          style: TextStyle(
                            color: groupDetected ? Colors.redAccent : Colors.grey,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // Smoking detection
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: smokingDetected
                        ? Colors.red.withOpacity(0.2)
                        : Colors.grey.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: smokingDetected ? Colors.redAccent : Colors.grey,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.smoke_free,
                        color: smokingDetected ? Colors.redAccent : Colors.grey,
                        size: 16,
                      ),
                      const SizedBox(width: 4),
<<<<<<< HEAD
                      Expanded(
                        child: Text(
                          smokingDetected ? 'Smoke: YES' : 'Smoke: NO',
                          style: TextStyle(
                            color: smokingDetected ? Colors.redAccent : Colors.grey,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
=======
                      Text(
                        'Smoke: ${smokingDetected ? "YES" : "NO"}',
                        style: TextStyle(
                          color:
                              smokingDetected ? Colors.redAccent : Colors.grey,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
>>>>>>> origin/hadia
                        ),
                      ),
                    ],
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
<<<<<<< HEAD

class ErrorApp extends StatelessWidget {
  final String error;

  const ErrorApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.red.shade900,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, color: Colors.white, size: 64),
              const SizedBox(height: 16),
              Text(
                'Configuration Error',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
=======
>>>>>>> origin/hadia
