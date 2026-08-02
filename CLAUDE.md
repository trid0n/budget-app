# Budget app — project notes for Claude

Read this before doing anything else in this repo. It captures state and decisions from a
very long prior session that won't be in a fresh context window. `README.md` has the
one-time setup steps (Supabase project, Vercel, keep-alive) — this file is about the
app's current shape, decisions made, and what's still open.

## What this is

A single-file household budgeting web app for one household (Liam + partner), used daily.
`index.html` (~5,750 lines, ~345KB) is the entire app — vanilla JS/CSS/HTML, no build
step, no framework. It's deployed as a static site on Vercel, data lives in Supabase
(Postgres + Auth), and it optionally connects to the Up Bank API (Australian bank) client-side
to pull real transactions and auto-assign them to budget line items.

Repo: `github.com/trid0n/budget-app`, deployed via Vercel from `main` (auto-deploy on push).

## Architecture essentials

- **Everything is in `index.html`.** CSS in a `<style>` block, all JS in `<script>` tags
  near the end of `<body>`. `migrate.html` was a one-time IndexedDB→Supabase migration
  tool (job's done, kept for history but not part of the live app). `legacy/` holds the
  pre-migration app version, also just history.
- **Supabase**: schema in `supabase/schema.sql`. `SUPABASE_URL` and `SUPABASE_ANON_KEY`
  are hardcoded as JS constants directly in `index.html` (not env vars) — this is
  intentional, not a leak. Row Level Security is the actual security boundary (every
  table policy is `user_id = auth.uid()`), so the anon key being public is expected
  Supabase usage, same as a Stripe *publishable* key.
- **Auth**: Supabase email/password, self-service sign-up is open on the public URL.
  Anyone can create an account, but RLS means they only ever see their own (empty) data.
- **Up Bank integration**: the personal access token is stored client-side
  (`user_settings.up_token`) and used to call `api.up.com.au` directly from the browser.
  This was a deliberate Phase-1 scope decision (see README's "What's deliberately not
  done yet") — moving it behind a Supabase Edge Function is a known future improvement,
  not yet started.
- **Single-file, not split into modules.** Also a deliberate deferred decision, not an
  oversight.
- **`db` object** (~line 1250) is the entire persistence layer — one method per
  load/save operation, each a thin wrapper over `sb.from(table)...`. If you're adding a
  new persisted field, this is where to wire it up, alongside a matching column in
  `supabase/schema.sql`.

## ⚠️ Outstanding: a schema migration may not be applied yet

A `period_mode` column was added to `user_settings` (commit `0375941`) for the
calendar/pay-cycle budgeting toggle. Unlike `index.html`, **schema changes can't be
applied by Claude** — there's no `psql`/`supabase` CLI in this environment, only the
Supabase SQL Editor (a human has to run it). Check whether this was actually run:

```sql
alter table public.user_settings add column if not exists period_mode text not null default 'calendar';
```

If unsure, ask the user, or just try it — `add column if not exists` is safe to
re-run. Until it's applied, saving `settings.periodMode` silently no-ops (the `db.saveSettings`
upsert would error on an unknown column, but errors are swallowed — see testing note below
about this pattern).

## How to test changes (established pattern — use this, don't skip verification)

This machine has **no `node`, `npm`, `gh`, or `supabase` CLI**. There's no way to syntax-check
JS outside a browser. The established, repeatedly-used workflow for any non-trivial change:

1. `cp index.html index-test.html`
2. Write `scratch-server.ps1` — a tiny PowerShell `System.Net.HttpListener` static file
   server on port 8973, serving `index-test.html` at `/`.
3. Write `.claude/launch.json` pointing at it (see any recent commit for the exact
   contents, or ask — it's a fixed template reused every time).
4. In `index-test.html`, insert a stub block right before `(async function init(){` that:
   - Overrides `sb.auth.getSession`/`onAuthStateChange` to fake a logged-in session
     (no real Supabase auth needed).
   - Overrides every `db.load*`/`db.save*` method to read/write an in-memory `_fakeDb`
     object instead of hitting real Supabase.
   - Optionally overrides `window.upFetch` to return canned fake Up Bank transaction data
     shaped like the real API (`{data:[{id, attributes:{description, amount:{value,
     currencyCode}, createdAt, status}, relationships:{}}], links:{}}`).
5. `mcp__Claude_Browser__preview_start` with the launch config, then use
   `read_console_messages(onlyErrors:true)`, `javascript_tool` (`javascript_exec`), and
   `computer` screenshots to actually exercise the feature and confirm it works —
   not just that it loads.
6. **Always clean up before committing**: `rm -f index-test.html scratch-server.ps1
   .claude/launch.json; rmdir .claude` (if `.claude` was created fresh — don't remove it
   if `.claude/settings.local.json` already existed there).

This caught multiple real bugs this session that static reading alone missed (see
"Bugs found this way" below). Don't skip it for anything touching app logic.

**Gotcha**: `javascript_exec` calls are separate tool round-trips with real wall-clock
gaps between them (often several seconds). Any UI with a `setTimeout` auto-dismiss (like
the transaction-remember popup, ~9s) can expire *between* your tool calls even though your
test script looks synchronous. Combine multi-step interactions into a single
`javascript_exec` call when timing matters.

## Workflow expectations (established this session, don't relitigate)

- **Commit and push directly to `main` without asking permission**, once a change is
  verified working. This was established early and repeated throughout — don't ask "should
  I commit?" for routine fixes/features.
- Exception: if a commit is blocked by the platform's own secret-detection safety
  classifier (happened once, for a Supabase anon key — a false positive since that key is
  meant to be public), don't fight it. Explain to the user and give them the exact
  `git commit`/`git push` commands to run themselves.
- Minimal, verified-necessary changes over defensive/speculative ones. Example: a
  strikethrough-toggle bug fix originally included an extra defensive exclusion clause
  that wasn't actually needed — it was reverted before committing because it was unproven
  scope creep. Default to the smallest fix that's confirmed to work.
- Don't add comments explaining *what* code does; only *why*, when non-obvious (a
  constraint, a workaround, an invariant). This codebase's existing comment style is a
  good model — keep matching it.
- When a request is genuinely open-ended ("suggest ways to…"), answer with a short set of
  concrete options and a recommendation — don't just build one interpretation.
  Architecturally significant ambiguity (e.g. "should this redesign keep or drop existing
  behavior X?") is worth one clarifying question before building, not a guess.

## Recent feature history (chronological, newest last)

Roughly the last ~25 commits, grouped by theme (see `git log` for exact messages):

1. **Strikethrough rendering** on charged items — went through several iterations to get
   pixel-accurate positioning (canvas text measurement + real DOM layout, not guessed
   metrics), landed on an empirically-calibrated result.
2. **Performance**: sequential → parallel → batched Supabase reads for month-switching,
   dashboard, and insights (was causing multi-second delays). `db.loadMonths(keys)`
   batches multiple month reads into one request.
3. **Category emoji system**: auto-matched from category name (whole-word regex, not
   substring, to avoid false positives like "car" matching "care"), manually
   overridable via a searchable ~290-entry picker, shown consistently across Ledger,
   Template, transaction lists, Dashboard.
4. **Transactions-list side panel**: replaced an old modal with a side-popping panel
   reusing the same floating-panel infrastructure as the Groceries/Tech inline source
   tables (`#inlinePanelHost`, `positionOneInlinePanel`/`renderOpenInlinePanels`). Fixed
   a real pre-existing bug in the process: `#inlinePanelHost` is a DOM *sibling* of
   `#view-ledger`, not a descendant (it's declared after all `.view` divs close), so click
   listeners on `#view-ledger` can never see clicks on its floating content — has to be a
   `document.body`-level listener. This bit us more than once; if you're adding
   interactive content to `#inlinePanelHost`, remember this.
5. **Runtime crash fix**: `findCatItemByName()` used to return a truthy `{cat, item}`
   object even when `item` wasn't found (both branches), so callers' `if(!found) return`
   never caught it — crashed with "Cannot read properties of undefined (reading
   'amount')" whenever a saved merchant rule pointed at an item that had since been
   renamed/deleted. Now returns `null` in that case. Worth remembering as a pattern to
   watch for elsewhere: a function that "found the container but not the thing inside it"
   should return falsy, not a partially-populated object.
6. **Keep-alive workflow fix**: `.github/workflows/keepalive.yml` had been failing on
   *every single run since #1* because `SUPABASE_URL`/`SUPABASE_ANON_KEY` were never
   actually added as GitHub repo secrets (a manual step from the original setup docs that
   silently never happened). Fixed by hardcoding the same public anon key/URL that's
   already in `index.html` directly into the workflow — removes a manual setup step
   that has no one around to redo if missed again. If you ever see this workflow failing,
   check `Actions → Supabase keep-alive` on GitHub for the actual error first.
7. **Pay-cycle budgeting toggle**: `settings.periodMode` (`'calendar'` | `'paycycle'`,
   see schema note above). In pay-cycle mode, "the current month" rolls over to next
   calendar month as soon as a transaction matching the linked Up Bank income source
   lands — not on the 1st. Live/manual bank balance is now only folded into the "left
   over after your goal" figure when viewing the actual current period (`isCurrentPeriod()`)
   — browsing a past/future month no longer has today's balance bleeding into its numbers.
8. **Merchant-rule redesign**: replaced a buried "remember this merchant" checkbox +
   two-item (above/below threshold) rule type with a small anchored popup (tick/cross/$
   icons) that appears after every manual transaction assignment. Rules are now
   single-item + optional minimum-amount gate (the two-item split was deliberately
   dropped — see commit `3c84778` for the reasoning). Added a "Manage merchant rules"
   list (Up Bank tab) to review/delete saved rules directly.
9. **Polish pass**: dark-mode flash on load fixed (theme cached in `localStorage`,
   applied synchronously before first paint, corrected once real settings load); Up Bank
   timeframe filters (1yr/all-time/custom/pay-cycle ones) tucked behind a "more options"
   gear toggle, leaving just Last month/3 months/6 months visible; login page visually
   redesigned (found and fixed a real bug in the process — the primary button's text was
   invisible, same color as its own background, due to a CSS specificity fight between
   `.mini-btn.gold` (2 classes) and `.auth-submit` (1 class); fixed via ID selector);
   Monthly Costs "no rounding" option removed from the *inline* table opened from a
   Budget-tab item (still available in the full Other Records table); income-source
   display replaced a run-on instructional sentence with a clean chip/pill.

## Known open items

- **Recurring savings-transfer auto-attribution** (explicitly requested, not yet built):
  the user does a batch of transfers to savers around midnight on the 1st of each month
  and wants these auto-attributed to template items, while staying editable/reassignable.
  Three approaches were proposed and discussed, recommendation was to start with the
  first:
  1. **Template-name matching** (recommended starting point) — reuse the existing
     fuzzy name-matching guess logic, treating template item names as match targets.
  2. **Explicit mapping** — user tags each template item once with which transfer
     description it corresponds to (like the existing income-source link).
  3. **Date+amount heuristic** — fallback layered on top of one of the above, not
     standalone (fragile if amounts vary month to month).
  Not started — the user hadn't confirmed which approach to proceed with as of the last
  message in the prior session.
- **Verify the `period_mode` schema migration was actually run** (see warning above).
- The project-management **task list tool** (`TaskList`/`TaskCreate`) still has 18 stale
  entries from the original Supabase-migration project (all marked completed) — it hasn't
  been used for anything since. Fine to ignore, or worth clearing out and starting fresh
  if picking it back up.
- `README.md` step 7 still tells a new setter-upper to add `SUPABASE_URL`/
  `SUPABASE_ANON_KEY` as GitHub repo secrets for the keep-alive workflow — this is now
  **stale/wrong** per the fix in point 6 above (values are hardcoded in the workflow
  file directly, no secrets needed). Worth fixing the README if you're in there anyway,
  though it wasn't flagged as urgent.

## Bugs found only by testing in the browser (not by reading code)

Worth knowing these exist as a class, since static review missed all of them:
- The `#inlinePanelHost`-is-a-sibling-not-descendant issue (item 4 above).
- The `findCatItemByName` truthy-empty-object issue (item 5 above) — was found by
  actually reproducing a stale-merchant-rule scenario in the test harness after static
  analysis of every `.amount` property access in the file failed to find it; the real bug
  turned out to be a different shape of crash entirely (`.item` being undefined, not
  `.attributes`).
- The CSS specificity bug on the login page's primary button (item 9 above) — invisible
  by pure code reading, obvious the moment it was screenshotted.

Moral: for anything visual or stateful, screenshot/exercise it — don't just confirm the
code "looks right."
