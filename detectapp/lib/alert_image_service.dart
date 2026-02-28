// alert_image_service.dart - FIXED PERMISSION HANDLING

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

class AlertImageService {
  Directory? _alertImagesDir;

  /// Initialize storage directory - saves to phone's Pictures/VisionBotAlerts
  Future<void> initialize() async {
    try {
      debugPrint('');
      debugPrint('═══════════════════════════════════');
      debugPrint('📁 Initializing AlertImageService');
      debugPrint('═══════��═══════════════════════════');
      
      // ✅ Request storage permission first
      final granted = await _requestStoragePermission();
      
      if (!granted) {
        debugPrint('⚠️ Storage permission not granted - using app directory instead');
        // Fallback to app directory (doesn't need permission)
        final appDir = await getApplicationDocumentsDirectory();
        _alertImagesDir = Directory('${appDir.path}/alert_images');
        debugPrint('   Using app directory: ${_alertImagesDir!.path}');
      } else {
        // Use external storage (visible in Gallery)
        if (Platform.isAndroid) {
          _alertImagesDir = Directory('/storage/emulated/0/Pictures/VisionBotAlerts');
          debugPrint('   Platform: Android');
          debugPrint('   Target: External storage (visible in Gallery)');
        } else {
          final appDir = await getApplicationDocumentsDirectory();
          _alertImagesDir = Directory('${appDir.path}/alert_images');
          debugPrint('   Platform: iOS/Other');
          debugPrint('   Target: App documents directory');
        }
      }
      
      debugPrint('   Path: ${_alertImagesDir!.path}');
      
      if (!await _alertImagesDir!.exists()) {
        debugPrint('   Status: Directory does not exist');
        debugPrint('   Creating directory...');
        await _alertImagesDir!.create(recursive: true);
        debugPrint('   ✅ Directory created successfully');
      } else {
        debugPrint('   Status: Directory already exists');
      }
      
      // ✅ Test write permissions
      debugPrint('   Testing write permissions...');
      try {
        final testFile = File('${_alertImagesDir!.path}/.test');
        await testFile.writeAsString('test');
        await testFile.delete();
        debugPrint('   ✅ Write permissions confirmed');
      } catch (e) {
        debugPrint('   ⚠️ Write test failed: $e');
        debugPrint('   Continuing anyway...');
      }
      
      // ✅ List existing content
      try {
        final entities = await _alertImagesDir!.list().toList();
        debugPrint('   Existing items: ${entities.length}');
      } catch (e) {
        debugPrint('   Could not list directory: $e');
      }
      
      debugPrint('✅ AlertImageService initialized');
      debugPrint('📸 Images will be saved to: ${_alertImagesDir!.path}');
      debugPrint('═══════════════════════════════════');
      debugPrint('');
    } catch (e, stackTrace) {
      debugPrint('❌ Failed to initialize alert images directory: $e');
      debugPrint('   Stack trace: $stackTrace');
      
      // ✅ Fallback to app directory on any error
      try {
        final appDir = await getApplicationDocumentsDirectory();
        _alertImagesDir = Directory('${appDir.path}/alert_images');
        await _alertImagesDir!.create(recursive: true);
        debugPrint('✅ Using fallback app directory: ${_alertImagesDir!.path}');
      } catch (fallbackError) {
        debugPrint('❌ Even fallback failed: $fallbackError');
        rethrow;
      }
    }
  }

