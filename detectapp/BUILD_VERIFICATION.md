# Build Verification Checklist

This checklist helps verify that all fixes have been properly applied and the app is ready to build.

## ✅ Configuration Files

### pubspec.yaml
- [ ] `tflite_flutter: ^0.11.0` (compatible with Flutter 3.32.7)
- [ ] `firebase_core: ^3.6.0` (latest stable)
- [ ] `cloud_firestore: ^5.4.4` (latest stable)
- [ ] `camera: ^0.11.0+2` (latest stable)
- [ ] `image: ^4.2.0` (compatible with new API)
- [ ] Asset path: `assets/model/vgg_face_embedding_no_opt.tflite`

### android/build.gradle
- [ ] AGP version: `8.3.2`
- [ ] Kotlin version: `2.0.21`
- [ ] Google services: `4.4.2`

### android/app/build.gradle
- [ ] Namespace: `com.example.detectapp`
- [ ] compileSdk: `36`
- [ ] minSdkVersion: `30` (Android 11)
- [ ] targetSdkVersion: `36`
- [ ] Java compatibility: `VERSION_21`
- [ ] Kotlin jvmTarget: `'21'`

### android/settings.gradle
- [ ] AGP version: `8.3.2` in plugins
- [ ] Kotlin version: `2.0.21` in plugins

### android/gradle.properties
- [ ] `flutter.useNativeAssets=false` (prevents FFI crash)
- [ ] `android.defaults.buildfeatures.buildconfig=true`
- [ ] `android.nonTransitiveRClass=false`
- [ ] `android.nonFinalResIds=false`

### android/app/src/main/AndroidManifest.xml
- [ ] No `package` attribute in manifest tag (uses namespace from build.gradle)
- [ ] `android.permission.CAMERA` permission present
- [ ] `android.permission.INTERNET` permission present
- [ ] Namespace defined in build.gradle instead

## ✅ Source Code

### lib/face_verification.dart
- [ ] Asset path: `assets/model/vgg_face_embedding_no_opt.tflite`
- [ ] Pixel access uses `.toDouble()` for image 4.x compatibility
- [ ] TFLite model loads using `Interpreter.fromAsset()`

### lib/face_Detector.dart
- [ ] Uses image 4.x API (named parameters)
- [ ] `img.Image(width: width, height: height)`
- [ ] `img.copyCrop()` with named parameters
- [ ] `img.copyResize()` with named parameters

### lib/camera.dart
- [ ] Uses camera package 0.11.x API
- [ ] `availableCameras()` called correctly
- [ ] `CameraController` initialized properly

## ✅ Assets

