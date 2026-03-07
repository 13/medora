-- ============================================================
-- Medora: Add description, manufacturer, form, atc_code to medications
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'description'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN description TEXT;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'manufacturer'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN manufacturer TEXT;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'form'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN form TEXT;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'atc_code'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN atc_code TEXT;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_medications_atc_code ON public.medications(atc_code);
CREATE INDEX IF NOT EXISTS idx_medications_manufacturer ON public.medications(manufacturer);

COMMENT ON COLUMN public.medications.description IS 'e.g. 400 MG COMPRESSE RIVESTITE- 30 COMPRESSE IN BLISTER';
COMMENT ON COLUMN public.medications.manufacturer IS 'Drug manufacturer name';
COMMENT ON COLUMN public.medications.form IS 'Pharmaceutical form, e.g. Compressa rivestita';
COMMENT ON COLUMN public.medications.atc_code IS 'ATC classification code, e.g. M01AE01';

