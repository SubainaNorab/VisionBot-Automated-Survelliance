// geojson_map_view.dart
// Car control: BLE + GPS path following
// - Start button starts forward motion
// - Car follows pre-loaded GeoJSON path
// - Manual direction overrides allowed (car resumes forward after turn)
// - Off-path detection shows warning but car keeps going
// - Lock to Path: active GPS correction to stay on centerline
// - Obstacle avoidance handled by Arduino automatically

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'ble_navigation_service.dart';
import 'navigation_state.dart';
import 'path_tracker.dart';

class GeoJSONMapView extends StatefulWidget {
  const GeoJSONMapView({Key? key}) : super(key: key);

  @override
  State<GeoJSONMapView> createState() => _GeoJSONMapViewState();
}

class _GeoJSONMapViewState extends State<GeoJSONMapView> {

  // ── Map data ───────────────────────────────────────────────────────────────
  List<LatLng> pathCoordinates = [];
  List<List<LatLng>> boundaryPolygons = [];
  final Set<Polyline> polylines = {};
  final Set<Polygon> polygons = {};
  Set<Marker> markers = {};
  GoogleMapController? _mapController;

  // ── BLE ────────────────────────────────────────────────────────────────────
  final BleNavigationService _ble = BleNavigationService();

  // ── Navigation state ───────────────────────────────────────────────────────
  NavigationState _navState = const NavigationState();

  // ── GPS ────────────────────────────────────────────────────────────────────
  StreamSubscription<Position>? _positionSub;
  Position? _lastPosition;

  // ── Turn state ─────────────────────────────────────────────────────────────
  bool _isTurning = false;
  int _currentWaypointIndex = 0;

  // ── Path tracking ──────────────────────────────────────────────────────────
  PathTracker? _pathTracker;
  bool _lockedToPath = false;
  Timer? _correctionTimer;
  DateTime _lastCorrectionTime = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Timing constants ───────────────────────────────────────────────────────
  // How close to a waypoint before turning (metres)
  static const double _waypointThresholdM = 6.0;
  // How far off-path before showing warning banner (metres)
  static const double _offPathThresholdM = 8.0;
  // Manual turn duration
  static const int _turnMs = 700;
  // Resume delay after manual turn
  static const int _resumeDelayMs = 300;
  // Correction nudge durations
  static const int _nudgeMs = 200;
  static const int _correctMs = 450;
  static const int _waypointTurnMs = 700;
  // Minimum ms between GPS corrections (prevents overcorrecting)
  static const int _correctionCooldownMs = 1500;

