class Person {
  final String id;
  final String name;
  final List<double> embedding;
  final String? imageUrl;
  final DateTime enrolledAt;

  Person({
    required this.id,
    required this.name,
    required this.embedding,
    this.imageUrl,
    required this.enrolledAt,
  });

  factory Person.fromFirestore(Map<String, dynamic> data, String docId) {
    // Convert embedding from Firestore (List<dynamic>) to List<double>
    final embeddingDynamic = data['embedding'] as List<dynamic>;
    final embedding =
        embeddingDynamic.map((e) => (e as num).toDouble()).toList();

    // Parse timestamp
    DateTime enrolledAt;
    try {
      if (data['enrolled_at'] != null) {
        enrolledAt = DateTime.parse(data['enrolled_at'] as String);
      } else if (data['timestamp'] != null) {
        enrolledAt = (data['timestamp'] as dynamic).toDate();
      } else {
        enrolledAt = DateTime.now();
      }
    } catch (e) {
      enrolledAt = DateTime.now();
    }

    return Person(
      id: docId,
      name: data['name'] as String,
      embedding: embedding,
      imageUrl: data['image_url'] as String?,
      enrolledAt: enrolledAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'embedding': embedding,
      'image_url': imageUrl,
      'enrolled_at': enrolledAt.toIso8601String(),
    };
  }

  @override
  String toString() {
    return 'Person(id:  $id, name: $name, embedding_size: ${embedding.length})';
  }

  // Check if embedding is valid
  bool isValidEmbedding() {
    if (embedding.isEmpty) return false;

    final nonZero = embedding.where((v) => v.abs() > 0.001).length;
    return nonZero > 10; // At least 10 non-zero values
  }
}
