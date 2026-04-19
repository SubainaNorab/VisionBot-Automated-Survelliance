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
  // ── GeoJSON data (optimized) ──────────────────────────────────────────────
  List<LatLng> pathCoordinates = [];
  List<List<LatLng>> boundaryPolygons = [];

  // Initialize as empty sets instead of late to prevent null safety issues
  Set<Polyline> polylines = {};
  Set<Polygon> polygons = {};
  Set<Marker> markers = {};
  Set<Marker> debugPathMarkers = {};

  bool _isLoading = true;
  String _statusMessage = 'Loading GeoJSON files...';
  bool _initializationFailed = false;

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
  static const double _markerMinMoveM = 8.0; // Increased from 5m
  static const Duration _markerUiMinInterval =
      Duration(milliseconds: 600); // Increased from 450ms
  int _lastDistStatusBucket = -1;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Load GeoJSON asynchronously to prevent blocking UI
    _loadGeoJSONFilesAsync();
    _setupBleListeners();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _bleStatusSub?.cancel();
    _bleConnSub?.cancel();
    _ble.dispose();
    super.dispose();
  }

  // ── Setup BLE listeners (moved to optimize lifecycle) ─────────────────────

  void _setupBleListeners() {
    try {
      _bleStatusSub = _ble.statusStream.listen(
        (status) {
          if (!mounted) return;
          setState(() => _carStatus = status);
          if (status == 'BLOCKED') {
            setState(() => _statusMessage = '⚠️ Obstacle! Car paused...');
          } else if (status == 'CLEAR' && _patrolActive && !_isTurning) {
            _ble.sendCommand('F');
            setState(() => _statusMessage = '🚗 Resumed forward');
          }
        },
        onError: (e) {
          debugPrint('[BLE] Status stream error: $e');
        },
      );

      _bleConnSub = _ble.connectionStream.listen(
        (connected) {
          if (!mounted) return;
          setState(() {
            _bleConnected = connected;
            if (!connected) {
              _patrolActive = false;
              _statusMessage = '❌ BLE disconnected';
            }
          });
        },
        onError: (e) {
          debugPrint('[BLE] Connection stream error: $e');
        },
      );
    } catch (e, st) {
      debugPrint('[BLE] Failed to setup listeners: $e\n$st');
    }
  }

  void _startGpsTracking() {
    _positionSub?.cancel();
    try {
      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter:
              10, // Increased from 8m to 10m - further reduce updates
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
    } catch (e, st) {
      debugPrint('[NAV] Failed to start GPS tracking: $e\n$st');
      if (mounted) {
        _updateStatus('GPS initialization failed');
      }
    }
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

    try {
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
    } catch (e, st) {
      debugPrint('[NAV] Error in position update: $e\n$st');
      if (mounted) {
        _updateStatus('GPS processing error - try again');
      }
    }
  }

  // ── Turn logic ────────────────────────────────────────────────────────────

  Future<void> _executeTurn() async {
    if (_isTurning) return;
    _isTurning = true;

    try {
      // Determine turn direction from current leg
      final turnDir = _getTurnDirection(_currentWaypointIndex);

      if (mounted) {
        setState(() =>
            _statusMessage = 'Turning ${turnDir == "L" ? "Left" : "Right"}...');
      }

      await _ble.sendCommand('S');
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted || !_patrolActive) {
        _isTurning = false;
        return;
      }

      await _ble.sendCommand(turnDir);
      await Future.delayed(Duration(milliseconds: _turnDurationMs));
      if (!mounted || !_patrolActive) {
        _isTurning = false;
        return;
      }

      await _ble.sendCommand('S');
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted || !_patrolActive) {
        _isTurning = false;
        return;
      }

      await _ble.sendCommand('F');

      // Advance to next waypoint
      final len = pathCoordinates.length;
      if (len > 0) {
        _currentWaypointIndex = (_currentWaypointIndex + 1) % len;
      }

      if (mounted) {
        setState(() =>
            _statusMessage = '🚗 Moving to waypoint $_currentWaypointIndex');
      }

      _isTurning = false;
    } catch (e, st) {
      debugPrint('[NAV] Turn execution failed: $e\n$st');
      _isTurning = false;
      if (mounted) {
        _updateStatus('Turn command failed');
      }
    }
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
    try {
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

      if (!mounted) return;

      _currentWaypointIndex = 0;
      _patrolActive = true;
      _isTurning = false;
      _lastDistStatusBucket = -1;
      _lastPublishedCarPos = null;

      _startGpsTracking();
      await _ble.sendCommand('F');

      _updateStatus('🚗 Patrol started — moving forward');
      debugPrint('[NAV] Patrol started');
    } catch (e, st) {
      debugPrint('[NAV] Failed to start patrol: $e\n$st');
      _patrolActive = false;
      _updateStatus('Failed to start patrol');
    }
  }

  Future<void> _stopPatrol() async {
    try {
      _patrolActive = false;
      _isTurning = false;
      _stopGpsTracking();
      await _ble.sendCommand('S');
      _updateStatus('⏹️ Patrol stopped');
      debugPrint('[NAV] Patrol stopped');
    } catch (e, st) {
      debugPrint('[NAV] Error stopping patrol: $e\n$st');
    }
  }

  Future<void> _connectBle() async {
    try {
      _updateStatus('Scanning for car...');
      final ok = await _ble.connect();
      _updateStatus(ok ? '✅ BLE connected!' : '❌ BLE not found');
      if (!mounted) return;
      setState(() {
        _bleConnected = ok;
      });
    } catch (e, st) {
      debugPrint('[BLE] Connection failed: $e\n$st');
      _updateStatus('BLE connection failed: $e');
    }
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
      final results = await Future.wait([
        _loadPathGeoJSON(),
        _loadBoundariesGeoJSON(),
      ], eagerError: false);

      if (!mounted) return;

      try {
        _synthesizePathFromBoundaryIfNeeded();
      } catch (e) {
        debugPrint('[ERROR] Failed to synthesize path: $e');
      }

      if (pathCoordinates.isNotEmpty || boundaryPolygons.isNotEmpty) {
        try {
          _setupMapUI();
        } catch (e) {
          debugPrint('[ERROR] Failed to setup map UI: $e');
          if (mounted) {
            setState(() {
              _initializationFailed = true;
              _statusMessage = 'Error rendering map: $e';
            });
            return;
          }
        }

        if (mounted) {
          setState(() {
            _isLoading = false;
            _statusMessage = pathCoordinates.isNotEmpty
                ? '✅ Path loaded — connect BLE to start'
                : '✅ Boundary loaded — connect BLE to start';
          });
        }
      } else if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = 'No path or boundary in GeoJSON assets';
        });
      }
    } catch (e, st) {
      debugPrint('[ERROR] Failed to load GeoJSON: $e\n$st');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _initializationFailed = true;
          _statusMessage = 'Error loading map data: $e';
        });
      }
    }
  }

  Future<void> _loadPathGeoJSON() async {
    try {
      final pathJson = await rootBundle.loadString('assets/geo/path.geojson');
      if (pathJson.length > 10 * 1024 * 1024) {
        throw Exception('Path GeoJSON too large (>10MB)');
      }
      _parsePathGeoJSON(jsonDecode(pathJson));
    } catch (e) {
      debugPrint('[ERROR] Failed to load path.geojson: $e');
      // Non-fatal - continue loading boundaries
    }
  }

  Future<void> _loadBoundariesGeoJSON() async {
    try {
      final boundariesJson =
          await rootBundle.loadString('assets/geo/boundaries.geojson');
      if (boundariesJson.length > 10 * 1024 * 1024) {
        throw Exception('Boundaries GeoJSON too large (>10MB)');
      }
      _parseBoundaryGeoJSON(jsonDecode(boundariesJson));
    } catch (e) {
      debugPrint('[ERROR] Failed to load boundaries.geojson: $e');
      // Non-fatal - continue with path
    }
  }

  void _parsePathGeoJSON(Map<String, dynamic> geoJson) {
    try {
      final features = geoJson['features'] as List<dynamic>?;
      if (features == null) return;

      for (final f in features) {
        if (pathCoordinates.length > 50000) {
          debugPrint('[WARN] Path coordinate limit reached (50k)');
          break;
        }

        final g = f['geometry'] as Map<String, dynamic>?;
        if (g == null) continue;

        if (g['type'] == 'LineString') {
          for (final c in (g['coordinates'] as List)) {
            pathCoordinates.add(
              LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
            );
          }
        } else if (g['type'] == 'Polygon') {
          // Many GeoJSON exports use a Polygon for a closed route ring.
          final rings = g['coordinates'] as List<dynamic>?;
          if (rings == null || rings.isEmpty) continue;
          final outer = rings.first as List<dynamic>;
          for (final c in outer) {
            if (pathCoordinates.length > 50000) break;
            final list = c as List<dynamic>;
            if (list.length < 2) continue;
            pathCoordinates.add(
              LatLng((list[1] as num).toDouble(), (list[0] as num).toDouble()),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[ERROR] Failed to parse path GeoJSON: $e');
      pathCoordinates.clear();
    }
  }

  void _parseBoundaryGeoJSON(Map<String, dynamic> geoJson) {
    try {
      final features = geoJson['features'] as List<dynamic>?;
      if (features == null) return;

      for (final f in features) {
        if (boundaryPolygons.length > 100) {
          debugPrint('[WARN] Boundary polygon limit reached (100)');
          break;
        }

        final g = f['geometry'] as Map<String, dynamic>?;
        if (g?['type'] != 'Polygon') continue;

        final coords = g!['coordinates'] as List<dynamic>?;
        if (coords == null || coords.isEmpty) continue;

        // Only the exterior ring — inner rings are holes; adding them broke "inside" logic.
        final outer = coords.first as List<dynamic>;
        final poly = <LatLng>[];
        for (final c in outer) {
          if (poly.length > 10000) {
            debugPrint('[WARN] Polygon coordinate limit reached (10k)');
            break;
          }
          final list = c as List<dynamic>;
          if (list.length < 2) continue;
          poly.add(
            LatLng((list[1] as num).toDouble(), (list[0] as num).toDouble()),
          );
        }
        if (poly.length >= 3) boundaryPolygons.add(poly);
      }
    } catch (e) {
      debugPrint('[ERROR] Failed to parse boundary GeoJSON: $e');
      boundaryPolygons.clear();
    }
  }

  /// If path.geojson had no LineString/Polygon route but a boundary exists, follow the boundary ring.
  void _synthesizePathFromBoundaryIfNeeded() {
    if (pathCoordinates.isNotEmpty || boundaryPolygons.isEmpty) return;
    final outer = boundaryPolygons.first;
    if (outer.length < 3) return;
    pathCoordinates.addAll(outer);
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

    // Skip if didn't move far enough
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

    // Skip if UI update interval not passed
    final now = DateTime.now();
    if (now.difference(_lastMarkerUiAt) < _markerUiMinInterval) return;

    _lastMarkerUiAt = now;
    _lastPublishedCarPos = pos;

    try {
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

      if (mounted) {
        setState(() {
          markers = {newMarker};
        });
      }
    } catch (e) {
      debugPrint('[ERROR] Failed to update car marker: $e');
    }
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
    if (pathCoordinates.isNotEmpty) {
      return CameraPosition(target: pathCoordinates.first, zoom: 17);
    }
    if (boundaryPolygons.isNotEmpty && boundaryPolygons.first.isNotEmpty) {
      return CameraPosition(target: boundaryPolygons.first.first, zoom: 17);
    }
    return const CameraPosition(target: LatLng(0, 0), zoom: 15);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // for AutomaticKeepAliveClientMixin

    return Stack(
      fit: StackFit.expand,
      children: [
        // GoogleMap must get tight bounded layout — bare Stack child caused native crashes.
        if (!_isLoading &&
            !_initializationFailed &&
            (pathCoordinates.isNotEmpty || boundaryPolygons.isNotEmpty))
          Positioned.fill(
            child: _buildGoogleMap(),
          )
        else
          Positioned.fill(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!_initializationFailed)
                    const CircularProgressIndicator()
                  else
                    Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 64,
                    ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  if (_initializationFailed) ...[
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _isLoading = true;
                          _initializationFailed = false;
                          pathCoordinates.clear();
                          boundaryPolygons.clear();
                          polylines.clear();
                          polygons.clear();
                        });
                        _loadGeoJSONFilesAsync();
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ],
              ),
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
        if (!_isLoading && !_initializationFailed)
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
                    onPressed:
                        _bleConnected ? () => _ble.sendCommand('L') : null,
                    tooltip: 'Turn Left',
                    child: const Icon(Icons.turn_left),
                  ),
                  const SizedBox(height: 8),
                  // Manual turn right
                  FloatingActionButton.small(
                    heroTag: 'right',
                    onPressed:
                        _bleConnected ? () => _ble.sendCommand('R') : null,
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

  /// Build GoogleMap with proper error handling
  Widget _buildGoogleMap() {
    try {
      return GoogleMap(
        initialCameraPosition: _getInitialCameraPosition(),
        polylines: polylines,
        polygons: polygons,
        markers: {...markers, ...debugPathMarkers},
        myLocationEnabled: true,
        myLocationButtonEnabled: true,
        compassEnabled: true,
        zoomGesturesEnabled: true,
        scrollGesturesEnabled: true,
        rotateGesturesEnabled: true,
        tiltGesturesEnabled: true,
      );
    } catch (e) {
      debugPrint('[ERROR] GoogleMap initialization failed: $e');
      if (mounted) {
        setState(() {
          _initializationFailed = true;
          _statusMessage = 'Map initialization failed: $e';
        });
      }
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              'Map Error\n$e',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ],
        ),
      );
    }
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
