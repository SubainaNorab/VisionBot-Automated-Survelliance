// navigation_state.dart
// Clean state model for navigation

enum CarCommand { forward, left, right, stop, emergency }

class NavigationState {
  final bool bleConnected;
  final bool patrolActive;
  final bool onPath;
  final String carStatus;     // BLOCKED / CLEAR
  final String statusMessage;
  final int currentWaypoint;
  final double? distToWaypoint;

  const NavigationState({
    this.bleConnected = false,
    this.patrolActive = false,
    this.onPath = true,
    this.carStatus = 'CLEAR',
    this.statusMessage = 'Connect BLE to start',
    this.currentWaypoint = 0,
    this.distToWaypoint,
  });

  NavigationState copyWith({
    bool? bleConnected,
    bool? patrolActive,
    bool? onPath,
    String? carStatus,
    String? statusMessage,
    int? currentWaypoint,
    double? distToWaypoint,
  }) {
    return NavigationState(
      bleConnected: bleConnected ?? this.bleConnected,
      patrolActive: patrolActive ?? this.patrolActive,
      onPath: onPath ?? this.onPath,
      carStatus: carStatus ?? this.carStatus,
      statusMessage: statusMessage ?? this.statusMessage,
      currentWaypoint: currentWaypoint ?? this.currentWaypoint,
      distToWaypoint: distToWaypoint ?? this.distToWaypoint,
    );
  }
}