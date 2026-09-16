import 'package:medora/services/supplement_registry_service.dart';

/// In-memory [SupplementRegistryService] for widget tests.
class FakeSupplementRegistry implements SupplementRegistryService {
  FakeSupplementRegistry({
    this.entries = const [],
    this.lastSyncAt,
    this.sourceUpdatedAt,
    this.failSync = false,
    this.syncedEntries = const [],
  });

  List<SupplementEntry> entries;
  DateTime? lastSyncAt;
  DateTime? sourceUpdatedAt;
  bool failSync;

  /// What [sync] stores.
  List<SupplementEntry> syncedEntries;
  int syncCalls = 0;

  /// Every query [searchByName] was called with.
  final searches = <String>[];

  @override
  Future<int> sync({void Function(double progress)? onProgress}) async {
    syncCalls++;
    onProgress?.call(0.5);
    if (failSync) throw Exception('offline');
    entries = syncedEntries;
    lastSyncAt = DateTime(2026, 9, 15);
    sourceUpdatedAt = DateTime.parse('2026-09-01');
    onProgress?.call(1);
    return entries.length;
  }

  @override
  Future<int> count() async => entries.length;

  @override
  Future<bool> hasData() async => entries.isNotEmpty;

  @override
  Future<DateTime?> lastSync() async => lastSyncAt;

  @override
  Future<DateTime?> sourceUpdated() async => sourceUpdatedAt;

  @override
  Future<List<SupplementEntry>> findByCode(String code) async {
    final key = SupplementRegistryService.codeKey(code);
    return [
      for (final e in entries)
        if (SupplementRegistryService.codeKey(e.code) == key) e,
    ];
  }

  @override
  Future<List<SupplementEntry>> searchByName(
    String query, {
    int limit = 50,
  }) async {
    searches.add(query);
    return [
      for (final e in entries)
        if (e.product.toLowerCase().contains(query.toLowerCase())) e,
    ].take(limit).toList();
  }

  @override
  Future<void> close() async {}
}
