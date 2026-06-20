// alert_image_service.dart - COMPLETE: Fixed image saving + Supabase sync (NON-BREAKING FIX)

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'image_uploader_service.dart';

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
        final appDir = await getApplicationDocumentsDirectory();
        _alertImagesDir = Directory('${appDir.path}/alert_images');
      } else {
        if (Platform.isAndroid) {
          _alertImagesDir =
              Directory('/storage/emulated/0/Pictures/VisionBotAlerts');
        } else {
          final appDir = await getApplicationDocumentsDirectory();
          _alertImagesDir = Directory('${appDir.path}/alert_images');
        }
      }

      if (!await _alertImagesDir!.exists()) {
        await _alertImagesDir!.create(recursive: true);
      }

      debugPrint('📸 Images → ${_alertImagesDir!.path}');
      debugPrint('═══════════════════════════════════');
    } catch (e) {
      debugPrint('❌ Init failed: $e');
      rethrow;
    }
  }

  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) {
      return (await Permission.photos.request()).isGranted;
    }

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    if (sdkInt >= 33) {
      return (await Permission.photos.request()).isGranted;
    } else {
      return (await Permission.storage.request()).isGranted;
    }
  }

  // =========================================================
  // 🔥 FIXED: SUPABASE HOOK (RETURN FIXED + SAFE CALL)
  // =========================================================

  Future<void> _uploadToSupabaseSafe(
    String localPath,
    String alertType,
  ) async {
    try {
      final result =
          await ImageUploaderService.saveAndUploadAlertImage(
        sourcePath: localPath,
        alertType: alertType,
        additionalInfo: localPath.split('/').last,
      );

      final url = result['remote'];

      if (url != null) {
        debugPrint('☁️ Supabase upload success: $url');
      } else {
        debugPrint('⚠️ Supabase upload returned null');
      }
    } catch (e) {
      debugPrint('⚠️ Supabase upload failed: $e');
    }
  }

  // =========================================================
  // FIXED: UNKNOWN FACE
  // =========================================================

  Future<String?> saveUnknownFaceImage(
    String sourcePath, {
    String? additionalInfo,
  }) async {
    final local = await _saveAlertImage(
      sourcePath: sourcePath,
      alertType: 'unknown_face',
      additionalInfo: additionalInfo,
    );

    if (local != null) {
      _uploadToSupabaseSafe(local, 'unknown_face');
    }

    return local;
  }

  // =========================================================
  // FIXED: GROUP DETECTED
  // =========================================================

  Future<String?> saveGroupImage(
    String sourcePath, {
    required int personCount,
    String? additionalInfo,
  }) async {
    final local = await _saveAlertImage(
      sourcePath: sourcePath,
      alertType: 'group_detected',
      additionalInfo: 'count_${personCount}_$additionalInfo',
    );

    if (local != null) {
      _uploadToSupabaseSafe(local, 'group_detected');
    }

    return local;
  }

  // =========================================================
  // FIXED: SMOKING
  // =========================================================

  Future<String?> saveSmokingImage(
    String sourcePath, {
    String? additionalInfo,
  }) async {
    final local = await _saveAlertImage(
      sourcePath: sourcePath,
      alertType: 'smoking_detected',
      additionalInfo: additionalInfo,
    );

    if (local != null) {
      _uploadToSupabaseSafe(local, 'smoking_detected');
    }

    return local;
  }

  // =========================================================
  // ORIGINAL LOGIC (UNCHANGED)
  // =========================================================

  Future<String?> _saveAlertImage({
    required String sourcePath,
    required String alertType,
    String? additionalInfo,
  }) async {
    if (_alertImagesDir == null) return null;

    try {
      final sourceFile = File(sourcePath);

      if (!await sourceFile.exists()) return null;

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

      final info = additionalInfo != null ? '_$additionalInfo' : '';
      final filename =
          '${alertType}_${dateStr}_${timeStr}_$timestamp$info.jpg';

      final destPath = '${typeDir.path}/$filename';

      await sourceFile.copy(destPath);

      return destPath;
    } catch (e) {
      debugPrint('❌ Save failed: $e');
      return null;
    }
  }

  String? get storagePath => _alertImagesDir?.path;
}