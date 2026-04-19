import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'ble_navigation_service.dart';

class GeoJSONMapView extends StatefulWidget {
  const GeoJSONMapView({Key? key}) : super(key: key);

  @override
  State<GeoJSONMapView> createState() => _GeoJSONMapViewState();
}

class _GeoJSONMapViewState extends State<GeoJSONMapView>
    with AutomaticKeepAliveClientMixin {
  GoogleMapController? _mapController;

  // ── GeoJSON data (optimized) ──────────────────────────────────────────────
  List<LatLng> pathCoordinates = [];
  List<List<LatLng>> boundaryPolygons = [];

  late Set<Polyline> polylines;
  late Set<Polygon> polygons;
  Set<Marker> markers = {};
  Set<Marker> debugPathMarkers = {};

  bool _isLoading = true;
  String _statusMessage = 'Loading GeoJSON files...';

  // ── BLE + Navigation ──────────────────────────────────────────────────────
  final BleNavigationService _ble = BleNavigationService();
  bool _bleConnected = false;
  bool _patrolActive = false;
  String _carStatus = 'CLEAR'; // BLOCKED or CLEAR from Arduino

  // GPS tracking
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<dynamic>? _bleStatusSub;
  StreamSubscription<dynamic>? _bleConnSub;
  int _currentWaypointIndex = 0;

  // Turn state
  bool _isTurning = false;
  static const double _waypointThresholdMeters = 4.0;
  static const int _turnDurationMs = 700; // tune on real surface

  /// Throttle marker/UI work from GPS stream.
  LatLng? _lastPublishedCarPos;
  DateTime _lastMarkerUiAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const double _markerMinMoveM = 5.0;
  static const Duration _markerUiMinInterval = Duration(milliseconds: 450);
  int _lastDistStatusBucket = -1;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    polylines = {};
    polygons = {};
    // Load GeoJSON asynchronously to prevent blocking UI
    _loadGeoJSONFilesAsync();
    _setupBleListeners();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _bleStatusSub?.cancel();
    _bleConnSub?.cancel();
    _mapController?.dispose();
    _ble.dispose();
    super.dispose();
  }

  // ── Setup BLE listeners (moved to optimize lifecycle) ─────────────────────

  void _setupBleListeners() {
    _bleStatusSub = _ble.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _carStatus = status);
      if (status == 'BLOCKED') {
        setState(() => _statusMessage = '⚠️ Obstacle! Car paused...');
      } else if (status == 'CLEAR' && _patrolActive && !_isTurning) {
        _ble.sendCommand('F');
        setState(() => _statusMessage = '🚗 Resumed forward');
      }
    });

    _bleConnSub = _ble.connectionStream.listen((connected) {
      if (!mounted) return;
      setState(() {
        _bleConnected = connected;
        if (!connected) {
          _patrolActive = false;
          _statusMessage = '❌ BLE disconnected';
        }
      });
    });
  }

  void _startGpsTracking() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 8,
      ),
    ).listen(
      _onPositionUpdate,
      onError: (Object e, StackTrace st) {
        debugPrint('[NAV] GPS stream error: $e\n$st');
        if (mounted) {
          _updateStatus('GPS error — stop patrol and try again');
        }
      },
    );
  }

  Future<bool> _ensureLocationReady() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) _updateStatus('Turn on device location (GPS)');
        return false;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          _updateStatus('Location permission required for patrol');
        }
        return false;
      }
      return true;
    } catch (e, st) {
      debugPrint('[NAV] Location prep failed: $e\n$st');
      return false;
    }
  }

  void _stopGpsTracking() {
    _positionSub?.cancel();
    _positionSub = null;
  }

  void _onPositionUpdate(Position pos) {
    if (!mounted) return;
    if (!_patrolActive || pathCoordinates.isEmpty) return;

    final carLatLng = LatLng(pos.latitude, pos.longitude);

    // Update car marker only once per position (batched update)
    _updateCarMarker(carLatLng);

    // Check if near boundary — if outside, stop and turn back
    final insideBoundary = _isPointInBoundary(carLatLng);
    if (!insideBoundary && !_isTurning) {
      debugPrint('[NAV] Outside boundary — turning back');
      _executeTurn();
      return;
    }

    // Check if near next waypoint corner
    if (_currentWaypointIndex < pathCoordinates.length) {
      final nextWaypoint = pathCoordinates[_currentWaypointIndex];
      final dist = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        nextWaypoint.latitude,
        nextWaypoint.longitude,
      );

      final bucket = dist.floor() ~/ 5;
      if (bucket != _lastDistStatusBucket) {
        _lastDistStatusBucket = bucket;
        if (mounted) {
          setState(() {
            _statusMessage =
                '🚗 To waypoint $_currentWaypointIndex: ${dist.toStringAsFixed(1)}m';
          });
        }
      }

      if (dist < _waypointThresholdMeters && !_isTurning) {
        debugPrint('[NAV] Reached waypoint $_currentWaypointIndex');
        _executeTurn();
      }
    }
  }

  // ── Turn logic ────────────────────────────────────────────────────────────

  Future<void> _executeTurn() async {
    if (_isTurning) return;
    _isTurning = true;

    // Determine turn direction from current leg
    final turnDir = _getTurnDirection(_currentWaypointIndex);

    if (mounted) {
      setState(() =>
          _statusMessage = 'Turning ${turnDir == "L" ? "Left" : "Right"}...');
    }

    await _ble.sendCommand('S');
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) {
      _isTurning = false;
      return;
    }

    await _ble.sendCommand(turnDir);
    await Future.delayed(Duration(milliseconds: _turnDurationMs));
    if (!mounted) {
      _isTurning = false;
      return;
    }

    await _ble.sendCommand('S');
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) {
      _isTurning = false;
      return;
    }

    await _ble.sendCommand('F');

    // Advance to next waypoint
    _currentWaypointIndex =
        (_currentWaypointIndex + 1) % pathCoordinates.length;

    if (mounted) {
      setState(
          () => _statusMessage = '🚗 Moving to waypoint $_currentWaypointIndex');
    }

    _isTurning = false;
  }

  /// Determine turn direction based on the rectangle path winding.
  /// For a clockwise rectangle all turns are Right.
  /// Adjust if your path is counter-clockwise.
  String _getTurnDirection(int waypointIndex) {
    if (pathCoordinates.length < 2) return 'R';

    // Calculate cross product to determine winding
    // Use first 3 points to detect CW vs CCW
    if (pathCoordinates.length >= 3) {
      final p1 = pathCoordinates[0];
      final p2 = pathCoordinates[1];
      final p3 = pathCoordinates[2];

      final cross =
          (p2.longitude - p1.longitude) * (p3.latitude - p1.latitude) -
              (p2.latitude - p1.latitude) * (p3.longitude - p1.longitude);

      // cross > 0 = CCW = turn Left, cross < 0 = CW = turn Right
      return cross > 0 ? 'L' : 'R';
    }

    return 'R'; // default
  }

  // ── Patrol control (optimized) ────────────────────────────────────────────

  Future<void> _startPatrol() async {
    if (!_bleConnected) {
      _updateStatus('Connect BLE first!');
      return;
    }
    if (pathCoordinates.isEmpty) {
      _updateStatus('No path loaded!');
      return;
    }

    final locOk = await _ensureLocationReady();
    if (!locOk) {
      _updateStatus('Allow location + enable GPS to start patrol');
      return;
    }

    _currentWaypointIndex = 0;
    _patrolActive = true;
    _isTurning = false;
    _lastDistStatusBucket = -1;
    _lastPublishedCarPos = null;

    _startGpsTracking();
    await _ble.sendCommand('F');

    _updateStatus('🚗 Patrol started — moving forward');
    debugPrint('[NAV] Patrol started');
  }

  Future<void> _stopPatrol() async {
    _patrolActive = false;
    _isTurning = false;
    _stopGpsTracking();
    await _ble.sendCommand('S');
    _updateStatus('⏹️ Patrol stopped');
    debugPrint('[NAV] Patrol stopped');
  }

  Future<void> _connectBle() async {
    _updateStatus('Scanning for car...');
    final ok = await _ble.connect();
    _updateStatus(ok ? '✅ BLE connected!' : '❌ BLE not found');
    if (!mounted) return;
    setState(() {
      _bleConnected = ok;
    });
  }

  // Helper to batch status updates
  void _updateStatus(String message) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
    });
  }

  // ── Async GeoJSON Loading (prevents UI blocking) ────────────────────────

  Future<void> _loadGeoJSONFilesAsync() async {
    try {
      // Load and parse in background to avoid blocking UI
      await Future.wait([
        _loadPathGeoJSON(),
        _loadBoundariesGeoJSON(),
      ]);

      if (!mounted) return;

      // Only set up UI if data loaded successfully
      if (pathCoordinates.isNotEmpty) {
        _setupMapUI();
        if (mounted) {
          setState(() {
            _isLoading = false;
            _statusMessage = '✅ Path loaded — connect BLE to start';
          });
        }
      }
    } catch (e) {
      debugPrint('[ERROR] Failed to load GeoJSON: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = 'Error loading map: $e';
        });
      }
    }
  }

  Future<void> _loadPathGeoJSON() async {
    try {
      final pathJson = await rootBundle.loadString('assets/geo/path.geojson');
      _parsePathGeoJSON(jsonDecode(pathJson));
    } catch (e) {
      debugPrint('[ERROR] Failed to load path.geojson: $e');
    }
  }

  Future<void> _loadBoundariesGeoJSON() async {
    try {
      final boundariesJson =
          await rootBundle.loadString('assets/geo/boundaries.geojson');
      _parseBoundaryGeoJSON(jsonDecode(boundariesJson));
    } catch (e) {
      debugPrint('[ERROR] Failed to load boundaries.geojson: $e');
    }
  }

  void _parsePathGeoJSON(Map<String, dynamic> geoJson) {
    final features = geoJson['features'] as List<dynamic>?;
    if (features == null) return;
    for (final f in features) {
      final g = f['geometry'] as Map<String, dynamic>?;
      if (g?['type'] == 'LineString') {
        for (final c in (g!['coordinates'] as List)) {
          pathCoordinates
              .add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
        }
      }
    }
  }

  void _parseBoundaryGeoJSON(Map<String, dynamic> geoJson) {
    final features = geoJson['features'] as List<dynamic>?;
    if (features == null) return;
    for (final f in features) {
      final g = f['geometry'] as Map<String, dynamic>?;
      if (g?['type'] == 'Polygon') {
        for (final ring in (g!['coordinates'] as List)) {
          final poly = <LatLng>[];
          for (final c in ring) {
            poly.add(
                LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
          }
          if (poly.isNotEmpty) boundaryPolygons.add(poly);
        }
      }
    }
  }

  void _setupMapUI() {
    // Build polylines
    if (pathCoordinates.isNotEmpty) {
      polylines.add(Polyline(
        polylineId: const PolylineId('path'),
        points: pathCoordinates,
        color: Colors.blue,
        width: 4,
        geodesic: false,
      ));
    }

    // Build polygons efficiently
    for (int i = 0; i < boundaryPolygons.length; i++) {
      polygons.add(Polygon(
        polygonId: PolygonId('boundary_$i'),
        points: boundaryPolygons[i],
        fillColor: Colors.green.withOpacity(0.2),
        strokeColor: Colors.green,
        strokeWidth: 3,
      ));
    }
  }

  void _updateCarMarker(LatLng pos) {
    if (!mounted) return;
    final last = _lastPublishedCarPos;
    if (last != null) {
      final moved = Geolocator.distanceBetween(
        last.latitude,
        last.longitude,
        pos.latitude,
        pos.longitude,
      );
      if (moved < _markerMinMoveM) return;
    }
    final now = DateTime.now();
    if (now.difference(_lastMarkerUiAt) < _markerUiMinInterval) return;
    _lastMarkerUiAt = now;
    _lastPublishedCarPos = pos;

    final newMarker = Marker(
      markerId: const MarkerId('car'),
      position: pos,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
      infoWindow: InfoWindow(
        title: 'Car',
        snippet:
            '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}',
      ),
    );

    setState(() {
      markers = {newMarker};
    });
  }

  bool _isPointInBoundary(LatLng point) {
    if (boundaryPolygons.isEmpty) return true;
    for (final poly in boundaryPolygons) {
      if (_isPointInPolygon(point, poly)) return true;
    }
    return false;
  }

  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    int count = 0;
    final n = polygon.length;
    for (int i = 0; i < n; i++) {
      final p1 = polygon[i];
      final p2 = polygon[(i + 1) % n];
      if ((p1.latitude <= point.latitude && point.latitude < p2.latitude) ||
          (p2.latitude <= point.latitude && point.latitude < p1.latitude)) {
        final intersectLng = p1.longitude +
            ((p2.longitude - p1.longitude) / (p2.latitude - p1.latitude)) *
                (point.latitude - p1.latitude);
        if (point.longitude < intersectLng) count++;
      }
    }
    return count.isOdd;
  }

  CameraPosition _getInitialCameraPosition() {
    if (pathCoordinates.isEmpty) {
      return const CameraPosition(target: LatLng(0, 0), zoom: 15);
    }
    return CameraPosition(target: pathCoordinates.first, zoom: 17);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // for AutomaticKeepAliveClientMixin

    return Stack(
      children: [
        // Google Map - only shown when loaded
        if (!_isLoading && pathCoordinates.isNotEmpty)
          GoogleMap(
            onMapCreated: (c) => _mapController = c,
            initialCameraPosition: _getInitialCameraPosition(),
            polylines: polylines,
            polygons: polygons,
            markers: {...markers, ...debugPathMarkers},
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            compassEnabled: true,
            // Performance optimizations
            zoomGesturesEnabled: true,
            scrollGesturesEnabled: true,
            rotateGesturesEnabled: true,
            tiltGesturesEnabled: true,
          )
        else
          // Loading state
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_statusMessage),
              ],
            ),
          ),

        // Status bar
        Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _statusMessage,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _StatusChip(
                        label: _bleConnected ? '🔵 BLE ON' : '⚪ BLE OFF',
                        color: _bleConnected ? Colors.blue : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      _StatusChip(
                        label:
                            _carStatus == 'BLOCKED' ? '🚫 BLOCKED' : '✅ CLEAR',
                        color:
                            _carStatus == 'BLOCKED' ? Colors.red : Colors.green,
                      ),
                      const SizedBox(width: 8),
                      _StatusChip(
                        label: _patrolActive ? '🟢 PATROL' : '⏸️ IDLE',
                        color: _patrolActive ? Colors.green : Colors.grey,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Control buttons
        Positioned(
          top: 16,
          right: 16,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // BLE connect
                FloatingActionButton.small(
                  heroTag: 'ble',
                  onPressed: _bleConnected ? null : _connectBle,
                  backgroundColor: _bleConnected ? Colors.blue : Colors.grey,
                  tooltip: 'Connect BLE',
                  child: const Icon(Icons.bluetooth),
                ),
                const SizedBox(height: 8),
                // Start patrol
                FloatingActionButton(
                  heroTag: 'play',
                  onPressed:
                      (_bleConnected && !_patrolActive) ? _startPatrol : null,
                  backgroundColor: Colors.green,
                  tooltip: 'Start Patrol',
                  child: const Icon(Icons.play_arrow),
                ),
                const SizedBox(height: 8),
                // Stop patrol
                FloatingActionButton(
                  heroTag: 'stop',
                  onPressed: _patrolActive ? _stopPatrol : null,
                  backgroundColor: Colors.red,
                  tooltip: 'Stop Patrol',
                  child: const Icon(Icons.stop),
                ),
                const SizedBox(height: 8),
                // Manual turn left
                FloatingActionButton.small(
                  heroTag: 'left',
                  onPressed: _bleConnected ? () => _ble.sendCommand('L') : null,
                  tooltip: 'Turn Left',
                  child: const Icon(Icons.turn_left),
                ),
                const SizedBox(height: 8),
                // Manual turn right
                FloatingActionButton.small(
                  heroTag: 'right',
                  onPressed: _bleConnected ? () => _ble.sendCommand('R') : null,
                  tooltip: 'Turn Right',
                  child: const Icon(Icons.turn_right),
                ),
                const SizedBox(height: 8),
                // Emergency Stop
                FloatingActionButton(
                  heroTag: 'estop',
                  onPressed: _bleConnected
                      ? () async {
                          await _stopPatrol();
                          await _ble.sendCommand('E');
                          if (mounted) {
                            setState(
                                () => _statusMessage = '🚨 EMERGENCY STOP');
                          }
                        }
                      : null,
                  backgroundColor: Colors.red.shade900,
                  tooltip: 'Emergency Stop',
                  child: const Icon(Icons.dangerous, color: Colors.yellow),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11)),
    );
  }
}
