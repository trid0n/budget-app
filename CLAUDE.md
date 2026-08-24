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

## Schema migrations — all applied

Every migration this app has needed is **confirmed run** by the user as of 2026-08-15:
`period_mode`, `platform_hidden`, `saver_order` and `feature_recurring` on `user_settings`;
the `up_transfer_rules` table; `actual_revenue` on `mtg_rows`; and the `recurring_costs`
table (plus its RLS policy). `supabase/schema.sql` is the source of truth and matches the
live database.

**Schema changes still cannot be applied by Claude** — there is no `psql`/`supabase` CLI
here, only the Supabase SQL Editor, which a human has to run. So if you add a column or
table: update `schema.sql`, write the code to fail soft without it (every `db.*` call is
already wrapped so a rejected column is swallowed rather than breaking the page), and give
the user the exact SQL. Say plainly which behaviour is dead until they run it — a save that
silently no-ops is the usual symptom, and `db.saveMtg`-style whole-row saves fail entirely
rather than losing one field.

`saver_account_id` on `recurring_costs` (linking a recurring cost's "saved so far" to a
specific Up saver) is included in that — confirmed run 2026-08-15.

Two tables are deliberately left in place but unused: `public.ballet` and the
`feature_ballet` column, orphaned when Recurring costs replaced the single Ballet
calculator. Safe to drop once no old client is running.

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
10. **Sidebar highlight animation, long-press name preview, transaction-linked amount
    floor, income replace-vs-add, income emoji**: the sidebar's active-tab highlight now
    slides between tabs (`updateSideHighlight()`) instead of jumping; long-pressing an
    item/transaction name on mobile shows a floating tooltip with the full text instead
    of entering edit mode (`bindLongPressReveal(..., {preventEdit:true})`); an item's
    amount can no longer be manually set below its linked transactions' total (snaps
    back with a toast); a month's first real income transaction now *replaces* the
    template's estimated amount instead of adding to it (`applyTxAmountToItem()`) —
    later transactions the same month still add normally; income line items can now
    have their own emoji (the category emoji picker was generalized to a `kind`
    parameter — `'cat'|'tplCat'|'income'|'tplIncome'` — rather than duplicated).
11. **Up Bank saver-transfer auto-mapping**: recurring savings transfers (the user does a
    batch to various savers around the 1st of each month) can now be mapped once
    (destination account → template item) via the same remember-popup pattern as
    merchant rules, then auto-attributed every month after — see `transferRules`,
    `maybeShowTransferRememberPopup()`, and the `up_transfer_rules` migration above.
    Keyed on the transfer's destination account ID (`relationships.transferAccount.data.id`),
    not description text — confirmed with the user that Up's transfer descriptions are
    generic/identical across every saver, so text can't tell them apart the way merchant
    rules do for normal spending.

12. **Guessed-transaction exclude button**: guessed rows already had "?" (confirm) and "×"
    (wrong guess — opens search) but no direct way to exclude one outright; added a third
    "–" button wiring up the previously-dead `data-tx-exclude` click handler.
13. **Auto-exclude covered transactions**: a reimbursed expense (matching "Cover from X"
    transfer within 48h, same amount) now stays excluded even if it was already assigned
    to an item — `autoApplyTxRules()` reverses the prior contribution and re-excludes it,
    guarding against a real race where `refreshUpData()` can call this before `monthData`
    exists yet (waits rather than excluding-without-reversing in that case).
14. **Per-platform tab visibility**: each user can now hide a feature/tab they have access
    to on just their phone or just their PC (`platformHidden`, self-service, layered on
    top of — not instead of — the existing admin on/off grant) — see the `platform_hidden`
    migration above and `isFeatureVisibleNow()`/`refreshAllFeatureVisibility()`. Shipped
    first as two independent mobile/PC toggles, then reworked on request into one 4-way
    segmented control per feature (Both/Phone/PC/Off) — "hidden on both" is as valid a
    choice as either single-platform one, and one tap reaches any state.
15. **Per-item "restore to template"**: a `›` button next to each item row's delete opens a
    small shared floating menu (`#itemRowMenuPanel`, one instance repositioned per click)
    with `restoreItemToTemplate()`. For a source-synced item (Tech/Groceries/Ballet/Monthly
    Costs) it re-runs that source's own apportionment rather than copying the template's
    flat number — those two are never the same value for day-apportioned items like Public
    Transport. Deliberately not reusing `syncAmountEverywhere()`: that no-ops on a past
    month by design, but an explicit restore click should still work there.
16. **Items follow their transactions' total**: `applyTxAmountToItem()` now *sets* an item to
    the sum of all its linked transactions instead of adding onto whatever the amount
    happened to be (which blended a stale template estimate with real transactions). Self-
    corrects prior drift. A manually-typed amount still sticks until the next transaction
    is attributed to that item.
17. **Ctrl/Cmd-click multi-select in the Up tab**: builds a `selectedTxIds` selection; the
    next assign / confirm-guess / exclude applies to every selected transaction. Shared
    `assignTxToItem()` / `excludeTx()` / `applyBulkAssignIfSelected()` helpers were factored
    out of the four existing call sites so all of them get bulk-apply without duplication.
