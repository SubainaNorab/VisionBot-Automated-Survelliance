import 'dart:io';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

class FaceDetectionService {
  static final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableContours: false,
      enableLandmarks: false,
    ),
  );

  static img.Image? detectAndCropFace(File imageFile) {
    final inputImage = InputImage.fromFile(imageFile);

    // ML Kit is async, but your current main calls sync.
    // Keep this method sync by doing a simple fallback crop if you want sync only.
    // Better: use detectAndCropFaceAsync below.
    return null;
  }

  static Future<img.Image?> detectAndCropFaceAsync(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final faces = await _detector.processImage(inputImage);

    if (faces.isEmpty) return null;

    final bytes = await imageFile.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    // pick the largest face
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

    final rect = best.boundingBox;

    int x = rect.left.floor();
    int y = rect.top.floor();
    int w = rect.width.floor();
    int h = rect.height.floor();

    // padding
    final pad = (w * 0.25).floor();
    x = (x - pad).clamp(0, decoded.width - 1);
    y = (y - pad).clamp(0, decoded.height - 1);
    w = (w + pad * 2).clamp(1, decoded.width - x);
    h = (h + pad * 2).clamp(1, decoded.height - y);

    final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
    return cropped;
  }

  static Future<void> dispose() async {
    await _detector.close();
  }
}
