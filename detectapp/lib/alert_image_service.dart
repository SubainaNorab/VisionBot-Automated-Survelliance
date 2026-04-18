// alert_image_service.dart - COMPLETE: Fixed image saving + better error handling

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

class AlertImageService {
  Directory? _alertImagesDir;

  Future<void> initialize() async {
    try {
      debugPrint('');
      debugPrint('═══════════════════════════════════');
      debugPrint('📁 Initializing AlertImageService');
      debugPrint('═══════════════════════════════════');
      
      final granted = await _requestStoragePermission();
      
      if (!granted) {
        debugPrint('⚠️ Storage permission not granted');
        final appDir = await getApplicationDocumentsDirectory();
        _alertImagesDir = Directory('${appDir.path}/alert_images');
        debugPrint('   Using app directory: ${_alertImagesDir!.path}');
      } else {
        if (Platform.isAndroid) {
          _alertImagesDir = Directory('/storage/emulated/0/Pictures/VisionBotAlerts');
          debugPrint('   Platform: Android');
          debugPrint('   Target: External storage');
        } else {
          final appDir = await getApplicationDocumentsDirectory();
          _alertImagesDir = Directory('${appDir.path}/alert_images');
          debugPrint('   Platform: iOS');
        }
      }
      
      debugPrint('   Path: ${_alertImagesDir!.path}');
      
      if (!await _alertImagesDir!.exists()) {
        debugPrint('   Creating directory...');
        await _alertImagesDir!.create(recursive: true);
        debugPrint('   ✅ Created');
      } else {
        debugPrint('   ✅ Exists');
      }
      
      // ✅ Test write permissions
      debugPrint('   Testing write permissions...');
      try {
        final testFile = File('${_alertImagesDir!.path}/.write_test');
        await testFile.writeAsString('test');
        await testFile.delete();
        debugPrint('   ✅ Write OK');
      } catch (e) {
        debugPrint('   ⚠️ Write test failed: $e');
      }
      
      // ✅ List existing content
      try {
        final entities = await _alertImagesDir!.list().toList();
        debugPrint('   Existing items: ${entities.length}');
      } catch (e) {
        debugPrint('   Could not list: $e');
      }
      
      debugPrint('✅ AlertImageService initialized');
      debugPrint('📸 Images → ${_alertImagesDir!.path}');
      debugPrint('════════���══════════════════════════');
      debugPrint('');
    } catch (e, stackTrace) {
      debugPrint('❌ Init failed: $e');
      debugPrint('   Stack: $stackTrace');
      
      try {
        final appDir = await getApplicationDocumentsDirectory();
        _alertImagesDir = Directory('${appDir.path}/alert_images');
        await _alertImagesDir!.create(recursive: true);
        debugPrint('✅ Fallback: ${_alertImagesDir!.path}');
      } catch (fallbackError) {
        debugPrint('❌ Fallback failed: $fallbackError');
        rethrow;
      }
    }
  }

  Future<bool> _requestStoragePermission() async {
    debugPrint('📋 Checking storage permissions...');
    
    if (!Platform.isAndroid) {
      debugPrint('   iOS - requesting photos');
      final status = await Permission.photos.request();
      return status.isGranted;
    }

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;
    
    debugPrint('   Android SDK: $sdkInt');

    if (sdkInt >= 33) {
      var status = await Permission.photos.status;
      if (!status.isGranted) {
        status = await Permission.photos.request();
      }
      return status.isGranted;
    } else if (sdkInt >= 30) {
      var status = await Permission.storage.status;
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      return status.isGranted;
    } else {
      var status = await Permission.storage.status;
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      return status.isGranted;
    }
  }

  Future<String?> saveUnknownFaceImage(String sourcePath, {
    String? additionalInfo,
  }) async {
    return _saveAlertImage(
      sourcePath: sourcePath,
      alertType: 'unknown_face',
      additionalInfo: additionalInfo,
    );
  }

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

  Future<String?> saveSmokingImage(String sourcePath, {
    String? additionalInfo,
  }) async {
    return _saveAlertImage(
      sourcePath: sourcePath,
      alertType: 'smoking_detected',
      additionalInfo: additionalInfo,
    );
  }

