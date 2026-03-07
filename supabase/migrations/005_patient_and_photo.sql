-- ============================================================
-- Medora: Patient name & medication photo fields
-- ============================================================

-- Add patient_name to treatments (for baby / family member treatments)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'treatments' AND column_name = 'patient_name'
    ) THEN
        ALTER TABLE public.treatments ADD COLUMN patient_name TEXT;
    END IF;
END $$;

-- Add image_path to medications (local photo path, not synced to Supabase)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'image_path'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN image_path TEXT;
    END IF;
END $$;

COMMENT ON COLUMN public.treatments.patient_name IS 'Name of the patient (e.g. baby, family member). NULL = self.';
COMMENT ON COLUMN public.medications.image_path IS 'Local path to medication photo. Not synced remotely.';

