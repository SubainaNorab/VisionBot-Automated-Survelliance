import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class AlertService {
  static const String _collection = 'alerts';

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DateTime? _lastAlertAt;
 
  DateTime? _lastGroupAt;
  DateTime? _lastSmokeAt;

  final int _faceCooldownMs = 2500;
  final int _groupCooldownMs = 5000; // 5 seconds for group
  final int _smokeCooldownMs = 3000;

  Future<void> createUnknownAlert({
    required double threshold,
    required String lens,
    String note = '',
  }) async {
    final now = DateTime.now();

    if (_lastAlertAt != null) {
      final diff = now.difference(_lastAlertAt!).inMilliseconds;
      if (diff < _faceCooldownMs) {
        return;
      }
    }

    _lastAlertAt = now;

    await _db.collection(_collection).add({
      'type': 'unknown_face',
      'created_at': FieldValue.serverTimestamp(),
      'created_at_local': now.toIso8601String(),
      'threshold': threshold,
      'lens': lens,
      'note': note,
    });
  }

/// Create group detection alert
  Future<void> createGroupAlert({
    required int personCount,
    required String lens,
  }) async {
    final now = DateTime.now();

    if (_lastGroupAt != null) {
      final diff = now.difference(_lastGroupAt!).inMilliseconds;
      if (diff < _groupCooldownMs) return;
    }

    _lastGroupAt = now;

    try {
      await _db.collection(_collection).add({
        'type': 'group_detected',
        'created_at': FieldValue.serverTimestamp(),
        'created_at_local': now.toIso8601String(),
        'person_count': personCount,
        'lens': lens,
        'note': 'Group of $personCount people detected',
      });
      debugPrint('✅ Group alert saved (count: $personCount)');
    } catch (e) {
      debugPrint('❌ Failed to save group alert: $e');
    }
  }

  /// Create smoking detection alert
  Future<void> createSmokingAlert({
    required String lens,
  }) async {
    final now = DateTime.now();

    if (_lastSmokeAt != null) {
      final diff = now.difference(_lastSmokeAt!).inMilliseconds;
      if (diff < _smokeCooldownMs) return;
    }

    _lastSmokeAt = now;

    try {
      await _db.collection(_collection).add({
        'type': 'smoking_detected',
        'created_at': FieldValue.serverTimestamp(),
        'created_at_local': now.toIso8601String(),
        'lens': lens,
        'note': 'Smoking detected',
      });
      debugPrint('✅ Smoking alert saved');
    } catch (e) {
      debugPrint('❌ Failed to save smoking alert: $e');
    }
  }

  /// Reset cooldowns 
  void resetCooldowns() {
    _lastAlertAt = null;
    _lastGroupAt = null;
    _lastSmokeAt = null;
  }
}