  Future<String?> _saveAlertImage({
    required String sourcePath,
    required String alertType,
    String? additionalInfo,
  }) async {
    if (_alertImagesDir == null) {
      debugPrint('❌ Alert directory not initialized');
      return null;
    }

    try {
      debugPrint('💾 Saving $alertType image...');
      
      final sourceFile = File(sourcePath);
      
      debugPrint('   Checking source: $sourcePath');
      
      if (!await sourceFile.exists()) {
        debugPrint('   ❌ Source not found');
        return null;
      }
      
      final sourceSize = await sourceFile.length();
      debugPrint('   ✅ Source exists ($sourceSize bytes)');

      final typeDir = Directory('${_alertImagesDir!.path}/$alertType');
      if (!await typeDir.exists()) {
        debugPrint('   Creating subdir: ${typeDir.path}');
        await typeDir.create(recursive: true);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final dateStr = DateTime.now().toIso8601String().split('T')[0];
      final timeStr = DateTime.now()
          .toIso8601String()
          .split('T')[1]
          .split('.')[0]
          .replaceAll(':', '-');
      
      final info = additionalInfo != null ? '_$additionalInfo' : '';
      final filename = '${alertType}_${dateStr}_${timeStr}_$timestamp$info.jpg';
      final destPath = '${typeDir.path}/$filename';

      debugPrint('   Copying to: $filename');

      await sourceFile.copy(destPath);

      final destFile = File(destPath);
      final destExists = await destFile.exists();
      
      if (destExists) {
        final fileSize = await destFile.length();
        debugPrint('   ✅ Image saved!');
        debugPrint('      File: $filename');
        debugPrint('      Size: $fileSize bytes');
        debugPrint('      Path: $destPath');
        
        return destPath;
      } else {
        debugPrint('   ❌ Copy failed - file not created');
        return null;
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Save failed: $e');
      debugPrint('   Stack: $stackTrace');
      return null;
    }
  }

  Future<List<String>> saveFaceImages(List<img.Image> faces, {
    required String alertType,
    String? sessionInfo,
  }) async {
    if (_alertImagesDir == null) {
      debugPrint('❌ Directory not initialized');
      return [];
    }

    final savedPaths = <String>[];

    try {
      debugPrint('💾 Saving ${faces.length} face(s)...');
      
      final typeDir = Directory('${_alertImagesDir!.path}/$alertType');
      if (!await typeDir.exists()) {
        await typeDir.create(recursive: true);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final dateStr = DateTime.now().toIso8601String().split('T')[0];
      final timeStr = DateTime.now()
          .toIso8601String()
          .split('T')[1]
          .split('.')[0]
          .replaceAll(':', '-');

      for (int i = 0; i < faces.length; i++) {
        try {
          final face = faces[i];
          
          final info = sessionInfo != null ? '_$sessionInfo' : '';
          final filename = '${alertType}_face${i + 1}_${dateStr}_${timeStr}_$timestamp$info.jpg';
          final destPath = '${typeDir.path}/$filename';

          final bytes = img.encodeJpg(face, quality: 90);
          await File(destPath).writeAsBytes(bytes);

          savedPaths.add(destPath);
          debugPrint('   ✅ Face ${i + 1}/${faces.length} saved (${bytes.length} bytes)');
        } catch (e) {
          debugPrint('   ❌ Face ${i + 1} failed: $e');
          continue;
        }
      }

      debugPrint('✅ Saved ${savedPaths.length} face(s)');
    } catch (e, stackTrace) {
      debugPrint('❌ Save faces failed: $e');
      debugPrint('   Stack: $stackTrace');
    }

    return savedPaths;
  }

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

      images.sort((a, b) => (b['modified'] as DateTime).compareTo(a['modified'] as DateTime));

      return images;
    } catch (e) {
      debugPrint('❌ Get images failed: $e');
      return [];
    }
  }

  String _extractAlertType(String path) {
    if (path.contains('unknown_face')) return 'unknown_face';
    if (path.contains('group_detected')) return 'group_detected';
    if (path.contains('smoking_detected')) return 'smoking_detected';
    return 'unknown';
  }

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
      debugPrint('❌ Get stats failed: $e');
      return {};
    }
  }

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

      debugPrint('🧹 Deleted $deletedCount old images');
      return deletedCount;
    } catch (e) {
      debugPrint('❌ Delete failed: $e');
      return 0;
    }
  }

  Future<void> clearAllImages() async {
    if (_alertImagesDir == null) return;

    try {
      if (await _alertImagesDir!.exists()) {
        await _alertImagesDir!.delete(recursive: true);
        await _alertImagesDir!.create(recursive: true);
        debugPrint('🧹 All images cleared');
      }
    } catch (e) {
      debugPrint('❌ Clear failed: $e');
    }
  }

  String? get storagePath => _alertImagesDir?.path;
}