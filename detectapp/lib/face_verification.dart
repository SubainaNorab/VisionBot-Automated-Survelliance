// face_verification.dart - FIXED: Crash recovery + fallback handling

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

  static const double threshold = 0.45;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Interpreter? _interpreter;

  int _inputW = 160;
  int _inputH = 160;
  int _embSize = 128;

  final List<Person> _people = [];
  
  // ✅ NEW: Track if verification is working
  bool _verificationBroken = false;

  Future<void> initialize() async {
    print('🔧 FaceVerification initialize');
    await _loadModel();
    await _loadPeople();
  }

  void dispose() {
    try {
      _interpreter?.close();
      _interpreter = null;
    } catch (e) {
      print('⚠️ Dispose error: $e');
    }
  }

  /// ✅ FIXED: Handle verification failures gracefully
  VerificationResult verifyFace(img.Image face) {
    try {
      // ✅ If verification is broken, return unknown
      if (_verificationBroken) {
        print('⚠️ Verification system broken, treating as unknown');
        return _fail('Verification system offline');
      }
      
      if (_interpreter == null) {
        _verificationBroken = true;
        return _fail('Model not loaded');
      }

      if (_people.isEmpty) {
        return _fail('No enrolled faces');
      }

      // ✅ Validate input
      if (face.width < 100 || face.height < 100) {
        return _fail('Face too small for verification');
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
            : '⚠️ NO MATCH dist=${bestDist.toStringAsFixed(3)}',
      );

      return VerificationResult(
        verified: matched,
        person: matched ? bestPerson : null,
        confidence: confidence,
        message: matched
            ? 'Verified ${bestPerson!.name}'
            : 'Not matched (distance=${bestDist.toStringAsFixed(3)})',
      );
    } catch (e, st) {
      print('❌ Verification error: $e');
      print('   Stack: $st');
      _verificationBroken = true;
      return _fail('Verification failed: $e');
    }
  }

  /// ✅ FIXED: Handle multiple faces with crash recovery
  List<VerificationResult> verifyMultipleFaces(List<img.Image> faces) {
    try {
      if (_interpreter == null) {
        _verificationBroken = true;
        return [_fail('Model not loaded')];
      }

      if (_people.isEmpty) {
        return [_fail('No enrolled faces')];
      }

      final results = <VerificationResult>[];

      for (int i = 0; i < faces.length; i++) {
        try {
          // ✅ If broken, treat all remaining as unknown
          if (_verificationBroken) {
            print('⚠️ Verification broken, treating face ${i+1} as unknown');
            results.add(_fail('Verification system offline'));
            continue;
          }
          
          final face = faces[i];
          
          // ✅ Validate input
          if (face.width < 100 || face.height < 100) {
            print('⚠️ Face ${i+1} too small (${face.width}x${face.height})');
            results.add(_fail('Face too small'));
            continue;
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
                ? '✅ MATCH [${i + 1}/${faces.length}] ${bestPerson!.name} dist=${bestDist.toStringAsFixed(3)}'
                : '⚠️ NO MATCH [${i + 1}/${faces.length}] dist=${bestDist.toStringAsFixed(3)}',
          );

          results.add(VerificationResult(
            verified: matched,
            person: matched ? bestPerson : null,
            confidence: confidence,
            message: matched
                ? 'Verified ${bestPerson!.name}'
                : 'Unknown (dist=${bestDist.toStringAsFixed(3)})',
          ));
        } catch (e, st) {
          print('❌ Face ${i+1} verification error: $e');
          print('   Stack: $st');
          _verificationBroken = true;
          
          // ✅ Add unknown result for this face
          results.add(_fail('Verification failed'));
        }
      }

      return results;
    } catch (e, st) {
      print('❌ Batch verification error: $e');
      print('   Stack: $st');
      _verificationBroken = true;
      return [_fail('Batch verification failed: $e')];
    }
  }

  Future<void> _loadPeople() async {
    try {
      _people.clear();

      final snap = await _db.collection(_collection).get();

      for (final doc in snap.docs) {
        final p = Person.fromFirestore(doc.id, doc.data());

        if (p.embedding.length != _embSize) continue;

        _people.add(p);
      }

      print('✅ Loaded ${_people.length} enrolled people');
    } catch (e) {
      print('❌ Load people error: $e');
    }
  }

  Future<void> _loadModel() async {
    try {
      final bytes = await rootBundle.load(_modelPath);
      _interpreter = Interpreter.fromBuffer(
        bytes.buffer.asUint8List(),
        options: InterpreterOptions()..threads = 1,  // ✅ Single thread to avoid crashes
      );

      final inShape = _interpreter!.getInputTensor(0).shape;
      final outShape = _interpreter!.getOutputTensor(0).shape;

      _inputH = inShape[1];
      _inputW = inShape[2];
      _embSize = outShape.last;

      print('✅ Model loaded input=$_inputW x $_inputH emb=$_embSize');
    } catch (e, st) {
      print('❌ Model load error: $e');
      print('   Stack: $st');
      _verificationBroken = true;
    }
  }

  List<List<List<List<double>>>> _preprocess(img.Image face) {
    try {
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
    } catch (e) {
      print('❌ Preprocess error: $e');
      _verificationBroken = true;
      rethrow;
    }
  }

  // ✅ FIXED: Add crash recovery in embedding
  List<double> _embedding(List<List<List<List<double>>>> input) {
    try {
      if (_interpreter == null) {
        throw Exception('Interpreter not initialized');
      }

      final out = List.generate(1, (_) => List.filled(_embSize, 0.0));

      // ✅ This is where it crashes - wrap in try-catch
      try {
        _interpreter!.run(input, out);
      } catch (e, st) {
        print('❌ TFLite inference crash: $e');
        print('   Stack: $st');
        _verificationBroken = true;
        rethrow;
      }

      final emb = out[0];

      final norm = sqrt(emb.fold(0.0, (s, v) => s + v * v));
      
      // ✅ Safety check for invalid norm
      if (norm == 0 || norm.isNaN || norm.isInfinite) {
        print('❌ Invalid embedding norm: $norm');
        _verificationBroken = true;
        throw Exception('Invalid embedding: norm=$norm');
      }
      
      for (int i = 0; i < emb.length; i++) {
        emb[i] /= norm;
      }

      print(
        '🧠 Embedding ok l2=${norm.toStringAsFixed(4)} '
        'range=[${emb.reduce(min).toStringAsFixed(3)}, '
        '${emb.reduce(max).toStringAsFixed(3)}]',
      );

      return emb;
    } catch (e, st) {
      print('❌ Embedding error: $e');
      print('   Stack: $st');
      _verificationBroken = true;
      rethrow;
    }
  }

  double _cosineDistance(List<double> a, List<double> b) {
    try {
      double dot = 0, na = 0, nb = 0;
      for (int i = 0; i < a.length; i++) {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
      }
      final result = 1.0 - (dot / (sqrt(na) * sqrt(nb)));
      return result.clamp(-1.0, 1.0);  // ✅ Clamp to valid range
    } catch (e) {
      print('❌ Distance calculation error: $e');
      return 1.0;  // ✅ Return max distance on error
    }
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