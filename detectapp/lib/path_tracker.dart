// path_tracker.dart
// Computes car position relative to path and generates correction commands

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';

enum PathStatus {
  onPath,        // within tolerance, go straight
  driftLeft,     // car has drifted left of path centre
  driftRight,    // car has drifted right of path centre
  offPath,       // far off path, needs significant correction
  atWaypoint,    // near a corner, needs to turn
}

class PathCorrection {
  final PathStatus status;
  final String? command;      // 'L', 'R', 'F', or null
  final double crossTrackM;   // metres left(+) or right(-) of path
  final double distToWaypointM;
  final int nextWaypointIndex;
  final String description;

  const PathCorrection({
    required this.status,
    required this.command,
    required this.crossTrackM,
    required this.distToWaypointM,
    required this.nextWaypointIndex,
    required this.description,
  });
}

class PathTracker {
  final List<LatLng> path;

  // How close to a waypoint corner before turning (metres)
  // Keep at 5-8m for outdoor GPS accuracy
  final double waypointThresholdM;

  // Within this distance of path centre = on path, no correction
  final double onPathToleranceM;

  // Beyond this = significant drift, send correction turn
  final double correctionThresholdM;

  int _currentSegment = 0;  // which segment of path we're on

  PathTracker({
    required this.path,
    this.waypointThresholdM    = 6.0,
    this.onPathToleranceM      = 2.5,
    this.correctionThresholdM  = 4.0,
  });

  void reset() {
    _currentSegment = 0;
  }

  int get currentSegment => _currentSegment;

  /// Main method — call this on every GPS update
  /// Returns what correction (if any) the car needs
  PathCorrection evaluate(LatLng carPos) {
    if (path.length < 2) {
      return PathCorrection(
        status: PathStatus.onPath,
        command: null,
        crossTrackM: 0,
        distToWaypointM: 0,
        nextWaypointIndex: 0,
        description: 'No path loaded',
      );
    }

    // Find which segment the car is currently on
    _updateCurrentSegment(carPos);

    // Get current segment endpoints
    final segStart = path[_currentSegment];
    final segEnd   = path[(_currentSegment + 1) % path.length];

    // Distance to the end waypoint of this segment
    final distToWaypoint = Geolocator.distanceBetween(
      carPos.latitude, carPos.longitude,
      segEnd.latitude, segEnd.longitude,
    );

    // Check if we're at the waypoint corner
    if (distToWaypoint < waypointThresholdM) {
      final turnCmd = _turnDirectionAt(_currentSegment + 1);
      return PathCorrection(
        status: PathStatus.atWaypoint,
        command: turnCmd,
        crossTrackM: 0,
        distToWaypointM: distToWaypoint,
        nextWaypointIndex: (_currentSegment + 1) % path.length,
        description: 'Corner — turn ${turnCmd == "L" ? "Left" : "Right"}',
      );
    }

    // Cross-track error — how far left/right of the path centre
    final crossTrack = _crossTrackErrorM(carPos, segStart, segEnd);

    debugPrint('[PATH] Cross-track: ${crossTrack.toStringAsFixed(2)}m, '
        'dist to corner: ${distToWaypoint.toStringAsFixed(1)}m');

    // Determine status and correction
    if (crossTrack.abs() <= onPathToleranceM) {
      return PathCorrection(
        status: PathStatus.onPath,
        command: 'F',
        crossTrackM: crossTrack,
        distToWaypointM: distToWaypoint,
        nextWaypointIndex: (_currentSegment + 1) % path.length,
        description: 'On path ✅',
      );
    }

    if (crossTrack.abs() > onPathToleranceM) {
      // crossTrack > 0 means car is LEFT of path → turn right to correct
      // crossTrack < 0 means car is RIGHT of path → turn left to correct
      final String cmd = crossTrack > 0 ? 'R' : 'L';
      final bool significant = crossTrack.abs() > correctionThresholdM;

      return PathCorrection(
        status: significant ? PathStatus.offPath : PathStatus.driftLeft,
        command: cmd,
        crossTrackM: crossTrack,
        distToWaypointM: distToWaypoint,
        nextWaypointIndex: (_currentSegment + 1) % path.length,
        description: significant
            ? 'Off path! Correcting ${cmd == "L" ? "←" : "→"}'
            : 'Drift ${crossTrack > 0 ? "left" : "right"} — nudging ${cmd == "L" ? "←" : "→"}',
      );
    }

    return PathCorrection(
      status: PathStatus.onPath,
      command: 'F',
      crossTrackM: crossTrack,
      distToWaypointM: distToWaypoint,
      nextWaypointIndex: (_currentSegment + 1) % path.length,
      description: 'On path',
    );
  }

