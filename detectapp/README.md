# Face Recognition App

A Flutter-based face recognition application using TensorFlow Lite and Firebase for automated surveillance.

## Features

- Real-time face detection and recognition using camera
- VGG Face model for face embeddings (4096-dimensional vectors)
- Firebase Firestore for storing face embeddings and recognition logs
- Camera integration with support for both front and back cameras
- Live recognition with confidence scores

## Technical Stack

- **Flutter SDK**: 3.32.7+
- **Android SDK**: 36
- **Android Gradle Plugin**: 8.3.2
- **Kotlin**: 2.0.21
- **Java**: 21
- **TensorFlow Lite**: 0.11.0
- **Firebase**: Core 3.6.0, Firestore 5.4.4
- **Camera**: 0.11.0+2
- **Image Processing**: 4.2.0

## Prerequisites

1. Flutter SDK installed (version 3.32.7 or higher)
2. Android Studio with SDK 36 installed
3. Java 21 JDK installed
4. Firebase project configured with Firestore enabled
5. Git LFS installed (for model file)

## Setup Instructions

### 1. Clone Repository with Git LFS

```bash
git lfs install
git clone https://github.com/SubainaNorab/VisionBot-Automated-Survelliance.git
cd VisionBot-Automated-Survelliance/detectapp
```

### 2. Download Model File

The VGG Face model (537MB) is stored in Git LFS. Ensure it's downloaded:

```bash
git lfs pull
```

Verify the model file size:
```bash
ls -lh assets/model/vgg_face_embedding_no_opt.tflite
# Should show ~537MB, not 134 bytes
```

### 3. Install Dependencies

```bash
flutter pub get
```

### 4. Configure Firebase

The app is pre-configured with Firebase credentials in `lib/firebase_options.dart`. Make sure you have:
- `google-services.json` in `android/app/` directory (already present)
- Firestore database created in Firebase console
- Collection named `people` for storing face embeddings

### 5. Build and Run

```bash
# For Android
flutter run

# Or build APK
flutter build apk --release
```

## Architecture

### Core Components

1. **FaceVerificationService** (`lib/face_verification.dart`)
   - Loads TFLite model
   - Generates face embeddings (4096-dimensional vectors)
   - Performs face recognition using cosine distance
   - Manages Firebase Firestore integration
   - Threshold: 0.68 for matching

2. **FaceDetector** (`lib/face_Detector.dart`)
   - Converts CameraImage to processable format
   - Handles YUV420 and BGRA8888 formats
   - Preprocesses images for model input (224x224 RGB)

3. **CameraScreen** (`lib/camera.dart`)
   - Real-time camera preview
   - Continuous face recognition
   - Visual feedback with confidence scores

### Data Flow

```
Camera → YUV/BGRA Image → RGB Conversion → 224x224 Resize → 
VGG Face Model → 4096D Embedding → Cosine Distance → Recognition Result
```

## Android Configuration

### Minimum Requirements
- **minSdkVersion**: 30 (Android 11)
- **targetSdkVersion**: 36
- **compileSdk**: 36

### Key Settings in gradle.properties
```properties
flutter.useNativeAssets=false  # Prevents native_assets crash
android.defaults.buildfeatures.buildconfig=true
android.nonTransitiveRClass=false
```

### Permissions Required
- `android.permission.CAMERA` - For camera access
- `android.permission.INTERNET` - For Firebase connectivity

## Firebase Collections

### Collection: `people`
Structure for enrolled persons:
```json
{
  "name": "Person Name",
  "embedding": [4096 double values],
  "image": "base64_encoded_image",
  "time": Timestamp
}
```

### Collection: `recognition_logs`
Structure for recognition events:
```json
{
  "person_id": "document_id",
  "person_name": "Person Name",
  "confidence": 0.95,
  "time": ServerTimestamp
}
```

## Known Issues & Solutions

### Issue 1: TFLite Native Assets Crash
**Solution**: Set `flutter.useNativeAssets=false` in gradle.properties (already configured)

### Issue 2: AGP 8.3 Namespace Requirements
**Solution**: Use `namespace` in build.gradle instead of `package` in AndroidManifest.xml (already configured)

### Issue 3: Java 21 Compatibility
**Solution**: Updated to Kotlin 2.0.21 and Java 21 target (already configured)

### Issue 4: Git LFS Model File
**Problem**: Model file appears as 134-byte pointer file
**Solution**: Run `git lfs pull` to download actual 537MB model file

## Development

### Adding New Face Embeddings

To enroll a new person, add a document to the `people` collection in Firestore:

```dart
await FirebaseFirestore.instance.collection('people').add({
  'name': 'John Doe',
  'embedding': embedding, // List<double> with 4096 values
  'image': base64Image,
  'time': FieldValue.serverTimestamp(),
});
```

### Adjusting Recognition Threshold

Edit `face_verification.dart`:
```dart
final double _threshold = 0.68; // Lower = stricter, Higher = more lenient
```

## Troubleshooting

### Build Fails with "namespace not found"
- Ensure AGP version is 8.3.2 in settings.gradle
- Verify namespace is set in app/build.gradle

### Camera Permission Denied
- Check AndroidManifest.xml has CAMERA permission
- Request runtime permissions on Android 11+

### Model Loading Fails
- Verify model file is downloaded from Git LFS (not just pointer)
- Check asset path matches pubspec.yaml

### Firebase Connection Issues
- Verify google-services.json is present
- Check internet connectivity
- Ensure Firebase project is active

## License

This project is for automated surveillance purposes.

## Support

For issues, please check the GitHub repository issues section.