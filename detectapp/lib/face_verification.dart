import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'model/person.dart';

class VerificationResult {
  final bool verified;
  final Person? person;
  final double distance;
  final double confidence;
  final String message;

  const VerificationResult({
    required this.verified,
    required this.person,
    required this.distance,
    required this.confidence,
    required this.message,
  });

  @override
  String toString() {
    return 'VerificationResult(verified=$verified, person=${person?.name}, distance=$distance, confidence=$confidence, message=$message)';
  }
}

class FaceVerificationService {
  static const String collectionName = 'enrolled_faces';
  static const String modelAssetPath = 'assets/facenet.tflite';

  static const double defaultThreshold = 0.90;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Interpreter? _interpreter;

  int _inputW = 160;
  int _inputH = 160;
  int _embeddingSize = 128;

  final List<Person> _enrolledPeople = [];

  int get enrolledCount => _enrolledPeople.length;
  bool get isReady => _interpreter != null;

  Future<void> initialize() async {
    _logStart('🚀', 'FaceVerification.initialize started');
    await _loadModel();
    await loadEnrolledPeople();
    _logOk('✅', 'FaceVerification.initialize done');
  }

  void dispose() {
    _logInfo('🧹', 'FaceVerification.dispose');
    _interpreter?.close();
    _interpreter = null;
  }

  VerificationResult verify(img.Image faceImage) {
    return verifyFace(faceImage);
  }

  VerificationResult verifyFace(
    img.Image faceImage, {
    double threshold = defaultThreshold,
  }) {
    if (_interpreter == null) {
      _logErr('❌', 'verifyFace called before model load');
      return const VerificationResult(
        verified: false,
        person: null,
        distance: 999,
        confidence: 0.0,
        message: 'Model not loaded',
      );
    }

    if (_enrolledPeople.isEmpty) {
      _logWarn('⚠️', 'No enrolled faces loaded');
      return const VerificationResult(
        verified: false,
        person: null,
        distance: 999,
        confidence: 0.0,
        message: 'No enrolled faces found in Firestore',
      );
    }

    _logInfo('🧠', 'Generating embedding...');
    final input = _preprocessFace(faceImage);
    final candidate = _getEmbedding(input);

    Person? bestPerson;
    double bestDistance = double.infinity;

    for (final person in _enrolledPeople) {
      final stored = person.embedding;
      if (stored.length != _embeddingSize) continue;

      final d = _euclideanDistance(candidate, stored);
      if (d < bestDistance) {
        bestDistance = d;
        bestPerson = person;
      }
    }

    if (bestPerson == null) {
      _logErr('❌', 'No valid enrolled embeddings found');
      return const VerificationResult(
        verified: false,
        person: null,
        distance: 999,
        confidence: 0.0,
        message: 'No valid enrolled embeddings',
      );
    }

    final verified = bestDistance <= threshold;
    final confidence =
        verified ? (1.0 - (bestDistance / threshold)).clamp(0.0, 1.0) : 0.0;

    final msg =
        verified
            ? '✅ Verified: ${bestPerson.name} (dist=${bestDistance.toStringAsFixed(3)})'
            : '❌ Not matched (dist=${bestDistance.toStringAsFixed(3)})';

    _logInfo(verified ? '✅' : '❌', msg);

    return VerificationResult(
      verified: verified,
      person: verified ? bestPerson : null,
      distance: bestDistance,
      confidence: confidence,
      message: msg,
    );
  }

  Future<void> loadEnrolledPeople() async {
    _logStart('📥', 'Loading enrolled people from Firestore...');

    _enrolledPeople.clear();

    final snap = await _db.collection(collectionName).get();

    for (final doc in snap.docs) {
      final data = doc.data();

      try {
        final p = Person.fromFirestore(doc.id, data);

        if (p.name.trim().isEmpty) continue;
        if (p.embedding.isEmpty) continue;

        if (p.embedding.length != _embeddingSize) {
          _logWarn(
            '⚠️',
            'Skip ${p.name}. embedding len=${p.embedding.length}, expected=$_embeddingSize',
          );
          continue;
        }

        _enrolledPeople.add(p);
      } catch (e) {
        _logWarn('⚠️', 'Skip doc ${doc.id}. parse error: $e');
      }
    }

    _logOk('✅', 'Loaded enrolled people: ${_enrolledPeople.length}');
  }

  Future<void> _loadModel() async {
    _logStart('📦', 'Loading FaceNet model asset...');

    final bytes = await rootBundle.load(modelAssetPath);
    final buffer = bytes.buffer.asUint8List();

    _interpreter = Interpreter.fromBuffer(
      buffer,
      options: InterpreterOptions(),
    );

    final inputShape = _interpreter!.getInputTensor(0).shape;
    final outputShape = _interpreter!.getOutputTensor(0).shape;

    _inputH = inputShape[1];
    _inputW = inputShape[2];
    _embeddingSize = outputShape.last;

    _logOk('✅', 'Model loaded. input=$_inputW x $_inputH, emb=$_embeddingSize');
  }

  List<List<List<List<double>>>> _preprocessFace(img.Image face) {
    final resized = img.copyResize(face, width: _inputW, height: _inputH);

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

        input[0][y][x][0] = p.r / 255.0;
        input[0][y][x][1] = p.g / 255.0;
        input[0][y][x][2] = p.b / 255.0;
      }
    }

    return input;
  }

  List<double> _getEmbedding(List<List<List<List<double>>>> input) {
    final out = List.generate(1, (_) => List.filled(_embeddingSize, 0.0));

    _interpreter!.run(input, out);

    final emb = out[0];

    final norm = sqrt(emb.fold(0.0, (s, v) => s + v * v));
    if (norm > 0) {
      for (int i = 0; i < emb.length; i++) {
        emb[i] = emb[i] / norm;
      }
    }

    return emb;
  }

  double _euclideanDistance(List<double> a, List<double> b) {
    final n = min(a.length, b.length);
    double sum = 0.0;

    for (int i = 0; i < n; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }

    return sqrt(sum);
  }

  void _logStart(String icon, String msg) {
    // ignore: avoid_print
    print('$icon $msg');
  }

  void _logOk(String icon, String msg) {
    // ignore: avoid_print
    print('$icon $msg');
  }

  void _logInfo(String icon, String msg) {
    // ignore: avoid_print
    print('$icon $msg');
  }

  void _logWarn(String icon, String msg) {
    // ignore: avoid_print
    print('$icon $msg');
  }

  void _logErr(String icon, String msg) {
    // ignore: avoid_print
    print('$icon $msg');
  }
}
