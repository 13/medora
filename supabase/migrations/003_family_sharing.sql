-- ============================================================
-- Medora: Family Sharing Migration
-- ============================================================

-- Families table
CREATE TABLE IF NOT EXISTS public.families (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    invite_code TEXT UNIQUE,
    owner_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_families_invite_code ON public.families(invite_code);

-- Family members table
CREATE TABLE IF NOT EXISTS public.family_members (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    family_id UUID NOT NULL REFERENCES public.families(id) ON DELETE CASCADE,
    user_id UUID,
    display_name TEXT,
    role TEXT NOT NULL DEFAULT 'member'
        CHECK (role IN ('owner', 'member')),
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_family_members_family ON public.family_members(family_id);
CREATE INDEX IF NOT EXISTS idx_family_members_user ON public.family_members(user_id);

-- Add family_id to existing tables (if not already present)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'medications' AND column_name = 'family_id'
    ) THEN
        ALTER TABLE public.medications ADD COLUMN family_id UUID;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'treatments' AND column_name = 'family_id'
    ) THEN
        ALTER TABLE public.treatments ADD COLUMN family_id UUID;
    END IF;
END $$;

-- RLS for families
ALTER TABLE public.families ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow all on families" ON public.families;
CREATE POLICY "Allow all on families"
    ON public.families FOR ALL
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS "Allow all on family_members" ON public.family_members;
CREATE POLICY "Allow all on family_members"
    ON public.family_members FOR ALL
    USING (true)
    WITH CHECK (true);

GRANT ALL ON public.families TO anon, authenticated;
GRANT ALL ON public.family_members TO anon, authenticated;

