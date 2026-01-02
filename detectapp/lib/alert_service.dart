import 'package:cloud_firestore/cloud_firestore.dart';

class AlertService {
  static const String _collection = 'alerts';

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DateTime? _lastAlertAt;
  int _cooldownMs = 2500;

  Future<void> createUnknownAlert({
    required double threshold,
    required String lens,
    String note = '',
  }) async {
    final now = DateTime.now();

    if (_lastAlertAt != null) {
      final diff = now.difference(_lastAlertAt!).inMilliseconds;
      if (diff < _cooldownMs) {
        return;
      }
    }

    _lastAlertAt = now;

    await _db.collection(_collection).add({
      'type': 'unknown_face',
      'created_at': FieldValue.serverTimestamp(),
      'created_at_local': now.toIso8601String(),
      'threshold': threshold,
      'lens': lens,
      'note': note,
    });
  }
}
