-- ============================================================
-- Medora: Flexible Prescription Scheduling Migration
-- ============================================================

-- Add schedule_type and schedule_times columns to prescriptions
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'prescriptions' AND column_name = 'schedule_type'
    ) THEN
        ALTER TABLE public.prescriptions
            ADD COLUMN schedule_type TEXT NOT NULL DEFAULT 'fixed_interval';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'prescriptions' AND column_name = 'schedule_times'
    ) THEN
        ALTER TABLE public.prescriptions
            ADD COLUMN schedule_times TEXT;
    END IF;
END $$;

-- schedule_type: 'fixed_interval' (every X hours) or 'times_per_day' (specific times)
-- schedule_times: JSON array of time strings e.g. '["08:00","12:00","18:00"]'

COMMENT ON COLUMN public.prescriptions.schedule_type IS 'fixed_interval or times_per_day';
COMMENT ON COLUMN public.prescriptions.schedule_times IS 'JSON array of HH:MM time strings for times_per_day schedule type';

