import subprocess
import csv
from pathlib import Path

SESSION_DIR = Path(__file__).parent / "my_session"
OUTPUT_DIR = SESSION_DIR / "jpg"
CSV_PATH = SESSION_DIR / "images.csv"

OUTPUT_DIR.mkdir(exist_ok=True)

heic_files = sorted(SESSION_DIR.glob("*.HEIC"))

rows = []
for heic in heic_files:
    jpg_name = heic.stem + ".jpg"
    jpg_path = OUTPUT_DIR / jpg_name
    subprocess.run(
        ["sips", "-s", "format", "jpeg", str(heic), "--out", str(jpg_path)],
        check=True,
        capture_output=True,
    )
    print(f"Converted {heic.name} -> jpg/{jpg_name}")
    rows.append({"heic_name": heic.name, "jpg_name": jpg_name})

with open(CSV_PATH, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["heic_name", "jpg_name"])
    writer.writeheader()
    writer.writerows(rows)

print(f"\nWrote {len(rows)} entries to {CSV_PATH}")
