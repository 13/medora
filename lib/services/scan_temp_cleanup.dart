/// Medora - sweeping the scanner's leftover crop folders
///
/// The scanner writes each second-pass crop into a fresh directory under the
/// app's temporary directory and deletes it in a `finally`. A crash (or the
/// system killing the app mid-scan) leaves one behind. This sweeps them at
/// startup — only direct children of the app's own temporary directory whose
/// name starts with one of [scanTempPrefixes], never a file, never anything
/// else in there (the image picker keeps its copies alongside).
///
/// Never the folder of a scan that is still running: the startup tasks run
/// again on every foreground resume, so returning from the gallery picker
/// resumes the app just as `_recognize` starts writing its crops. Anything
/// touched within [scanTempMinAge] is therefore left alone — an orphan is
/// still swept on the next launch, but a live scan is never cut off.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const List<String> scanTempPrefixes = [
  'scan_region_',
  'scan_stripe_',
  'scan_area_',
];

/// How recently a crop folder must have been touched to count as a live
/// scan's and be spared. Comfortably longer than any single scan pass.
const Duration scanTempMinAge = Duration(minutes: 10);

/// Deletes leftover scanner crop directories in [tempDir] that have not been
/// touched for [minAge]; returns how many were removed. A missing directory,
/// or one that cannot be read or deleted, is logged and counted as nothing.
/// [now] is the clock, injected by the tests.
Future<int> cleanScanTempDirs(
  Directory tempDir, {
  Duration minAge = scanTempMinAge,
  DateTime Function()? now,
}) async {
  final clock = now ?? DateTime.now;
  var removed = 0;
  try {
    if (!await tempDir.exists()) return 0;
    await for (final entry in tempDir.list(followLinks: false)) {
      if (entry is! Directory) continue;
      if (!scanTempPrefixes.any(p.basename(entry.path).startsWith)) continue;
      try {
        // A scan writing into this folder right now owns it - see the
        // library comment above.
        if (clock().difference((await entry.stat()).modified) < minAge) {
          continue;
        }
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