18. **New jar-and-coin logo + Template tab icon**: favicon and sidebar brand mark redrawn
    (the brand mark's coin is filled with `var(--gold)` — the same colour as its own tile —
    so it reads as a cut-out and tracks dark mode for free). Template's `▥` swapped for `⧉`,
    since `▥` was nearly indistinguishable from Records' `▤` right below it. **How the
    favicon was chosen**: rendered each candidate to a canvas at true 16/20/32px and
    upscaled 8x with `image-rendering:pixelated`. Judging a favicon from a large preview
    tells you nothing about what survives at tab size — worth repeating for any future
    icon work. **Superseded** — both are now plain line art (a stroke-only jar with a
    dollar sign, same drawing for favicon and sidebar). The filled versions turned to mush
    at 28px; strokes survive it. Same canvas-upscale method picked the replacement.
19. **Undo now covers transaction assignments.** `pushUndo('month', …)` snapshots
    `txAssignments` alongside `monthData`, because they change together but only the latter
    was captured — so undoing an unassign restored the item's amount while leaving the
    transaction detached. Fixes undo for assign/exclude too.
20. **Account settings reworked**: one "Tabs & features" section (a 4-way Both/Phone/PC/Off
    control per feature, replacing a separate on/off list plus a per-platform list), two
    columns on wide screens, name auto-saves as you type, and no Close button (the corner
    × does it). Email/password deliberately still need an explicit press — per keystroke
    they'd email a confirmation to a half-typed address or set the password to a prefix.
    Hidden tabs no longer flash on load: the hidden set is cached in `localStorage` and
    applied as a `<style>` before first paint, the same trick the theme already used.
21. **Up tab**: no page scroll and no visible scrollbars. Three separate causes, in order —
    a tooltip with no positioned ancestor hanging below the fold, a `UP_TX_LIST_MIN_HEIGHT`
    floor too high to shrink past once the savers grid wrapped, and stale
    `.up-tx-list::-webkit-scrollbar` rules *below* the hide rule that re-widened it. The
    list is re-capped by a `ResizeObserver` on the elements beneath it, since they settle
    after the initial sizing runs (async `/accounts` fetch, income chip, transfer banner).
22. **Savers drag to reorder**, default highest balance first (`saver_order`). Mouse/pen
    only — on touch that gesture is how you scroll down to reach them.
23. **Recurring costs replaces Ballet**: an arbitrary list, each row with its own cycle
    length in weeks, syncing to the template item sharing its name (the Monthly Costs
    contract) instead of one hardcoded name. The admin grant and the "Flexible Tracker"
    alias are both gone; it's an ordinary self-service feature. Set-aside maths unchanged.
24. **MTG actual revenue**: profit and totals now come off what a card actually sold for,
    with expected kept as an estimate. `actual_revenue` is nullable on purpose — blank
    means "not sold yet" and stays out of the revenue total, unlike a real 0.

## Known open items

- No outstanding schema migrations — see "Schema migrations" above.
- **Ballet was not carried into Recurring costs.** The user chose to start fresh, so
  `recurring_costs` began empty while their old values still sit in the untouched
  `public.ballet` row. They were given both options (re-add it by hand, or an `insert …
  select from public.ballet` to copy it across) — worth checking which they did before
  assuming the row exists.
- The project-management **task list tool** (`TaskList`/`TaskCreate`) holds the 2026-08-13
  six-feature batch (all completed). Safe to clear for a fresh batch — nothing depends on
  its history.
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
- The "un-excluding a transfer transaction is a no-op" bug (item 11 above): the
  un-exclude button `delete`d the transaction's assignment entry outright, which made it
  indistinguishable from "never seen" to `autoApplyTxRules()` — which then immediately
  re-excluded it on the very next render. Static reading of the un-exclude handler in
  isolation looked correct; only became obvious by actually clicking Excluded → un-exclude
  in the test harness and checking whether the button state survived a re-render.
- **The mobile "two scrollbar thumbs" / "scroll range shrinks depending on where you
  start dragging" bug** — this took roughly seven fix attempts across a very long session
  before landing on the real cause, and is worth reading in full if it ever resurfaces.
  The actual bug: per the CSS Overflow spec, if one of `overflow-x`/`overflow-y` is set to
  a non-`visible` value and the other is left `visible` (explicitly or by default), the
  `visible` axis's *computed* value silently becomes `auto` instead — confirmed via
  `getComputedStyle`, not visible from reading the source CSS. Any element that sets only
  one axis is a latent independent scroll container waiting to happen the moment *any*
  content — including invisible content — extends past its box. Two real instances found
  this way:
  1. `#viewPagerViewport` (wraps the entire swipeable pager, every tab) — only
     `overflow-x:hidden` was set; `overflow-y` computed to `auto`, making the whole pager
     wrapper a second, independent, touch-scrollable region layered on top of the page.
  2. `.chart` (`#dashChart`, the Dashboard bar chart, mobile only) — only
     `overflow-x:auto` was set (for horizontal panning). `overflow-y` computed to `auto`,
     and each bar's `[data-tip]::before` tooltip (`position:absolute; top:100%`, invisible
     via `opacity:0` until real `:hover`) extended past the box, giving it genuine
     scrollable overflow nobody could see.
  Six earlier fix attempts (touch axis-lock tuning, `overscroll-behavior-y:none`, a
  ResizeObserver→rAF→ResizeObserver detour, `position:sticky`→`fixed` on the sidebar,
  removing nested scroll from `.rec-table-wrap`/`.up-tx-list`) were all real, individually
  correct fixes for real problems — none of them were this bug, which is why the user kept
  reporting "still happening" after each one shipped. **What finally worked**: stop
  reasoning from the CSS and instead sweep the live DOM for ground truth —
  `document.querySelectorAll('*')`, check `getComputedStyle(el).overflowY/overflowX` for
  `auto`/`scroll`, and flag anything where `scrollHeight > clientHeight` (or the `-Width`
  equivalent) is actually true. This finds every real independently-scrollable element on
  the page in one pass, with zero guessing about which element or which tab. If a scroll
  bug like this ever comes back, run that sweep first, on every tab, before touching any
  more CSS.

