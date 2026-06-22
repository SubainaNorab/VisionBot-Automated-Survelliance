// firestore_command_listener.dart
// Listens to Firestore for commands from VisionBot app
// Relays them to ESP32 via BLE
// Also writes car status back to Firestore

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'ble_navigation_service.dart';

class FirestoreCommandListener {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final BleNavigationService _ble;
  VoidCallback? onUserAppCommand;

  StreamSubscription? _commandSub;
  Timer? _statusTimer;

  // Last known car position from GPS
  double? lastLat;
  double? lastLng;
  String obstacleStatus = 'CLEAR';

  FirestoreCommandListener(this._ble);

  void start() {
    _listenForCommands();
    _startStatusReporter();
    debugPrint('[Firestore] Command listener started');
  }

  void stop() {
    _commandSub?.cancel();
    _statusTimer?.cancel();
  }

  // ── Listen for commands written by VisionBot ──────────────────────────────
  void _listenForCommands() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));

    _commandSub = _db
        .collection('ble_commands')
        .where('executed', isEqualTo: false)
        .where('sent_at', isGreaterThan: Timestamp.fromDate(cutoff))
        .snapshots()
        .listen((snapshot) async {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added ||
            change.type == DocumentChangeType.modified) {
          try {
            final data = change.doc.data();
            if (data == null) continue;

            final cmd = data['command'] as String?;

            final sentAt = (data['sent_at_client'] as Timestamp?)?.toDate();
            if (sentAt != null && 
              DateTime.now().difference(sentAt).inMinutes > 5) {
                // Mark old unexecuted commands as executed to clean up
                await change.doc.reference.update({'executed': true});
                continue;
              }
            if (cmd != null && ['F', 'L', 'R', 'S', 'E'].contains(cmd)) {
  debugPrint('[Firestore] Received command: $cmd');

  if (_ble.isConnected) {
    try {
      await _ble.sendCommand(cmd);
    } catch (e) {
      debugPrint('[Firestore] BLE send error: $e');
    }
  } else {
    debugPrint('[Firestore] BLE not connected, skipping: $cmd');
  }

  final source = data['source'] as String? ?? '';
  if (source == 'user_app') {
    onUserAppCommand?.call();
  }

  try {
    await change.doc.reference.update({'executed': true});
  } catch (e) {
    debugPrint('[Firestore] Failed to mark executed: $e');
  }
}
          } catch (e) {
            debugPrint('[Firestore] Command processing error: $e');
          }
        }
      }
    }, onError: (e) {
      debugPrint('[Firestore] Command listener error: $e');
    });
  }

  // ── Report car status back to Firestore for VisionBot to see ─────────────
  void _startStatusReporter() {
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        await _db.collection('car_status').doc('current').set({
          'online': _ble.isConnected,
          'obstacle_status': obstacleStatus,
          'latitude': lastLat,
          'longitude': lastLng,
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('[Firestore] Status report error: $e');
      }
    });
  }

  // Call this from BLE status stream when Arduino reports BLOCKED/CLEAR
  void updateObstacleStatus(String status) {
    obstacleStatus = status;
  }

  // Call this from GPS position updates
  void updatePosition(double lat, double lng) {
    lastLat = lat;
    lastLng = lng;
  }
}
