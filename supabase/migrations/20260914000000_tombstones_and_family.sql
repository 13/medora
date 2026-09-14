-- ============================================================
-- Medora - Tombstones for sync + family RLS fixes (Phase 3)
-- Apply after 20260901000000_initial_schema.sql.
-- ============================================================

-- 1. Tombstone columns. Deletes from the app set deleted_at instead of
--    removing the row, so other devices can pull the deletion. Hard purge of
--    old tombstones is a server-side job (not part of this migration).
ALTER TABLE medications   ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE treatments    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE dose_logs     ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- 2. Delta pull indexes (pull asks for updated_at > cursor).
CREATE INDEX IF NOT EXISTS idx_med_updated   ON medications(user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_treat_updated ON treatments(user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_presc_updated ON prescriptions(updated_at);
CREATE INDEX IF NOT EXISTS idx_dose_updated  ON dose_logs(updated_at);

-- 3. Tombstone cascade: deleting a parent tombstones its children so every
--    device sees the whole subtree disappear (local FK cascade would handle
--    the first device, but other devices pull children independently).
CREATE OR REPLACE FUNCTION cascade_tombstone_treatment()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    UPDATE prescriptions SET deleted_at = NEW.deleted_at
      WHERE treatment_id = NEW.id AND deleted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION cascade_tombstone_medication()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    UPDATE prescriptions SET deleted_at = NEW.deleted_at
      WHERE medication_id = NEW.id AND deleted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION cascade_tombstone_prescription()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    UPDATE dose_logs SET deleted_at = NEW.deleted_at
      WHERE prescription_id = NEW.id AND deleted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS treatments_tombstone_cascade ON treatments;
CREATE TRIGGER treatments_tombstone_cascade
  AFTER UPDATE OF deleted_at ON treatments
  FOR EACH ROW EXECUTE FUNCTION cascade_tombstone_treatment();

DROP TRIGGER IF EXISTS medications_tombstone_cascade ON medications;
CREATE TRIGGER medications_tombstone_cascade
  AFTER UPDATE OF deleted_at ON medications
  FOR EACH ROW EXECUTE FUNCTION cascade_tombstone_medication();

DROP TRIGGER IF EXISTS prescriptions_tombstone_cascade ON prescriptions;
CREATE TRIGGER prescriptions_tombstone_cascade
  AFTER UPDATE OF deleted_at ON prescriptions
  FOR EACH ROW EXECUTE FUNCTION cascade_tombstone_prescription();

-- 4. Family RLS: members (not only owners) can read their family and update
--    their own membership row; a user may insert their own membership.
--
--    `families_select` needs to look at `family_members` and the
--    `family_members` policies need to look at `families`. Expressed as plain
--    subqueries those two policies reference each other and Postgres aborts
--    any SELECT on either table with 42P17 (infinite recursion in policy).
--    The two SECURITY DEFINER helpers below run with the definer's rights, so
--    their internal reads bypass RLS and the cycle is broken. They are STABLE
--    (one evaluation per query, not per row) and pin `search_path` so a
--    caller-controlled schema cannot shadow the tables they read.

CREATE OR REPLACE FUNCTION is_family_member(p_family_id TEXT)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM family_members m
    WHERE m.family_id = p_family_id AND m.user_id = auth.uid()
  )
$$;

CREATE OR REPLACE FUNCTION is_family_owner(p_family_id TEXT)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM families f
    WHERE f.id = p_family_id AND f.owner_id = auth.uid()
  )
$$;

REVOKE ALL ON FUNCTION is_family_member(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION is_family_member(TEXT) TO authenticated;
REVOKE ALL ON FUNCTION is_family_owner(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION is_family_owner(TEXT) TO authenticated;

-- Both tables' policies are rewritten here (including the ones created by
-- 20260901000000) so that no policy body reads the other table directly.

DROP POLICY IF EXISTS "families_select" ON families;
CREATE POLICY "families_select" ON families
  FOR SELECT USING (owner_id = auth.uid() OR is_family_member(id));

DROP POLICY IF EXISTS "family_members_select" ON family_members;
CREATE POLICY "family_members_select" ON family_members
  FOR SELECT USING (user_id = auth.uid() OR is_family_member(family_id) OR is_family_owner(family_id));

DROP POLICY IF EXISTS "family_members_insert" ON family_members;
CREATE POLICY "family_members_insert" ON family_members
  FOR INSERT WITH CHECK (user_id = auth.uid() OR is_family_owner(family_id));

DROP POLICY IF EXISTS "family_members_update" ON family_members;
CREATE POLICY "family_members_update" ON family_members
  FOR UPDATE USING (user_id = auth.uid() OR is_family_owner(family_id));

DROP POLICY IF EXISTS "family_members_delete" ON family_members;
CREATE POLICY "family_members_delete" ON family_members
  FOR DELETE USING (user_id = auth.uid() OR is_family_owner(family_id));

-- 5. Join by invite code without exposing the families table to strangers.
CREATE OR REPLACE FUNCTION join_family(p_invite_code TEXT, p_display_name TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_family families%ROWTYPE;
  v_member family_members%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  SELECT * INTO v_family FROM families WHERE invite_code = p_invite_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid invite code';
  END IF;
  SELECT * INTO v_member FROM family_members
    WHERE family_id = v_family.id AND user_id = auth.uid();
  IF NOT FOUND THEN
    INSERT INTO family_members (family_id, user_id, display_name, role)
      VALUES (v_family.id, auth.uid(), p_display_name, 'member')
      RETURNING * INTO v_member;
  END IF;
  RETURN json_build_object('family', row_to_json(v_family), 'member', row_to_json(v_member));
END;
$$;

REVOKE ALL ON FUNCTION join_family(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION join_family(TEXT, TEXT) TO authenticated;