  /// Cross-track error in metres
  /// Positive = car is to the LEFT of path direction
  /// Negative = car is to the RIGHT of path direction
  double _crossTrackErrorM(LatLng car, LatLng segA, LatLng segB) {
    // Convert to local flat metres relative to segA
    final carX  = _lngToM(car.longitude  - segA.longitude, segA.latitude);
    final carY  = _latToM(car.latitude   - segA.latitude);
    final endX  = _lngToM(segB.longitude - segA.longitude, segA.latitude);
    final endY  = _latToM(segB.latitude  - segA.latitude);

    final segLen = (endX * endX + endY * endY);
    if (segLen < 0.001) return 0;

    // Unit vector along segment
    final len  = _sqrt(segLen);
    final ux   = endX / len;
    final uy   = endY / len;

    // Cross product (signed area) gives left/right
    // positive = left of direction, negative = right
    return carX * uy - carY * ux;
  }

  /// Find which segment the car is currently closest to
  void _updateCurrentSegment(LatLng car) {
    if (path.length < 2) return;

    double minDist = double.infinity;
    int    bestSeg = _currentSegment;

    // Only check current segment and a few ahead (don't jump backwards)
    final end = (path.length - 1).clamp(0, path.length - 1);
    for (int i = _currentSegment; i < end; i++) {
      final d = _distToSegmentM(car, path[i], path[(i + 1) % path.length]);
      if (d < minDist) {
        minDist = d;
        bestSeg = i;
      }
    }

    if (bestSeg != _currentSegment) {
      debugPrint('[PATH] Segment: $_currentSegment → $bestSeg');
      _currentSegment = bestSeg;
    }
  }

  /// Perpendicular distance from point to segment in metres
  double _distToSegmentM(LatLng p, LatLng a, LatLng b) {
    final px = _lngToM(p.longitude - a.longitude, a.latitude);
    final py = _latToM(p.latitude  - a.latitude);
    final bx = _lngToM(b.longitude - a.longitude, a.latitude);
    final by = _latToM(b.latitude  - a.latitude);

    final lenSq = bx * bx + by * by;
    if (lenSq < 0.001) {
      return Geolocator.distanceBetween(
        p.latitude, p.longitude, a.latitude, a.longitude);
    }

    double t = ((px * bx + py * by) / lenSq).clamp(0.0, 1.0);
    final dx = px - t * bx;
    final dy = py - t * by;
    return _sqrt(dx * dx + dy * dy);
  }

  /// Turn direction at a given waypoint index using cross product
  String _turnDirectionAt(int waypointIndex) {
    if (path.length < 3) return 'R';

    final prev = path[(waypointIndex - 1) % path.length];
    final curr = path[waypointIndex % path.length];
    final next = path[(waypointIndex + 1) % path.length];

    final ax = curr.longitude - prev.longitude;
    final ay = curr.latitude  - prev.latitude;
    final bx = next.longitude - curr.longitude;
    final by = next.latitude  - curr.latitude;

    // Cross product z — negative = clockwise = right turn
    final cross = ax * by - ay * bx;
    return cross < 0 ? 'R' : 'L';
  }

  double _latToM(double dLat) => dLat * 110540.0;

  double _lngToM(double dLng, double refLat) {
    final cosLat = _cos(refLat * 3.14159265358979 / 180.0);
    return dLng * 111320.0 * cosLat;
  }

  double _cos(double rad) {
    return 1.0 - (rad*rad)/2.0 + (rad*rad*rad*rad)/24.0;
  }

  double _sqrt(double v) {
    if (v <= 0) return 0;
    double x = v;
    for (int i = 0; i < 10; i++) x = (x + v / x) / 2;
    return x;
  }
}