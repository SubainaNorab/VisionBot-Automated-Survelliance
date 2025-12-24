class Person {
  final String id;
  final String name;

  // multiple embeddings per person
  final List<List<double>> embeddings;

  Person({
    required this.id,
    required this.name,
    required this.embeddings,
  });

  Map<String, dynamic> toMap() {
    return {
      "name": name,
      "embeddings": embeddings,
    };
  }

  factory Person.fromMap(String id, Map<String, dynamic> map) {
    final raw = (map["embeddings"] ?? []) as List<dynamic>;

    final parsed = raw
        .map((e) =>
            (e as List<dynamic>).map((v) => (v as num).toDouble()).toList())
        .toList();

    return Person(
      id: id,
      name: (map["name"] ?? "") as String,
      embeddings: parsed,
    );
  }
}
