-- ============================================================
-- Medora: Add quantity_unit, is_archived to medications;
--         auto_diminish to prescriptions
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'quantity_unit'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN quantity_unit TEXT;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'is_archived'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN is_archived BOOLEAN NOT NULL DEFAULT FALSE;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'prescriptions' AND column_name = 'auto_diminish'
    ) THEN
        ALTER TABLE public.prescriptions ADD COLUMN auto_diminish BOOLEAN NOT NULL DEFAULT FALSE;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_medications_is_archived ON public.medications(is_archived);

COMMENT ON COLUMN public.medications.quantity_unit IS 'Unit of quantity: pieces, pills, ml, bustine, ampoules, etc.';
COMMENT ON COLUMN public.medications.is_archived IS 'Whether the medication is archived (finished/hidden)';
COMMENT ON COLUMN public.prescriptions.auto_diminish IS 'Whether taking a dose auto-decreases medication stock';

