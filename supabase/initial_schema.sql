-- ============================================================
-- Medora - Complete Supabase Schema
-- Run this once to set up a fresh Supabase project.
-- ============================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS medications (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  family_id TEXT,
  name TEXT NOT NULL,
  description TEXT,
  active_ingredients TEXT,   -- JSON array: ["ibuprofen","paracetamol"]
  category TEXT,
  manufacturer TEXT,
  form TEXT,
  atc_code TEXT,
  symptoms TEXT,             -- JSON array: ["cough","fever"]
  patient_tags TEXT,         -- JSON array: ["baby","mom"]
  purchase_date DATE,
  expiry_date DATE,
  quantity INTEGER NOT NULL DEFAULT 0,
  quantity_unit TEXT,
  minimum_stock_level INTEGER NOT NULL DEFAULT 0,
  storage_location TEXT,
  barcode TEXT,
  image_path TEXT,
  notes TEXT,
  is_archived BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS treatments (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  family_id TEXT,
  name TEXT NOT NULL,
  patient_tags TEXT,         -- JSON array
  symptom_tags TEXT,         -- JSON array
  start_date DATE NOT NULL,
  end_date DATE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS prescriptions (
  id TEXT PRIMARY KEY,
  treatment_id TEXT NOT NULL REFERENCES treatments(id) ON DELETE CASCADE,
  medication_id TEXT NOT NULL REFERENCES medications(id) ON DELETE CASCADE,
  dosage TEXT NOT NULL,
  dosage_amount DOUBLE PRECISION,
  dosage_unit TEXT,
  interval_hours INTEGER NOT NULL DEFAULT 8,
  duration_days INTEGER NOT NULL DEFAULT 7,
  start_time TIMESTAMPTZ NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  auto_diminish BOOLEAN NOT NULL DEFAULT FALSE,
  notes TEXT,
  schedule_type TEXT NOT NULL DEFAULT 'fixed_interval',
  schedule_times TEXT,       -- JSON array: ["08:00","12:00","18:00"]
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS dose_logs (
  id TEXT PRIMARY KEY,
  prescription_id TEXT NOT NULL REFERENCES prescriptions(id) ON DELETE CASCADE,
  scheduled_time TIMESTAMPTZ NOT NULL,
  taken_time TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'pending',  -- pending, taken, skipped, missed
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS families (
  id TEXT PRIMARY KEY DEFAULT uuid_generate_v4()::text,
  name TEXT NOT NULL,
  invite_code TEXT UNIQUE,
  owner_id UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS family_members (
  id TEXT PRIMARY KEY DEFAULT uuid_generate_v4()::text,
  family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id),
  display_name TEXT,
  role TEXT NOT NULL DEFAULT 'member',
  joined_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_med_user      ON medications(user_id);
CREATE INDEX IF NOT EXISTS idx_med_barcode   ON medications(barcode);
CREATE INDEX IF NOT EXISTS idx_med_expiry    ON medications(expiry_date);

CREATE INDEX IF NOT EXISTS idx_treat_user    ON treatments(user_id);
CREATE INDEX IF NOT EXISTS idx_treat_active  ON treatments(is_active);

CREATE INDEX IF NOT EXISTS idx_presc_treat   ON prescriptions(treatment_id);
CREATE INDEX IF NOT EXISTS idx_presc_med     ON prescriptions(medication_id);

CREATE INDEX IF NOT EXISTS idx_dose_presc    ON dose_logs(prescription_id);
CREATE INDEX IF NOT EXISTS idx_dose_sched    ON dose_logs(scheduled_time);
CREATE INDEX IF NOT EXISTS idx_dose_status   ON dose_logs(status);

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================

ALTER TABLE medications     ENABLE ROW LEVEL SECURITY;
ALTER TABLE treatments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE prescriptions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE dose_logs       ENABLE ROW LEVEL SECURITY;
ALTER TABLE families        ENABLE ROW LEVEL SECURITY;
ALTER TABLE family_members  ENABLE ROW LEVEL SECURITY;

-- Medications: users can only see/modify their own
CREATE POLICY "medications_select" ON medications
  FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "medications_insert" ON medications
  FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "medications_update" ON medications
  FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "medications_delete" ON medications
  FOR DELETE USING (user_id = auth.uid());

-- Treatments: users can only see/modify their own
CREATE POLICY "treatments_select" ON treatments
  FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "treatments_insert" ON treatments
  FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "treatments_update" ON treatments
  FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "treatments_delete" ON treatments
  FOR DELETE USING (user_id = auth.uid());

-- Prescriptions: access via treatment ownership
CREATE POLICY "prescriptions_select" ON prescriptions
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM treatments t WHERE t.id = treatment_id AND t.user_id = auth.uid())
  );
CREATE POLICY "prescriptions_insert" ON prescriptions
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM treatments t WHERE t.id = treatment_id AND t.user_id = auth.uid())
  );
CREATE POLICY "prescriptions_update" ON prescriptions
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM treatments t WHERE t.id = treatment_id AND t.user_id = auth.uid())
  );
CREATE POLICY "prescriptions_delete" ON prescriptions
  FOR DELETE USING (
    EXISTS (SELECT 1 FROM treatments t WHERE t.id = treatment_id AND t.user_id = auth.uid())
  );

-- Dose logs: access via prescription → treatment ownership
CREATE POLICY "dose_logs_select" ON dose_logs
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM prescriptions p
      JOIN treatments t ON t.id = p.treatment_id
      WHERE p.id = prescription_id AND t.user_id = auth.uid()
    )
  );
CREATE POLICY "dose_logs_insert" ON dose_logs
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM prescriptions p
      JOIN treatments t ON t.id = p.treatment_id
      WHERE p.id = prescription_id AND t.user_id = auth.uid()
    )
  );
CREATE POLICY "dose_logs_update" ON dose_logs
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM prescriptions p
      JOIN treatments t ON t.id = p.treatment_id
      WHERE p.id = prescription_id AND t.user_id = auth.uid()
    )
  );
CREATE POLICY "dose_logs_delete" ON dose_logs
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM prescriptions p
      JOIN treatments t ON t.id = p.treatment_id
      WHERE p.id = prescription_id AND t.user_id = auth.uid()
    )
  );

-- Families: owner can manage
CREATE POLICY "families_select" ON families
  FOR SELECT USING (owner_id = auth.uid());
CREATE POLICY "families_insert" ON families
  FOR INSERT WITH CHECK (owner_id = auth.uid());
CREATE POLICY "families_update" ON families
  FOR UPDATE USING (owner_id = auth.uid());
CREATE POLICY "families_delete" ON families
  FOR DELETE USING (owner_id = auth.uid());

-- Family members: visible to family members
CREATE POLICY "family_members_select" ON family_members
  FOR SELECT USING (
    user_id = auth.uid() OR
    EXISTS (SELECT 1 FROM families f WHERE f.id = family_id AND f.owner_id = auth.uid())
  );
CREATE POLICY "family_members_insert" ON family_members
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM families f WHERE f.id = family_id AND f.owner_id = auth.uid())
  );
CREATE POLICY "family_members_delete" ON family_members
  FOR DELETE USING (
    user_id = auth.uid() OR
    EXISTS (SELECT 1 FROM families f WHERE f.id = family_id AND f.owner_id = auth.uid())
  );

-- ============================================================
-- FUNCTIONS
-- ============================================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER medications_updated_at
  BEFORE UPDATE ON medications
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER treatments_updated_at
  BEFORE UPDATE ON treatments
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER prescriptions_updated_at
  BEFORE UPDATE ON prescriptions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

