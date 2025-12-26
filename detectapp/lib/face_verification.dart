import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'model/person.dart';

class VerificationResult {
  final bool verified;
  final Person? person;
  final double confidence;
  final String message;

  const VerificationResult({
    required this.verified,
    required this.person,
    required this.confidence,
    required this.message,
  });

  @override
  String toString() {
    return 'VerificationResult(verified=$verified, person=${person?.name}, confidence=$confidence, message=$message)';
  }
}

class FaceVerificationService {
  static const String _collectionName = 'enrolled_faces';
  static const String _modelAssetPath = 'assets/facenet.tflite';

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Interpreter? _interpreter;

  int _inputW = 160;
  int _inputH = 160;
  int _embeddingSize = 128;

  final List<Person> _enrolledPeople = [];

  int get enrolledCount => _enrolledPeople.length;

  Future<void> initialize() async {
    await _loadModel();
    await loadEnrolledPeople();
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }

  // Keep your old call style working
  VerificationResult verify(img.Image faceImage) {
    return verifyFace(faceImage);
  }

  // New name, matches what you were calling in another main.dart
  VerificationResult verifyFace(img.Image faceImage) {
    if (_interpreter == null) {
      return const VerificationResult(
        verified: false,
        person: null,
        confidence: 0.0,
        message: 'Model not loaded',
      );
    }

    if (_enrolledPeople.isEmpty) {
      return const VerificationResult(
        verified: false,
        person: null,
        confidence: 0.0,
        message: 'No enrolled faces found in Firestore',
      );
    }

    final input = _preprocessFace(faceImage);
    final candidate = _getEmbedding(input);

    double bestDistance = double.infinity;
    Person? bestPerson;

    for (final person in _enrolledPeople) {
      for (final stored in person.embeddings) {
        if (stored.length != _embeddingSize) continue;

        final d = _cosineDistance(candidate, stored);
        if (d < bestDistance) {
          bestDistance = d;
          bestPerson = person;
        }
      }
    }

    if (bestPerson == null) {
      return const VerificationResult(
        verified: false,
        person: null,
        confidence: 0.0,
        message: 'No valid enrolled embeddings',
      );
    }

    // Cosine distance: 0 is identical, bigger is worse.
    // Threshold depends on your model and preprocessing.
    // Start here, then tune.
    const threshold = 0.45;

    final verified = bestDistance <= threshold;

    // Convert distance to confidence-like score (0..1), simple and stable.
    final confidence = (1.0 - (bestDistance / threshold)).clamp(0.0, 1.0);

    return VerificationResult(
      verified: verified,
      person: verified ? bestPerson : null,
      confidence: confidence,
      message:
          verified
              ? 'Verified: ${bestPerson.name}'
              : 'Not matched (distance=${bestDistance.toStringAsFixed(3)})',
    );
  }

  Future<void> loadEnrolledPeople() async {
    _enrolledPeople.clear();

    final snap = await _db.collection(_collectionName).get();

    for (final doc in snap.docs) {
      final data = doc.data();
      final p = Person.fromMap(doc.id, data);

      // Filter out bad docs
      if (p.name.trim().isEmpty) continue;
      if (p.embeddings.isEmpty) continue;
      if (p.embeddings.first.length != _embeddingSize) continue;

      _enrolledPeople.add(p);
    }

    // Debug print
    // ignore: avoid_print
    print('✅ Loaded enrolled people: ${_enrolledPeople.length}');
  }

  Future<void> _loadModel() async {
    // ignore: avoid_print
    print('🚀 FaceVerification.initialize started');

    // Do NOT load AssetManifest.json. It can fail in some setups.
    // Just load the model directly.
    final ByteData bytes = await rootBundle.load(_modelAssetPath);
    final buffer = bytes.buffer.asUint8List();

    _interpreter = Interpreter.fromBuffer(
      buffer,
      options: InterpreterOptions(),
    );

    final inputShape = _interpreter!.getInputTensor(0).shape;
    final outputShape = _interpreter!.getOutputTensor(0).shape;

    // input: [1, H, W, 3]
    _inputH = inputShape[1];
    _inputW = inputShape[2];

    // output: [1, 128]
    _embeddingSize = outputShape.last;

    // ignore: avoid_print
    print('✅ Model loaded. input=$_inputH x $_inputW, emb=$_embeddingSize');
  }

  List<List<List<List<double>>>> _preprocessFace(img.Image face) {
    // resize to model input
    final resized = img.copyResize(face, width: _inputW, height: _inputH);

    // float32 normalized 0..1
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputH,
        (_) => List.generate(_inputW, (_) => List.filled(3, 0.0)),
      ),
    );

    for (int y = 0; y < _inputH; y++) {
      for (int x = 0; x < _inputW; x++) {
        final p = resized.getPixel(x, y);

        final r = p.r / 255.0;
        final g = p.g / 255.0;
        final b = p.b / 255.0;

        input[0][y][x][0] = r;
        input[0][y][x][1] = g;
        input[0][y][x][2] = b;
      }
    }

    return input;
  }

  List<double> _getEmbedding(List<List<List<List<double>>>> input) {
    final out = List.generate(1, (_) => List.filled(_embeddingSize, 0.0));

    _interpreter!.run(input, out);

    final emb = out[0];

    // L2 normalize like your Python script
    final norm = sqrt(emb.fold(0.0, (s, v) => s + v * v));
    if (norm > 0) {
      for (int i = 0; i < emb.length; i++) {
        emb[i] = emb[i] / norm;
      }
    }

    return emb;
  }

  double _cosineDistance(List<double> a, List<double> b) {
    double dot = 0.0;
    double na = 0.0;
    double nb = 0.0;

    final n = min(a.length, b.length);
    for (int i = 0; i < n; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }

    final denom = sqrt(na) * sqrt(nb);
    if (denom == 0) return 1.0;

    final sim = dot / denom; // -1..1
    return 1.0 - sim; // 0 is best
  }
}
