-- ============================================================
-- Medora: Add dosage_amount and dosage_unit to prescriptions
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'prescriptions' AND column_name = 'dosage_amount'
    ) THEN
        ALTER TABLE public.prescriptions ADD COLUMN dosage_amount NUMERIC;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'prescriptions' AND column_name = 'dosage_unit'
    ) THEN
        ALTER TABLE public.prescriptions ADD COLUMN dosage_unit TEXT;
    END IF;
END $$;

COMMENT ON COLUMN public.prescriptions.dosage_amount IS 'Numeric dosage amount (e.g. 1.5, 0.5)';
COMMENT ON COLUMN public.prescriptions.dosage_unit IS 'Unit override for this prescription (e.g. pills, ml). Falls back to medication unit.';

