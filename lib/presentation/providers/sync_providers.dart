/// Medora - Sync-related providers that must not depend on providers.dart
/// (app_mode_provider.dart imports this file).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';

final syncCursorStoreProvider = Provider<SyncCursorStore>(
  (ref) => SyncCursorStore(ref.watch(sharedPreferencesProvider)),
);

final syncFailureStoreProvider = Provider<SyncFailureStore>(
  (ref) => SyncFailureStore(ref.watch(sharedPreferencesProvider)),
);

final localUploadMarkerProvider = Provider<LocalUploadMarker>(
  (ref) => LocalUploadMarker(
    database: AppDatabase.instance,
    cursors: ref.watch(syncCursorStoreProvider),
    prefs: ref.watch(sharedPreferencesProvider),
  ),
);
