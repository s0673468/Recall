-- Shared read-only concept labels used by Recall's retention and primer UI.
--
-- Provenance: copied from the deployed private runtime migration
-- recall-anki-sync/migrations/003_concept_nodes.sql. METIS and primer authoring
-- upsert with the service-role key; clients receive SELECT only.

begin;

create table if not exists public.concept_nodes (
  node_id text primary key,
  title text not null,
  module text not null,
  difficulty integer,
  updated_at timestamptz not null default now()
);

alter table public.concept_nodes enable row level security;

drop policy if exists read_all on public.concept_nodes;
create policy read_all on public.concept_nodes for select
  using (true);

grant select on table public.concept_nodes to anon, authenticated;

commit;
