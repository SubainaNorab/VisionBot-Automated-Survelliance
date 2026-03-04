import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:io';
import 'dart:developer' as developer;
import 'location_service.dart';

class UnknownFaceAlert {
  final String id;
  final DateTime timestamp;
  final String? imageUrl;
  final LocationData? location;
  final double confidence;
  final String? description;
  final bool isResolved;

  UnknownFaceAlert({
    this.id = '',
    required this.timestamp,
    this.imageUrl,
    this.location,
    required this.confidence,
    this.description,
    this.isResolved = false,
  });

  Map<String, dynamic> toFirestoreMap() => {
    'timestamp': timestamp,
    'imageUrl': imageUrl,
    'location': location?.toMap(),
    'address': location?.address ?? 'Unknown',
    'latitude': location?.latitude ?? 0.0,
    'longitude': location?.longitude ?? 0.0,
    'accuracy': location?.accuracy ?? 0.0,
    'confidence': confidence,
    'description': description,
    'isResolved': isResolved,
    'createdAt': FieldValue.serverTimestamp(),
  };

  static UnknownFaceAlert fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    LocationData? location;
    try {
      final locMap = data['location'] as Map<String, dynamic>?;
      if (locMap != null) {
        location = LocationData(
          latitude: (locMap['latitude'] as num?)?.toDouble() ?? 0,
          longitude: (locMap['longitude'] as num?)?.toDouble() ?? 0,
          accuracy: (locMap['accuracy'] as num?)?.toDouble() ?? 0,
          altitude: (locMap['altitude'] as num?)?.toDouble() ?? 0,
          timestamp: (locMap['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
          heading: (locMap['heading'] as num?)?.toDouble() ?? 0,
          speed: (locMap['speed'] as num?)?.toDouble() ?? 0,
          address: data['address'] as String?,
        );
      }
    } catch (e) {
      developer.log('Parse error: $e');
    }

    return UnknownFaceAlert(
      id: doc.id,
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      imageUrl: data['imageUrl'] as String?,
      location: location,
      confidence: (data['confidence'] as num?)?.toDouble() ?? 0,
      description: data['description'] as String?,
      isResolved: data['isResolved'] as bool? ?? false,
    );
  }
}

class AlertService {
  static final AlertService _instance = AlertService._internal();
  factory AlertService() => _instance;
  AlertService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  static const String UNKNOWN_FACES_COLLECTION = 'unknown_faces';
  static const String GROUP_ALERTS_COLLECTION = 'group_alerts';
  static const String SMOKING_ALERTS_COLLECTION = 'smoking_alerts';

  // ✅ Create unknown face alert WITH location data
  Future<void> createUnknownAlert({
    String? imagePath,
    List<String>? faceImagePaths,
    required String note,
    double? latitude,
    double? longitude,
    String? placeName,
    String? address,
  }) async {
    try {
      developer.log('📝 Creating unknown face alert...');

      String? imageUrl;
      
      // Upload image if provided
      if (imagePath != null) {
        File imageFile = File(imagePath);
        if (await imageFile.exists()) {
          developer.log('📤 Uploading image...');
          String fileName = 'unknown_faces/${DateTime.now().millisecondsSinceEpoch}.jpg';
          Reference ref = _storage.ref().child(fileName);

          TaskSnapshot uploadTask = await ref.putFile(
            imageFile,
            SettableMetadata(
              contentType: 'image/jpeg',
              customMetadata: {
                'timestamp': DateTime.now().toIso8601String(),
                'type': 'unknown_face_alert',
              },
            ),
          );

          imageUrl = await uploadTask.ref.getDownloadURL();
          developer.log('✅ Image uploaded: $imageUrl');
        }
      }

      // Create Firestore document with location data
      Map<String, dynamic> alertData = {
        'timestamp': DateTime.now(),
        'imageUrl': imageUrl,
        'note': note,
        'type': 'unknown_face',
        'isResolved': false,
        'createdAt': FieldValue.serverTimestamp(),
        
        // ✅ Location data fields
        'latitude': latitude ?? 0.0,
        'longitude': longitude ?? 0.0,
        'placeName': placeName ?? 'Unknown',
        'address': address ?? 'Unknown',
        'hasLocation': latitude != null && longitude != null,
      };

      if (faceImagePaths != null && faceImagePaths.isNotEmpty) {
        alertData['faceImagePaths'] = faceImagePaths;
      }

      DocumentReference docRef = 
          await _firestore.collection(UNKNOWN_FACES_COLLECTION).add(alertData);

      developer.log('✅ Alert saved to Firestore: ${docRef.id}');
      developer.log('   Latitude: $latitude');
      developer.log('   Longitude: $longitude');
      developer.log('   Place: $placeName');
      developer.log('   Address: $address');
    } catch (e) {
      developer.log('❌ Error creating unknown alert: $e');
      rethrow;
    }
  }

