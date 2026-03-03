// alert_service.dart - UPDATED WITH LOCATION SUPPORT
// ⚠️ IMPORTANT: All existing functionality preserved. Only location fields added.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class AlertService {
  static const String _collection = 'alerts';

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DateTime? _lastAlertAt;
  DateTime? _lastGroupAt;
  DateTime? _lastSmokeAt;

  final int _faceCooldownMs = 2500;
  final int _groupCooldownMs = 5000;
  final int _smokeCooldownMs = 3000;

  Future<void> createUnknownAlert({
    required double threshold,
    required String lens,
    String note = '',
    String? imagePath,
    List<String>? faceImagePaths,
    // ✅ NEW: location fields (optional — won't break if not provided)
    double? latitude,
    double? longitude,
    String? placeName,
    String? address,
  }) async {
    final now = DateTime.now();

    if (_lastAlertAt != null) {
      final diff = now.difference(_lastAlertAt!).inMilliseconds;
      if (diff < _faceCooldownMs) {
        return;
      }
    }

    _lastAlertAt = now;

    // ✅ Build data map — location fields added but won't break if null
    final data = <String, dynamic>{
      'type': 'unknown_face',
      'created_at': FieldValue.serverTimestamp(),
      'created_at_local': now.toIso8601String(),
      'threshold': threshold,
      'lens': lens,
      'note': note,
      'image_path': imagePath,
      'face_image_paths': faceImagePaths,
      'has_image': imagePath != null,
      'face_count': faceImagePaths?.length ?? 0,
    };

    // ✅ Add location data only if available
    if (latitude != null && longitude != null) {
      data['latitude'] = latitude;
      data['longitude'] = longitude;
      data['place_name'] = placeName ?? 'Unknown location';
      data['address'] = address ?? '';
      data['has_location'] = true;
      data['geo_point'] = GeoPoint(latitude, longitude);
    } else {
      data['has_location'] = false;
    }

    await _db.collection(_collection).add(data);

    debugPrint('✅ Unknown face alert saved'
        '${imagePath != null ? ' with image' : ''}'
        '${latitude != null ? ' at $placeName' : ''}');
  }

  Future<void> createGroupAlert({
    required int personCount,
    required String lens,
    String? imagePath,
    // ✅ NEW: location fields
    double? latitude,
    double? longitude,
    String? placeName,
    String? address,
  }) async {
    final now = DateTime.now();

    if (_lastGroupAt != null) {
      final diff = now.difference(_lastGroupAt!).inMilliseconds;
      if (diff < _groupCooldownMs) return;
    }

    _lastGroupAt = now;

    try {
      final data = <String, dynamic>{
        'type': 'group_detected',
        'created_at': FieldValue.serverTimestamp(),
        'created_at_local': now.toIso8601String(),
        'person_count': personCount,
        'lens': lens,
        'note': 'Group of $personCount people detected',
        'image_path': imagePath,
        'has_image': imagePath != null,
      };

      if (latitude != null && longitude != null) {
        data['latitude'] = latitude;
        data['longitude'] = longitude;
        data['place_name'] = placeName ?? 'Unknown location';
        data['address'] = address ?? '';
        data['has_location'] = true;
        data['geo_point'] = GeoPoint(latitude, longitude);
      } else {
        data['has_location'] = false;
      }

      await _db.collection(_collection).add(data);
      debugPrint('✅ Group alert saved (count: $personCount)'
          '${imagePath != null ? ' with image' : ''}'
          '${latitude != null ? ' at $placeName' : ''}');
    } catch (e) {
      debugPrint('❌ Failed to save group alert: $e');
    }
  }

  Future<void> createSmokingAlert({
    required String lens,
    String? imagePath,
    // ✅ NEW: location fields
    double? latitude,
    double? longitude,
    String? placeName,
    String? address,
  }) async {
    final now = DateTime.now();

    if (_lastSmokeAt != null) {
      final diff = now.difference(_lastSmokeAt!).inMilliseconds;
      if (diff < _smokeCooldownMs) return;
    }

    _lastSmokeAt = now;

    try {
      final data = <String, dynamic>{
        'type': 'smoking_detected',
        'created_at': FieldValue.serverTimestamp(),
        'created_at_local': now.toIso8601String(),
        'lens': lens,
        'note': 'Smoking detected',
        'image_path': imagePath,
        'has_image': imagePath != null,
      };

      if (latitude != null && longitude != null) {
        data['latitude'] = latitude;
        data['longitude'] = longitude;
        data['place_name'] = placeName ?? 'Unknown location';
        data['address'] = address ?? '';
        data['has_location'] = true;
        data['geo_point'] = GeoPoint(latitude, longitude);
      } else {
        data['has_location'] = false;
      }

      await _db.collection(_collection).add(data);
      debugPrint('🚬 Smoking alert saved'
          '${imagePath != null ? ' with image' : ''}'
          '${latitude != null ? ' at $placeName' : ''}');
    } catch (e) {
      debugPrint('❌ Failed to save smoking alert: $e');
    }
  }

  void resetCooldowns() {
    _lastAlertAt = null;
    _lastGroupAt = null;
    _lastSmokeAt = null;
  }
}