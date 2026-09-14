/// Medora - Family Local Datasource (SQLite)
library;

import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:sqflite/sqflite.dart';

class FamilyLocalDatasource {
  FamilyLocalDatasource();

  Future<Database> get _db => AppDatabase.instance.database;

  // ── Families ───────────────────────────────────────────────

  /// Inserts or updates a family **without** `INSERT OR REPLACE`.
  ///
  /// `family_members.family_id` is `REFERENCES families(id) ON DELETE CASCADE`
  /// and the database runs with `PRAGMA foreign_keys = ON`, so an
  /// `INSERT OR REPLACE` here would delete the existing families row — taking
  /// every one of its member rows with it — before inserting the new one.
  /// Every pull would then silently destroy local membership state, including
  /// rows still waiting to be pushed. Update-then-insert keeps the row
  /// identity, so nothing cascades.
  Future<void> upsertFamily(FamilyModel family,
      {required String syncStatus}) async {
    final db = await _db;
    final values = {
      'id': family.id,
      'name': family.name,
      'invite_code': family.inviteCode,
      'owner_id': family.ownerId,
      'created_at':
          family.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      'sync_status': syncStatus,
    };
    final updated = await db.update('families', values,
        where: 'id = ?', whereArgs: [family.id]);
    if (updated == 0) {
      await db.insert('families', values,
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<FamilyModel?> getFamilyById(String id) async {
    final db = await _db;
    final rows = await db.query('families', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _familyFromRow(rows.first);
  }

  Future<FamilyModel?> getFirstFamily() async {
    final db = await _db;
    final rows = await db.query('families',
        where: 'sync_status != ?',
        whereArgs: [SyncStatus.pendingDelete],
        limit: 1);
    if (rows.isEmpty) return null;
    return _familyFromRow(rows.first);
  }

  Future<void> deleteFamily(String id) async {
    final db = await _db;
    await db.delete('families', where: 'id = ?', whereArgs: [id]);
    await db.delete('family_members', where: 'family_id = ?', whereArgs: [id]);
  }

  // ── Family Members ─────────────────────────────────────────

  Future<void> upsertMember(FamilyMemberModel member,
      {required String syncStatus}) async {
    final db = await _db;
    await db.insert(
      'family_members',
      {
        'id': member.id,
        'family_id': member.familyId,
        'user_id': member.userId,
        'display_name': member.displayName,
        'role': member.role,
        'joined_at':
            member.joinedAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
        'sync_status': syncStatus,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<FamilyMemberModel>> getMembers(String familyId) async {
    final db = await _db;
    final rows = await db.query('family_members',
        where: 'family_id = ? AND sync_status != ?',
        whereArgs: [familyId, SyncStatus.pendingDelete],
        orderBy: 'joined_at ASC');
    return rows.map(_memberFromRow).toList();
  }

  Future<FamilyMemberModel?> getCurrentMembership() async {
    final db = await _db;
    final rows = await db.query('family_members',
        where: 'sync_status != ?',
        whereArgs: [SyncStatus.pendingDelete],
        limit: 1);
    if (rows.isEmpty) return null;
    return _memberFromRow(rows.first);
  }

  Future<void> removeMember(String memberId) async {
    final db = await _db;
    await db.delete('family_members', where: 'id = ?', whereArgs: [memberId]);
  }

  /// Marks the member row as a pending deletion; the next push removes it
  /// remotely and then hard-deletes it locally.
  Future<void> markMemberDeleted(String memberId) async {
    final db = await _db;
    await db.update('family_members', {'sync_status': SyncStatus.pendingDelete},
        where: 'id = ?', whereArgs: [memberId]);
  }

  Future<void> hardDeleteMember(String memberId) async {
    final db = await _db;
    await db.delete('family_members', where: 'id = ?', whereArgs: [memberId]);
  }

  Future<void> markFamilyDeleted(String familyId) async {
    final db = await _db;
    await db.update('families', {'sync_status': SyncStatus.pendingDelete},
        where: 'id = ?', whereArgs: [familyId]);
  }

  /// Removes synced members of [familyId] whose ids are not in [keepIds]
  /// (pending rows are left for the push phase).
  Future<void> deleteMembersNotIn(String familyId, Set<String> keepIds) async {
    final db = await _db;
    final rows = await db.query('family_members',
        columns: ['id'],
        where: 'family_id = ? AND sync_status = ?',
        whereArgs: [familyId, SyncStatus.synced]);
    for (final row in rows) {
      final id = row['id'] as String;
      if (!keepIds.contains(id)) {
        await db.delete('family_members', where: 'id = ?', whereArgs: [id]);
      }
    }
  }

  // ── Row mappers ────────────────────────────────────────────

  FamilyModel _familyFromRow(Map<String, dynamic> row) {
    return FamilyModel(
      id: row['id'] as String,
      name: row['name'] as String,
      inviteCode: row['invite_code'] as String?,
      ownerId: row['owner_id'] as String?,
      createdAt: row['created_at'] != null
          ? DateTime.tryParse(row['created_at'] as String)
          : null,
    );
  }

  FamilyMemberModel _memberFromRow(Map<String, dynamic> row) {
    return FamilyMemberModel(
      id: row['id'] as String,
      familyId: row['family_id'] as String,
      userId: row['user_id'] as String?,
      displayName: row['display_name'] as String?,
      role: row['role'] as String? ?? 'member',
      joinedAt: row['joined_at'] != null
          ? DateTime.tryParse(row['joined_at'] as String)
          : null,
    );
  }
}

