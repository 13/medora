/// Medora - sweeping the scanner's leftover crop folders
///
/// The scanner writes each second-pass crop into a fresh directory under the
/// app's temporary directory and deletes it in a `finally`. A crash (or the
/// system killing the app mid-scan) leaves one behind. This sweeps them at
/// startup — only direct children of the app's own temporary directory whose
/// name starts with one of [scanTempPrefixes], never a file, never anything
/// else in there (the image picker keeps its copies alongside).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

const List<String> scanTempPrefixes = [
  'scan_region_',
  'scan_stripe_',
  'scan_area_',
];

/// Deletes leftover scanner crop directories in [tempDir]; returns how many
/// were removed. A missing directory, or one that cannot be read or deleted,
/// is logged and counted as nothing.
Future<int> cleanScanTempDirs(Directory tempDir) async {
  var removed = 0;
  try {
    if (!await tempDir.exists()) return 0;
    await for (final entry in tempDir.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!scanTempPrefixes.any(name.startsWith)) continue;
      try {
        await entry.delete(recursive: true);
        removed++;
      } on FileSystemException catch (e) {
        debugPrint('[scan] leftover crop folder not deleted: $e');
      }
    }
  } on FileSystemException catch (e) {
    debugPrint('[scan] temporary directory not swept: $e');
  }
  return removed;
}
