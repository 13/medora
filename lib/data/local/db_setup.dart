import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Initializes the database factory for desktop platforms.
void setupDatabaseFactory() {
  if (Platform.isLinux || Platform.isWindows) {
    // Initialize FFI
    sqfliteFfiInit();
    // Set the databaseFactory to the FFI version
    databaseFactory = databaseFactoryFfi;
  }
}
