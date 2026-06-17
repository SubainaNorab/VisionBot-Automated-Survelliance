import 'dart:io';
import 'package:flutter/foundation.dart';

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
          await _uploadBinary(remotePath, fileBytes);

          final publicUrl = _getPublicUrl(remotePath);

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
            await _uploadBinary(remotePath, fileBytes);

            final publicUrl = _getPublicUrl(remotePath);
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
        await _deleteObject(path);
        debugPrint('✅ Deleted: $path');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('⚠️ Delete error: $e');
      return false;
    }
  }

  static Future<void> _uploadBinary(String remotePath, List<int> fileBytes) async {
    final uri = Uri.parse('$_supabaseUrl/storage/v1/object/$_bucket/$remotePath');
    final request = await HttpClient().putUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_supabaseAnonKey');
    request.headers.set('apikey', _supabaseAnonKey);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
    request.headers.set('x-upsert', 'true');
    request.add(fileBytes);

    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.transform(const SystemEncoding().decoder).join();
      throw HttpException('Upload failed (${response.statusCode}): $body');
    }
  }

  static Future<void> _deleteObject(String path) async {
    final uri = Uri.parse('$_supabaseUrl/storage/v1/object/$_bucket/$path');
    final request = await HttpClient().deleteUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_supabaseAnonKey');
    request.headers.set('apikey', _supabaseAnonKey);

    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.transform(const SystemEncoding().decoder).join();
      throw HttpException('Delete failed (${response.statusCode}): $body');
    }
  }

  static String _getPublicUrl(String remotePath) {
    return '$_supabaseUrl/storage/v1/object/public/$_bucket/$remotePath';
  }
}