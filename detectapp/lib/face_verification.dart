// right verify

import 'dart:math';
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
}

class FaceVerificationService {
  static const String _collection = 'enrolled_faces';
  static const String _modelPath = 'assets/facenet.tflite';

  static const double threshold = 0.45; // correct FaceNet cosine distance

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Interpreter? _interpreter;

  int _inputW = 160;
  int _inputH = 160;
  int _embSize = 128;

  final List<Person> _people = [];



  Future<void> initialize() async {
    print('🚀 FaceVerification initialize');
    await _loadModel();
    await _loadPeople();
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }


  VerificationResult verifyFace(img.Image face) {
    if (_interpreter == null) {
      return _fail('Model not loaded');
    }

    if (_people.isEmpty) {
      return _fail('No enrolled faces');
    }

    final input = _preprocess(face);
    final candidate = _embedding(input);

    double bestDist = double.infinity;
    Person? bestPerson;

    for (final p in _people) {
      final d = _cosineDistance(candidate, p.embedding);
      if (d < bestDist) {
        bestDist = d;
        bestPerson = p;
      }
    }

    final matched = bestDist <= threshold;
    final confidence = (1.0 - (bestDist / threshold)).clamp(0.0, 1.0);

    print(
      matched
          ? '✅ MATCH ${bestPerson!.name} dist=${bestDist.toStringAsFixed(3)}'
          : '❌ NO MATCH dist=${bestDist.toStringAsFixed(3)}',
    );

    return VerificationResult(
      verified: matched,
      person: matched ? bestPerson : null,
      confidence: confidence,
      message: matched
          ? 'Verified ${bestPerson!.name}'
          : 'Not matched (distance=${bestDist.toStringAsFixed(3)})',
    );
  }


  Future<void> _loadPeople() async {
    _people.clear();

    final snap = await _db.collection(_collection).get();

    for (final doc in snap.docs) {
      final p = Person.fromFirestore(doc.id, doc.data());

      if (p.embedding.length != _embSize) continue;

      _people.add(p);
    }

    print('📦 Loaded ${_people.length} enrolled people');
  }


  Future<void> _loadModel() async {
    final bytes = await rootBundle.load(_modelPath);
    _interpreter = Interpreter.fromBuffer(
      bytes.buffer.asUint8List(),
      options: InterpreterOptions(),
    );

    final inShape = _interpreter!.getInputTensor(0).shape;
    final outShape = _interpreter!.getOutputTensor(0).shape;

    _inputH = inShape[1];
    _inputW = inShape[2];
    _embSize = outShape.last;

    print('✅ Model loaded input=$_inputW x $_inputH emb=$_embSize');
  }


  List<List<List<List<double>>>> _preprocess(img.Image face) {
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

  // ================= EMBEDDING =================

  List<double> _embedding(List<List<List<List<double>>>> input) {
    final out = List.generate(1, (_) => List.filled(_embSize, 0.0));

    _interpreter!.run(input, out);

    final emb = out[0];

    final norm = sqrt(emb.fold(0.0, (s, v) => s + v * v));
    for (int i = 0; i < emb.length; i++) {
      emb[i] /= norm;
    }

    print(
      '🧠 Embedding ok l2=${norm.toStringAsFixed(4)} '
      'range=[${emb.reduce(min).toStringAsFixed(3)}, '
      '${emb.reduce(max).toStringAsFixed(3)}]',
    );

    return emb;
  }


  double _cosineDistance(List<double> a, List<double> b) {
    double dot = 0, na = 0, nb = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return 1.0 - (dot / (sqrt(na) * sqrt(nb)));
  }

  VerificationResult _fail(String msg) {
    return VerificationResult(
      verified: false,
      person: null,
      confidence: 0.0,
      message: msg,
    );
  }
}
