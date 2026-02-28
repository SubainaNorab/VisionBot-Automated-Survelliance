// face_detector.dart - RELAXED DISTANCE FOR 4-6 FOOTSTEPS

import 'dart:io';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

class FaceInfo {
  final img.Image croppedFace;
  final double distanceScore;
  final int originalWidth;
  final int originalHeight;
  final String distanceStatus;
  
  FaceInfo({
    required this.croppedFace,
    required this.distanceScore,
    required this.originalWidth,
    required this.originalHeight,
    required this.distanceStatus,
  });
  
  bool get isTooFar => distanceScore == 0.0;
  bool get isTooClose => distanceScore == 2.0;
  bool get isGoodDistance => distanceScore >= 0.5 && distanceScore <= 1.0;
  bool get isPerfectDistance => distanceScore == 1.0;
}

class FaceDetectionService {
  final FaceDetector _detector;

  // ✅ UPDATED: Much more relaxed distance thresholds for 4-6 footsteps (2-4 meters)
  int minFaceWidth = 50;   // Was 100, now 50 (detect from 2x further)
  int maxFaceWidth = 500;  // Was 400, now 500 (allow closer)
  int idealMinWidth = 80;  // Was 150, now 80 (better range)
  int idealMaxWidth = 450; // Was 350, now 450 (wider ideal range)

  FaceDetectionService()
    : _detector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.accurate,
          enableTracking: false,
          enableLandmarks: false,
          enableContours: false,
          minFaceSize: 0.05, // ✅ Was 0.08, now 0.05 (detect smaller/further faces - 60% smaller)
        ),
      );

  void setDistanceThresholds({
    required int minWidth,
    required int maxWidth,
    required int idealMin,
    required int idealMax,
  }) {
    minFaceWidth = minWidth;
    maxFaceWidth = maxWidth;
    idealMinWidth = idealMin;
    idealMaxWidth = idealMax;
    print('📏 Distance thresholds updated: $minWidth-$maxWidth (ideal: $idealMin-$idealMax)');
  }

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

  Future<List<FaceInfo>> detectAndCropAllFacesWithDistance(
    String filePath, {
    double paddingPercent = 0.25,
    int outputSize = 160,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Image file not found: $filePath');
    }

    var input = InputImage.fromFilePath(filePath);
    var faces = await _detector.processImage(input);

    if (faces.isEmpty) {
      print('⚠️ No faces in original image, trying enhanced version...');
      
      final bytes = await file.readAsBytes();
      var decoded = img.decodeImage(bytes);
      
      if (decoded != null) {
        decoded = _enhanceForDetection(decoded);
        
        final tempPath = filePath.replaceAll('.jpg', '_enhanced.jpg');
        final tempFile = File(tempPath);
        await tempFile.writeAsBytes(img.encodeJpg(decoded, quality: 95));
        
        input = InputImage.fromFilePath(tempPath);
        faces = await _detector.processImage(input);
        
        print('📸 Enhanced detection found ${faces.length} face(s)');
        
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }

    if (faces.isEmpty) {
      throw Exception('No face detected in image');
    }

    print('✅ ML Kit detected ${faces.length} face(s)');

    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception('Failed to decode image bytes');
    }

    final List<FaceInfo> faceInfoList = [];

    for (int i = 0; i < faces.length; i++) {
      final face = faces[i];
      final box = face.boundingBox;

      final originalWidth = box.width.toInt();
      final originalHeight = box.height.toInt();

      final distanceResult = _calculateDistanceScore(originalWidth);

      print('👤 Face ${i + 1}: ${originalWidth}x${originalHeight}px - ${distanceResult['status']}');

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

      faceInfoList.add(FaceInfo(
        croppedFace: resized,
        distanceScore: distanceResult['score'] as double,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
        distanceStatus: distanceResult['status'] as String,
      ));
    }

    return faceInfoList;
  }

  Future<List<img.Image>> detectAndCropAllFaces(
    String filePath, {
    double paddingPercent = 0.25,
    int outputSize = 160,
  }) async {
    final faceInfos = await detectAndCropAllFacesWithDistance(
      filePath,
      paddingPercent: paddingPercent,
      outputSize: outputSize,
    );
    
    return faceInfos.map((info) => info.croppedFace).toList();
  }

  Map<String, dynamic> _calculateDistanceScore(int faceWidth) {
    double score;
    String status;

    if (faceWidth < minFaceWidth) {
      score = 0.0;
      status = '❌ TOO FAR (${faceWidth}px < ${minFaceWidth}px)';
    } else if (faceWidth > maxFaceWidth) {
      score = 2.0;
      status = '❌ TOO CLOSE (${faceWidth}px > ${maxFaceWidth}px)';
    } else if (faceWidth >= idealMinWidth && faceWidth <= idealMaxWidth) {
      score = 1.0;
      status = '✅ PERFECT (${faceWidth}px)';
    } else {
      score = 0.5;
      status = '⚠️ ACCEPTABLE (${faceWidth}px)';
    }

    return {
      'score': score,
      'status': status,
    };
  }

  img.Image _enhanceForDetection(img.Image image) {
    var enhanced = img.adjustColor(
      image,
      brightness: 1.15,
      contrast: 1.25,
      saturation: 1.05,
    );
    
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