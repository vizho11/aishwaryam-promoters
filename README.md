# aishwaryam-promoters

Real estate team console — employee logins, daily activity, follow-ups, lead pipeline &
conversion rate, targets/commission/leaderboard, property listings, and day-off requests.

`index.html` is the whole app — no build step, no bundler. All data (employees, leads,
follow-ups, daily activity, day-offs, properties) lives in a real **Supabase** (Postgres)
backend, so it syncs across every device.

Run it locally:

```
python3 -m http.server 8000
```

Then open http://localhost:8000/index.html.

## One-time backend setup

1. Create a free project at [supabase.com](https://supabase.com).
2. Open **SQL Editor → New query**, paste in the contents of `supabase/setup.sql`, and run
   it. It's idempotent — safe to re-run any time you pull in changes to that file.
3. Set the admin passcode (this can only be done from the SQL editor, which runs as the
   Postgres superuser and bypasses the restriction that blocks it everywhere else):
   ```sql
   select admin_set_passcode('yourpasscode');
   ```
4. In **Project Settings → API**, copy your **Project URL** and **anon public** key, and
   paste them into `index.html` near the top of its `<script>` block:
   ```js
   const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
   const SUPABASE_ANON_KEY = 'YOUR-ANON-KEY';
   ```

The Supabase JS client is vendored as `vendor-supabase-js.js` (same origin, no CDN).
Fonts (Archivo, Manrope, JetBrains Mono) are bundled in `fonts.css`, also with no CDN calls.

## Logging in

- **Employees** never self-signup — the admin creates each account (Employees page → Add
  Employee), which shows the initial password **once**; copy it and send it to that employee
  directly (it can never be displayed again, only reset).
- **Admin** login is hidden by default — visit with `?apadmin=1` in the URL (e.g.
  `http://localhost:8000/index.html?apadmin=1`) to reveal the Admin tab on the login screen.
  This is obscurity, not real access control (anyone reading the source can find the
  parameter), but it keeps the option from ever appearing for regular employees.
- There's no "forgot passcode" flow for the admin passcode short of running
  `update admin_config set passcode_hash = null;` in the SQL editor and re-running
  `admin_set_passcode(...)`. Employee passwords, on the other hand, can be reset any time
  from the Employees page (the key icon next to each row).

## Security model

Every table (`employees`, `leads`, `follow_ups`, `daily_activity`, `day_offs`, `properties`,
plus the internal `admin_config`/`auth_attempts`) has row-level security enabled with **zero**
policies — there is no direct anon read or write of any kind, even with the anon key. The
only way in or out is through `SECURITY DEFINER` functions in `supabase/setup.sql`, each of
which re-verifies the caller's admin passcode or employee email+password itself (never
trusting the client's "I'm logged in" state), so calling the API directly bypasses nothing:

- Passwords are hashed with `pgcrypto` and never returned by any function.
- Repeated wrong-password/passcode guesses get rate-limited and locked out for a few minutes
  (only failures count, so normal use is never throttled).
- Employees can only create/edit leads and follow-ups assigned to themselves; admins can see
  and manage everything.
- The leaderboard and team day-off calendar are visible to any logged-in employee (not just
  admin) but only expose names and aggregate numbers — never another employee's email, phone,
  target, commission rate, or personal leave reason.

## Notes

- **Conversion rate** = closed-won leads ÷ total leads (all-time), shown per employee and
  company-wide.
- **Leaderboard, targets & commission**: admin sets a monthly ₹ target and commission % per
  employee; the dashboard shows progress toward that target and an estimated commission
  figure for deals closed so far this month — both computed client-side from real lead data,
  nothing hardcoded.
- **Day-off calendar**: any approved time off shows up on a shared "who's out" list visible
  to the whole team (name + dates only, not the reason) so people can plan around it.
- Palette: deep navy/charcoal sidebar with a warm brass-gold accent — avoids the "generic AI
  dark UI" look, reserves gold for prize/target/leaderboard moments the same way a physical
  awards wall would. Real inline SVG icons (no emoji), soft elevation shadows, and
  `font-variant-numeric: tabular-nums` on every money/count figure so columns of numbers align.
- Chart colors (pipeline funnel, leaderboard bars) follow a validated sequential-blue ramp for
  the in-progress pipeline stages and reserved status colors (green/red) for the two closed
  states, rather than an arbitrary rainbow.