Moral: for anything visual or stateful, screenshot/exercise it — don't just confirm the
code "looks right." For scroll-container bugs specifically, don't reason from the CSS at
all — sweep the live DOM for elements with real `scrollHeight > clientHeight` first.

- **The Up tab's leftover ~48px of page scroll** (2026-08-13) — a second instance of the
  `[data-tip]::before` tooltip bug that had already bitten `.tf-toggle-btn` once (see item
  9's "Gotcha" above). `#upChooseIncomeBtn`'s tooltip is `position:absolute; top:100%`, but
  `.mini-btn` had no `position:relative`, so it anchored to a distant ancestor and laid out
  as real content far below the fold — creating genuine page scroll on a tab whose
  transaction list was already correctly capped. Two rounds of "make `sizeUpTxList()`'s
  arithmetic more correct" (adding `.wrap`'s real 80px bottom padding, then measuring the
  overflow directly) both failed to find it, because the extra height was never coming from
  the list. **What worked**: binary-searching the live DOM — walk `#upContent`'s children,
  `display:none` each in turn, re-read `document.documentElement.scrollHeight`, and see
  which one changes it. That named the culprit in one pass with no CSS reasoning at all.
  Generalise: when "the page is taller than it should be," don't compute what the height
  *ought* to be — hide things until it changes. And if a `[data-tip]` element ever seems
  involved, check its nearest positioned ancestor first; this is now the third instance.

25. **Day-apportioned items carry a goal AND a spent figure.** Groceries and every Monthly
    Costs item (Public Transport, rent, internet) are apportioned over the days *remaining*
    in the month, so their amount is a target for what's left — a different quantity from
    what has already been spent on them. Two writers used to fight over that one number:
    `syncAmountEverywhere()` set it to the apportioned goal on load, then
    `applyTxAmountToItem()` overwrote it with the month's actual spend the moment a
    transaction landed, and the next load put it back. The row now shows both — the goal in
    the input, spend beneath it (`.amt-spent`, computed live from `getTxsForItem`, never
    stored) — and `isApportionedItem()` keeps transactions off the goal in
    `applyTxAmountToItem`, `reverseTxAssignmentIfSameMonth`, the focusout floor, the
    paperclip's "stale" state and the panel's "Set to $X". Plain items are untouched and
    still follow their transactions. **Totals still run off the goal**, not the spend.
    Tech and Recurring sync flat monthly figures, so they're deliberately out of scope.

## Data repairs (a fix to the code is not a fix to the data)

- **229 cross-month `tx_assignments` re-stamped** (2026-08-24). Symptom reported as
  "entering the app sets Groceries to a number in the thousands" ($4,442.09). Cause was
  the cross-month auto-attribution bug fixed in `b4dbfaf` — but that commit only stopped
  *new* mis-attributions and, in the same change, hid the existing ones by having
  `getTxsForItem` skip assignments whose `monthKey` disagreed with the transaction's own
  date. `6efee66` removed that skip a day later (correctly — it left an item's amount
  counting transactions its own panel refused to list), which un-hid ~$63k of never-cleaned
  data: 229 assignments going back to 2025-06, all stamped with the then-open month.
  `applyTxAmountToItem` *sets* an item to the sum of its linked transactions, so every new
  Coles transaction re-summed the whole pile onto Groceries. Repaired in the browser console
  against live data (no `psql` here) by re-stamping each assignment's `monthKey` to
  `dateToKey(new Date(a.date))` and re-saving via `db.saveTxAssignments` — re-stamping, not
  deleting, so the Up tab's assigned badges survive and `autoApplyTxRules` still skips them.
  Re-stamped rows point at the *open* month's `itemId`s, so they read as inert in the months
  they moved to rather than showing up as stray linked transactions there.
  **The lesson worth keeping**: when a bug has been writing bad rows, guarding the write path
  fixes the future and nothing else. Ask separately what is already in the database, and
  repair it in the same change — a masking read filter is not a repair, and whoever removes
  the mask later (for good reasons) gets the original bug back with no idea why.
