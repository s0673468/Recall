-- Safe rollback for migrations/006_apply_review_rpc.sql.
-- The function contains no state. Current clients recognize its absence and use
-- the weaker client-side replay path. Run this before rolling back migration 005.

begin;

drop function if exists public.apply_review(
  bigint, text, smallint, timestamptz, real, real, timestamptz, smallint,
  boolean, integer, text, text
);

commit;
