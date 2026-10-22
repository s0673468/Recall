# Web review: Recall Hub or Recall's Flutter PWA?

**Recommendation: use Recall Hub as the web review surface, subject to confirming
its deployment and review delivery.** Two facts decide this: the
[current README](../../README.md#role) names Android and Hub as supported clients,
and the [Pages workflow](../../.github/workflows/pages.yml) disables PWA deployment
with `if: false`. Choosing the PWA means restarting a retired delivery path.
This recommendation does not establish Hub's feature parity or live acceptance.

Scope: repository evidence only, as of 2026-10-22. The separate private
`s0673468/recall-hub` repository is unavailable; its code, tests and deployment
were not inspected. No card contents or personal data were used.

| Area | Recall Hub | Recall's own Flutter PWA |
| --- | --- | --- |
| Features | Designated for laptop/web review. Exact controls, reading, statistics, settings and keyboard parity are unverified. | [Legacy guide](../../WEB_SETUP.md#browser-layout-and-features) documents review/interval previews, undo, flags/hiding, decks, statistics/forecasts, reading, settings, split view and keyboard ratings. No native widgets or scheduled delivery after tab closure. |
| Offline | Storage, restart recovery and offline review support are unverified. | Durable review/flag outboxes and pending settings are documented. Use one offline review tab: storage is shared, write serialization is per process. Installed offline startup remains unverified here. |
| Sync path | [Data ownership](../../README.md#data-ownership) assigns Android/Hub scheduling to Recall's Supabase project. Hub's actual scheduler, replay, deduplication and settings implementation cannot be verified here. | Same Flutter app/backend and FSRS engine as Android. Pending writes replay before refresh; visible online tabs sync each minute and on reconnect/focus. Supabase remains authoritative. |
| Maintenance cost | Already designated; separate-repository upkeep is unknown. Lower total cost is not established. | Shares Android logic, but revival adds web builds, browser acceptance, worker updates and hosting. Source is preserved; build/publication is retired. |
| Test coverage | Suite, CI status and deployed acceptance are unavailable. | [Testing guide](../testing.md#coverage-boundaries) describes synthetic scheduling, replay, isolation and UI coverage; browser regressions exist. CI runs the Chrome quota test but no PWA build. Tests do not prove live delivery. |
| Hosting | [Web pointer](../../web/README.md) says to use the existing bookmark. Deployed URL and hosting are unverified. | Historical Pages build used `/Recall/` and local resources. Push/manual deployment is disabled; old sites or cached workers may still serve. |

**Hub risks:** missing features, offline loss or scheduler/sync divergence remain
unverified. Acceptance needs deployment confirmation and a synthetic review that
survives restart/reconnect and reaches a test backend exactly once, plus required
reading/settings checks. These checks remain outstanding.

**PWA risks:** historical setup is not current delivery guidance. Cache/worker
upgrades and storage loss can strand writes. Single-level undo can overwrite
another device's review (README). Revival needs maintenance ownership and fresh
browser/deployment acceptance.

**Transition boundary:** preserve old browser storage and pending reviews. The
[retirement note](../../web/README.md) establishes no outbox export/transfer,
zero-pending proof or live Hub acceptance. Resolve old pending writes before
abandoning that client.
