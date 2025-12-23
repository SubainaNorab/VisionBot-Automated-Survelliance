import 'package:image/image.dart' as img;

class FaceDetectionService {
  // Simple face detection using center crop
  // For production, replace with Google ML Kit Face Detection or MTCNN

  /// Detect and crop face from image
  /// Returns cropped face or null if no face detected
  static img.Image? detectAndCropFace(img.Image image) {
    print('🔍 Detecting face in ${image.width}x${image.height} image');

    // Simple center crop method
    // TODO: Replace with actual face detection for production
    // Options:
    // 1. Google ML Kit Face Detection
    // 2. MTCNN
    // 3. OpenCV Haar Cascades (via FFI)

    final size = image.width < image.height ? image.width : image.height;
    final x = (image.width - size) ~/ 2;
    final y = (image.height - size) ~/ 2;

    try {
      final cropped = img.copyCrop(
        image,
        x: x,
        y: y,
        width: size,
        height: size,
      );

      print('✅ Face cropped:  ${cropped.width}x${cropped.height}');
      return cropped;
    } catch (e) {
      print('❌ Face crop failed: $e');
      return null;
    }
  }

  /// Preprocess face for FaceNet model
  /// Resize to 160x160
  static img.Image preprocessForFaceNet(img.Image face) {
    print('🔄 Preprocessing face for FaceNet.. .');

    final resized = img.copyResize(
      face,
      width: 160,
      height: 160,
      interpolation: img.Interpolation.linear,
    );

    print('✅ Resized to 160x160');
    return resized;
  }

  /// Validate if image might contain a face
  /// Basic validation - checks if image is not too small
  static bool isValidFaceImage(img.Image? image) {
    if (image == null) return false;

    // Face should be at least 50x50 pixels
    if (image.width < 50 || image.height < 50) {
      print('⚠️ Image too small for face detection');
      return false;
    }

    return true;
  }

  /// Extract face region with padding
  /// Used for better face crop quality
  static img.Image? extractFaceWithPadding(
    img.Image image,
    int x,
    int y,
    int width,
    int height, {
    double padding = 0.3,
  }) {
    try {
      // Calculate padding
      final pad = (width * padding).toInt();

      // Calculate crop boundaries with padding
      final x1 = (x - pad).clamp(0, image.width - 1);
      final y1 = (y - pad).clamp(0, image.height - 1);
      final x2 = (x + width + pad).clamp(0, image.width);
      final y2 = (y + height + pad).clamp(0, image.height);

      final cropWidth = x2 - x1;
      final cropHeight = y2 - y1;

      if (cropWidth <= 0 || cropHeight <= 0) {
        return null;
      }

      return img.copyCrop(
        image,
        x: x1,
        y: y1,
        width: cropWidth,
        height: cropHeight,
      );
    } catch (e) {
      print('❌ Extract face with padding failed: $e');
      return null;
    }
  }
}