  /// ✅ UPDATED: Request storage permission with proper Android version handling
  Future<bool> _requestStoragePermission() async {
    debugPrint('📋 Checking storage permissions...');
    
    if (!Platform.isAndroid) {
      // iOS - request photo library permission
      debugPrint('   iOS detected - requesting photo library access');
      final status = await Permission.photos.request();
      
      if (status.isGranted) {
        debugPrint('   ✅ Photo library permission granted');
        return true;
      } else {
        debugPrint('   ⚠️ Photo library permission denied - using app directory');
        return false;
      }
    }

    // Get Android version
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;
    
    debugPrint('   Android SDK version: $sdkInt');

    if (sdkInt >= 33) {
      // Android 13+ (API 33+) - Use photos permission
      debugPrint('   Android 13+ - requesting photos permission');
      
      var status = await Permission.photos.status;
      debugPrint('   Current photos permission status: $status');
      
      if (!status.isGranted) {
        status = await Permission.photos.request();
        debugPrint('   After request - photos permission status: $status');
      }
      
      if (status.isGranted) {
        debugPrint('   ✅ Photos permission granted');
        return true;
      } else if (status.isPermanentlyDenied) {
        debugPrint('   ❌ Photos permission permanently denied');
        debugPrint('   User must enable in Settings manually');
        return false;
      } else {
        debugPrint('   ⚠️ Photos permission denied');
        return false;
      }
    } else if (sdkInt >= 30) {
      // Android 11-12 (API 30-32) - Use manageExternalStorage or storage
      debugPrint('   Android 11-12 - requesting storage permission');
      
      var status = await Permission.storage.status;
      debugPrint('   Current storage permission status: $status');
      
      if (!status.isGranted) {
        status = await Permission.storage.request();
        debugPrint('   After request - storage permission status: $status');
      }
      
      if (status.isGranted) {
        debugPrint('   ✅ Storage permission granted');
        return true;
      } else {
        debugPrint('   ⚠️ Storage permission denied');
        return false;
      }
    } else {
      // Android 10 and below - Use storage permission
      debugPrint('   Android 10 or below - requesting storage permission');
      
      var status = await Permission.storage.status;
      debugPrint('   Current storage permission status: $status');
      
      if (!status.isGranted) {
        status = await Permission.storage.request();
        debugPrint('   After request - storage permission status: $status');
      }
      
      if (status.isGranted) {
        debugPrint('   ✅ Storage permission granted');
        return true;
      } else {
        debugPrint('   ⚠️ Storage permission denied');
        return false;
      }
    }
  }

  /// Save image for unknown face alert
  Future<String?> saveUnknownFaceImage(String sourcePath, {
    String? additionalInfo,
  }) async {
    return _saveAlertImage(
      sourcePath: sourcePath,
      alertType: 'unknown_face',
      additionalInfo: additionalInfo,
    );
  }

  /// Save image for group detection alert
  Future<String?> saveGroupImage(String sourcePath, {
    required int personCount,
    String? additionalInfo,
  }) async {
    return _saveAlertImage(
      sourcePath: sourcePath,
      alertType: 'group_detected',
      additionalInfo: 'count_${personCount}_$additionalInfo',
    );
  }

  /// Save image for smoking detection alert
  Future<String?> saveSmokingImage(String sourcePath, {
    String? additionalInfo,
  }) async {
    return _saveAlertImage(
      sourcePath: sourcePath,
      alertType: 'smoking_detected',
      additionalInfo: additionalInfo,
    );
  }

