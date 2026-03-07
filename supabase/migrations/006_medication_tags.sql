-- ============================================================
-- Medora: Medication tag fields (active_ingredients, symptoms, patient_tags)
-- ============================================================

-- Rename active_ingredient to active_ingredients (stores JSON array)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'active_ingredients'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN active_ingredients JSONB DEFAULT '[]';
    END IF;
END $$;

-- Migrate old active_ingredient data into new column
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'active_ingredient'
    ) THEN
        UPDATE public.medications
        SET active_ingredients = jsonb_build_array(active_ingredient)
        WHERE active_ingredient IS NOT NULL
          AND active_ingredient != ''
          AND (active_ingredients IS NULL OR active_ingredients = '[]');
    END IF;
END $$;

-- Add symptoms tags column (stores JSON array, e.g. ["cough", "headache"])
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'symptoms'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN symptoms JSONB DEFAULT '[]';
    END IF;
END $$;

-- Add patient_tags column (stores JSON array, e.g. ["Baby", "Mom"])
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'patient_tags'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN patient_tags JSONB DEFAULT '[]';
    END IF;
END $$;

-- Create GIN indexes for tag-based queries
CREATE INDEX IF NOT EXISTS idx_med_symptoms
    ON public.medications USING GIN (symptoms);
CREATE INDEX IF NOT EXISTS idx_med_patient_tags
    ON public.medications USING GIN (patient_tags);
CREATE INDEX IF NOT EXISTS idx_med_active_ingredients
    ON public.medications USING GIN (active_ingredients);

COMMENT ON COLUMN public.medications.active_ingredients IS 'JSON array of active ingredient names';
COMMENT ON COLUMN public.medications.symptoms IS 'JSON array of symptom/condition tags this medication treats';
COMMENT ON COLUMN public.medications.patient_tags IS 'JSON array of patient names this medication is for';

