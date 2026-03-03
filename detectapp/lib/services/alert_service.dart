// lib/services/alert_service.dart
// KEY FIX: uploads images to Firebase Storage before saving URL to Firestore

import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

class AlertService {
  static const String _collection = 'alerts';

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance; // ✅ ADDED

  DateTime? _lastAlertAt;
  DateTime? _lastGroupAt;
  DateTime? _lastSmokeAt;

  final int _faceCooldownMs = 2500;
  final int _groupCooldownMs = 5000;
  final int _smokeCooldownMs = 3000;

  // ✅ FIX: uploads image to Storage and saves download URL (not local path)
  Future<String?> _uploadImage(String? localPath, String folder) async {
    if (localPath == null) return null;
    final file = File(localPath);
    if (!await file.exists()) {
      debugPrint('⚠️ Image not found for upload: $localPath');
      return null;
    }
    try {
      final name = '${folder}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = _storage.ref().child('alerts/$folder/$name');
      await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      debugPrint('📤 Image uploaded: $url');
      return url;
    } catch (e) {
      debugPrint('❌ Image upload failed: $e');
      return null;
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
    String? placeName,
    String? address,
  }) async {
    final now = DateTime.now();
    if (_lastAlertAt != null &&
        now.difference(_lastAlertAt!).inMilliseconds < _faceCooldownMs) {
      debugPrint('⏱️ Unknown alert skipped (cooldown)');
      return;
    }
    _lastAlertAt = now;

    debugPrint('🚨 Saving unknown face alert...');
    debugPrint('   GPS: ${latitude != null ? "$latitude, $longitude" : "none"}');
    debugPrint('   Image: ${imagePath ?? "none"}');

    // ✅ Upload image to Firebase Storage first
    final imageUrl = await _uploadImage(imagePath, 'unknown_face');

    final data = <String, dynamic>{
      'type': 'unknown_face',
      'created_at': FieldValue.serverTimestamp(),
      'created_at_local': now.toIso8601String(),
      'threshold': threshold,
      'lens': lens,
      'note': note,
      'has_image': imageUrl != null,
    };

    // ✅ Save Firebase Storage URL (not local path)
    if (imageUrl != null) {
      data['image_url'] = imageUrl;
    }

    // ✅ Save GPS data
    if (latitude != null && longitude != null) {
      data['latitude'] = latitude;
      data['longitude'] = longitude;
      data['place_name'] = placeName ?? 'Unknown';
      data['address'] = address ?? '';
      data['has_location'] = true;
      data['geo_point'] = GeoPoint(latitude, longitude);
    } else {
      data['has_location'] = false;
    }

    await _db.collection(_collection).add(data);

    debugPrint('✅ Alert saved — GPS: ${latitude != null ? "YES ($placeName)" : "NO"}'
        ' — Image: ${imageUrl != null ? "YES" : "NO"}');
  }

  Future<void> createGroupAlert({
    required int personCount,
    required String lens,
    String? imagePath,
    double? latitude,
    double? longitude,
    String? placeName,
    String? address,
  }) async {
    final now = DateTime.now();
    if (_lastGroupAt != null &&
        now.difference(_lastGroupAt!).inMilliseconds < _groupCooldownMs) return;
    _lastGroupAt = now;

    try {
      final imageUrl = await _uploadImage(imagePath, 'group_detected');

      final data = <String, dynamic>{
        'type': 'group_detected',
        'created_at': FieldValue.serverTimestamp(),
        'created_at_local': now.toIso8601String(),
        'person_count': personCount,
        'lens': lens,
        'note': 'Group of $personCount people detected',
        'has_image': imageUrl != null,
        if (imageUrl != null) 'image_url': imageUrl,
        'has_location': latitude != null,
        if (latitude != null) ...{
          'latitude': latitude,
          'longitude': longitude,
          'place_name': placeName ?? 'Unknown',
          'address': address ?? '',
          'geo_point': GeoPoint(latitude, longitude!),
        },
      };

      await _db.collection(_collection).add(data);
      debugPrint('✅ Group alert saved ($personCount people)');
    } catch (e) {
      debugPrint('❌ Group alert failed: $e');
    }
  }

  Future<void> createSmokingAlert({
    required String lens,
    String? imagePath,
    double? latitude,
    double? longitude,
    String? placeName,
    String? address,
  }) async {
    final now = DateTime.now();
    if (_lastSmokeAt != null &&
        now.difference(_lastSmokeAt!).inMilliseconds < _smokeCooldownMs) return;
    _lastSmokeAt = now;

    try {
      final imageUrl = await _uploadImage(imagePath, 'smoking_detected');

      final data = <String, dynamic>{
        'type': 'smoking_detected',
        'created_at': FieldValue.serverTimestamp(),
        'created_at_local': now.toIso8601String(),
        'lens': lens,
        'note': 'Smoking detected',
        'has_image': imageUrl != null,
        if (imageUrl != null) 'image_url': imageUrl,
        'has_location': latitude != null,
        if (latitude != null) ...{
          'latitude': latitude,
          'longitude': longitude,
          'place_name': placeName ?? 'Unknown',
          'address': address ?? '',
          'geo_point': GeoPoint(latitude, longitude!),
        },
      };

      await _db.collection(_collection).add(data);
      debugPrint('✅ Smoking alert saved');
    } catch (e) {
      debugPrint('❌ Smoking alert failed: $e');
    }
  }

  void resetCooldowns() {
    _lastAlertAt = null;
    _lastGroupAt = null;
    _lastSmokeAt = null;
  }
}