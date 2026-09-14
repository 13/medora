import 'package:medora/data/local/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _ffiReady = false;

/// Point [AppDatabase] at a fresh in-memory SQLite database.
/// Call from `setUp`.
Future<void> setUpTestDatabase() async {
  if (!_ffiReady) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    _ffiReady = true;
  }
  await AppDatabase.instance.reset();
  AppDatabase.debugPathOverride = inMemoryDatabasePath;
}

/// Close the in-memory database. Call from `tearDown`.
Future<void> tearDownTestDatabase() async {
  await AppDatabase.instance.reset();
  AppDatabase.debugPathOverride = null;
}
