# Deploy LenDen (Supabase + Render, free)

**Result:** one public URL such as `https://lenden-xxxx.onrender.com` that serves the web app
(all four roles) and the API (`/docs`), with data stored permanently in **Supabase PostgreSQL**.

```
Browser / phone ──► Render (Docker: Flutter web + FastAPI + model) ──► Supabase PostgreSQL
```

Time: about 30 minutes, mostly waiting for the first build. Cost: free.

---

## Current deployment

| Piece | Where |
|---|---|
| App + API | Render web service **`lenden`** (Singapore, free, Docker): https://lenden-qydc.onrender.com |
| Source | GitHub `MahmudulHasanJoy/LenDen-Loan-Predictor`, branch `main` |
| Database | Supabase project **`loanready`** (Singapore), tables created by migration `loanready_initial_schema` with row-level security on |
| Secrets | `LENDEN_JWT_SECRET` (random, set in Render), `DATABASE_URL` (see below) |

Pushing to `main` redeploys automatically. A **force** push may not, so use **Manual Deploy → Deploy latest commit** in Render if needed.

### Connect the Render service to Supabase

Until `DATABASE_URL` is set, the server uses a temporary built-in SQLite database that resets
whenever Render restarts. To store data permanently in Supabase:

1. **Set a database password.** In Supabase, open the `loanready` project and go to
   **Project Settings → Database → Reset database password**. Save the new password somewhere safe.
2. **Copy the connection string.** Click **Connect → Session pooler** and copy the **URI**.
   Replace `[YOUR-PASSWORD]` with the new password (no brackets).
3. **Add it to Render.** Open the **`lenden`** service, go to **Environment → Add environment variable**,
   and set **Key** `DATABASE_URL` and **Value** the URI from step 2. Click **Save, rebuild and deploy**.
4. **Check it worked.**
   - https://lenden-qydc.onrender.com/health should show `"database": "postgres"`.
   - The Render logs should show `{"event": "demo_seeded"}`.
   - Supabase **Table Editor** should show rows in `orgs`, `users` and `applications`.

Never commit the connection string or paste it into chats. If it leaks, reset the database
password and update the Render variable.

---

## 1. Put the project on GitHub (5 min)

The `LenDen` folder is already a Git repository with the full commit history (30 commits).

**Option A: GitHub Desktop (no commands)**
1. Install GitHub Desktop (desktop.github.com) and sign in to your GitHub account.
2. **File → Add local repository**, then choose the `LenDen` folder (the one containing `README.md`).
3. Click **Publish repository**, keep the name **LenDen**, choose Public or Private, and click **Publish**.
   This creates the repo on GitHub and pushes all commits to `origin`.

**Option B: command line**
1. On github.com, create a new **empty** repository named `LenDen`. Don't add a README, .gitignore or licence.
2. In PowerShell, inside the `LenDen` folder:
   ```powershell
   git remote add origin https://github.com/<your-username>/LenDen.git
   git push -u origin main
   ```

> The dataset `data/Loan_default.csv` is ignored by `.gitignore` on purpose. The trained models in
> `artifacts/` are included, and the server only needs those.

GitHub Actions now runs all tests on SQLite **and** PostgreSQL, plus the Flutter build. Check the
**Actions** tab for green ticks.

## 2. Create the Supabase database (5 min)

1. Go to supabase.com, sign in with GitHub, and click **New project**:
   - **Name:** `lenden`
   - **Database password:** click *Generate* and **save it somewhere safe**
   - **Region:** **Southeast Asia (Singapore)**. Same region as Render means faster queries.
2. When the project is ready, click **Connect** (top bar) and choose **Session pooler**.
   Copy the **URI**. It looks like:
   ```
   postgresql://postgres.abcdefghijkl:[YOUR-PASSWORD]@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres
   ```
3. Replace `[YOUR-PASSWORD]` with your database password (no brackets). This is your
   **`DATABASE_URL`**. Treat it like a password.

**Why the session pooler:** Render connects over IPv4, and Supabase's *direct* connection is
IPv6-only. The session pooler works over IPv4. LenDen also turns off prepared statements
(`prepare_threshold=None`), so the transaction pooler on port 6543 works too.

You don't need to create any tables. LenDen creates them on first start, with row-level security
switched on so Supabase's public REST API can't read them.

## 3. Deploy on Render (2 min of clicks, plus a 10–15 min first build)

1. Go to render.com and sign in with GitHub.
2. Click **New → Blueprint**, pick your `lenden` repo, and Render reads `render.yaml`.
3. When asked for **`DATABASE_URL`**, paste the Supabase URI from step 2. `LENDEN_JWT_SECRET`
   is generated for you.
4. Click **Apply**. The first build compiles the Flutter web app inside Docker, so it is slow.
   Later deploys reuse the cache.
5. When the service shows **Live**, open its URL:
   - `https://<your-service>.onrender.com`: the LenDen app
   - `https://<your-service>.onrender.com/docs`: the API docs
   - `https://<your-service>.onrender.com/health`: should show `"database": "postgres"`

On first start the empty database is filled with demo data (2 lenders, 5 staff, 200 borrowers).
This takes about a minute in the background. Log in with the demo chips (password `demo1234`).

## 4. Check the data in Supabase

