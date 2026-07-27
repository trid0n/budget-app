# Budget app

Single-file household budgeting app (`index.html`), persisted in Supabase (Postgres + Auth) so it syncs across devices, deployed on Vercel.

This machine has no `node`/`npm`, `gh` CLI, or `supabase` CLI installed, so the steps below are all dashboard/browser-based — no local tooling required.

## 1. Create the Supabase project

1. Create a project at [supabase.com](https://supabase.com) (any region/plan works — free tier is fine).
2. Go to **SQL Editor → New query**, paste in the contents of [`supabase/schema.sql`](supabase/schema.sql), and run it. This creates every table, enables Row Level Security, and locks each row to its owning user.
3. Go to **Settings → API**. Copy the **Project URL** and the **anon public** key — you'll need both in the next step. (The anon key is meant to be public/embedded in client code; RLS is what actually protects your data, not secrecy of this key.)
4. Go to **Authentication → Providers** and confirm Email is enabled (it is by default). Optionally, under **Authentication → Settings**, turn off "Confirm email" if you don't want to click a confirmation link on first sign-up.

## 2. Wire the app to your project

Open `index.html` and replace the two placeholder constants near the top of the `<script>` block:

```js
const SUPABASE_URL = '__SUPABASE_URL__';
const SUPABASE_ANON_KEY = '__SUPABASE_ANON_KEY__';
```

with your actual project URL and anon key from step 1.3. Do the same in `migrate.html`'s two input fields when you get to step 4 (those are entered in the page itself, not hardcoded).

## 3. Create your account

Open `index.html` in a browser (works straight off disk, or once deployed). Use the **Sign up** tab with your email and a password. Since sign-up is open on a public URL: anyone who finds it can create an account, but Row Level Security means their account only ever sees its own (empty) data — never yours.

## 4. Migrate your existing data (one-time)

If you have real budget data sitting in the old app's IndexedDB:

1. Open the **old** deployed app (or `legacy/budget-assign.html`) in a browser, open DevTools → Console, and run:
   ```js
   copy(JSON.stringify(await (async()=>{const out={};const r=await window.storage.list('',false);for(const k of r.keys){const v=await window.storage.get(k,false); out[k]=v.value;} return out;})()))
   ```
   This copies a complete dump of everything stored (months, tech items, grocery, transaction assignments/rules, everything) to your clipboard.
2. Open `migrate.html` in a browser, paste in your Supabase URL + anon key, log in with the account from step 3, paste the clipboard dump into the textarea, and click **Run migration**.
3. Spot-check a few rows in the Supabase dashboard's Table Editor against what you see in the old app.
4. Once you're confident the data is over, `migrate.html` and `legacy/` aren't needed anymore (they're kept in git history regardless).

## 5. Push to GitHub

```bash
git add -A
git commit -m "Migrate persistence to Supabase"
```

Then create a new repo on [github.com/new](https://github.com/new) (don't initialize it with a README), and:

```bash
git remote add origin https://github.com/<you>/<repo>.git
git branch -M main
git push -u origin main
```

## 6. Deploy on Vercel

1. At [vercel.com/new](https://vercel.com/new), import the GitHub repo.
2. Framework preset: **Other** (static site, no build step).
3. Deploy. Vercel serves `index.html` at the project root automatically.

## 7. Keep Supabase awake

The free tier auto-pauses a project after 7 days with no activity. [`​.github/workflows/keepalive.yml`](.github/workflows/keepalive.yml) pings it daily via GitHub Actions.

1. In your GitHub repo, go to **Settings → Secrets and variables → Actions** and add two repository secrets:
   - `SUPABASE_URL` — your project URL
   - `SUPABASE_ANON_KEY` — your anon key
2. Go to the **Actions** tab, select "Supabase keep-alive", and click **Run workflow** once to confirm it succeeds before relying on the daily schedule.

## What's deliberately not done yet

- **Up Bank token still lives in the browser** (in the `user_settings.up_token` column, loaded client-side, used to call `api.up.com.au` directly). Moving that behind a Supabase Edge Function so the token never reaches the browser is a planned follow-up phase, not part of this migration.
- **Single file, not split into modules.** `index.html` is still one ~280KB file. Splitting it into separate CSS/JS files is a planned follow-up refactor once this migration has been running smoothly for a while.
