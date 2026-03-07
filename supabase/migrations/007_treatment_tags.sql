-- ============================================================
-- Medora: Treatment tag fields (patient_tags, symptom_tags)
-- ============================================================

-- Add patient_tags column (stores JSON array, e.g. ["Baby", "Mom"])
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'treatments' AND column_name = 'patient_tags'
    ) THEN
        ALTER TABLE public.treatments ADD COLUMN patient_tags JSONB DEFAULT '[]';
    END IF;
END $$;

-- Add symptom_tags column (stores JSON array, e.g. ["fever", "cough"])
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'treatments' AND column_name = 'symptom_tags'
    ) THEN
        ALTER TABLE public.treatments ADD COLUMN symptom_tags JSONB DEFAULT '[]';
    END IF;
END $$;

-- Migrate existing patient_name data to patient_tags
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'treatments' AND column_name = 'patient_name'
    ) THEN
        UPDATE public.treatments
        SET patient_tags = jsonb_build_array(patient_name)
        WHERE patient_name IS NOT NULL
          AND patient_name != ''
          AND (patient_tags IS NULL OR patient_tags = '[]');
    END IF;
END $$;

-- Migrate existing symptoms data to symptom_tags
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'treatments' AND column_name = 'symptoms'
    ) THEN
        UPDATE public.treatments
        SET symptom_tags = jsonb_build_array(symptoms)
        WHERE symptoms IS NOT NULL
          AND symptoms != ''
          AND (symptom_tags IS NULL OR symptom_tags = '[]');
    END IF;
END $$;

-- Create GIN indexes for tag-based queries
CREATE INDEX IF NOT EXISTS idx_treat_patient_tags
    ON public.treatments USING GIN (patient_tags);
CREATE INDEX IF NOT EXISTS idx_treat_symptom_tags
    ON public.treatments USING GIN (symptom_tags);

COMMENT ON COLUMN public.treatments.patient_tags IS 'JSON array of patient names for this treatment';
COMMENT ON COLUMN public.treatments.symptom_tags IS 'JSON array of symptom/condition tags';

