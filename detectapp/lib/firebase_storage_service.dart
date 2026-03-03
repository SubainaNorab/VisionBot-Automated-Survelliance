import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

class FirebaseStorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;


  Future<String?> uploadAlertImage({
    required String localPath,
    required String alertType,
    String? sessionId,
  }) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        debugPrint('❌ Upload: file not found at $localPath');
        return null;
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final id = sessionId ?? timestamp.toString();
      final filename = '${alertType}_$id.jpg';
      final storagePath = 'alerts/$alertType/$filename';

      debugPrint('☁️ Uploading to Storage: $storagePath');

      final ref = _storage.ref().child(storagePath);
      final metadata = SettableMetadata(
        contentType: 'image/jpeg',
        customMetadata: {
          'alert_type': alertType,
          'uploaded_at': DateTime.now().toIso8601String(),
        },
      );

      final task = ref.putFile(file, metadata);

    
      task.snapshotEvents.listen((snapshot) {
        final progress =
            (snapshot.bytesTransferred / snapshot.totalBytes * 100)
                .toStringAsFixed(0);
        debugPrint('   Upload progress: $progress%');
      });

      final snapshot = await task;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      debugPrint('✅ Image uploaded: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      debugPrint('❌ Upload failed: $e');
      return null;
    }
  }

  /// Upload multiple face images and return list of URLs
  Future<List<String>> uploadFaceImages({
    required List<String> localPaths,
    required String alertType,
    String? sessionId,
  }) async {
    final urls = <String>[];
    final id = sessionId ?? DateTime.now().millisecondsSinceEpoch.toString();

    for (int i = 0; i < localPaths.length; i++) {
      final url = await uploadAlertImage(
        localPath: localPaths[i],
        alertType: alertType,
        sessionId: '${id}_face$i',
      );
      if (url != null) urls.add(url);
    }

    debugPrint('☁️ Uploaded ${urls.length}/${localPaths.length} face images');
    return urls;
  }
}