  bool _isLoading = true;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadGeoJSON();
    _setupBleListeners();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _correctionTimer?.cancel();
    _ble.dispose();
    super.dispose();
  }

  // ── BLE listeners ──────────────────────────────────────────────────────────

  void _setupBleListeners() {
    _ble.statusStream.listen((status) {
      _updateState(_navState.copyWith(carStatus: status));
      if (status == 'CLEAR' && _navState.patrolActive && !_isTurning) {
        _ble.sendCommand('F');
      }
    });

    _ble.connectionStream.listen((connected) {
      _updateState(_navState.copyWith(
        bleConnected: connected,
        statusMessage: connected
            ? '✅ BLE connected — press Start'
            : '❌ BLE disconnected',
        patrolActive: connected ? _navState.patrolActive : false,
      ));
      if (!connected && _navState.patrolActive) {
        _stopEverything();
      }
    });
  }

  // ── GPS ────────────────────────────────────────────────────────────────────

  void _startGps() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen(_onPosition);
  }

  void _stopGps() {
    _positionSub?.cancel();
    _positionSub = null;
  }

  void _onPosition(Position pos) {
    if (!_navState.patrolActive) return;

    _lastPosition = pos;
    final carPos = LatLng(pos.latitude, pos.longitude);

    _updateCarMarker(carPos);
    _mapController?.animateCamera(CameraUpdate.newLatLng(carPos));

    // Always check on/off path for banner
    final onPath = _isOnPath(carPos);
    if (onPath != _navState.onPath) {
      _updateState(_navState.copyWith(onPath: onPath));
    }

    // ── Locked to path — active GPS correction ─────────────────────────────
    if (_lockedToPath && _pathTracker != null && !_isTurning) {
      final correction = _pathTracker!.evaluate(carPos);
      _applyCorrection(correction);
      return;
    }

    // ── Normal mode — waypoint turns only ──────────────────────────────────
    if (_isTurning || pathCoordinates.isEmpty) return;

    final target = pathCoordinates[_currentWaypointIndex];
    final dist = Geolocator.distanceBetween(
      pos.latitude, pos.longitude,
      target.latitude, target.longitude,
    );

    _updateState(_navState.copyWith(
      currentWaypoint: _currentWaypointIndex,
      distToWaypoint: dist,
      statusMessage: onPath
          ? '🚗 To corner ${_currentWaypointIndex + 1}: ${dist.toStringAsFixed(1)}m'
          : '🚗 Moving (off path)',
    ));

    if (dist < _waypointThresholdM) {
      debugPrint('[NAV] Reached waypoint $_currentWaypointIndex');
      _doAutoTurn();
    }
  }

  // ── Path correction ────────────────────────────────────────────────────────

  Future<void> _applyCorrection(PathCorrection correction) async {
    if (_isTurning) return;

    final now = DateTime.now();
    if (now.difference(_lastCorrectionTime).inMilliseconds < _correctionCooldownMs) return;

    _updateState(_navState.copyWith(
      statusMessage: correction.description,
      onPath: correction.status == PathStatus.onPath ||
              correction.status == PathStatus.atWaypoint,
      distToWaypoint: correction.distToWaypointM,
      currentWaypoint: correction.nextWaypointIndex,
    ));

    switch (correction.status) {
      case PathStatus.onPath:
        // Clear — nothing to do, car is already going forward
        break;

      case PathStatus.atWaypoint:
        debugPrint('[PATH] Waypoint turn: ${correction.command}');
        _lastCorrectionTime = now;
        await _executeCorrectionTurn(correction.command!, _waypointTurnMs);
        _currentWaypointIndex = correction.nextWaypointIndex;
        break;

      case PathStatus.driftLeft:
      case PathStatus.driftRight:
        debugPrint('[PATH] Drift nudge: ${correction.command} '
            '(${correction.crossTrackM.toStringAsFixed(2)}m)');
        _lastCorrectionTime = now;
        await _executeCorrectionTurn(correction.command!, _nudgeMs);
        break;

      case PathStatus.offPath:
        debugPrint('[PATH] Off-path correction: ${correction.command} '
            '(${correction.crossTrackM.toStringAsFixed(2)}m)');
        _lastCorrectionTime = now;
        await _executeCorrectionTurn(correction.command!, _correctMs);
        break;
    }
  }

  Future<void> _executeCorrectionTurn(String dir, int durationMs) async {
    _isTurning = true;
    await _ble.sendCommand(dir);
    await Future.delayed(Duration(milliseconds: durationMs));
    await _ble.sendCommand('F');
    _isTurning = false;
  }

  // ── Path lock ──────────────────────────────────────────────────────────────

  void _lockToPath() {
    if (pathCoordinates.isEmpty) return;

    _pathTracker = PathTracker(
      path: pathCoordinates,
      waypointThresholdM: 6.0,    // ← was 999, now enabled for corners
      onPathToleranceM: 5.0,
      correctionThresholdM: 10.0,
    );
    _pathTracker!.reset();
    _lockedToPath = true;

    _updateState(_navState.copyWith(
      statusMessage: '📍 Locked to path — 616m loop, 10 corners',
      onPath: true,
    ));
  }

  void _unlockFromPath() {
    _lockedToPath = false;
    _pathTracker = null;
    _correctionTimer?.cancel();
    debugPrint('[PATH] Unlocked from path');
  }

  // ── Path utilities ─────────────────────────────────────────────────────────

  bool _isOnPath(LatLng pos) {
    if (pathCoordinates.length < 2) return true;
    for (int i = 0; i < pathCoordinates.length - 1; i++) {
      final d = _distToSegmentM(pos, pathCoordinates[i], pathCoordinates[i + 1]);
      if (d <= _offPathThresholdM) return true;
    }
    return false;
  }

  double _distToSegmentM(LatLng p, LatLng a, LatLng b) {
    final px = (p.longitude - a.longitude) * 111320 * _cos(a.latitude);
    final py = (p.latitude - a.latitude) * 110540;
    final bx = (b.longitude - a.longitude) * 111320 * _cos(a.latitude);
    final by = (b.latitude - a.latitude) * 110540;

    final lenSq = bx * bx + by * by;
    if (lenSq == 0) return _distM(p, a);

    double t = ((px * bx + py * by) / lenSq).clamp(0.0, 1.0);
    final dx = px - t * bx;
    final dy = py - t * by;
    final distSq = dx * dx + dy * dy;
    if (distSq <= 0) return 0;
    return _sqrtManual(distSq);
  }

  double _sqrtManual(double v) {
    if (v <= 0) return 0;
    double x = v;
    for (int i = 0; i < 16; i++) x = (x + v / x) / 2;
    return x;
  }

  double _distM(LatLng a, LatLng b) {
    return Geolocator.distanceBetween(
        a.latitude, a.longitude, b.latitude, b.longitude);
  }

  double _cos(double degrees) {
    final rad = degrees * 3.14159265358979 / 180.0;
    return 1.0 - (rad * rad) / 2.0 + (rad * rad * rad * rad) / 24.0;
  }

  // ── Turn logic ─────────────────────────────────────────────────────────────

  Future<void> _doAutoTurn() async {
    if (_isTurning || !_navState.patrolActive) return;
    _isTurning = true;

    final dir = _turnDirectionAt(_currentWaypointIndex);
    debugPrint('[NAV] Auto turn $dir at waypoint $_currentWaypointIndex');

    _updateState(_navState.copyWith(
      statusMessage: 'Turning ${dir == "L" ? "Left ←" : "Right →"}...',
    ));

    await _ble.sendCommand(dir);
    await Future.delayed(Duration(milliseconds: _turnMs));
    await _ble.sendCommand('F');

    _currentWaypointIndex = (_currentWaypointIndex + 1) % pathCoordinates.length;
    _isTurning = false;
  }

  Future<void> _manualTurn(String dir) async {
    if (!_navState.patrolActive || _isTurning) return;
    _isTurning = true;

    debugPrint('[NAV] Manual turn: $dir');
    _updateState(_navState.copyWith(
      statusMessage: 'Manual ${dir == "L" ? "Left ←" : "Right →"}',
    ));

    await _ble.sendCommand(dir);
    await Future.delayed(Duration(milliseconds: _turnMs));
    await _ble.sendCommand('F');

    _isTurning = false;
    _updateState(_navState.copyWith(statusMessage: '🚗 Resumed forward'));
  }

  String _turnDirectionAt(int waypointIndex) {
    if (pathCoordinates.length < 3) return 'R';

    final prev = waypointIndex > 0
        ? pathCoordinates[waypointIndex - 1]
        : pathCoordinates[pathCoordinates.length - 1];
    final curr = pathCoordinates[waypointIndex];
    final next = pathCoordinates[(waypointIndex + 1) % pathCoordinates.length];

    final ax = curr.longitude - prev.longitude;
    final ay = curr.latitude - prev.latitude;
    final bx = next.longitude - curr.longitude;
    final by = next.latitude - curr.latitude;

    final cross = ax * by - ay * bx;
    return cross < 0 ? 'R' : 'L';
  }

  // ── Patrol control ─────────────────────────────────────────────────────────

  Future<void> _startPatrol() async {
    if (!_navState.bleConnected) return;

    _currentWaypointIndex = 0;
    _isTurning = false;

    _updateState(_navState.copyWith(
      patrolActive: true,
      statusMessage: '🚗 Moving forward...',
    ));

    await _ble.sendCommand('F');
    _startGps();
    debugPrint('[NAV] Patrol started');
  }

  Future<void> _stopPatrol() async {
    _isTurning = false;
    _unlockFromPath();
    _stopGps();
    await _ble.sendCommand('S');
    _updateState(_navState.copyWith(
      patrolActive: false,
      statusMessage: '⏹️ Stopped',
    ));
    debugPrint('[NAV] Patrol stopped');
  }

  Future<void> _emergencyStop() async {
    _isTurning = false;
    _unlockFromPath();
    _stopGps();
    await _ble.sendCommand('E');
    _updateState(_navState.copyWith(
      patrolActive: false,
      statusMessage: '🚨 EMERGENCY STOP',
    ));
    debugPrint('[NAV] Emergency stop');
  }

  void _stopEverything() {
    _isTurning = false;
    _unlockFromPath();
    _stopGps();
    _updateState(_navState.copyWith(
      patrolActive: false,
      statusMessage: '⚠️ Stopped — BLE lost',
    ));
  }

  Future<void> _connectBle() async {
    _updateState(_navState.copyWith(statusMessage: '🔍 Scanning for car...'));
    final ok = await _ble.connect();
    _updateState(_navState.copyWith(
      bleConnected: ok,
      statusMessage: ok ? '✅ Connected — press Start' : '❌ Car not found',
    ));
  }

  // ── State helper ───────────────────────────────────────────────────────────

  void _updateState(NavigationState s) {
    if (mounted) setState(() => _navState = s);
  }

  // ── Map helpers ────────────────────────────────────────────────────────────

  Future<void> _loadGeoJSON() async {
    try {
      final pathJson = await rootBundle.loadString('assets/geo/path.geojson');
      _parsePathGeoJSON(jsonDecode(pathJson));

      final boundJson = await rootBundle.loadString('assets/geo/boundaries.geojson');
      _parseBoundaryGeoJSON(jsonDecode(boundJson));

      _buildMapOverlays();

      setState(() {
        _isLoading = false;
        _navState = _navState.copyWith(statusMessage: 'Path loaded — connect BLE');
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _navState = _navState.copyWith(statusMessage: 'GeoJSON error: $e');
      });
    }
  }

  void _parsePathGeoJSON(Map<String, dynamic> g) {
    for (final f in (g['features'] as List)) {
      final geo = f['geometry'] as Map<String, dynamic>;
      if (geo['type'] == 'LineString') {
        for (final c in (geo['coordinates'] as List)) {
          pathCoordinates.add(
            LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
          );
        }
      }
    }
    debugPrint('[MAP] ${pathCoordinates.length} path points loaded');
  }

  void _parseBoundaryGeoJSON(Map<String, dynamic> g) {
    for (final f in (g['features'] as List)) {
      final geo = f['geometry'] as Map<String, dynamic>;
      if (geo['type'] == 'Polygon') {
        for (final ring in (geo['coordinates'] as List)) {
          final poly = <LatLng>[];
          for (final c in ring) {
            poly.add(LatLng(
              (c[1] as num).toDouble(),
              (c[0] as num).toDouble(),
            ));
          }
          if (poly.isNotEmpty) boundaryPolygons.add(poly);
        }
      }
    }
    debugPrint('[MAP] ${boundaryPolygons.length} boundary polygon(s)');
  }

  void _buildMapOverlays() {
    if (pathCoordinates.isNotEmpty) {
      polylines.add(Polyline(
        polylineId: const PolylineId('path'),
        points: pathCoordinates,
        color: Colors.blue,
        width: 4,
      ));
    }

    for (int i = 0; i < pathCoordinates.length; i++) {
      markers.add(Marker(
        markerId: MarkerId('wp_$i'),
        position: pathCoordinates[i],
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(title: 'Waypoint ${i + 1}'),
      ));
    }

    for (int i = 0; i < boundaryPolygons.length; i++) {
      polygons.add(Polygon(
        polygonId: PolygonId('b$i'),
        points: boundaryPolygons[i],
        fillColor: Colors.green.withOpacity(0.15),
        strokeColor: Colors.green,
        strokeWidth: 2,
      ));
    }
  }

  void _updateCarMarker(LatLng pos) {
    markers.removeWhere((m) => m.markerId.value == 'car');
    markers.add(Marker(
      markerId: const MarkerId('car'),
      position: pos,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
      infoWindow: InfoWindow(
        title: '🚗 Car',
        snippet: '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}',
      ),
    ));
    if (mounted) setState(() {});
  }

  CameraPosition get _initialCamera {
    if (pathCoordinates.isEmpty) {
      return const CameraPosition(target: LatLng(0, 0), zoom: 15);
    }
    return CameraPosition(target: pathCoordinates.first, zoom: 17);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Map
        if (_isLoading)
          const Center(child: CircularProgressIndicator())
        else
          GoogleMap(
            onMapCreated: (c) => _mapController = c,
            initialCameraPosition: _initialCamera,
            polylines: polylines,
            polygons: polygons,
            markers: markers,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            compassEnabled: true,
          ),

        // Off-path warning banner
        if (_navState.patrolActive && !_navState.onPath)
          const Positioned(
            top: 16,
            left: 16,
            right: 70,
            child: _OffPathBanner(),
          ),

        // Status bar
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _StatusBar(state: _navState),
        ),

        // Control panel
        Positioned(
          top: 16,
          right: 12,
          child: _ControlPanel(
            state: _navState,
            lockedToPath: _lockedToPath,
            onConnect: _connectBle,
            onStart: _startPatrol,
            onStop: _stopPatrol,
            onEmergency: _emergencyStop,
            onLeft: () => _manualTurn('L'),
            onRight: () => _manualTurn('R'),
            onLock: _lockToPath,
            onUnlock: _unlockFromPath,
          ),
        ),
      ],
    );
  }
}

