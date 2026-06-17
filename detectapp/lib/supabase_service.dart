import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  static late final String _supabaseUrl;
  static late final String _supabaseAnonKey;

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

      _supabaseUrl = supabaseUrl.replaceAll(RegExp(r'\/$'), '');
      _supabaseAnonKey = supabaseAnonKey;

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

  /// Upload alert image to Supabase (FIXED)
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

      debugPrint('📤 Uploading to Supabase (FIXED SDK)');
      debugPrint('   Type: $alertType');
      debugPrint('   File: $fileName');
      debugPrint('   Size: ${(fileSize / 1024).toStringAsFixed(2)} KB');

      final bytes = await file.readAsBytes();

      // ✅ FIX: Use official Supabase client
      await Supabase.instance.client.storage
          .from(_bucket)
          .uploadBinary(
            remotePath,
            bytes,
            fileOptions: const FileOptions(
              upsert: true,
              cacheControl: '3600',
            ),
          );

      final publicUrl = Supabase.instance.client.storage
          .from(_bucket)
          .getPublicUrl(remotePath);

      debugPrint('✅ Upload successful');
      debugPrint('🔗 URL: $publicUrl');

      return publicUrl;
    } catch (e, st) {
      debugPrint('❌ Upload error: $e');
      debugPrint('   Stack: $st');
      return null;
    }
  }

  /// Upload multiple face images (FIXED only upload part, logic unchanged)
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

        final bytes = await file.readAsBytes();

        await Supabase.instance.client.storage
            .from(_bucket)
            .uploadBinary(
              remotePath,
              bytes,
              fileOptions: const FileOptions(
                upsert: true,
              ),
            );

        final url = Supabase.instance.client.storage
            .from(_bucket)
            .getPublicUrl(remotePath);

        uploadedUrls.add(url);

        debugPrint('✅ Face ${i + 1} uploaded');
      }

      return uploadedUrls;
    } catch (e) {
      debugPrint('❌ Face upload error: $e');
      return uploadedUrls;
    }
  }
}