import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'dart:developer' as developer;

class LocationData {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double altitude;
  final DateTime timestamp;
  final double heading;
  final double speed;
  final String? address;

  LocationData({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.altitude,
    required this.timestamp,
    required this.heading,
    required this.speed,
    this.address,
  });

  Map<String, dynamic> toMap() => {
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'altitude': altitude,
    'timestamp': timestamp,
    'heading': heading,
    'speed': speed,
    'address': address,
  };

  String getGoogleMapsUrl() => 'https://maps.google.com/?q=$latitude,$longitude';
}

class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  Future<bool> requestLocationPermission() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        developer.log('Location permission denied forever');
        return false;
      }
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        developer.log('Location service disabled');
        return false;
      }
      return true;
    } catch (e) {
      developer.log('Error: $e');
      return false;
    }
  }

  Future<LocationData?> getCurrentLocationWithAddress() async {
    try {
      bool hasPermission = await requestLocationPermission();
      if (!hasPermission) return null;

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 10),
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () async {
          return await Geolocator.getLastKnownPosition() ??
              Position(
                latitude: 0, longitude: 0,
                timestamp: DateTime.now(),
                accuracy: 0, altitude: 0,
                altitudeAccuracy: 0, heading: 0,
                headingAccuracy: 0, speed: 0,
                speedAccuracy: 0,
              );
        },
      );

      String? address;
      try {
        List<Placemark> placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          Placemark p = placemarks.first;
          List<String> parts = [];
          if (p.name?.isNotEmpty ?? false) parts.add(p.name!);
          if (p.locality?.isNotEmpty ?? false) parts.add(p.locality!);
          if (p.administrativeArea?.isNotEmpty ?? false) parts.add(p.administrativeArea!);
          if (p.country?.isNotEmpty ?? false) parts.add(p.country!);
          address = parts.join(', ');
        }
      } catch (e) {
        developer.log('Geocoding error: $e');
      }

      return LocationData(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        altitude: position.altitude,
        timestamp: position.timestamp ?? DateTime.now(),
        heading: position.heading,
        speed: position.speed,
        address: address,
      );
    } catch (e) {
      developer.log('Location error: $e');
      return null;
    }
  }

  static double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    return Geolocator.distanceBetween(lat1, lon1, lat2, lon2);
  }
}