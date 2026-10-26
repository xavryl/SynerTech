"""Refresh site/downloads from the schema folders.

Run after changing any schema file or the PDF:
    python build_site.py

It copies the SQL files and the PDF into site/downloads, builds the .zip
bundles, and writes site/downloads/manifest.json (file sizes shown on the page).
"""

import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "site" / "downloads"

ENGINES = {
    "sqlite": ["sqlite/schema.sql", "sqlite/example_checkout.sql"],
    "postgresql": ["postgresql/schema.sql", "postgresql/example_checkout.sql"],
    "mysql": ["mysql/schema.sql", "mysql/example_checkout.sql"],
    "supabase": [
        "supabase/migrations/20261026000000_pos_schema.sql",
        "supabase/migrations/20261026000100_auth_and_rls.sql",
    ],
}
PDF = "POS_v1_Database_Design.pdf"


def make_zip(name, paths):
    target = OUT / name
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in paths:
            z.write(ROOT / rel, arcname=f"pos-schemas/{rel}")
    return target


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    manifest = {}
    all_files = []
    for engine, files in ENGINES.items():
        for rel in files:
            src = ROOT / rel
            dst = OUT / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
            text = src.read_text(encoding="utf-8")
            manifest[rel] = {"bytes": dst.stat().st_size, "lines": len(text.splitlines())}
            all_files.append(rel)
        z = make_zip(f"pos-{engine}.zip", files + ["README.md"])
        manifest[z.name] = {"bytes": z.stat().st_size}

    z = make_zip("pos-schemas-all.zip", all_files + ["README.md"])
    manifest[z.name] = {"bytes": z.stat().st_size}

    shutil.copyfile(ROOT / PDF, OUT / PDF)
    manifest[PDF] = {"bytes": (OUT / PDF).stat().st_size}

    (OUT / "manifest.json").write_text(json.dumps({"files": manifest}, indent=2), encoding="utf-8")
    print(f"Wrote {len(manifest)} files to {OUT}")


if __name__ == "__main__":
    main()
