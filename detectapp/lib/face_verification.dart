import "dart:math";
import "dart:typed_data";
import "package:cloud_firestore/cloud_firestore.dart";
import "package:flutter/services.dart";
import "package:image/image.dart" as img;
import "package:tflite_flutter/tflite_flutter.dart";
import "model/person.dart";

class VerificationResult {
  final bool verified;
  final Person? person;
  final double confidence;
  final String message;
  final Person? nearestMatch;
  final double? nearestSimilarity;

  VerificationResult({
    required this.verified,
    required this.person,
    required this.confidence,
    required this.message,
    required this.nearestMatch,
    required this.nearestSimilarity,
  });
}

class FaceVerificationService {
  static const String facesCollection = "enrolled_faces";
  static const int inputSize = 160;

  double recognitionThreshold = 0.55;

  Interpreter? _interpreter;
  int _embeddingSize = 0;

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final List<Person> _people = [];

  String? _lastWinnerId;
  int _winnerStreak = 0;
  DateTime? _cooldownUntil;

  void _log(String msg) {
    print(msg);
  }

  Future<void> initialize() async {
    _log("🚀 FaceVerification.initialize started");

    try {
      _log("📦 Loading AssetManifest.json");
      final manifest = await rootBundle.loadString("AssetManifest.json");
      _log("✅ AssetManifest loaded. Length: ${manifest.length}");

      final hasKey = manifest.contains("\"assets/facenet.tflite\"");
      _log(hasKey
          ? "✅ Found key assets/facenet.tflite in AssetManifest"
          : "❌ AssetManifest missing key assets/facenet.tflite");

      if (!hasKey) {
        _log("🔎 Printing first 30 asset keys for debugging");
        final keys = _extractAssetKeys(manifest);
        final show = keys.take(30).toList();
        for (final k in show) {
          _log("🧾 asset: $k");
        }
        throw Exception("AssetManifest missing assets/facenet.tflite");
      }

      _log("🧪 Trying rootBundle.load(assets/facenet.tflite)");
      final bytes = await rootBundle.load("assets/facenet.tflite");
      _log("✅ rootBundle.load success. Bytes: ${bytes.lengthInBytes}");

      _log("🧠 Loading TFLite interpreter fromAsset(facenet.tflite)");
      _interpreter = await Interpreter.fromAsset("facenet.tflite");
      _log("✅ Interpreter loaded");

      final outTensor = _interpreter!.getOutputTensor(0);
      _embeddingSize = outTensor.shape.last;
      _log("✅ Model output shape: ${outTensor.shape}. embeddingSize=$_embeddingSize");

      _log("📥 Loading enrolled faces from Firestore: $facesCollection");
      await loadEnrolledPeople();
      _log("✅ initialize finished");
    } catch (e) {
      _log("🔥 initialize failed: $e");
      rethrow;
    }
  }

  List<String> _extractAssetKeys(String manifest) {
    final keys = <String>[];
    final regex = RegExp(r"\"([^\"]+)\":\s*\[");
    for (final m in regex.allMatches(manifest)) {
      final k = m.group(1);
      if (k != null) keys.add(k);
    }
    return keys;
  }

  Future<void> loadEnrolledPeople() async {
    _people.clear();
    try {
      final snap = await _db.collection(facesCollection).get();
      for (final doc in snap.docs) {
        final p = Person.fromMap(doc.id, doc.data());
        if (p.embeddings.isNotEmpty) _people.add(p);
      }
      _log("✅ Firestore loaded. People: ${_people.length}");
    } catch (e) {
      _log("⚠️ Firestore load failed: $e");
    }
  }

