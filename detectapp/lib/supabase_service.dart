// lib/services/supabase_service.dart - Fixed with retry logic

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  static late final SupabaseClient _client;
  
  static const String _bucket = 'alert_images';

  /// Initialize Supabase
  static Future<void> initialize({
    required String supabaseUrl,
    required String supabaseAnonKey,
  }) async {
    try {
      debugPrint('');
      debugPrint('═══════════════════════════════════');
      debugPrint('🔧 Initializing Supabase Storage');
      debugPrint('═══════════════════════════════════');
      
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
      );
      
      _client = Supabase.instance.client;
      
      debugPrint('✅ Supabase initialized');
      debugPrint('   URL: ${supabaseUrl.substring(0, 20)}...');
      debugPrint('   Bucket: $_bucket');
      debugPrint('═══════════════════════════════════');
      debugPrint('');
    } catch (e, st) {
      debugPrint('❌ Supabase initialization failed: $e');
      debugPrint('   Stack: $st');
      rethrow;
    }
  }

  /// Upload alert image to Supabase (with retry)
  static Future<String?> uploadAlertImage({
    required String localPath,
    required String alertType,
    required String fileName,
  }) async {
    try {
      final file = File(localPath);
      
      if (!await file.exists()) {
        debugPrint('❌ File not found: $localPath');
        return null;
      }

      final fileSize = await file.length();
      final remotePath = '$alertType/$fileName';

      debugPrint('📤 Uploading to Supabase');
      debugPrint('   Type: $alertType');
      debugPrint('   File: $fileName');
      debugPrint('   Size: ${(fileSize / 1024).toStringAsFixed(2)} KB');

      final fileBytes = await file.readAsBytes();

      // ✅ Retry logic
      int retryCount = 0;
      const int maxRetries = 3;
      
      while (retryCount < maxRetries) {
        try {
          await _client.storage
              .from(_bucket)
              .uploadBinary(
                remotePath,
                fileBytes,
                fileOptions: const FileOptions(
                  cacheControl: '3600',
                  upsert: true,  // ✅ Allow overwrite
                ),
              );

          final publicUrl = _client.storage.from(_bucket).getPublicUrl(remotePath);

          debugPrint('✅ Uploaded: $publicUrl');
          
          return publicUrl;
        } catch (e) {
          retryCount++;
          debugPrint('⚠️ Upload attempt $retryCount failed: $e');
          
          if (retryCount < maxRetries) {
            await Future.delayed(Duration(seconds: retryCount * 2));
          } else {
            rethrow;
          }
        }
      }
      
      return null;
    } catch (e, st) {
      debugPrint('❌ Upload error: $e');
      debugPrint('   Stack: $st');
      return null;
    }
  }

  /// Upload multiple face images (with retry)
  static Future<List<String>> uploadFaceImages({
    required List<String> localPaths,
    required String alertType,
    required String sessionId,
  }) async {
    final uploadedUrls = <String>[];

    try {
      debugPrint('📤 Uploading ${localPaths.length} face crops');

      for (int i = 0; i < localPaths.length; i++) {
        final localPath = localPaths[i];
        final file = File(localPath);

        if (!await file.exists()) {
          debugPrint('⚠️ Face ${i + 1} not found');
          continue;
        }

        final fileName = '${alertType}_face${i + 1}_${sessionId}.jpg';
        final remotePath = '$alertType/$fileName';
        final fileSize = await file.length();

        debugPrint('   Face ${i + 1}: $fileName (${(fileSize / 1024).toStringAsFixed(2)} KB)');

        final fileBytes = await file.readAsBytes();

        // ✅ Retry logic for faces
        int retryCount = 0;
        const int maxRetries = 3;
        bool uploaded = false;

        while (retryCount < maxRetries && !uploaded) {
          try {
            await _client.storage
                .from(_bucket)
                .uploadBinary(
                  remotePath,
                  fileBytes,
                  fileOptions: const FileOptions(
                    cacheControl: '3600',
                    upsert: true,
                  ),
                );

            final publicUrl = _client.storage.from(_bucket).getPublicUrl(remotePath);
            uploadedUrls.add(publicUrl);
            uploaded = true;
            debugPrint('      ✅ Uploaded');
          } catch (e) {
            retryCount++;
            debugPrint('      ⚠️ Retry $retryCount: $e');
            
            if (retryCount < maxRetries) {
              await Future.delayed(Duration(seconds: retryCount * 2));
            }
          }
        }

        if (!uploaded) {
          debugPrint('      ❌ Failed after $maxRetries retries');
        }
      }

      debugPrint('✅ Uploaded ${uploadedUrls.length} faces');
      return uploadedUrls;
    } catch (e, st) {
      debugPrint('❌ Face upload error: $e');
      return uploadedUrls;
    }
  }

  /// Delete image
  static Future<bool> deleteImage(String publicUrl) async {
    try {
      final uri = Uri.parse(publicUrl);
      final pathSegments = uri.pathSegments;
      
      if (pathSegments.length >= 3) {
        final path = pathSegments.sublist(pathSegments.length - 2).join('/');
        await _client.storage.from(_bucket).remove([path]);
        debugPrint('✅ Deleted: $path');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('⚠️ Delete error: $e');
      return false;
    }
  }
}