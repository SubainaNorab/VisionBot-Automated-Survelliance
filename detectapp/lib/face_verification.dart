import 'dart:typed_data';
import 'dart:math';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image/image.dart' as img;
import 'model/person.dart';

class FaceVerificationService {
  Interpreter? _interpreter;
  List<Person> _enrolledPeople = [];

  // FaceNet Configuration
  static const int INPUT_SIZE = 160;
  static const int EMBEDDING_SIZE = 128;
  static const double RECOGNITION_THRESHOLD =
      0.55; // Cosine similarity threshold

  // Getters
  bool get isInitialized => _interpreter != null;
  int get enrolledCount => _enrolledPeople.length;
  List<Person> get enrolledPeople => List.unmodifiable(_enrolledPeople);

  /// Initialize the face verification service
  Future<void> initialize() async {
    print('=' * 70);
    print('🔄 Initializing Face Verification Service');
    print('=' * 70);

    try {
      // Load TFLite FaceNet model
      print('\n📦 Loading FaceNet model...');
      _interpreter = await Interpreter.fromAsset('facenet.tflite');

      var inputShape = _interpreter!.getInputTensor(0).shape;
      var outputShape = _interpreter!.getOutputTensor(0).shape;

      print('✅ FaceNet model loaded! ');
      print('   Input shape: $inputShape');
      print('   Output shape: $outputShape');

      // Load enrolled people from Firestore
      await loadEnrolledPeople();

      print('\n✅ Face Verification Service initialized! ');
      print('=' * 70);
    } catch (e) {
      print('❌ Initialization error: $e');
      rethrow;
    }
  }

  /// Load enrolled people from Firebase Firestore
  Future<void> loadEnrolledPeople() async {
    print('\n🔥 Loading enrolled people from Firestore...');

    try {
      final snapshot =
          await FirebaseFirestore.instance.collection('enrolled_faces').get();

      if (snapshot.docs.isEmpty) {
        print('⚠️ No enrolled people found in Firestore');
        _enrolledPeople = [];
        return;
      }

      _enrolledPeople = snapshot.docs.map((doc) {
        return Person.fromFirestore(doc.data(), doc.id);
      }).toList();

      print('✅ Loaded ${_enrolledPeople.length} enrolled people: ');
      for (var person in _enrolledPeople) {
        final valid = person.isValidEmbedding() ? '✅' : '⚠️';
        print('   $valid ${person.name} (${person.embedding.length} dims)');
      }
    } catch (e) {
      print('❌ Error loading from Firestore: $e');
      _enrolledPeople = [];
      rethrow;
    }
  }

  /// Generate embedding from face image
  List<double> getEmbedding(img.Image face) {
    if (_interpreter == null) {
      throw Exception('Model not initialized');
    }

    // Ensure face is 160x160
    final resized = img.copyResize(
      face,
      width: INPUT_SIZE,
      height: INPUT_SIZE,
    );

    // Convert to Float32 input
    final input = _imageToInput(resized);

    // Prepare output buffer
    final output = List.generate(
      1,
      (_) => List<double>.filled(EMBEDDING_SIZE, 0.0),
    );

    // Run inference
    _interpreter!.run(input, output);

    // Extract and L2 normalize
    final embedding = output[0];
    final normalized = _l2Normalize(embedding);

    return normalized;
  }

  /// Convert image to model input format
  List<List<List<List<double>>>> _imageToInput(img.Image image) {
    // Create input tensor [1, 160, 160, 3]
    final input = List.generate(
      1,
      (_) => List.generate(
        INPUT_SIZE,
        (y) => List.generate(
          INPUT_SIZE,
          (x) {
            final pixel = image.getPixel(x, y);
            return [
              pixel.r / 255.0,
              pixel.g / 255.0,
              pixel.b / 255.0,
            ];
          },
        ),
      ),
    );

    return input;
  }

  /// L2 normalize embedding vector
  List<double> _l2Normalize(List<double> embedding) {
    double sum = 0.0;
    for (var val in embedding) {
      sum += val * val;
    }

    final norm = sqrt(sum);

    if (norm == 0) {
      print('⚠️ Warning: Zero norm in embedding');
      return embedding;
    }

    return embedding.map((val) => val / norm).toList();
  }

  /// Calculate cosine similarity between two embeddings
  double _cosineSimilarity(List<double> emb1, List<double> emb2) {
    if (emb1.length != emb2.length) {
      throw Exception(
          'Embedding size mismatch:  ${emb1.length} vs ${emb2.length}');
    }

    double dotProduct = 0.0;
    for (int i = 0; i < emb1.length; i++) {
      dotProduct += emb1[i] * emb2[i];
    }

    // Since embeddings are L2 normalized, dot product = cosine similarity
    return dotProduct;
  }

  /// Verify and recognize face
  VerificationResult verify(img.Image face) {
    print('\n🔍 Verifying face...');

    if (_enrolledPeople.isEmpty) {
      return VerificationResult(
        verified: false,
        person: null,
        confidence: 0.0,
        message: 'No enrolled people in database',
      );
    }

    // Get embedding for input face
    final faceEmbedding = getEmbedding(face);

    // Check embedding quality
    final nonZero = faceEmbedding.where((v) => v.abs() > 0.001).length;
    print('   Face embedding non-zero:  $nonZero/${faceEmbedding.length}');

    if (nonZero < 10) {
      return VerificationResult(
        verified: false,
        person: null,
        confidence: 0.0,
        message: 'Invalid face embedding (too many zeros)',
      );
    }

    // Find best match
    Person? bestMatch;
    double bestSimilarity = 0.0;

    print('   Comparing with enrolled people:');
    for (var person in _enrolledPeople) {
      final similarity = _cosineSimilarity(faceEmbedding, person.embedding);

      print('      ${person.name}: ${similarity.toStringAsFixed(4)}');

      if (similarity > bestSimilarity) {
        bestSimilarity = similarity;
        bestMatch = person;
      }
    }

    // Check if best match exceeds threshold
    if (bestSimilarity >= RECOGNITION_THRESHOLD) {
      print(
          '✅ VERIFIED: ${bestMatch!.name} (${(bestSimilarity * 100).toStringAsFixed(1)}%)');

      return VerificationResult(
        verified: true,
        person: bestMatch,
        confidence: bestSimilarity,
        message: 'Welcome, ${bestMatch.name}!',
      );
    } else {
      print(
          '❌ NOT VERIFIED (best:  ${bestMatch?.name} @ ${(bestSimilarity * 100).toStringAsFixed(1)}%)');

      return VerificationResult(
        verified: false,
        person: null,
        confidence: bestSimilarity,
        message: 'Unknown person (confidence too low)',
        nearestMatch: bestMatch?.name,
        nearestSimilarity: bestSimilarity,
      );
    }
  }

  /// Dispose resources
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _enrolledPeople.clear();
  }
}

/// Result of face verification
class VerificationResult {
  final bool verified;
  final Person? person;
  final double confidence;
  final String message;
  final String? nearestMatch;
  final double? nearestSimilarity;

  VerificationResult({
    required this.verified,
    required this.person,
    required this.confidence,
    required this.message,
    this.nearestMatch,
    this.nearestSimilarity,
  });

  @override
  String toString() {
    return 'VerificationResult(verified: $verified, person:  ${person?.name}, confidence: ${(confidence * 100).toStringAsFixed(1)}%)';
  }
}
