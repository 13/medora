-- Medora: sick leave (Krankenstand) on a treatment. The treatment remote
-- datasource uploads `TreatmentModel.toJson()` as a whole row, so these
-- columns must exist before a client on schema v15 syncs.
--
-- No RLS change: the treatments_* policies are already `user_id = auth.uid()`
-- and a column is not a row. No trigger change: the tombstone cascade fires
-- per row, not per column.
alter table if exists public.treatments
  add column if not exists sick_leave_from date,
  add column if not exists sick_leave_to   date,
  add column if not exists sick_leave_ref  text,
  add column if not exists doctor          text;
