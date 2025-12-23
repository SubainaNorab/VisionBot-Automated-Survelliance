# Setup Guide - Face Recognition App

This guide helps you set up and build the Flutter face recognition app successfully.

## Quick Start

```bash
# 1. Navigate to project
cd detectapp

# 2. Download Git LFS files (important!)
git lfs pull

# 3. Install dependencies
flutter pub get

# 4. Run the app
flutter run
```

## Detailed Setup

### Step 1: System Requirements

Ensure you have:
- ✅ Flutter SDK 3.32.7 or higher
- ✅ Java JDK 21 or higher
- ✅ Android SDK 36
- ✅ Git LFS installed

**Check Flutter version:**
```bash
flutter --version
# Should show Flutter 3.32.7 or higher
```

**Check Java version:**
```bash
java -version
# Should show version 21 or higher
```

**Install Git LFS (if not installed):**
```bash
# Ubuntu/Debian
sudo apt-get install git-lfs

# macOS
brew install git-lfs

# Windows (using Chocolatey)
choco install git-lfs

# Initialize Git LFS
git lfs install
```

### Step 2: Download Model File

The VGG Face model is stored using Git LFS due to its large size (537MB).

**Download the model:**
```bash
cd /path/to/VisionBot-Automated-Survelliance
git lfs pull
```

**Verify the model was downloaded:**
```bash
cd detectapp
ls -lh assets/model/vgg_face_embedding_no_opt.tflite
```

You should see a file size of approximately **537 MB**. If you see **134 bytes**, the model hasn't been downloaded from LFS yet.

### Step 3: Install Flutter Dependencies

```bash
cd detectapp
flutter pub get
```

This will download:
- tflite_flutter 0.11.0
- firebase_core 3.6.0
- cloud_firestore 5.4.4
- camera 0.11.0+2
- image 4.2.0
- And other dependencies

### Step 4: Configure Android SDK

**Set ANDROID_HOME environment variable:**
```bash
# Linux/macOS (add to ~/.bashrc or ~/.zshrc)
export ANDROID_HOME=$HOME/Android/Sdk
export PATH=$PATH:$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools

# Windows (in Environment Variables)
ANDROID_HOME=C:\Users\YourName\AppData\Local\Android\Sdk
```

**Install required SDK components:**
```bash
# Using Android Studio SDK Manager or command line:
sdkmanager "platforms;android-36"
sdkmanager "build-tools;34.0.0"
sdkmanager "ndk;25.1.8937393"
```

### Step 5: Firebase Configuration

The app comes pre-configured with Firebase credentials, but you can update them:

**Option 1: Use existing configuration** (recommended)
- The app uses the existing Firebase project: `visionbot-82c8b`
- Credentials are in `lib/firebase_options.dart`
- google-services.json is in `android/app/`

**Option 2: Use your own Firebase project**
1. Create a new Firebase project at https://console.firebase.google.com
2. Add an Android app with package name: `com.example.detectapp`
3. Download `google-services.json` and place in `android/app/`
4. Run FlutterFire CLI to regenerate firebase_options.dart:
   ```bash
   flutter pub global activate flutterfire_cli
   flutterfire configure
   ```
5. Enable Firestore in Firebase Console
6. Create collection named `people`

### Step 6: Build the App

**For development (with debugging):**
```bash
flutter run
```

**For release (optimized):**
```bash
flutter build apk --release
# APK will be at: build/app/outputs/flutter-apk/app-release.apk
```

**For specific Android version:**
```bash
flutter build apk --release --target-platform android-arm64
```

## Common Build Errors & Fixes

### Error 1: "flutter: command not found"

**Solution:**
```bash
# Add Flutter to PATH
export PATH="$PATH:/path/to/flutter/bin"

# Or install Flutter:
git clone https://github.com/flutter/flutter.git -b stable
export PATH="$PATH:`pwd`/flutter/bin"
flutter doctor
```

### Error 2: "Model file not found" or "Failed to load model"

**Cause:** Git LFS pointer file instead of actual model

**Solution:**
```bash
git lfs pull
# Then rebuild
flutter clean
flutter pub get
flutter run
```

### Error 3: "Namespace not specified" (AGP 8.3+)

**Status:** ✅ Already fixed in configuration