  // ✅ Create group alert WITH location data
  Future<void> createGroupAlert({
    required int personCount,
    required String lens,
    String? imagePath,
    double? latitude,
    double? longitude,
    String? placeName,
    String? address,
  }) async {
    try {
      developer.log('📝 Creating group alert...');

      String? imageUrl;

      if (imagePath != null) {
        File imageFile = File(imagePath);
        if (await imageFile.exists()) {
          developer.log('📤 Uploading group image...');
          String fileName = 'group_alerts/${DateTime.now().millisecondsSinceEpoch}.jpg';
          Reference ref = _storage.ref().child(fileName);

          TaskSnapshot uploadTask = await ref.putFile(
            imageFile,
            SettableMetadata(
              contentType: 'image/jpeg',
              customMetadata: {
                'timestamp': DateTime.now().toIso8601String(),
                'type': 'group_alert',
                'personCount': personCount.toString(),
              },
            ),
          );

          imageUrl = await uploadTask.ref.getDownloadURL();
          developer.log('✅ Group image uploaded: $imageUrl');
        }
      }

      Map<String, dynamic> alertData = {
        'timestamp': DateTime.now(),
        'type': 'group_detection',
        'personCount': personCount,
        'lens': lens,
        'imageUrl': imageUrl,
        'isResolved': false,
        'createdAt': FieldValue.serverTimestamp(),
        
        // ✅ Location data fields
        'latitude': latitude ?? 0.0,
        'longitude': longitude ?? 0.0,
        'placeName': placeName ?? 'Unknown',
        'address': address ?? 'Unknown',
        'hasLocation': latitude != null && longitude != null,
      };

      DocumentReference docRef =
          await _firestore.collection(GROUP_ALERTS_COLLECTION).add(alertData);

      developer.log('✅ Group alert saved: ${docRef.id}');
      developer.log('   Person count: $personCount');
      developer.log('   Location: $placeName');
    } catch (e) {
      developer.log('❌ Error creating group alert: $e');
      rethrow;
    }
  }

  // ✅ Create smoking alert WITH location data
  Future<void> createSmokingAlert({
    required String lens,
    String? imagePath,
    double? latitude,
    double? longitude,
    String? placeName,
    String? address,
  }) async {
    try {
      developer.log('📝 Creating smoking alert...');

      String? imageUrl;

      if (imagePath != null) {
        File imageFile = File(imagePath);
        if (await imageFile.exists()) {
          developer.log('📤 Uploading smoking image...');
          String fileName = 'smoking_alerts/${DateTime.now().millisecondsSinceEpoch}.jpg';
          Reference ref = _storage.ref().child(fileName);

          TaskSnapshot uploadTask = await ref.putFile(
            imageFile,
            SettableMetadata(
              contentType: 'image/jpeg',
              customMetadata: {
                'timestamp': DateTime.now().toIso8601String(),
                'type': 'smoking_alert',
              },
            ),
          );

          imageUrl = await uploadTask.ref.getDownloadURL();
          developer.log('✅ Smoking image uploaded: $imageUrl');
        }
      }

      Map<String, dynamic> alertData = {
        'timestamp': DateTime.now(),
        'type': 'smoking_detection',
        'lens': lens,
        'imageUrl': imageUrl,
        'isResolved': false,
        'createdAt': FieldValue.serverTimestamp(),
        
        // ✅ Location data fields
        'latitude': latitude ?? 0.0,
        'longitude': longitude ?? 0.0,
        'placeName': placeName ?? 'Unknown',
        'address': address ?? 'Unknown',
        'hasLocation': latitude != null && longitude != null,
      };

      DocumentReference docRef =
          await _firestore.collection(SMOKING_ALERTS_COLLECTION).add(alertData);

      developer.log('✅ Smoking alert saved: ${docRef.id}');
      developer.log('   Location: $placeName');
    } catch (e) {
      developer.log('❌ Error creating smoking alert: $e');
      rethrow;
    }
  }

  // Get unknown face alerts stream
  Stream<List<UnknownFaceAlert>> getAlertsStream({bool onlyUnresolved = true}) {
    Query query = _firestore
        .collection(UNKNOWN_FACES_COLLECTION)
        .orderBy('timestamp', descending: true);
    
    if (onlyUnresolved) {
      query = query.where('isResolved', isEqualTo: false);
    }
    
    return query.snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) => UnknownFaceAlert.fromFirestore(doc))
          .toList();
    });
  }

  // Mark alert as resolved
  Future<void> markResolved(String alertId) async {
    try {
      await _firestore
          .collection(UNKNOWN_FACES_COLLECTION)
          .doc(alertId)
          .update({'isResolved': true});
      
      developer.log('✅ Alert marked as resolved: $alertId');
    } catch (e) {
      developer.log('❌ Error marking alert as resolved: $e');
      rethrow;
    }
  }

  // Delete alert
  Future<void> deleteAlert(String alertId) async {
    try {
      await _firestore
          .collection(UNKNOWN_FACES_COLLECTION)
          .doc(alertId)
          .delete();
      
      developer.log('✅ Alert deleted: $alertId');
    } catch (e) {
      developer.log('❌ Error deleting alert: $e');
      rethrow;
    }
  }

  // Get group alerts stream
  Stream<List<Map<String, dynamic>>> getGroupAlertsStream() {
    return _firestore
        .collection(GROUP_ALERTS_COLLECTION)
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => {...doc.data() as Map<String, dynamic>, 'id': doc.id})
              .toList();
        });
  }

  // Get smoking alerts stream
  Stream<List<Map<String, dynamic>>> getSmokingAlertsStream() {
    return _firestore
        .collection(SMOKING_ALERTS_COLLECTION)
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => {...doc.data() as Map<String, dynamic>, 'id': doc.id})
              .toList();
        });
  }

  // Reset cooldowns (if needed)
  void resetCooldowns() {
    // Placeholder for any cooldown reset logic
  }
}