// ── Widgets ────────────────────────────────────────────────────────────────────

class _OffPathBanner extends StatelessWidget {
  const _OffPathBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.shade800,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6),
        ],
      ),
      child: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Car not on path — continuing forward',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final NavigationState state;
  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            state.statusMessage,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _Chip(
                label: state.bleConnected ? '🔵 BLE' : '⚫ BLE',
                color: state.bleConnected ? Colors.blue : Colors.grey,
              ),
              const SizedBox(width: 8),
              _Chip(
                label: state.patrolActive ? '🟢 RUNNING' : '⏸ IDLE',
                color: state.patrolActive ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 8),
              _Chip(
                label: state.carStatus == 'BLOCKED' ? '🚫 BLOCKED' : '✅ CLEAR',
                color: state.carStatus == 'BLOCKED' ? Colors.red : Colors.green,
              ),
              if (state.distToWaypoint != null) ...[
                const SizedBox(width: 8),
                _Chip(
                  label: '📍 ${state.distToWaypoint!.toStringAsFixed(1)}m',
                  color: Colors.orange,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  final NavigationState state;
  final bool lockedToPath;
  final VoidCallback onConnect;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onEmergency;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onLock;
  final VoidCallback onUnlock;

  const _ControlPanel({
    required this.state,
    required this.lockedToPath,
    required this.onConnect,
    required this.onStart,
    required this.onStop,
    required this.onEmergency,
    required this.onLeft,
    required this.onRight,
    required this.onLock,
    required this.onUnlock,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // BLE Connect
        _RoundButton(
          icon: Icons.bluetooth,
          color: state.bleConnected ? Colors.blue : Colors.grey,
          tooltip: state.bleConnected ? 'Connected' : 'Connect BLE',
          onPressed: state.bleConnected ? null : onConnect,
          small: true,
        ),
        const SizedBox(height: 8),

        // START
        _RoundButton(
          icon: Icons.play_arrow,
          color: Colors.green,
          tooltip: 'Start',
          onPressed: (state.bleConnected && !state.patrolActive) ? onStart : null,
        ),
        const SizedBox(height: 8),

        // STOP
        _RoundButton(
          icon: Icons.stop,
          color: Colors.orange,
          tooltip: 'Stop',
          onPressed: state.patrolActive ? onStop : null,
        ),
        const SizedBox(height: 8),

        // EMERGENCY STOP
        _RoundButton(
          icon: Icons.dangerous,
          color: Colors.red.shade900,
          tooltip: 'Emergency Stop',
          onPressed: onEmergency,
          iconColor: Colors.yellow,
        ),
        const SizedBox(height: 8),

        // LOCK TO PATH
        _RoundButton(
          icon: lockedToPath ? Icons.push_pin : Icons.push_pin_outlined,
          color: lockedToPath ? Colors.purple : Colors.blueGrey,
          tooltip: lockedToPath ? 'Unlock Path' : 'Lock to Path',
          onPressed: (state.bleConnected && state.patrolActive)
              ? (lockedToPath ? onUnlock : onLock)
              : null,
          small: true,
        ),
        const SizedBox(height: 16),

        // Manual LEFT
        _RoundButton(
          icon: Icons.turn_left,
          color: Colors.teal,
          tooltip: 'Turn Left',
          onPressed: (state.bleConnected && state.patrolActive) ? onLeft : null,
          small: true,
        ),
        const SizedBox(height: 8),

        // Manual RIGHT
        _RoundButton(
          icon: Icons.turn_right,
          color: Colors.teal,
          tooltip: 'Turn Right',
          onPressed: (state.bleConnected && state.patrolActive) ? onRight : null,
          small: true,
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool small;
  final Color? iconColor;

  const _RoundButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
    this.small = false,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    if (small) {
      return FloatingActionButton.small(
        heroTag: tooltip,
        onPressed: onPressed,
        backgroundColor: onPressed == null ? Colors.grey.shade800 : color,
        tooltip: tooltip,
        child: Icon(icon,
            color: iconColor ?? (onPressed == null ? Colors.grey : Colors.white)),
      );
    }
    return FloatingActionButton(
      heroTag: tooltip,
      onPressed: onPressed,
      backgroundColor: onPressed == null ? Colors.grey.shade800 : color,
      tooltip: tooltip,
      child: Icon(icon,
          color: iconColor ?? (onPressed == null ? Colors.grey : Colors.white)),
    );
  }
}