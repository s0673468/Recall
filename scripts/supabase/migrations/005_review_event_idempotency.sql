-- Server-enforced event identity for Recall's durable mobile outboxes.
--
-- Provenance: copied from Health's deployed
-- scripts/supabase_migrate_recall_idempotency.sql. Safe before an app release:
-- existing rows retain NULL event IDs while new clients upsert by
-- (card_id, client_event_id).

begin;

alter table public.review_log
  add column if not exists client_event_id text;

create unique index if not exists review_log_card_client_event_uidx
  on public.review_log (card_id, client_event_id);

alter table public.note_flags
  add column if not exists client_event_id text;

create unique index if not exists note_flags_card_client_event_uidx
  on public.note_flags (card_id, client_event_id);

commit;
