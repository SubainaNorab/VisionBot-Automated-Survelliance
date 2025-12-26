import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'model/person.dart';

class FaceVerificationService {
  FaceVerificationService._internal();
  static final FaceVerificationService instance =
      FaceVerificationService._internal();

  factory FaceVerificationService() => instance;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Interpreter? _interpreter;
  int _embeddingSize = 128;

  final List<Person> _people = [];

  bool get isModelLoaded => _interpreter != null;
  int get enrolledCount => _people.length;

  final String collectionName = "enrolled_faces";

  /* ===================== PUBLIC API ===================== */

  Future<void> loadEnrolledPeople() async {
    await initialize();
  }

  Future<Person?> verifyFace(
    List<double> embedding, {
    double threshold = 0.55,
  }) async {
    if (_interpreter == null) {
      print("⚠️ verifyFace called before model load. Initializing...");
      await initialize();
    }

    if (_people.isEmpty) {
      print("⚠️ No enrolled faces available for verification");
      return null;
    }

    Person? best;
    double bestScore = -999;

    for (final person in _people) {
      for (final ref in person.embeddings) {
        final score = _cosineSimilarity(embedding, ref);
        if (score > bestScore) {
          bestScore = score;
          best = person;
        }
      }
    }

    print("🔎 Best match score=$bestScore person=${best?.name}");

    if (best != null && bestScore >= threshold) {
      print("✅ Face verified: ${best.name}");
      return best;
    }

    print("❌ Face not recognized");
    return null;
  }

  /* ===================== INIT ===================== */

  Future<void> initialize() async {
    try {
      print("🚀 FaceVerification.initialize started");
      await _loadModel();
      await _loadEnrolledFaces();
      print(
        "✅ FaceVerification ready. modelLoaded=$isModelLoaded people=${_people.length}",
      );
    } catch (e) {
      print("❌ FaceVerification.initialize failed: $e");
      rethrow;
    }
  }

  /* ===================== MODEL ===================== */

  Future<void> _loadModel() async {
    if (_interpreter != null) {
      print("ℹ️ FaceNet already loaded");
      return;
    }

    try {
      print("📦 Loading FaceNet asset");
      final ByteData bd = await rootBundle.load("assets/facenet.tflite");
      final Uint8List bytes = bd.buffer.asUint8List();

      print("🧠 Creating TFLite interpreter");
      _interpreter = Interpreter.fromBuffer(bytes);

      final outShape = _interpreter!.getOutputTensor(0).shape;
      _embeddingSize = outShape.last;

      print("✅ FaceNet loaded. embeddingSize=$_embeddingSize");
    } catch (e) {
      print("❌ Failed to load FaceNet: $e");
      _interpreter = null;
      rethrow;
    }
  }

  /* ===================== FIRESTORE ===================== */

  Future<void> _loadEnrolledFaces() async {
    try {
      print("📥 Loading Firestore collection: $collectionName");

      final snap = await _db.collection(collectionName).get();
      print("✅ Firestore docs found: ${snap.docs.length}");

      _people.clear();

      for (final doc in snap.docs) {
        final data = doc.data();
        final name = (data["name"] ?? "") as String;

        try {
          final embeddings = _parseEmbeddings(data);

          if (embeddings.isEmpty) {
            print("⚠️ ${doc.id} skipped. No embeddings");
            continue;
          }

          final len = embeddings.first.length;
          if (len != _embeddingSize) {
            print(
              "⚠️ ${doc.id} skipped. Embedding size mismatch $len != $_embeddingSize",
            );
            continue;
          }

          _people.add(Person(id: doc.id, name: name, embeddings: embeddings));

          print("👤 Loaded ${name} embeddings=${embeddings.length}");
        } catch (e) {
          print("❌ Failed parsing ${doc.id}: $e");
          print("🧾 Keys: ${data.keys.toList()}");
        }
      }

      if (_people.isEmpty) {
        print("⚠️ No valid enrolled faces loaded");
      } else {
        print("✅ Total enrolled faces loaded: ${_people.length}");
      }
    } catch (e) {
      print("❌ Firestore load failed: $e");
      rethrow;
    }
  }

  List<List<double>> _parseEmbeddings(Map<String, dynamic> data) {
    if (data.containsKey("embeddings") && data["embeddings"] != null) {
      final raw = data["embeddings"] as List<dynamic>;
      return raw
          .map(
            (e) =>
                (e as List<dynamic>).map((v) => (v as num).toDouble()).toList(),
          )
          .toList();
    }

    if (data.containsKey("embedding") && data["embedding"] != null) {
      final raw = data["embedding"] as List<dynamic>;
      return [raw.map((v) => (v as num).toDouble()).toList()];
    }

    return [];
  }

  /* ===================== MATH ===================== */

  double _cosineSimilarity(List<double> a, List<double> b) {
    double dot = 0;
    double na = 0;
    double nb = 0;

    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }

    final denom = sqrt(na) * sqrt(nb);
    if (denom == 0) return -1;
    return dot / denom;
  }

  /* ===================== CLEANUP ===================== */

  void dispose() {
    try {
      _interpreter?.close();
      _interpreter = null;
      print("🧹 FaceVerification disposed");
    } catch (_) {}
  }
}
