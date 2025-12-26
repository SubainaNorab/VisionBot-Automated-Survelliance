class Person {
  final String id;
  final String name;

  // Multiple embeddings per person
  final List<List<double>> embeddings;

  Person({required this.id, required this.name, required this.embeddings});

  Map<String, dynamic> toMap() {
    return {"name": name, "embeddings": embeddings};
  }

  factory Person.fromMap(String id, Map<String, dynamic> map) {
    final name = (map["name"] ?? "") as String;

    // Support BOTH formats from Firestore:
    // 1) "embedding": [128 floats]  (your Python script)
    // 2) "embeddings": [[128 floats], [128 floats], ...]
    final dynamic rawEmbeddings = map["embeddings"];
    final dynamic rawEmbedding = map["embedding"];

    List<List<double>> parsed = [];

    if (rawEmbeddings is List) {
      // expected: List<List<num>>
      parsed =
          rawEmbeddings
              .map(
                (e) => (e as List).map((v) => (v as num).toDouble()).toList(),
              )
              .toList();
    } else if (rawEmbedding is List) {
      // expected: List<num>
      final one = rawEmbedding.map((v) => (v as num).toDouble()).toList();
      parsed = [one];
    } else {
      parsed = [];
    }

    return Person(id: id, name: name, embeddings: parsed);
  }
}