  Future<VerificationResult> verifyFace(img.Image faceImage) async {
    if (_cooldownUntil != null && DateTime.now().isBefore(_cooldownUntil!)) {
      return VerificationResult(
        verified: false,
        person: null,
        confidence: 0.0,
        message: "⏳ Cooldown",
        nearestMatch: null,
        nearestSimilarity: null,
      );
    }

    if (_people.isEmpty) {
      return VerificationResult(
        verified: false,
        person: null,
        confidence: 0.0,
        message: "⚠️ No enrolled faces",
        nearestMatch: null,
        nearestSimilarity: null,
      );
    }

    final probe = await extractEmbedding(faceImage);
    if (probe == null) {
      return VerificationResult(
        verified: false,
        person: null,
        confidence: 0.0,
        message: "❌ Embedding failed",
        nearestMatch: null,
        nearestSimilarity: null,
      );
    }

    Person? bestPerson;
    double bestSim = -1.0;

    for (final p in _people) {
      final s = _bestSimilarityForPerson(p, probe);
      if (s > bestSim) {
        bestSim = s;
        bestPerson = p;
      }
    }

    if (bestPerson == null) {
      return VerificationResult(
        verified: false,
        person: null,
        confidence: 0.0,
        message: "❌ No match",
        nearestMatch: null,
        nearestSimilarity: null,
      );
    }

    if (bestSim >= recognitionThreshold) {
      final stable = _stableWinner(bestPerson.id);

      if (!stable) {
        return VerificationResult(
          verified: false,
          person: null,
          confidence: bestSim,
          message: "🟡 Hold steady (${bestSim.toStringAsFixed(3)})",
          nearestMatch: bestPerson,
          nearestSimilarity: bestSim,
        );
      }

      _cooldownUntil = DateTime.now().add(const Duration(seconds: 4));

      return VerificationResult(
        verified: true,
        person: bestPerson,
        confidence: bestSim,
        message: "✅ Verified ${bestPerson.name} (${bestSim.toStringAsFixed(3)})",
        nearestMatch: bestPerson,
        nearestSimilarity: bestSim,
      );
    }

    _lastWinnerId = null;
    _winnerStreak = 0;

    return VerificationResult(
      verified: false,
      person: null,
      confidence: bestSim,
      message: "❌ Unknown (${bestSim.toStringAsFixed(3)})",
      nearestMatch: bestPerson,
      nearestSimilarity: bestSim,
    );
  }

  double _bestSimilarityForPerson(Person p, List<double> probe) {
    double best = -1.0;
    for (final emb in p.embeddings) {
      final s = cosineSimilarity(probe, emb);
      if (s > best) best = s;
    }
    return best;
  }

  bool _stableWinner(String personId) {
    if (_lastWinnerId == personId) {
      _winnerStreak += 1;
    } else {
      _lastWinnerId = personId;
      _winnerStreak = 1;
    }
    return _winnerStreak >= 3;
  }

  Future<List<double>?> extractEmbedding(img.Image faceImage) async {
    final i = _interpreter;
    if (i == null) {
      _log("❌ Interpreter is null");
      return null;
    }

    if (_embeddingSize == 0) {
      final outTensor = i.getOutputTensor(0);
      _embeddingSize = outTensor.shape.last;
      _log("ℹ️ embeddingSize detected late: $_embeddingSize");
    }

    final input =
        _imageToInputBuffer(faceImage).reshape([1, inputSize, inputSize, 3]);
    final output = List.filled(_embeddingSize, 0.0).reshape([1, _embeddingSize]);

    i.run(input, output);

    final raw = List<double>.from(output[0]);
    return l2Normalize(raw);
  }

  Float32List _imageToInputBuffer(img.Image image) {
    final resized = img.copyResize(image, width: inputSize, height: inputSize);

    final buffer = Float32List(1 * inputSize * inputSize * 3);
    int idx = 0;

    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final p = resized.getPixel(x, y);
        buffer[idx++] = p.r / 255.0;
        buffer[idx++] = p.g / 255.0;
        buffer[idx++] = p.b / 255.0;
      }
    }

    return buffer;
  }

  List<double> l2Normalize(List<double> v) {
    double sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = sqrt(sum);
    if (norm == 0.0) return v;
    return v.map((e) => e / norm).toList();
  }

  double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return -1.0;

    double dot = 0.0;
    double na = 0.0;
    double nb = 0.0;

    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }

    final denom = sqrt(na) * sqrt(nb);
    if (denom == 0.0) return -1.0;
    return dot / denom;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}
