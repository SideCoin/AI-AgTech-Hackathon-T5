"""Generate a static mock session folder for testing.

Run once to (re)create tests/fixtures/sample_session/:

    python tests/fixtures/gen_sample_session.py

Uses only stdlib — no package dependencies required.
The generated files are committed to the repo so tests don't need to re-run this.
"""

import json
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

SESSION_DIR = Path(__file__).parent / "sample_session"

SESSION_ID = "test-session-2026-05-16"
SESSION_START = datetime(2026, 5, 16, 9, 0, 0, tzinfo=timezone.utc)

# Realistic field observations: (note, lat, lon, minutes_after_start)
OBSERVATIONS = [
    ("White powdery coating on lower leaves of row 4", 38.5382, -121.7617, 3),
    ("Clusters of small green insects on new growth tips", 38.5384, -121.7615, 8),
    ("Yellow and brown spots on leaf margins, spreading", 38.5386, -121.7613, 14),
    ("Plant wilting despite soil looking moist", 38.5388, -121.7611, 20),
    ("Drip emitter blocked on row 3, pooling water nearby", 38.5390, -121.7609, 27),
    ("Pale yellow striping between leaf veins on several plants", 38.5392, -121.7607, 33),
    ("", 38.5394, -121.7605, 39),  # silent capture — no voice note
]

# Stable UUIDs so the fixture is deterministic across runs
_UUIDS = [
    uuid.UUID("11111111-0001-0001-0001-000000000001"),
    uuid.UUID("11111111-0002-0002-0002-000000000002"),
    uuid.UUID("11111111-0003-0003-0003-000000000003"),
    uuid.UUID("11111111-0004-0004-0004-000000000004"),
    uuid.UUID("11111111-0005-0005-0005-000000000005"),
    uuid.UUID("11111111-0006-0006-0006-000000000006"),
    uuid.UUID("11111111-0007-0007-0007-000000000007"),
]


def _iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def generate(out_dir: Path = SESSION_DIR) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    session_end = SESSION_START + timedelta(minutes=45)
    (out_dir / "session.json").write_text(
        json.dumps(
            {"sessionID": SESSION_ID, "start": _iso(SESSION_START), "end": _iso(session_end)},
            indent=2,
        )
    )

    for obs_uuid, (note, lat, lon, mins) in zip(_UUIDS, OBSERVATIONS):
        ts = SESSION_START + timedelta(minutes=mins)
        obs = {
            "id": str(obs_uuid),
            "note": note,
            "latitude": lat,
            "longitude": lon,
            "timestamp": _iso(ts),
            "category": None,
        }
        (out_dir / f"{obs_uuid}.json").write_text(json.dumps(obs, indent=2))

    print(f"Generated {len(OBSERVATIONS)} observations in {out_dir}")


if __name__ == "__main__":
    generate()