The namespace is set in `android/app/build.gradle`:
```gradle
android {
    namespace "com.example.detectapp"
    compileSdk 36
    ...
}
```

### Error 4: "Native assets crash" or "Null pointer in FFI"

**Status:** ✅ Already fixed in configuration

Native assets are disabled in `android/gradle.properties`:
```properties
flutter.useNativeAssets=false
```

### Error 5: "Unsupported class file major version 65" (Java version)

**Cause:** Java 21 bytecode incompatible with older tools

**Solution:** Update Kotlin and Gradle (already done):
- Kotlin: 2.0.21
- AGP: 8.3.2
- Gradle: 8.5

### Error 6: "Camera permission denied"

**Solution:**
1. Ensure CAMERA permission is in AndroidManifest.xml (✅ already present)
2. For Android 11+, request permission at runtime:
   ```dart
   // The app already handles this in camera initialization
   ```
3. If testing on emulator, grant permission manually in Settings

### Error 7: "Firebase initialization failed"

**Check:**
1. Internet connectivity
2. google-services.json is present in `android/app/`
3. Firebase project is active in console
4. Firestore is enabled

**Debug:**
```bash
adb logcat | grep -i firebase
```

### Error 8: "Execution failed for task ':app:processDebugResources'"

**Solution:**
```bash
flutter clean
cd android
./gradlew clean
cd ..
flutter pub get
flutter run
```

## Gradle Wrapper Issues

If Gradle wrapper fails to download:

```bash
cd android
./gradlew wrapper --gradle-version=8.5 --distribution-type=all
cd ..
flutter run
```

## Testing the App

### 1. Test Model Loading

Run the app and check logs:
```bash
flutter run --verbose | grep -i "tflite\|model"
```

Should see: `✓ TFLite model loaded`

### 2. Test Camera

Grant camera permission when prompted, then:
- Front camera should activate
- Preview should be visible
- Frame processing should start

### 3. Test Firebase

Check Firestore connection:
```bash
adb logcat | grep -i firestore
```

Should see: `✓ Loaded X people from Firebase`

### 4. Test Recognition

To test recognition, you need to add face embeddings to Firestore:

1. Go to Firebase Console → Firestore Database
2. Create a document in `people` collection:
   ```json
   {
     "name": "Test Person",
     "embedding": [/* 4096 double values */],
     "image": "base64_string",
     "time": "2024-01-01T00:00:00Z"
   }
   ```

## Performance Optimization

### For faster builds:

**Enable Gradle daemon:**
```properties
# In android/gradle.properties
org.gradle.daemon=true
org.gradle.parallel=true
org.gradle.configureondemand=true
```

**Use Gradle build cache:**
```bash
# In android/gradle.properties
android.enableBuildCache=true
org.gradle.caching=true
```

### For smaller APK size:

```bash
# Build split APKs per ABI
flutter build apk --split-per-abi

# Or build app bundle
flutter build appbundle
```

## Deployment

### Release Checklist

- [ ] Git LFS model file is downloaded (537MB)
- [ ] All dependencies installed successfully
- [ ] App builds without errors
- [ ] Camera permission works
- [ ] Firebase connection successful
- [ ] Model loads correctly
- [ ] Face recognition works
- [ ] Signed APK generated (for distribution)

### Generate Signed APK

1. Create keystore:
   ```bash
   keytool -genkey -v -keystore ~/upload-keystore.jks \
     -keyalg RSA -keysize 2048 -validity 10000 \
     -alias upload
   ```

2. Create `android/key.properties`:
   ```properties
   storePassword=<password>
   keyPassword=<password>
   keyAlias=upload
   storeFile=/path/to/upload-keystore.jks
   ```

3. Update `android/app/build.gradle` to use signing config

4. Build:
   ```bash
   flutter build apk --release
   ```

## Support

If you encounter issues not covered here:

1. Check Flutter doctor: `flutter doctor -v`
2. Check Android licenses: `flutter doctor --android-licenses`
3. Review logs: `flutter run --verbose`
4. Check GitHub Issues for similar problems

## Additional Resources

- Flutter Documentation: https://docs.flutter.dev
- TFLite Flutter: https://pub.dev/packages/tflite_flutter
- Firebase for Flutter: https://firebase.flutter.dev
- Git LFS: https://git-lfs.github.com
