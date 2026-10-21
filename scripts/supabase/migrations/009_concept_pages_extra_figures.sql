-- concept_pages.extra_figures: up to three inline figures per Read-tab primer.
--
-- Each primer keeps its hero `figure_svg` above the body. This adds an ordered
-- JSON array of extra figures, each `{"svg": "<svg ...>", "after_paragraph": k}`,
-- drawn right after top-level paragraph k of `body_html` (paragraphs are split
-- on `<br><br>` outside any open tag and numbered from 1). Service-role primer
-- tooling writes it; clients only read it and tolerate malformed elements.
--
-- Additive and idempotent: existing rows get `[]`, older clients never select
-- the column, and RLS/grants are unchanged (global read, service-role writes).

begin;

alter table public.concept_pages
  add column if not exists extra_figures jsonb not null default '[]'::jsonb;

alter table public.concept_pages
  drop constraint if exists concept_pages_extra_figures_check;

alter table public.concept_pages
  add constraint concept_pages_extra_figures_check
  -- The CASE guarantees jsonb_array_length never sees a scalar or object, so
  -- a wrong shape is a clean check violation (23514) rather than an error.
  check (
    case
      when jsonb_typeof(extra_figures) = 'array'
        then jsonb_array_length(extra_figures) <= 3
      else false
    end
  );

commit;
