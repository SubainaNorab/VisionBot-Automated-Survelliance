
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'supabase_service.dart';

class ImageUploaderService {
  /// Save image in memory and upload directly to Supabase
  static Future<Map<String, String?>> saveAndUploadAlertImage({
    required String sourcePath,
    required String alertType,
    required String additionalInfo,
  }) async {
    try {
      debugPrint('');
      debugPrint('Processing Alert Image');
      debugPrint('─────────────────────────────');

      // Verify source file exists
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        debugPrint(' Source file not found');
        return {'remote': null};
      }

      final fileSize = await sourceFile.length();
      debugPrint('Type: $alertType');
      debugPrint('Size: ${(fileSize / 1024).toStringAsFixed(2)} KB');

      // Generate filename
      final timestamp = DateTime.now().toIso8601String();
      final dateStr = timestamp.split('T')[0];
      final timeStr = timestamp.split('T')[1].split('.')[0].replaceAll(':', '-');
      final info = additionalInfo.isNotEmpty ? '_$additionalInfo' : '';
      final fileName = '${alertType}_${dateStr}_$timeStr$info.jpg';

      debugPrint('File: $fileName');
      debugPrint('');

      // Upload directly to Supabase
      debugPrint(' Uploading to Supabase Storage...');
      
      final supabaseUrl = await SupabaseService.uploadAlertImage(
        localPath: sourcePath,
        alertType: alertType,
        fileName: fileName,
      );

      debugPrint('');
      debugPrint('─────────────────────────────');

      return {
        'remote': supabaseUrl,
      };
    } catch (e, st) {
      debugPrint(' Error: $e');
      debugPrint('   Stack: $st');
      return {'remote': null};
    }
  }

  /// Save faces in memory and upload to Supabase
  static Future<List<String>> saveAndUploadFaceImages({
    required List<img.Image> faces,
    required String alertType,
    required String sessionInfo,
  }) async {
    final uploadedUrls = <String>[];

    try {
      debugPrint('');
      debugPrint('💾 Processing Face Crops');
      debugPrint('─────────────────────────────');
      debugPrint('Count: ${faces.length}');

      if (faces.isEmpty) {
        debugPrint('⚠️ No faces to process');
        return [];
      }

      // Save faces to temporary directory
      final tempDir = await getTemporaryDirectory();
      final tempPaths = <String>[];

      debugPrint('Saving to temp directory...');

      for (int i = 0; i < faces.length; i++) {
        final face = faces[i];
        final tempPath = '${tempDir.path}/face${i + 1}_temp.jpg';
        
        final bytes = img.encodeJpg(face, quality: 90);
        await File(tempPath).writeAsBytes(bytes);
        tempPaths.add(tempPath);

        debugPrint('   Face ${i + 1}: ${(bytes.length / 1024).toStringAsFixed(2)} KB');
      }

      // Upload all to Supabase
      debugPrint('');
      debugPrint('📤 Uploading to Supabase Storage...');

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final urls = await SupabaseService.uploadFaceImages(
        localPaths: tempPaths,
        alertType: alertType,
        sessionId: '${sessionInfo}_$timestamp',
      );

      uploadedUrls.addAll(urls);

      // Cleanup temporary files
      debugPrint('');
      debugPrint(' Cleaning up temp files...');

      for (final path in tempPaths) {
        try {
          await File(path).delete();
        } catch (e) {
          debugPrint('Could not delete: $e');
        }
      }

      debugPrint('');
      debugPrint('─────────────────────────────');
      debugPrint(' Processed ${uploadedUrls.length} faces');

      return uploadedUrls;
    } catch (e, st) {
      debugPrint(' Error: $e');
      debugPrint('   Stack: $st');
      return uploadedUrls;
    }
  }
}