# POS v1 database

Database design for a single-branch retail POS (pharmacy / convenience / hardware, Philippines).
The full write-up is in `POS_v1_Database_Design.pdf` and on the website in `site/`.

| Folder | Use it for |
|---|---|
| `sqlite/` | SQLite 3.37+ (Electron `better-sqlite3`, Tauri `tauri-plugin-sql`) |
| `postgresql/` | PostgreSQL 15+: own server, Google Cloud SQL / AlloyDB, AWS RDS / Aurora PostgreSQL |
| `mysql/` | MySQL 8.0.16+: own server, Google Cloud SQL for MySQL, AWS RDS / Aurora MySQL |
| `supabase/migrations/` | Supabase: the PostgreSQL schema plus staff login and row level security |
| `site/` | The website (static files, ready for Cloudflare) |
| `docs/` | Source of the PDF (`pos_design.html`) |

Each database folder has `schema.sql` (tables, views, triggers, seed data) and
`example_checkout.sql` (a sample stock-in, Senior Citizen sale, regular sale, refund and exchange).

Tested: SQLite 3.45 and PostgreSQL 18 (including the Supabase files, with a stand-in
for Supabase Auth). The MySQL version has not been run yet.

The discount and VAT rules are a starting point: verify them against current BIR
and DTI rules before go-live.

## Website

`site/` is a plain static site: no framework and no build step needed to host it.
The files people download live in `site/downloads/`.

**After changing any schema file or the PDF**, refresh the downloads (copies, .zip
bundles and file sizes):

```
python build_site.py
```

**Preview locally:**

```
python -m http.server 8788 --directory site
```

Then open http://localhost:8788. (Opening `index.html` straight from disk works too,
but the "View" code viewer and file sizes need a web server.)

### GitHub Pages (current setup)

Live at **https://xavryl.github.io/SynerTech/**.

Every push to `main` runs `.github/workflows/pages.yml`, which runs `build_site.py`
and publishes the `site` folder. Nothing else to do: edit, commit, push. Progress shows
under the repository's **Actions** tab.

### Or host it on Cloudflare

**Option A: drag and drop (no tools needed)**

1. Cloudflare dashboard → **Workers & Pages** → **Create** → **Pages** → **Upload assets**.
2. Name the project (e.g. `pos-db-design`) and drop the **`site` folder**.
3. Deploy. The site is live at `https://<project>.pages.dev`. To update it later,
   upload the folder again as a new deployment.

**Option B: command line**

```
npx wrangler pages deploy site --project-name pos-db-design
```

The first run asks you to log in to Cloudflare.

**Option C: from a Git repository**

Push this folder to GitHub or GitLab, then in Cloudflare **Workers & Pages** → **Create** →
**Pages** → **Connect to Git**. Settings: framework preset **None**, build command
**empty**, build output directory **`site`**. Every push redeploys. Run
`python build_site.py` and commit before pushing so the downloads are up to date.

`site/_headers` sets basic security headers, and makes `.sql` files open as plain text
when someone opens one in a new tab.
