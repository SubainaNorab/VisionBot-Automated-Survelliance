import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseManager {
  static final SupabaseManager _instance = SupabaseManager._internal();
  factory SupabaseManager() => _instance;

  late final SupabaseClient client;

  SupabaseManager._internal() {
    client = SupabaseClient(
      'https://iypgzkflvwqzpqmjmbpd.supabase.co',
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Iml5cGd6a2ZsdndxenBxbWptYnBkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQ5MzQ3OTcsImV4cCI6MjA4MDUxMDc5N30.iOdEdeYWh5tGsdRnjzIizNVSMAbH8RPRsCyYxCsSBb0',
    );
  }
}
