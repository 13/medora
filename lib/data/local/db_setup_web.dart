import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

void setupDatabaseFactory() {
  debugPrint('DEBUG: Initializing sqflite for web...');
  databaseFactory = databaseFactoryFfiWeb;
}
