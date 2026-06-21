// alert_service.dart -

import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class AlertService {
  static const String _collection = 'alerts';

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  static final String _serverUrl =
      dotenv.env['RAILWAY_SERVER_URL'] ?? '';

  DateTime? _lastAlertAt;
  DateTime? _lastGroupAt;
  DateTime? _lastSmokeAt;

  final int _faceCooldownMs = 2500;
  final int _groupCooldownMs = 5000;
  final int _smokeCooldownMs = 3000;

  // ── NEW: sends the alert to the Railway server so it can push FCM ────────
  Future<void> _notifyRailway(Map<String, dynamic> alert) async {
    if (_serverUrl.isEmpty) {
      debugPrint('⚠️ RAILWAY_SERVER_URL not set, skipping push notify');
      return;
    }
    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/api/robot/alerts'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'alerts': [alert]}),
          )
          .timeout(const Duration(seconds: 5));

      debugPrint('📤 Railway notify status: ${response.statusCode}');
    } catch (e) {
      debugPrint('⚠️ Railway notify failed: $e');
    }
  }

  Future<void> createUnknownAlert({
    required double threshold,
    required String lens,
    String note = '',
    String? imagePath,
    List<String>? faceImagePaths,
    double? latitude,
    double? longitude,
    String? locationName,
  }) async {
    final now = DateTime.now();

    if (_lastAlertAt != null) {
      final diff = now.difference(_lastAlertAt!).inMilliseconds;
      if (diff < _faceCooldownMs) {
        return;
      }
    }

    _lastAlertAt = now;

    final alertId = 'alert_${now.millisecondsSinceEpoch}';

    await _db.collection(_collection).doc(alertId).set({
      'type': 'unknown_face',
      'alert_id': alertId,
      'created_at': FieldValue.serverTimestamp(),
      'created_at_local': now.toIso8601String(),
      'threshold': threshold,
      'lens': lens,
      'note': note,
      'image_path': imagePath,
      'face_image_paths': faceImagePaths,
      'has_image': imagePath != null,
      'face_count': faceImagePaths?.length ?? 0,
      'latitude': latitude,
      'longitude': longitude,
      'location_name': locationName,
    });

    debugPrint(' Unknown face alert saved with location: $locationName');

    // NEW: push to Railway -> FCM
    _notifyRailway({
      'alert_id': alertId,
      'type': 'unknown_face',
      'title': 'Unknown Person Detected',
      'message': note.isEmpty ? 'Unknown face detected by VisionBot' : note,
    });
  }

  Future<void> createGroupAlert({
    required int personCount,
    required String lens,
    String? imagePath,
    double? latitude,
    double? longitude,
    String? locationName,
  }) async {
    final now = DateTime.now();

    if (_lastGroupAt != null) {
      final diff = now.difference(_lastGroupAt!).inMilliseconds;
      if (diff < _groupCooldownMs) return;
    }

    _lastGroupAt = now;

    final alertId = 'alert_${now.millisecondsSinceEpoch}';

    try {
      await _db.collection(_collection).doc(alertId).set({
        'type': 'group_detected',
        'alert_id': alertId,
        'created_at': FieldValue.serverTimestamp(),
        'created_at_local': now.toIso8601String(),
        'person_count': personCount,
        'lens': lens,
        'note': 'Group of $personCount people detected',
        'image_path': imagePath,
        'has_image': imagePath != null,
        'latitude': latitude,
        'longitude': longitude,
        'location_name': locationName,
      });
      debugPrint(' Group alert saved with location: $locationName');

      // NEW: push to Railway -> FCM
      _notifyRailway({
        'alert_id': alertId,
        'type': 'group_detected',
        'title': 'Group Detected',
        'message': 'Group of $personCount people detected',
      });
    } catch (e) {
      debugPrint(' Failed to save group alert: $e');
    }
  }

  Future<void> createSmokingAlert({
    required String lens,
    String? imagePath,
    double? latitude,
    double? longitude,
    String? locationName,
  }) async {
    final now = DateTime.now();

    if (_lastSmokeAt != null) {
      final diff = now.difference(_lastSmokeAt!).inMilliseconds;
      if (diff < _smokeCooldownMs) return;
    }

    _lastSmokeAt = now;

    final alertId = 'alert_${now.millisecondsSinceEpoch}';

    try {
      await _db.collection(_collection).doc(alertId).set({
        'type': 'smoking_detected',
        'alert_id': alertId,
        'created_at': FieldValue.serverTimestamp(),
        'created_at_local': now.toIso8601String(),
        'lens': lens,
        'note': 'Smoking detected',
        'image_path': imagePath,
        'has_image': imagePath != null,
        'latitude': latitude,
        'longitude': longitude,
        'location_name': locationName,
      });
      debugPrint('🚬 Smoking alert saved with location: $locationName');

      // NEW: push to Railway -> FCM
      _notifyRailway({
        'alert_id': alertId,
        'type': 'smoking_detected',
        'title': 'Smoking Detected',
        'message': 'Smoking detected by VisionBot',
      });
    } catch (e) {
      debugPrint(' Failed to save smoking alert: $e');
    }
  }

  void resetCooldowns() {
    _lastAlertAt = null;
    _lastGroupAt = null;
    _lastSmokeAt = null;
  }
}