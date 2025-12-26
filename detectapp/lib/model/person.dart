class Person {
  final String id;
  final String name;
  final List<double> embedding;
  final String imageUrl;

  const Person({
    required this.id,
    required this.name,
    required this.embedding,
    required this.imageUrl,
  });

  factory Person.fromFirestore(String id, Map<String, dynamic> data) {
    final rawEmb = (data['embedding'] as List?) ?? const [];
    final emb = rawEmb.map((e) => (e as num).toDouble()).toList();

    return Person(
      id: id,
      name: (data['name'] as String?) ?? id,
      embedding: emb,
      imageUrl: (data['image_url'] as String?) ?? '',
    );
  }
}
