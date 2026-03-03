// location_service.dart - GPS Location Fetching

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart'
    show Geolocator, LocationPermission, LocationAccuracy;
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

  Map<String, dynamic> toMap() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'place_name': placeName,
      'address': address,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  @override
  String toString() =>
      'LocationData(lat: $latitude, lng: $longitude, place: $placeName)';
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

  /// Initialize and request permissions
  Future<bool> initialize() async {
    debugPrint('📍 Initializing LocationService...');

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('⚠️ Location services are disabled.');
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('⚠️ Location permission denied.');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('❌ Location permission permanently denied.');
      return false;
    }

    debugPrint('✅ LocationService initialized with permission: $permission');
    return true;
  }

  /// Get current GPS location with place name
  Future<LocationData?> getCurrentLocation() async {
    try {
      debugPrint('📍 Fetching current location...');

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      debugPrint(
          '📍 Got position: ${position.latitude}, ${position.longitude}');

      // Reverse geocode to get place name
      String placeName = 'Unknown location';
      String address = '${position.latitude}, ${position.longitude}';

      try {
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        ).timeout(const Duration(seconds: 5));

        if (placemarks.isNotEmpty) {
          final place = placemarks.first;

          // Build human-readable place name
          final parts = <String>[];

          if (place.name != null && place.name!.isNotEmpty) {
            parts.add(place.name!);
          }
          if (place.subLocality != null && place.subLocality!.isNotEmpty) {
            parts.add(place.subLocality!);
          }
          if (place.locality != null && place.locality!.isNotEmpty) {
            parts.add(place.locality!);
          }

          placeName = parts.isNotEmpty ? parts.join(', ') : 'Unknown location';

          // Full address
          final addrParts = <String>[];
          if (place.street != null && place.street!.isNotEmpty) {
            addrParts.add(place.street!);
          }
          if (place.subLocality != null && place.subLocality!.isNotEmpty) {
            addrParts.add(place.subLocality!);
          }
          if (place.locality != null && place.locality!.isNotEmpty) {
            addrParts.add(place.locality!);
          }
          if (place.administrativeArea != null &&
              place.administrativeArea!.isNotEmpty) {
            addrParts.add(place.administrativeArea!);
          }
          if (place.country != null && place.country!.isNotEmpty) {
            addrParts.add(place.country!);
          }

          address = addrParts.join(', ');
          debugPrint('📍 Place: $placeName');
          debugPrint('📍 Address: $address');
        }
      } catch (e) {
        debugPrint('⚠️ Reverse geocoding failed: $e');
        // Fallback to coordinates
        placeName = 'Lat: ${position.latitude.toStringAsFixed(4)}, '
            'Lng: ${position.longitude.toStringAsFixed(4)}';
      }

      final locationData = LocationData(
        latitude: position.latitude,
        longitude: position.longitude,
        placeName: placeName,
        address: address,
        timestamp: DateTime.now(),
      );

      _lastKnownLocation = locationData;
      return locationData;
    } catch (e) {
      debugPrint('❌ Failed to get location: $e');

      // Return last known location as fallback
      if (_lastKnownLocation != null) {
        debugPrint('ℹ️ Using last known location as fallback');
        return _lastKnownLocation;
      }
      return null;
    }
  }

  /// Quick location fetch (uses last known if recent enough)
  Future<LocationData?> getLocationFast({
    int maxAgeSeconds = 30,
  }) async {
    // Use cached location if recent
    if (_lastKnownLocation != null) {
      final age =
          DateTime.now().difference(_lastKnownLocation!.timestamp).inSeconds;
      if (age < maxAgeSeconds) {
        debugPrint(
            '📍 Using cached location (${age}s old): ${_lastKnownLocation!.placeName}');
        return _lastKnownLocation;
      }
    }
    return getCurrentLocation();
  }
}
