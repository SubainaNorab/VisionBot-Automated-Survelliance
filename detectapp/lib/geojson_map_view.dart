import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class GeoJSONMapView extends StatefulWidget {
  const GeoJSONMapView({Key? key}) : super(key: key);

  @override
  State<GeoJSONMapView> createState() => _GeoJSONMapViewState();
}

class _GeoJSONMapViewState extends State<GeoJSONMapView> {
  late GoogleMapController _mapController;

  // GeoJSON Data
  List<LatLng> pathCoordinates = [];
  List<List<LatLng>> boundaryPolygons = [];

  // Map UI Elements
  final Set<Polyline> polylines = {};
  final Set<Polygon> polygons = {};
  Set<Marker> markers = {};
  Set<Marker> debugPathMarkers = {};

  // Marker Animation
  Timer? _movementTimer;
  LatLng _carMarkerPosition = const LatLng(0, 0);
  int _currentWaypointIndex = 0;
  bool _isMoving = false;

  // Status
  bool _isLoading = true;
  String _statusMessage = 'Loading GeoJSON files...';

  @override
  void initState() {
    super.initState();
    _loadGeoJSONFiles();
  }

  @override
  void dispose() {
    _movementTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  /// Load both GeoJSON files from assets
  Future<void> _loadGeoJSONFiles() async {
    try {
      debugPrint('📂 Loading GeoJSON files...');

      // Load path.geojson
      final pathJson = await rootBundle.loadString('assets/geo/path.geojson');
      final pathData = jsonDecode(pathJson) as Map<String, dynamic>;
      _parsePathGeoJSON(pathData);

      // Load boundaries.geojson
      final boundariesJson =
          await rootBundle.loadString('assets/geo/boundaries.geojson');
      final boundariesData = jsonDecode(boundariesJson) as Map<String, dynamic>;
      _parseBoundaryGeoJSON(boundariesData);

      if (pathCoordinates.isNotEmpty) {
        _carMarkerPosition = pathCoordinates.first;
        _updateMarker();
        _setupMapUI();
        setState(() {
          _isLoading = false;
          _statusMessage = '✅ Ready to navigate';
        });
        debugPrint('✅ GeoJSON files loaded successfully');
      } else {
        setState(() {
          _isLoading = false;
          _statusMessage = '❌ No path coordinates found';
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading GeoJSON: $e');
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error: ${e.toString()}';
      });
    }
  }

  /// Parse LineString path from GeoJSON
  void _parsePathGeoJSON(Map<String, dynamic> geoJson) {
    try {
      final features = geoJson['features'] as List<dynamic>?;

      if (features == null || features.isEmpty) {
        debugPrint('⚠️ No features found in path GeoJSON');
        return;
      }

      for (final feature in features) {
        final geometry = feature['geometry'] as Map<String, dynamic>?;
        if (geometry == null) continue;

        final geometryType = geometry['type'] as String?;
        final coordinates = geometry['coordinates'] as List<dynamic>?;

        if (geometryType == 'LineString' && coordinates != null) {
          for (final coord in coordinates) {
            if (coord is List && coord.length >= 2) {
              final lng = (coord[0] as num).toDouble();
              final lat = (coord[1] as num).toDouble();
              pathCoordinates.add(LatLng(lat, lng));
            }
          }
          debugPrint('✅ Loaded ${pathCoordinates.length} path waypoints');
        }
      }
    } catch (e) {
      debugPrint('❌ Error parsing path GeoJSON: $e');
    }
  }

  /// Parse Polygon boundaries from GeoJSON
  void _parseBoundaryGeoJSON(Map<String, dynamic> geoJson) {
    try {
      final features = geoJson['features'] as List<dynamic>?;

      if (features == null || features.isEmpty) {
        debugPrint('⚠️ No features found in boundary GeoJSON');
        return;
      }

      for (final feature in features) {
        final geometry = feature['geometry'] as Map<String, dynamic>?;
        if (geometry == null) continue;

        final geometryType = geometry['type'] as String?;
        final coordinates = geometry['coordinates'] as List<dynamic>?;

        if (geometryType == 'Polygon' && coordinates != null) {
          for (final ring in coordinates) {
            if (ring is List) {
              final polygon = <LatLng>[];
              for (final coord in ring) {
                if (coord is List && coord.length >= 2) {
                  final lng = (coord[0] as num).toDouble();
                  final lat = (coord[1] as num).toDouble();
                  polygon.add(LatLng(lat, lng));
                }
              }
              if (polygon.isNotEmpty) {
                boundaryPolygons.add(polygon);
              }
            }
          }
          debugPrint('✅ Loaded ${boundaryPolygons.length} boundary polygon(s)');
        }
      }
    } catch (e) {
      debugPrint('❌ Error parsing boundary GeoJSON: $e');
    }
  }

  /// Setup map UI elements (polylines and polygons)
  void _setupMapUI() {
    // Add path polyline
    if (pathCoordinates.isNotEmpty) {
      polylines.add(
        Polyline(
          polylineId: const PolylineId('path'),
          points: pathCoordinates,
          color: Colors.blue,
          width: 4,
          geodesic: true,
        ),
      );
      debugPrint('✅ Polyline path added');
    }

    // Debug: show a red marker at every path waypoint
    debugPathMarkers = _buildDebugPathMarkersFromLatLng(pathCoordinates);

    // Add boundary polygons
    for (int i = 0; i < boundaryPolygons.length; i++) {
      polygons.add(
        Polygon(
          polygonId: PolygonId('boundary_$i'),
          points: boundaryPolygons[i],
          fillColor: Colors.green.withOpacity(0.2),
          strokeColor: Colors.green,
          strokeWidth: 3,
          geodesic: true,
        ),
      );
    }
    debugPrint('✅ ${polygons.length} polygon(s) added');

    setState(() {});
  }

  /// Debug markers from raw [lng, lat] pairs.
  /// Each input coordinate is converted to LatLng(lat, lng).
  Set<Marker> _buildDebugPathMarkersFromLngLat(List<List<double>> lngLatPath) {
    final points = <LatLng>[];
    for (final coord in lngLatPath) {
      if (coord.length < 2) continue;
      final lng = coord[0];
      final lat = coord[1];
      points.add(LatLng(lat, lng));
    }
    return _buildDebugPathMarkersFromLatLng(points);
  }

  /// Debug markers from LatLng points (red).
  Set<Marker> _buildDebugPathMarkersFromLatLng(List<LatLng> points) {
    return points.asMap().entries.map((entry) {
      final i = entry.key;
      final p = entry.value;
      return Marker(
        markerId: MarkerId('debug_path_$i'),
        position: p,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(
          title: 'Path point $i',
          snippet:
              'Lat: ${p.latitude.toStringAsFixed(6)}, Lng: ${p.longitude.toStringAsFixed(6)}',
        ),
      );
    }).toSet();
  }

  /// Update car marker position
  void _updateMarker() {
    final insideBoundary = _isPointInBoundary(_carMarkerPosition);
    final markerColor = insideBoundary
        ? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue)
        : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);

    markers = {
      Marker(
        markerId: const MarkerId('car'),
        position: _carMarkerPosition,
        infoWindow: InfoWindow(
          title: 'Car Position',
          snippet: 'Lat: ${_carMarkerPosition.latitude.toStringAsFixed(4)}, '
              'Lng: ${_carMarkerPosition.longitude.toStringAsFixed(4)}\n'
              'Inside Boundary: $insideBoundary',
        ),
        icon: markerColor,
      ),
    };
  }

