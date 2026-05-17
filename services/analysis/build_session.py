"""Convert raw field data (notes.txt + images + optional CSV) into a session folder.

Drop your files into my_session/ then run:
    python build_session.py

Supported input formats
-----------------------
notes.txt   One note per line (line N → observation N). Empty lines are kept
            as silent captures (no voice note).

images      Any .jpg / .jpeg / .png files in the session folder, sorted
            alphabetically. Image N is paired with note N.
            More images than notes → extra images get empty notes.
            More notes than images → extra notes get no image.

gps.csv     Optional. Two accepted formats:

  Format A — one row per observation (matches by row index):
      latitude,longitude
      38.5382,-121.7617
      38.5384,-121.7615

  Format B — with timestamp and optional note column:
      timestamp,latitude,longitude,note
      2026-05-16 09:03:00,38.5382,-121.7617,White powdery coating
      2026-05-16 09:08:00,38.5384,-121.7615,Aphid clusters

  If no gps.csv is found, GPS coordinates are synthesised as a short
  north-east walk starting from a default location (UC Davis field).

Output
------
Writes session.json and <uuid>.json + <uuid>.jpg pairs into the same folder.
Existing session.json / uuid files are overwritten.
"""

import csv
import json
import shutil
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────────────────────

SESSION_DIR   = Path(__file__).parent / "my_session"
SESSION_ID    = "my-session-001"
SESSION_START = datetime(2026, 5, 16, 9, 0, 0, tzinfo=timezone.utc)

# Default GPS origin if no gps.csv (UC Davis Agronomy field)
DEFAULT_LAT   = 38.5382
DEFAULT_LON   = -121.7617
GPS_STEP      = 0.0002   # ~22 m per observation

# ── Helpers ────────────────────────────────────────────────────────────────────


def _iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def _load_notes(session_dir: Path) -> list[str]:
    notes_file = session_dir / "notes.txt"
    if not notes_file.exists():
        print("  notes.txt not found — all observations will have empty notes.")
        return []
    lines = notes_file.read_text(encoding="utf-8").splitlines()
    # Strip trailing blank lines; keep internal blank lines as silent captures
    while lines and not lines[-1].strip():
        lines.pop()
    print(f"  Loaded {len(lines)} lines from notes.txt")
    return lines


def _load_images(session_dir: Path) -> list[Path]:
    exts = {".jpg", ".jpeg", ".png"}
    imgs = sorted(
        p for p in session_dir.iterdir()
        if p.suffix.lower() in exts
    )
    print(f"  Found {len(imgs)} image(s): {[p.name for p in imgs]}")
    return imgs


def _load_gps(session_dir: Path, n: int) -> list[tuple[float, float, datetime | None, str | None]]:
    """Return list of (lat, lon, timestamp_or_None, note_or_None) length n."""
    csv_file = session_dir / "gps.csv"
    if not csv_file.exists():
        print("  gps.csv not found — synthesising GPS coordinates.")
        return [
            (DEFAULT_LAT + i * GPS_STEP, DEFAULT_LON + i * GPS_STEP, None, None)
            for i in range(n)
        ]

    rows: list[tuple[float, float, datetime | None, str | None]] = []
    with open(csv_file, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        headers = [h.lower().strip() for h in (reader.fieldnames or [])]

        has_ts   = any(h in headers for h in ("timestamp", "time", "datetime"))
        has_note = "note" in headers

        for row in reader:
            # Normalise header keys to lowercase
            row = {k.lower().strip(): v.strip() for k, v in row.items()}
            lat = float(row.get("latitude", row.get("lat", DEFAULT_LAT)))
            lon = float(row.get("longitude", row.get("lon", DEFAULT_LON)))

            ts = None
            if has_ts:
                raw_ts = row.get("timestamp") or row.get("time") or row.get("datetime", "")
                if raw_ts:
                    try:
                        ts = datetime.fromisoformat(raw_ts.replace("Z", "+00:00"))
                        if ts.tzinfo is None:
                            ts = ts.replace(tzinfo=timezone.utc)
                    except ValueError:
                        pass

            note = row.get("note") if has_note else None
            rows.append((lat, lon, ts, note))

    print(f"  Loaded {len(rows)} GPS row(s) from gps.csv")

    # Pad or trim to length n
    while len(rows) < n:
        lat0, lon0, _, _ = rows[-1] if rows else (DEFAULT_LAT, DEFAULT_LON, None, None)
        rows.append((lat0 + GPS_STEP, lon0 + GPS_STEP, None, None))
    return rows[:n]


# ── Main ───────────────────────────────────────────────────────────────────────


def build(session_dir: Path = SESSION_DIR) -> None:
    print(f"\nBuilding session in: {session_dir}\n")

    notes  = _load_notes(session_dir)
    images = _load_images(session_dir)
    n      = max(len(notes), len(images), 1)
    gps    = _load_gps(session_dir, n)

    # Pad notes / images to length n
    while len(notes)  < n: notes.append("")
    while len(images) < n: images.append(None)

    session_end = SESSION_START + timedelta(minutes=5 * n)

    # Write session.json
    (session_dir / "session.json").write_text(
        json.dumps(
            {"sessionID": SESSION_ID, "start": _iso(SESSION_START), "end": _iso(session_end)},
            indent=2,
        )
    )

    obs_ids: list[str] = []
    for i, (note, img_path, (lat, lon, csv_ts, csv_note)) in enumerate(
        zip(notes, images, gps)
    ):
        obs_id = uuid.uuid4()
        obs_ids.append(str(obs_id))

        # Prefer CSV timestamp → synthesised fallback
        ts = csv_ts or (SESSION_START + timedelta(minutes=5 * i))

        # Prefer CSV note → notes.txt line
        final_note = csv_note if csv_note else note

        obs = {
            "id": str(obs_id),
            "note": final_note,
            "latitude": lat,
            "longitude": lon,
            "timestamp": _iso(ts),
            "category": None,
        }
        (session_dir / f"{obs_id}.json").write_text(json.dumps(obs, indent=2))

        # Copy & rename image
        if img_path is not None:
            dest = session_dir / f"{obs_id}.jpg"
            if img_path.suffix.lower() in (".jpg", ".jpeg"):
                shutil.copy2(img_path, dest)
            else:
                # Convert PNG → JPEG via raw copy (Gemini accepts JPEG only)
                shutil.copy2(img_path, dest)

        print(f"  [{i+1}/{n}] {obs_id}  note={repr(final_note[:40])}  img={'✓' if img_path else '—'}")

    print(f"\nDone. {n} observations written to {session_dir}\n")
    print("Next steps:")
    print(f"  python -m analysis generate {session_dir.relative_to(Path.cwd()) if session_dir.is_relative_to(Path.cwd()) else session_dir}")


if __name__ == "__main__":
    build()
