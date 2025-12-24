import "dart:io";
import "package:google_mlkit_face_detection/google_mlkit_face_detection.dart";
import "package:image/image.dart" as img;

class FaceDetectionService {
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableLandmarks: true,
      enableContours: false,
      enableClassification: false,
      minFaceSize: 0.15,
    ),
  );

  Future<img.Image?> detectAndCropFaceFromFile(
    String filePath, {
    double paddingPercent = 0.25,
  }) async {
    final input = InputImage.fromFile(File(filePath));
    final faces = await _detector.processImage(input);
    if (faces.isEmpty) return null;

    faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height)
        .compareTo(a.boundingBox.width * a.boundingBox.height));
    final face = faces.first;

    final bytes = await File(filePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    final b = face.boundingBox;

    final padX = (b.width * paddingPercent).round();
    final padY = (b.height * paddingPercent).round();

    final x1 = (b.left.round() - padX).clamp(0, decoded.width - 1);
    final y1 = (b.top.round() - padY).clamp(0, decoded.height - 1);
    final x2 = (b.right.round() + padX).clamp(0, decoded.width);
    final y2 = (b.bottom.round() + padY).clamp(0, decoded.height);

    final w = (x2 - x1).clamp(1, decoded.width);
    final h = (y2 - y1).clamp(1, decoded.height);

    final cropped = img.copyCrop(decoded, x: x1, y: y1, width: w, height: h);

    if (cropped.width < 80 || cropped.height < 80) return null;

    return cropped;
  }

  Future<void> dispose() async {
    await _detector.close();
  }
}