  /// Generic save method
  Future<String?> _saveAlertImage({
    required String sourcePath,
    required String alertType,
    String? additionalInfo,
  }) async {
    if (_alertImagesDir == null) {
      debugPrint('❌ Alert images directory not initialized');
      return null;
    }

    try {
      debugPrint('💾 Saving $alertType image...');
      
      final sourceFile = File(sourcePath);
      
      debugPrint('   Checking source: $sourcePath');
      
      if (!await sourceFile.exists()) {
        debugPrint('   ❌ Source image not found!');
        return null;
      }
      
      final sourceSize = await sourceFile.length();
      debugPrint('   ✅ Source exists (${sourceSize} bytes)');

      // Create type-specific subdirectory
      final typeDir = Directory('${_alertImagesDir!.path}/$alertType');
      if (!await typeDir.exists()) {
        debugPrint('   Creating subdirectory: ${typeDir.path}');
        await typeDir.create(recursive: true);
      }

      // Generate unique filename with timestamp
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final dateStr = DateTime.now().toIso8601String().split('T')[0];
      final timeStr = DateTime.now().toIso8601String().split('T')[1].split('.')[0].replaceAll(':', '-');
      
      final info = additionalInfo != null ? '_$additionalInfo' : '';
      final filename = '${alertType}_${dateStr}_${timeStr}_${timestamp}$info.jpg';
      final destPath = '${typeDir.path}/$filename';

      debugPrint('   Copying to: $destPath');

      // Copy image
      await sourceFile.copy(destPath);

      final destFile = File(destPath);
      final destExists = await destFile.exists();
      
      if (destExists) {
        final fileSize = await destFile.length();
        debugPrint('   ✅ Image saved successfully!');
        debugPrint('      File: $filename');
        debugPrint('      Size: $fileSize bytes');
        debugPrint('      Path: $destPath');
        
        return destPath;
      } else {
        debugPrint('   ❌ Copy failed - destination file not found');
        return null;
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Failed to save alert image: $e');
      debugPrint('   Stack trace: $stackTrace');
      return null;
    }
  }

  /// Save cropped face images (multiple faces from one frame)
  Future<List<String>> saveFaceImages(List<img.Image> faces, {
    required String alertType,
    String? sessionInfo,
  }) async {
    if (_alertImagesDir == null) {
      debugPrint('❌ Cannot save face images - directory not initialized');
      return [];
    }

    final savedPaths = <String>[];

    try {
      debugPrint('💾 Saving ${faces.length} cropped face images...');
      
      final typeDir = Directory('${_alertImagesDir!.path}/$alertType');
      if (!await typeDir.exists()) {
        await typeDir.create(recursive: true);
        debugPrint('   Created subdirectory: ${typeDir.path}');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final dateStr = DateTime.now().toIso8601String().split('T')[0];
      final timeStr = DateTime.now().toIso8601String().split('T')[1].split('.')[0].replaceAll(':', '-');

      for (int i = 0; i < faces.length; i++) {
        final face = faces[i];
        
        final info = sessionInfo != null ? '_$sessionInfo' : '';
        final filename = '${alertType}_face${i + 1}_${dateStr}_${timeStr}_${timestamp}$info.jpg';
        final destPath = '${typeDir.path}/$filename';

        // Encode and save
        final bytes = img.encodeJpg(face, quality: 90);
        await File(destPath).writeAsBytes(bytes);

        savedPaths.add(destPath);
        debugPrint('   ✅ Face ${i + 1}/${faces.length} saved: $filename (${bytes.length} bytes)');
      }

      debugPrint('✅ Saved ${savedPaths.length} face images successfully');
    } catch (e, stackTrace) {
      debugPrint('❌ Failed to save face images: $e');
      debugPrint('   Stack trace: $stackTrace');
    }

    return savedPaths;
  }

  /// Get all alert images by type
  Future<List<Map<String, dynamic>>> getAlertImages({String? alertType}) async {
    if (_alertImagesDir == null) return [];

    try {
      final images = <Map<String, dynamic>>[];

      Directory searchDir = _alertImagesDir!;
      
      if (alertType != null) {
        searchDir = Directory('${_alertImagesDir!.path}/$alertType');
        if (!await searchDir.exists()) {
          return [];
        }
      }

      await for (final entity in searchDir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.jpg')) {
          final stat = await entity.stat();
          final filename = entity.path.split('/').last;
          
          images.add({
            'path': entity.path,
            'filename': filename,
            'size': stat.size,
            'modified': stat.modified,
            'type': _extractAlertType(entity.path),
          });
        }
      }

      // Sort by modified time (newest first)
      images.sort((a, b) => (b['modified'] as DateTime).compareTo(a['modified'] as DateTime));

      return images;
    } catch (e) {
      debugPrint('❌ Failed to get alert images: $e');
      return [];
    }
  }

  String _extractAlertType(String path) {
    if (path.contains('unknown_face')) return 'unknown_face';
    if (path.contains('group_detected')) return 'group_detected';
    if (path.contains('smoking_detected')) return 'smoking_detected';
    return 'unknown';
  }

  /// Get statistics
  Future<Map<String, int>> getStats() async {
    if (_alertImagesDir == null) return {};

    try {
      final stats = <String, int>{
        'unknown_face': 0,
        'group_detected': 0,
        'smoking_detected': 0,
        'total': 0,
      };

      await for (final entity in _alertImagesDir!.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.jpg')) {
          stats['total'] = (stats['total'] ?? 0) + 1;
          
          final type = _extractAlertType(entity.path);
          stats[type] = (stats[type] ?? 0) + 1;
        }
      }

      return stats;
    } catch (e) {
      debugPrint('❌ Failed to get stats: $e');
      return {};
    }
  }

  /// Delete old images (cleanup)
  Future<int> deleteOldImages({int daysToKeep = 30}) async {
    if (_alertImagesDir == null) return 0;

    try {
      final cutoffDate = DateTime.now().subtract(Duration(days: daysToKeep));
      int deletedCount = 0;

      await for (final entity in _alertImagesDir!.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.jpg')) {
          final stat = await entity.stat();
          
          if (stat.modified.isBefore(cutoffDate)) {
            await entity.delete();
            deletedCount++;
          }
        }
      }

      debugPrint('🧹 Deleted $deletedCount old alert images');
      return deletedCount;
    } catch (e) {
      debugPrint('❌ Failed to delete old images: $e');
      return 0;
    }
  }

  /// Delete all images
  Future<void> clearAllImages() async {
    if (_alertImagesDir == null) return;

    try {
      if (await _alertImagesDir!.exists()) {
        await _alertImagesDir!.delete(recursive: true);
        await _alertImagesDir!.create(recursive: true);
        debugPrint('🧹 All alert images cleared');
      }
    } catch (e) {
      debugPrint('❌ Failed to clear images: $e');
    }
  }

  String? get storagePath => _alertImagesDir?.path;
}