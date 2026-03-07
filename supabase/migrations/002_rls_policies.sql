-- ============================================================
-- Medora: Row Level Security Policies
-- MVP mode: permissive (allow all) — no auth required.
-- When you add Supabase Auth, replace these with user-scoped policies.
-- ============================================================

-- Enable RLS (keeps the door closed by default)
ALTER TABLE public.medications  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.treatments   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prescriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dose_logs    ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- MEDICATIONS — allow all (anon + authenticated)
-- ============================================================
DROP POLICY IF EXISTS "Allow all on medications" ON public.medications;
CREATE POLICY "Allow all on medications"
    ON public.medications FOR ALL
    USING (true)
    WITH CHECK (true);

-- ============================================================
-- TREATMENTS — allow all
-- ============================================================
DROP POLICY IF EXISTS "Allow all on treatments" ON public.treatments;
CREATE POLICY "Allow all on treatments"
    ON public.treatments FOR ALL
    USING (true)
    WITH CHECK (true);

-- ============================================================
-- PRESCRIPTIONS — allow all
-- ============================================================
DROP POLICY IF EXISTS "Allow all on prescriptions" ON public.prescriptions;
CREATE POLICY "Allow all on prescriptions"
    ON public.prescriptions FOR ALL
    USING (true)
    WITH CHECK (true);

-- ============================================================
-- DOSE_LOGS — allow all
-- ============================================================
DROP POLICY IF EXISTS "Allow all on dose_logs" ON public.dose_logs;
CREATE POLICY "Allow all on dose_logs"
    ON public.dose_logs FOR ALL
    USING (true)
    WITH CHECK (true);

-- ============================================================
-- GRANT anon role access to all tables
-- (Required when using the anon key without authentication)
-- ============================================================
GRANT ALL ON public.medications   TO anon, authenticated;
GRANT ALL ON public.treatments    TO anon, authenticated;
GRANT ALL ON public.prescriptions TO anon, authenticated;
GRANT ALL ON public.dose_logs     TO anon, authenticated;
