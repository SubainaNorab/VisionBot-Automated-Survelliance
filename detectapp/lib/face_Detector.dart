import 'dart:io';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

class FaceDetectionService {
  final FaceDetector _detector;

  FaceDetectionService()
    : _detector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          enableTracking: false,
          enableLandmarks: false,
          enableContours: false,
          minFaceSize: 0.15,
        ),
      );

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

  Future<void> dispose() async {
    await _detector.close();
  }
}
