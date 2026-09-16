-- Medora: the EAN barcode of the pack, alongside the label code in `barcode`.
-- The medication remote datasource uploads `MedicationModel.toJson()` as a
-- whole, so this column must exist before a client on schema v14 syncs.
alter table if exists public.medications
  add column if not exists ean text;

create index if not exists idx_med_ean on public.medications (ean);
