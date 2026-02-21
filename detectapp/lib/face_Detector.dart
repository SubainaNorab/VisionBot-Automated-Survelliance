// face_detector.dart

import 'dart:io';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

class FaceDetectionService {
  final FaceDetector _detector;

  FaceDetectionService()
    : _detector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.accurate,
          enableTracking: false,
          enableLandmarks: false,
          enableContours: false,
          minFaceSize: 0.08, // ✅ Even lower for robot distance
        ),
      );

  /// Detect and crop the LARGEST face from an image file
  Future<img.Image> detectAndCropFaceFromFile(
    String filePath, {
    double paddingPercent = 0.25,
    int outputSize = 160,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Image file not found: $filePath');
    }

    final input = InputImage.fromFilePath(filePath);
    final faces = await _detector.processImage(input);

    if (faces.isEmpty) {
      throw Exception('No face detected in image');
    }

    Face best = faces.first;
    double bestArea = 0;

    for (final f in faces) {
      final r = f.boundingBox;
      final area = r.width * r.height;
      if (area > bestArea) {
        bestArea = area;
        best = f;
      }
    }

    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception('Failed to decode image bytes');
    }

    final box = best.boundingBox;

    int x = box.left.round();
    int y = box.top.round();
    int w = box.width.round();
    int h = box.height.round();

    final padX = (w * paddingPercent).round();
    final padY = (h * paddingPercent).round();

    x = (x - padX).clamp(0, decoded.width - 1);
    y = (y - padY).clamp(0, decoded.height - 1);

    final x2 = (x + w + padX * 2).clamp(0, decoded.width);
    final y2 = (y + h + padY * 2).clamp(0, decoded.height);

    final cropW = (x2 - x).clamp(1, decoded.width);
    final cropH = (y2 - y).clamp(1, decoded.height);

    final faceCrop = img.copyCrop(
      decoded,
      x: x,
      y: y,
      width: cropW,
      height: cropH,
    );

    final resized = img.copyResize(
      faceCrop,
      width: outputSize,
      height: outputSize,
      interpolation: img.Interpolation.average,
    );

    return resized;
  }

  /// ✅ NEW: Detect ALL faces with rotation fallback for angle issues
  Future<List<img.Image>> detectAndCropAllFaces(
    String filePath, {
    double paddingPercent = 0.25,
    int outputSize = 160,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Image file not found: $filePath');
    }

    // ✅ ANGLE FIX: Try original image first
    var input = InputImage.fromFilePath(filePath);
    var faces = await _detector.processImage(input);

    // ✅ ANGLE FIX: If no faces found, try with image enhancement
    if (faces.isEmpty) {
      print('⚠️ No faces in original image, trying enhanced version...');
      
      final bytes = await file.readAsBytes();
      var decoded = img.decodeImage(bytes);
      
      if (decoded != null) {
        // Enhance image for better detection
        decoded = _enhanceForDetection(decoded);
        
        // Save enhanced version temporarily
        final tempPath = filePath.replaceAll('.jpg', '_enhanced.jpg');
        final tempFile = File(tempPath);
        await tempFile.writeAsBytes(img.encodeJpg(decoded, quality: 95));
        
        // Try detection on enhanced image
        input = InputImage.fromFilePath(tempPath);
        faces = await _detector.processImage(input);
        
        print('📸 Enhanced detection found ${faces.length} face(s)');
        
        // Clean up temp file
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }

    if (faces.isEmpty) {
      throw Exception('No face detected in image');
    }

    print('✅ Detected ${faces.length} face(s)');

    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception('Failed to decode image bytes');
    }

    final List<img.Image> croppedFaces = [];

    // Process ALL faces
    for (final face in faces) {
      final box = face.boundingBox;

      int x = box.left.round();
      int y = box.top.round();
      int w = box.width.round();
      int h = box.height.round();

      final padX = (w * paddingPercent).round();
      final padY = (h * paddingPercent).round();

      x = (x - padX).clamp(0, decoded.width - 1);
      y = (y - padY).clamp(0, decoded.height - 1);

      final x2 = (x + w + padX * 2).clamp(0, decoded.width);
      final y2 = (y + h + padY * 2).clamp(0, decoded.height);

      final cropW = (x2 - x).clamp(1, decoded.width);
      final cropH = (y2 - y).clamp(1, decoded.height);

      final faceCrop = img.copyCrop(
        decoded,
        x: x,
        y: y,
        width: cropW,
        height: cropH,
      );

      final resized = img.copyResize(
        faceCrop,
        width: outputSize,
        height: outputSize,
        interpolation: img.Interpolation.average,
      );

      croppedFaces.add(resized);
    }

    return croppedFaces;
  }

  /// ✅ NEW: Enhance image for better face detection (angle/lighting issues)
  img.Image _enhanceForDetection(img.Image image) {
    // Increase brightness and contrast
    var enhanced = img.adjustColor(
      image,
      brightness: 1.15,
      contrast: 1.25,
      saturation: 1.05,
    );
    
    // Apply slight sharpening
    enhanced = img.convolution(
      enhanced,
      filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
      div: 1,
    );
    
    return enhanced;
  }

  Future<void> dispose() async {
    await _detector.close();
  }
}