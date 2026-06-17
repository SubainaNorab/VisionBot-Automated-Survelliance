// main.dart - MERGED: Hybrid detection + Path navigation

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:permission_handler/permission_handler.dart';
import 'model/person.dart';
import 'firebase_options.dart';
import 'supabase_service.dart';
import 'survelliance_controller.dart';
import 'geojson_map_view.dart';
import 'custom_app_bar.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  debugPrint('');
  debugPrint('╔═══════════════════════════════════╗');
  debugPrint('║  VisionBot - Loading Credentials   ║');
  debugPrint('╚═══════════════════════════════════╝');
  debugPrint('');

  try {
    // ✅ Step 1: Get Supabase credentials from dart-define
    debugPrint('1️⃣ Reading Supabase credentials...');
final supabaseUrl = dotenv.env['SUPABASE_URL']!;
final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY']!;

// if (supabaseUrl == null || supabaseAnonKey == null) {
//   throw Exception('Missing SUPABASE credentials in .env file');
// }
    await Supabase.initialize(
  url: supabaseUrl,
  anonKey: supabaseAnonKey,
);
    // final supabaseUrl = dotenv.env['SUPABASE_URL'];
    // final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];

    // if (supabaseUrl == null || supabaseAnonKey == null) {
    //   throw Exception(
    //     '❌ Missing Supabase credentials!\n'
    //     '   Please provide SUPABASE_URL and SUPABASE_ANON_KEY via --dart-define'
    //   );
    // }

    // debugPrint('   ✅ Credentials loaded securely');
    // debugPrint('   URL: ${supabaseUrl.substring(0, 20)}...');

    // ✅ Step 2: Initialize Firebase
    debugPrint('');
    debugPrint('2️⃣ Initializing Firebase...');
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('   ✅ Firebase ready');

    // ✅ Step 3: Initialize Supabase with loaded credentials
    debugPrint('');
    debugPrint('3️⃣ Initializing Supabase Storage...');
    await SupabaseService.initialize(
      supabaseUrl: supabaseUrl,
      supabaseAnonKey: supabaseAnonKey,
    );
    debugPrint('   ✅ Supabase ready');

    // ✅ Step 4: Request Permissions
    debugPrint('');
    debugPrint('4️⃣ Requesting permissions...');
    await _requestAllPermissions();
    debugPrint('   ✅ Permissions handled');

    debugPrint('');
    debugPrint('╔═══════════════════════════════════╗');
    debugPrint('║   App Ready - Starting VisionBot   ║');
    debugPrint('║    HYBRID MODE + PATH FOLLOW 🚀    ║');
    debugPrint('╚═══════════════════════════════════╝');
    debugPrint('');

    runApp(const VisionBot());
  } catch (e, st) {
    debugPrint('');
    debugPrint('╔═══════════════════════════════════╗');
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
    
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    }
    
    debugPrint('📋 Permission Results:');
    statuses.forEach((permission, status) {
      final emoji = status.isGranted ? '✅' : '⚠️';
      debugPrint('   $emoji ${permission.toString().split('.').last}: $status');
    });
    
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
        colorSchemeSeed: Colors.orange,
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

class _SurveillanceScreenState extends State<SurveillanceScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final SurveillanceController _controller;
  late final TabController _tabController;

  bool _mapContentReady = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    // ✅ TWO TABS: Surveillance + Location
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onMainTabChanged);

    _controller = SurveillanceController(groupThreshold: 1);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.initialize();
    });
  }

  void _onMainTabChanged() {
    if (_tabController.indexIsChanging) return;
    
    if (_tabController.index == 1) {
      // ✅ Switching to MAP TAB
      _prepareMapTab();
    } else {
      // ✅ Switching to SURVEILLANCE TAB
      _prepareSurveillanceTab();
    }
  }

  Future<void> _prepareMapTab() async {
    if (!mounted) return;
    setState(() => _mapContentReady = false);
    
    // ✅ Pause surveillance before mounting map
    await _controller.pauseForMapTab();
    
    if (!mounted || _tabController.index != 1) return;
    setState(() => _mapContentReady = true);
  }

  Future<void> _prepareSurveillanceTab() async {
    if (!mounted) return;
    setState(() => _mapContentReady = false);
    
    // ✅ Resume surveillance after leaving map
    await _controller.resumeFromMapTab();
    
    if (!mounted || _tabController.index != 0) return;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('📱 App lifecycle: $state');
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
      builder: (context, snapshot) {
        final state = snapshot.data ?? _controller.currentState;

        return Scaffold(
          backgroundColor: Colors.black,
          appBar: VisionBotAppBar(
            tabController: _tabController,
            onSettingsPressed: () => _showDetectionSettings(context),
            onSwitchCameraPressed: _controller.switchCamera,
            onVerifyFacePressed: _controller.verifyFace,
            isProcessingFace: state.processingFace,
          ),
          // ✅ AnimatedBuilder: Switch between surveillance + map
          body: AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              final onLocation = _tabController.index == 1;
              
              if (!onLocation) {
                // ✅ SURVEILLANCE TAB
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
                          Positioned(top: 8, right: 8, child: _LiveIndicator()),
                          Positioned(
                            top: 8,
                            left: 8,
                            child: _buildAutoVerifyStatus(),
                          ),
                        ],
                      ),
                    ),
                    _buildStatusPanel(state),
                  ],
                );
              }
              
              // ✅ LOCATION/MAP TAB
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
          ),
        );
      },
    );
  }

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

  Widget _buildStatusPanel(SurveillanceState state) {
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

          // Auto verify toggle + Manual verify button
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
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  title: const Text(
                    'Medium Range (2-4m)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Face: 50-500px | RECOMMENDED',
                    style: TextStyle(fontSize: 11, color: Colors.green),
                  ),
                  leading: const Icon(Icons.groups, color: Colors.green, size: 20),
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
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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

class _HybridDetectionDisplay extends StatelessWidget {
  final int yoloPeopleCount;
  final int verifiedPeopleCount;
  final int knownCount;
  final int unknownCount;
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
          Row(
            children: [
              Icon(Icons.people, color: Colors.orangeAccent, size: 18),
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
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                      Expanded(
                        child: Text(
                          smokingDetected ? 'Smoke: YES' : 'Smoke: NO',
                          style: TextStyle(
                            color:
                                smokingDetected ? Colors.redAccent : Colors.grey,
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
            ],
          ),
        ],
      ),
    );
  }
}

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