-- Read-only concept primers rendered by Recall.
--
-- Provenance: based on the migration staged in
-- _inbox/archive/recall-concept-primers/concept_pages_migration.sql and the
-- recorded production apply on 2026-07-29. The staged draft omitted figure_svg;
-- production, the METIS authoring contract, and Recall's client all include it.

begin;

create table if not exists public.concept_pages (
  node_id text primary key references public.concept_nodes(node_id),
  title text not null,
  body_html text not null,
  figure_svg text,
  updated_at timestamptz not null default now()
);

alter table public.concept_pages enable row level security;

drop policy if exists read_all on public.concept_pages;
create policy read_all on public.concept_pages for select
  using (true);

grant select on table public.concept_pages to anon, authenticated;

commit;