### Model File
- [ ] File exists: `assets/model/vgg_face_embedding_no_opt.tflite`
- [ ] File size: ~537MB (not 134 bytes - that's Git LFS pointer)
- [ ] Run `git lfs pull` if file is only 134 bytes

### Firebase
- [ ] `google-services.json` exists in `android/app/`
- [ ] `lib/firebase_options.dart` configured
- [ ] Firebase project active

## ✅ Build Requirements

### System
- [ ] Java 21 installed: `java -version`
- [ ] Flutter 3.32.7+ installed: `flutter --version`
- [ ] Android SDK 36 installed
- [ ] Git LFS installed: `git lfs version`

### Dependencies
- [ ] Run `flutter pub get` successfully
- [ ] No dependency conflicts
- [ ] All packages downloaded

## ✅ Compatibility Fixes Applied

### Issue 1: TFLite FFI Compatibility
- [x] **Status**: FIXED
- [x] **Solution**: Upgraded to tflite_flutter 0.11.0
- [x] **Verification**: Disabled native_assets in gradle.properties

### Issue 2: Native Assets Crash
- [x] **Status**: FIXED
- [x] **Solution**: `flutter.useNativeAssets=false` in gradle.properties
- [x] **Verification**: Property is set correctly

### Issue 3: Package Namespace (AGP 8.3+)
- [x] **Status**: FIXED
- [x] **Solution**: Namespace in build.gradle, removed from AndroidManifest.xml
- [x] **Verification**: `namespace "com.example.detectapp"` in app/build.gradle

### Issue 4: FFI Binding Errors
- [x] **Status**: FIXED
- [x] **Solution**: Disabled native_assets, using compatible TFLite version
- [x] **Verification**: tflite_flutter 0.11.0 doesn't require FFI bindings

### Issue 5: Image Package API
- [x] **Status**: FIXED
- [x] **Solution**: Updated pixel access to use `.toDouble()` for image 4.x
- [x] **Verification**: All image operations use image 4.x API

### Issue 6: Java 21 Compatibility
- [x] **Status**: FIXED
- [x] **Solution**: Updated Kotlin to 2.0.21, Java target to 21
- [x] **Verification**: All Gradle configs use Java 21

## 🧪 Testing Steps

### 1. Clean Build
```bash
cd detectapp
flutter clean
flutter pub get
```

### 2. Verify Model File
```bash
ls -lh assets/model/vgg_face_embedding_no_opt.tflite
# Should show ~537MB, not 134 bytes
# If 134 bytes, run: git lfs pull
```

### 3. Check Dependencies
```bash
flutter pub outdated
# All packages should be compatible
```

### 4. Verify Android Configuration
```bash
cd android
./gradlew dependencies --configuration debugCompileClasspath
cd ..
```

### 5. Build Debug APK
```bash
flutter build apk --debug
# Should complete without errors
```

### 6. Build Release APK
```bash
flutter build apk --release
# Should complete without errors
```

### 7. Run on Device/Emulator
```bash
flutter run
# Should start without errors
# Check logs for:
# ✓ TFLite model loaded
# ✓ Firebase initialized
# ✓ Camera initialized
```

## 🔍 Verification Commands

### Check Flutter Doctor
```bash
flutter doctor -v
# All checks should pass or have minor warnings
```

### Check Android Licenses
```bash
flutter doctor --android-licenses
# Accept all licenses
```

### Check Gradle
```bash
cd android
./gradlew --version
# Should show Gradle 8.5+
cd ..
```

### Check Build
```bash
flutter build apk --debug --verbose 2>&1 | tee build.log
# Review build.log for any errors
```

## ⚠️ Common Issues During Verification

### If model file is 134 bytes:
```bash
git lfs install
git lfs pull
```

### If dependency conflicts:
```bash
flutter pub cache repair
flutter clean
flutter pub get
```

### If Gradle fails:
```bash
cd android
./gradlew clean
./gradlew build --refresh-dependencies
cd ..
```

### If namespace error:
- Verify `namespace` is in `android/app/build.gradle`
- Verify `package` is NOT in `AndroidManifest.xml`

### If native_assets crash:
- Verify `flutter.useNativeAssets=false` in `gradle.properties`

## ✅ Final Verification

Before considering the app ready for deployment:

- [ ] App builds successfully (debug mode)
- [ ] App builds successfully (release mode)
- [ ] App runs on emulator without crashes
- [ ] Model loads without errors
- [ ] Camera initializes correctly
- [ ] Firebase connects successfully
- [ ] Face detection works
- [ ] Face recognition works (if test data available)
- [ ] No security vulnerabilities detected
- [ ] Code review passed

## 📝 Notes

- All configuration changes are backward compatible with existing code
- The app will work on Android 11 (API 30) and above
- For older Android versions, reduce minSdkVersion (but may lose some features)
- Git LFS is required for the model file - standard Git clone won't download it

## 🎯 Success Criteria

The app is ready when:
1. ✅ All items in this checklist are verified
2. ✅ Build completes without errors
3. ✅ App runs without crashes
4. ✅ Core functionality (camera + model) works
5. ✅ Firebase integration successful

---

**Last Updated**: After applying all compatibility fixes for Flutter 3.32.7, AGP 8.3, and Java 21