  /// Point-in-Polygon check using ray casting algorithm
  bool _isPointInBoundary(LatLng point) {
    if (boundaryPolygons.isEmpty) return true;

    for (final polygon in boundaryPolygons) {
      if (_isPointInPolygon(point, polygon)) {
        return true;
      }
    }
    return false;
  }

  /// Ray casting algorithm for point-in-polygon detection
  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    int intersectionCount = 0;
    final n = polygon.length;

    for (int i = 0; i < n; i++) {
      final p1 = polygon[i];
      final p2 = polygon[(i + 1) % n];

      // Check if point latitude is between the two polygon points
      if ((p1.latitude <= point.latitude && point.latitude < p2.latitude) ||
          (p2.latitude <= point.latitude && point.latitude < p1.latitude)) {
        // Calculate intersection longitude
        final dx = p2.longitude - p1.longitude;
        final dy = p2.latitude - p1.latitude;
        final intersectionLng =
            p1.longitude + (dx / dy) * (point.latitude - p1.latitude);

        // Check if intersection is to the right of the point
        if (point.longitude < intersectionLng) {
          intersectionCount++;
        }
      }
    }

    // If intersection count is odd, point is inside polygon
    return intersectionCount.isOdd;
  }

  /// Start moving the marker along the path
  void _startMarkerAnimation() {
    if (_isMoving || pathCoordinates.isEmpty) return;

    _isMoving = true;
    _currentWaypointIndex = 0;
    debugPrint('🚗 Starting marker animation along path');

    setState(() {
      _statusMessage = '🚗 Car is moving...';
    });

    // Move marker every 500ms to next waypoint
    _movementTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_currentWaypointIndex < pathCoordinates.length) {
        _carMarkerPosition = pathCoordinates[_currentWaypointIndex];
        _updateMarker();

        final insideBoundary = _isPointInBoundary(_carMarkerPosition);
        debugPrint(
          '📍 Waypoint $_currentWaypointIndex: '
          'Pos(${_carMarkerPosition.latitude.toStringAsFixed(4)}, '
          '${_carMarkerPosition.longitude.toStringAsFixed(4)}) | '
          'Inside: $insideBoundary',
        );

        setState(() {
          _statusMessage =
              'Waypoint $_currentWaypointIndex / ${pathCoordinates.length} '
              '| Inside: $insideBoundary';
        });

        _currentWaypointIndex++;
      } else {
        // Animation complete
        _movementTimer?.cancel();
        _isMoving = false;
        debugPrint('✅ Animation complete');
        setState(() {
          _statusMessage = '✅ Journey complete!';
        });
      }
    });
  }

  /// Stop marker animation
  void _stopMarkerAnimation() {
    _movementTimer?.cancel();
    _isMoving = false;
    _currentWaypointIndex = 0;
    if (pathCoordinates.isNotEmpty) {
      _carMarkerPosition = pathCoordinates.first;
      _updateMarker();
    }
    debugPrint('⏹️ Animation stopped');
    setState(() {
      _statusMessage = '⏹️ Animation stopped';
    });
  }

  /// Calculate initial camera position
  CameraPosition _getInitialCameraPosition() {
    if (pathCoordinates.isEmpty) {
      return const CameraPosition(
        target: LatLng(0, 0),
        zoom: 15,
      );
    }

    // Center on first waypoint
    return CameraPosition(
      target: pathCoordinates.first,
      zoom: 16,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Google Maps
        if (!_isLoading)
          GoogleMap(
            onMapCreated: (controller) {
              _mapController = controller;
            },
            initialCameraPosition: _getInitialCameraPosition(),
            polylines: polylines,
            polygons: polygons,
            markers: {...markers, ...debugPathMarkers},
            myLocationButtonEnabled: true,
            compassEnabled: true,
            mapToolbarEnabled: true,
            zoomControlsEnabled: true,
          )
        else
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

        // Status Panel
        Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Status: $_statusMessage',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (!_isLoading) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Path Waypoints: ${pathCoordinates.length} | '
                    'Boundaries: ${boundaryPolygons.length}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Control Buttons
        Positioned(
          top: 16,
          right: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FloatingActionButton(
                heroTag: 'play',
                onPressed: _isLoading ? null : _startMarkerAnimation,
                tooltip: 'Start Animation',
                child: const Icon(Icons.play_arrow),
              ),
              const SizedBox(height: 8),
              FloatingActionButton(
                heroTag: 'stop',
                onPressed: _isLoading ? null : _stopMarkerAnimation,
                tooltip: 'Stop Animation',
                child: const Icon(Icons.stop),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
