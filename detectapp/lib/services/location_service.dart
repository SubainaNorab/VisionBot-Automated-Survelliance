// lib/services/location_service.dart

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart' show placemarkFromCoordinates;

class LocationData {
  final double latitude;
  final double longitude;
  final String placeName;
  final String address;
  final DateTime timestamp;

  const LocationData({
    required this.latitude,
    required this.longitude,
    required this.placeName,
    required this.address,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'latitude': latitude,
        'longitude': longitude,
        'place_name': placeName,
        'address': address,
        'timestamp': timestamp.toIso8601String(),
      };
}

class LocationService {
  static LocationService? _instance;
  LocationData? _lastKnownLocation;

  static LocationService get instance {
    _instance ??= LocationService._();
    return _instance!;
  }

  LocationService._();

  LocationData? get lastKnownLocation => _lastKnownLocation;

  // ✅ FIX 1: Returns Future<void> not Future<bool>
  Future<void> initialize() async {
    debugPrint('📍 LocationService: initializing...');
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('⚠️ GPS: location services are OFF');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        debugPrint('❌ GPS: permission denied');
        return;
      }

      debugPrint('✅ GPS permission OK — doing warm-up...');

      // Warm-up fetch so GPS has a fix before first alert
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );

      _lastKnownLocation = LocationData(
        latitude: pos.latitude,
        longitude: pos.longitude,
        placeName: '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}',
        address: '',
        timestamp: DateTime.now(),
      );

      debugPrint('✅ GPS warm-up: ${pos.latitude}, ${pos.longitude}');
    } catch (e) {
      debugPrint('⚠️ GPS warm-up failed: $e');
    }
  }

  Future<LocationData?> getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 8),
      );

      String placeName =
          '${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}';
      String address = placeName;

      try {
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        ).timeout(const Duration(seconds: 5));

        if (placemarks.isNotEmpty) {
          final place = placemarks.first;
          final parts = <String>[
            if (place.name?.isNotEmpty == true) place.name!,
            if (place.subLocality?.isNotEmpty == true) place.subLocality!,
            if (place.locality?.isNotEmpty == true) place.locality!,
          ];
          if (parts.isNotEmpty) placeName = parts.join(', ');

          final addrParts = <String>[
            if (place.street?.isNotEmpty == true) place.street!,
            if (place.locality?.isNotEmpty == true) place.locality!,
            if (place.administrativeArea?.isNotEmpty == true) place.administrativeArea!,
            if (place.country?.isNotEmpty == true) place.country!,
          ];
          if (addrParts.isNotEmpty) address = addrParts.join(', ');
        }
      } catch (e) {
        debugPrint('⚠️ Geocoding failed, using coordinates: $e');
      }

      final data = LocationData(
        latitude: position.latitude,
        longitude: position.longitude,
        placeName: placeName,
        address: address,
        timestamp: DateTime.now(),
      );

      _lastKnownLocation = data;
      debugPrint('✅ GPS: $placeName');
      return data;
    } catch (e) {
      debugPrint('❌ GPS fetch failed: $e — using cached: $_lastKnownLocation');
      return _lastKnownLocation;
    }
  }

  Future<LocationData?> getLocationFast({int maxAgeSeconds = 30}) async {
    if (_lastKnownLocation != null) {
      final age = DateTime.now().difference(_lastKnownLocation!.timestamp).inSeconds;
      if (age < maxAgeSeconds) {
        debugPrint('📍 GPS: cached (${age}s old): ${_lastKnownLocation!.placeName}');
        return _lastKnownLocation;
      }
    }
    return getCurrentLocation();
  }
}