// face_verification.dart - COMPLETE REWRITE: Proper embedding handling + debugging

import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/foundation.dart';

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

  // ✅ UPDATED: Threshold tuned for FaceNet
  static const double threshold = 0.45;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Interpreter? _interpreter;

  int _inputW = 160;
  int _inputH = 160;
  int _embSize = 128;

  final List<Person> _people = [];

  Future<void> initialize() async {
    debugPrint('');
    debugPrint('═══════════════════════════════════');
    debugPrint('🔧 FaceVerification initialize');
    debugPrint('═══════════════════════════════════');
    
    await _loadModel();
    await _loadPeople();
    
    debugPrint('✅ FaceVerification initialized');
    debugPrint('═══════════════════════════════════');
    debugPrint('');
  }

  void dispose() {
    try {
      _interpreter?.close();
      _interpreter = null;
      debugPrint('✅ FaceVerification disposed');
    } catch (e) {
      debugPrint('⚠️ Dispose error: $e');
    }
  }

  /// ✅ FIXED: Verify single face with complete error handling
  VerificationResult verifyFace(img.Image face) {
    try {
      if (_interpreter == null) {
        return _fail('Model not loaded');
      }

      if (_people.isEmpty) {
        return _fail('No enrolled faces');
      }

      // ✅ Validate input face size
      if (face.width < 80 || face.height < 80) {
        debugPrint('⚠️ Face too small: ${face.width}x${face.height}');
        return _fail('Face too small for verification');
      }

      debugPrint('🔍 Verifying face (${face.width}x${face.height})...');

      final input = _preprocess(face);
      final candidate = _embedding(input);

      // ✅ Validate embedding
      if (candidate.isEmpty) {
        return _fail('Failed to generate embedding');
      }

      if (!_isValidEmbedding(candidate)) {
        debugPrint('❌ Invalid embedding: contains NaN or Inf');
        return _fail('Invalid embedding generated');
      }

      final candidateNorm = _getEmbeddingNorm(candidate);
      debugPrint('   Candidate embedding norm: ${candidateNorm.toStringAsFixed(4)}');

      double bestDist = double.infinity;
      Person? bestPerson;

      // ✅ Find closest match
      debugPrint('   Comparing against ${_people.length} enrolled people...');
      for (final p in _people) {
        try {
          if (!_isValidEmbedding(p.embedding)) {
            debugPrint('   ⚠️ Skipping ${p.name}: invalid enrollment embedding');
            continue;
          }

          final d = _cosineDistance(candidate, p.embedding);
          debugPrint('   ${p.name}: distance=${d.toStringAsFixed(4)}');

          if (d < bestDist) {
            bestDist = d;
            bestPerson = p;
          }
        } catch (e) {
          debugPrint('   ❌ Error comparing to ${p.name}: $e');
          continue;
        }
      }

      // ✅ Check if matched
      final matched = bestDist <= threshold;
      final confidence = (1.0 - (bestDist / threshold)).clamp(0.0, 1.0);

      if (matched && bestPerson != null) {
        debugPrint('✅ MATCH: ${bestPerson.name}');
        debugPrint('   Distance: ${bestDist.toStringAsFixed(4)} (threshold: ${threshold.toStringAsFixed(4)})');
        debugPrint('   Confidence: ${(confidence * 100).toStringAsFixed(1)}%');
      } else {
        debugPrint('⚠️ NO MATCH');
        debugPrint('   Best distance: ${bestDist.toStringAsFixed(4)} (threshold: ${threshold.toStringAsFixed(4)})');
      }

      return VerificationResult(
        verified: matched,
        person: matched ? bestPerson : null,
        confidence: confidence,
        message: matched
            ? 'Verified ${bestPerson!.name}'
            : 'Unknown (dist=${bestDist.toStringAsFixed(3)})',
      );
    } catch (e, st) {
      debugPrint('❌ Verify face error: $e');
      debugPrint('   Stack: $st');
      return _fail('Verification error: $e');
    }
  }

  /// ✅ FIXED: Verify multiple faces with individual error handling
  List<VerificationResult> verifyMultipleFaces(List<img.Image> faces) {
    try {
      if (_interpreter == null) {
        return [_fail('Model not loaded')];
      }

      if (_people.isEmpty) {
        return [_fail('No enrolled faces')];
      }

      if (faces.isEmpty) {
        return [_fail('No faces to verify')];
      }

      debugPrint('');
      debugPrint('🔍 Verifying ${faces.length} face(s)...');

      final results = <VerificationResult>[];

      for (int i = 0; i < faces.length; i++) {
        try {
          final face = faces[i];
          debugPrint('');
          debugPrint('   Face ${i + 1}/${faces.length} (${face.width}x${face.height})');

          // ✅ Validate input
          if (face.width < 80 || face.height < 80) {
            debugPrint('   ⚠️ Too small for verification');
            results.add(_fail('Face too small'));
            continue;
          }

          // ✅ Generate embedding for this face
          final input = _preprocess(face);
          final candidate = _embedding(input);

          if (candidate.isEmpty) {
            debugPrint('   ⚠️ Embedding generation failed');
            results.add(_fail('No embedding generated'));
            continue;
          }

          if (!_isValidEmbedding(candidate)) {
            debugPrint('   ⚠️ Embedding contains NaN/Inf');
            results.add(_fail('Invalid embedding'));
            continue;
          }

          final candidateNorm = _getEmbeddingNorm(candidate);
          debugPrint('   Embedding norm: ${candidateNorm.toStringAsFixed(4)}');

          // ✅ Find closest enrolled person
          double bestDist = double.infinity;
          Person? bestPerson;

          for (final p in _people) {
            try {
              if (!_isValidEmbedding(p.embedding)) {
                continue;
              }

              final d = _cosineDistance(candidate, p.embedding);
              if (d < bestDist) {
                bestDist = d;
                bestPerson = p;
              }
            } catch (e) {
              debugPrint('   ⚠️ Error with ${p.name}: $e');
              continue;
            }
          }

          // ✅ Check match
          final matched = bestDist <= threshold;
          final confidence = (1.0 - (bestDist / threshold)).clamp(0.0, 1.0);

          if (matched && bestPerson != null) {
            debugPrint('   ✅ MATCH: ${bestPerson.name} (dist=${bestDist.toStringAsFixed(4)})');
          } else {
            debugPrint('   ⚠️ NO MATCH (dist=${bestDist.toStringAsFixed(4)})');
          }

          results.add(VerificationResult(
            verified: matched,
            person: matched ? bestPerson : null,
            confidence: confidence,
            message: matched
                ? 'Verified ${bestPerson!.name}'
                : 'Unknown (dist=${bestDist.toStringAsFixed(3)})',
          ));
        } catch (e, st) {
          debugPrint('   ❌ Error: $e');
          debugPrint('      Stack: $st');
          // ✅ Add unknown result for this face, continue to next
          results.add(_fail('Face verification failed'));
        }
      }

      debugPrint('');
      return results;
    } catch (e, st) {
      debugPrint('❌ Batch verification error: $e');
      debugPrint('   Stack: $st');
      return [_fail('Batch verification failed: $e')];
    }
  }

  // ✅ NEW: Validate embedding is real number
  bool _isValidEmbedding(List<double> embedding) {
    for (final val in embedding) {
      if (val.isNaN || val.isInfinite) {
        return false;
      }
    }
    return true;
  }

  // ✅ NEW: Get embedding L2 norm
  double _getEmbeddingNorm(List<double> embedding) {
    double sum = 0;
    for (final val in embedding) {
      sum += val * val;
    }
    return sqrt(sum);
  }

  Future<void> _loadPeople() async {
    try {
      _people.clear();

      debugPrint('📥 Loading enrolled faces from Firebase...');

      final snap = await _db.collection(_collection).get();

      debugPrint('   Found ${snap.docs.length} documents');

      for (final doc in snap.docs) {
        try {
          final p = Person.fromFirestore(doc.id, doc.data());

          // ✅ Validate enrollment data
          if (p.embedding.isEmpty) {
            debugPrint('   ⚠️ Skipping ${p.name}: empty embedding');
            continue;
          }

          if (p.embedding.length != _embSize) {
            debugPrint('   ⚠️ Skipping ${p.name}: embedding size ${p.embedding.length} != $_embSize');
            continue;
          }

          // ✅ Validate embedding is valid numbers
          if (!_isValidEmbedding(p.embedding)) {
            debugPrint('   ⚠️ Skipping ${p.name}: contains NaN/Inf');
            continue;
          }

          // ✅ Check embedding norm
          final norm = _getEmbeddingNorm(p.embedding);
          debugPrint('   ✅ Loaded ${p.name}');
          debugPrint('      Embedding size: ${p.embedding.length}');
          debugPrint('      Norm: ${norm.toStringAsFixed(4)}');
          debugPrint('      First 5 values: ${p.embedding.take(5).map((v) => v.toStringAsFixed(4)).join(', ')}');

          _people.add(p);
        } catch (e, st) {
          debugPrint('   ❌ Failed to load ${doc.id}: $e');
          debugPrint('      Stack: $st');
          continue;
        }
      }

      debugPrint('✅ Loaded ${_people.length} enrolled people');

      if (_people.isEmpty) {
        debugPrint('⚠️ WARNING: No enrolled faces loaded!');
      }
    } catch (e, st) {
      debugPrint('❌ Load people error: $e');
      debugPrint('   Stack: $st');
    }
  }

  Future<void> _loadModel() async {
    try {
      debugPrint('📥 Loading FaceNet model...');

      final bytes = await rootBundle.load(_modelPath);
      _interpreter = Interpreter.fromBuffer(
        bytes.buffer.asUint8List(),
        options: InterpreterOptions()..threads = 1,
      );

      final inShape = _interpreter!.getInputTensor(0).shape;
      final outShape = _interpreter!.getOutputTensor(0).shape;

      _inputH = inShape[1];
      _inputW = inShape[2];
      _embSize = outShape.last;

      debugPrint('✅ Model loaded');
      debugPrint('   Input shape: ${inShape[0]}x${_inputW}x${_inputH}x${inShape[3]}');
      debugPrint('   Output shape: ${outShape[0]}x$_embSize');
    } catch (e, st) {
      debugPrint('❌ Model load error: $e');
      debugPrint('   Stack: $st');
    }
  }

  // ✅ FIXED: Proper preprocessing matching enrollment
  List<List<List<List<double>>>> _preprocess(img.Image face) {
    try {
      // ✅ Resize to model input size
      final resized = img.copyResize(face, width: _inputW, height: _inputH);

      final input = List.generate(
        1,
        (_) => List.generate(
          _inputH,
          (_) => List.generate(_inputW, (_) => List.filled(3, 0.0)),
        ),
      );

      // ✅ Convert to normalized float [0.0, 1.0]
      // Match Python: face_normalized = face_rgb.astype(np.float32) / 255.0
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
      debugPrint('❌ Preprocess error: $e');
      rethrow;
    }
  }

  // ✅ FIXED: Generate embedding with proper L2 normalization
  List<double> _embedding(List<List<List<List<double>>>> input) {
    try {
      if (_interpreter == null) {
        throw Exception('Interpreter not initialized');
      }

      final out = List.generate(1, (_) => List.filled(_embSize, 0.0));

      // ✅ Run inference
      _interpreter!.run(input, out);

      final emb = out[0];

      // ✅ L2 normalize (match Python: embedding_flat / norm)
      // This is EXACTLY what the enrollment script does
      double normSqSum = 0;
      for (final v in emb) {
        normSqSum += v * v;
      }

      final norm = sqrt(normSqSum);

      if (norm == 0 || norm.isNaN || norm.isInfinite) {
        debugPrint('❌ Invalid norm: $norm');
        throw Exception('Invalid embedding norm: $norm');
      }

      for (int i = 0; i < emb.length; i++) {
        emb[i] /= norm;
      }

      // ✅ Validate result
      for (final val in emb) {
        if (val.isNaN || val.isInfinite) {
          debugPrint('❌ Embedding contains NaN/Inf after normalization');
          throw Exception('Invalid normalized embedding');
        }
      }

      return emb;
    } catch (e, st) {
      debugPrint('❌ Embedding error: $e');
      debugPrint('   Stack: $st');
      rethrow;
    }
  }

  // ✅ FIXED: Proper cosine distance calculation
  double _cosineDistance(List<double> a, List<double> b) {
    try {
      if (a.length != b.length) {
        throw Exception('Embedding size mismatch: ${a.length} vs ${b.length}');
      }

      double dot = 0;
      double naSqSum = 0;
      double nbSqSum = 0;

      for (int i = 0; i < a.length; i++) {
        dot += a[i] * b[i];
        naSqSum += a[i] * a[i];
        nbSqSum += b[i] * b[i];
      }

      final naSqrt = sqrt(naSqSum);
      final nbSqrt = sqrt(nbSqSum);

      if (naSqrt == 0 || nbSqrt == 0 || naSqrt.isNaN || nbSqrt.isNaN) {
        debugPrint('⚠️ Invalid norms in distance calc: $naSqrt, $nbSqrt');
        return 1.0;  // ✅ Max distance on error
      }

      // ✅ Cosine distance = 1 - cosine_similarity
      final cosineSimilarity = dot / (naSqrt * nbSqrt);
      final distance = 1.0 - cosineSimilarity;

      return distance.clamp(-1.0, 2.0);  // ✅ Clamp to valid range
    } catch (e) {
      debugPrint('❌ Distance calculation error: $e');
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