In Supabase, open **Table Editor** to see `orgs`, `users`, `applications`, `org_settings` and
`audit_log`. Approve an application in the app, refresh, and you'll see the new `status` and a new
`audit_log` row.

## 5. Point the phone app at the live server

```bash
cd mobile
flutter build apk --release --dart-define=API_URL=https://<your-service>.onrender.com
# APK: build/app/outputs/flutter-apk/app-release.apk  (send it to any Android phone)
```

Or keep your current build and set the address under **Server settings** in the app.

---

## Upgrading the live v2 service to v3

v3 upgrades the database in place: on start the API runs `python -m lenden.migrate`, which
adds the new tables and columns (migrations `0001`–`0003`) and keeps all v2 data. Nothing to do by
hand. After the deploy:

- `/health` shows `"version": "3.0.0"` and `"model_version": "lenden-v3"`.
- An **existing** demo database keeps its v2 data; the new features (offers, loans, credit levels)
  start empty for those accounts. For the full v3 demo, reset the demo data (see below).
- v2 apps already installed keep working: every v2 path is still served next to `/v1`.

### Environment variables

| Variable | Needed | What it does |
|---|---|---|
| `DATABASE_URL` | yes (production) | Supabase session-pooler URI. Without it the API uses a temporary SQLite file. |
| `LENDEN_JWT_SECRET` | yes | Signs access tokens and file links. Render generates it. |
| `LENDEN_SEED_DEMO` | no (default `1`) | Fill an empty database with demo data. |
| `LENDEN_RUN_JOBS` | no (default `1`) | Run background jobs (reminders, repayment checks, drift, email) in the web process. |
| `LENDEN_DEV_EXPOSE_CODES` | demo only | Show login codes and reset links on screen, **only for demo accounts**. Set `0` for real users. |
| `RESEND_API_KEY` or `SMTP_HOST`/`SMTP_USER`/`SMTP_PASSWORD` | no | Send real emails. Otherwise emails are written to the log. |
| `LENDEN_MAIL_FROM` | no | Sender, e.g. `LenDen <no-reply@yourdomain>`. |
| `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` | no | Store uploaded documents in a private Supabase Storage bucket (`lenden-docs`). Otherwise they are kept on the server's disk, which Render's free tier wipes on restart. |
| `SENTRY_DSN` | no | Error tracking (also `pip install sentry-sdk`). |
| `LENDEN_CORS_ORIGINS` | no | Comma-separated origins allowed to call the API from other sites. |
| `LENDEN_PUBLIC_URL` | no | Used in password-reset links, e.g. `https://lenden-qydc.onrender.com`. |

Keep secrets in Render's **Environment** tab only, never in the repo or in chats.

### Nightly backups (optional)

`.github/workflows/backup.yml` runs `pg_dump` every night and keeps the dump for 7 days as a
workflow artifact. To turn it on, add `DATABASE_URL` as a repository secret in GitHub
(**Settings → Secrets and variables → Actions**). It also counts as activity, so the Supabase
free project is not paused.

### Safer releases

Push v3 to a branch first (for example `develop`) and open a pull request: CI runs the backend tests
on SQLite and PostgreSQL and builds the Flutter app. Merge to `main` only when it is green, and Render
deploys it. A failed Render build never replaces the running version.

## Good to know (free tiers)

| | What happens | What to do |
|---|---|---|
| **Render free** | The service sleeps after about 15 min without visits. The next visit takes up to a minute to wake it. | Open the link a minute before a demo or interview. |
| **Supabase free** | A project with no activity for 7 days is **paused**. | Click **Resume project** in the dashboard. Data is kept. |
| **Demo data** | Created only when the database is empty. | To reset: see below. |

### Reset the demo data

From your computer, inside the project folder:

```powershell
$env:DATABASE_URL = "postgresql://postgres.xxxx:PASSWORD@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres"
pip install -r requirements-api.txt
$env:PYTHONPATH = "src"
python -m lenden.seed --reset      # deletes ALL LenDen tables, re-runs migrations, re-creates demo data
```

### Going beyond a demo

- Set `LENDEN_SEED_DEMO=0` in Render and create real lenders from the platform-owner console.
- Change or remove the demo accounts. Everyone can see their password in this repo.
- Use a custom domain (Render → Settings → Custom Domains) and a paid tier so it doesn't sleep.
- Turn on Supabase's daily backups (paid plans), or schedule `pg_dump`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Render log: `connection ... Network is unreachable` | You used the **direct** connection string. Use the **Session pooler** URI. |
| `password authentication failed` | Wrong password in `DATABASE_URL`, or `[ ]` brackets left in. |
| `/health` shows `"database": "sqlite"` | `DATABASE_URL` isn't set on the Render service (Environment tab). |
| App opens but says it can't reach the server | Wait for `demo_seeded` in the Render logs (about 1–3 minutes on the free tier), then refresh. |
| Supabase "project paused" | Dashboard → Resume. |
| Build fails at `flutter build web` | Copy the error from the Render log. It's a Dart compile error to fix in `mobile/lib`. |

## Run locally against Supabase (optional)

```powershell
$env:DATABASE_URL = "<your session pooler URI>"
uvicorn api.main:app --port 8000
```

Without `DATABASE_URL`, everything uses a local SQLite file (`var/lenden.db`), so you can
develop offline.
