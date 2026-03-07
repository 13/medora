-- ============================================================
-- Medora: Home Medicine Cabinet Manager
-- Initial Database Schema Migration (v2 - auth-optional MVP)
-- ============================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- MEDICATIONS TABLE
-- user_id is nullable for the MVP (single-device, no auth required)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.medications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID,               -- NULL = anonymous/single-user mode
    name TEXT NOT NULL,
    active_ingredient TEXT,
    category TEXT,
    purchase_date DATE,
    expiry_date DATE,
    quantity INTEGER NOT NULL DEFAULT 0,
    minimum_stock_level INTEGER NOT NULL DEFAULT 5,
    storage_location TEXT,
    barcode TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_medications_user_id    ON public.medications(user_id);
CREATE INDEX IF NOT EXISTS idx_medications_barcode    ON public.medications(barcode);
CREATE INDEX IF NOT EXISTS idx_medications_expiry_date ON public.medications(expiry_date);
CREATE INDEX IF NOT EXISTS idx_medications_category   ON public.medications(category);

-- ============================================================
-- TREATMENTS TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS public.treatments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID,
    name TEXT NOT NULL,
    symptoms TEXT,
    start_date DATE NOT NULL,
    end_date DATE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_treatments_user_id  ON public.treatments(user_id);
CREATE INDEX IF NOT EXISTS idx_treatments_is_active ON public.treatments(is_active);

-- ============================================================
-- PRESCRIPTIONS TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS public.prescriptions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    treatment_id UUID NOT NULL REFERENCES public.treatments(id) ON DELETE CASCADE,
    medication_id UUID NOT NULL REFERENCES public.medications(id) ON DELETE CASCADE,
    dosage TEXT NOT NULL,
    interval_hours INTEGER NOT NULL DEFAULT 8,
    duration_days INTEGER NOT NULL DEFAULT 7,
    start_time TIMESTAMPTZ NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_prescriptions_treatment_id  ON public.prescriptions(treatment_id);
CREATE INDEX IF NOT EXISTS idx_prescriptions_medication_id ON public.prescriptions(medication_id);
CREATE INDEX IF NOT EXISTS idx_prescriptions_is_active     ON public.prescriptions(is_active);

-- ============================================================
-- DOSE LOGS TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS public.dose_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    prescription_id UUID NOT NULL REFERENCES public.prescriptions(id) ON DELETE CASCADE,
    scheduled_time TIMESTAMPTZ NOT NULL,
    taken_time TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'taken', 'skipped', 'missed')),
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dose_logs_prescription_id ON public.dose_logs(prescription_id);
CREATE INDEX IF NOT EXISTS idx_dose_logs_scheduled_time  ON public.dose_logs(scheduled_time);
CREATE INDEX IF NOT EXISTS idx_dose_logs_status          ON public.dose_logs(status);

-- ============================================================
-- UPDATED_AT TRIGGER
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_medications_updated_at ON public.medications;
CREATE TRIGGER update_medications_updated_at
    BEFORE UPDATE ON public.medications
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_treatments_updated_at ON public.treatments;
CREATE TRIGGER update_treatments_updated_at
    BEFORE UPDATE ON public.treatments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_prescriptions_updated_at ON public.prescriptions;
CREATE TRIGGER update_prescriptions_updated_at
    BEFORE UPDATE ON public.prescriptions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
