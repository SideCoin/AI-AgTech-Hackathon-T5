"""Load observations and session manifest from a flat CSV file."""

from __future__ import annotations

import csv
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

from .models import Observation, SessionManifest


def load_from_csv(
    csv_path: Path,
    jpg_dir: Path,
) -> tuple[list[Observation], SessionManifest, dict[str, Path]]:
    """Parse CSV rows into Observations, a synthetic SessionManifest, and an image map.

    The CSV must have columns: time, gps_lat, gps_lng, note, jpg_name.
    time format: %m/%d/%Y %H:%M

    Returns:
        (observations, manifest, image_map)
        image_map: str(obs.id) → absolute jpg Path, only for rows where jpg exists.
    """
    observations: list[Observation] = []
    image_map: dict[str, Path] = {}

    with csv_path.open(newline="") as f:
        rows = list(csv.DictReader(f))

    for row in rows:
        obs_id = uuid.uuid4()
        ts = datetime.strptime(row["time"], "%m/%d/%Y %H:%M").replace(
            tzinfo=timezone.utc
        )
        obs = Observation(
            id=obs_id,
            note=row.get("note", ""),
            latitude=float(row["gps_lat"]),
            longitude=float(row["gps_lng"]),
            timestamp=ts,
        )
        observations.append(obs)

        jpg_name = row.get("jpg_name", "").strip()
        if jpg_name:
            jpg_path = jpg_dir / jpg_name
            if jpg_path.exists():
                image_map[str(obs_id)] = jpg_path

    start = min(o.timestamp for o in observations)
    end = max(o.timestamp for o in observations)
    manifest = SessionManifest(
        sessionID=csv_path.stem,
        start=start,
        end=end,
    )
    return observations, manifest, image_map


def iter_rows(
    csv_path: Path,
    jpg_dir: Path,
) -> Iterator[tuple[str, Observation, str, Path | None]]:
    """Yield (csv_id, observation, jpg_name, jpg_path_or_None) one row at a time.

    Allows per-row processing without loading all rows into memory first.
    """
    with csv_path.open(newline="") as f:
        for row in csv.DictReader(f):
            obs_id = uuid.uuid4()
            ts = datetime.strptime(row["time"], "%m/%d/%Y %H:%M").replace(
                tzinfo=timezone.utc
            )
            obs = Observation(
                id=obs_id,
                note=row.get("note", ""),
                latitude=float(row["gps_lat"]),
                longitude=float(row["gps_lng"]),
                timestamp=ts,
            )
            jpg_name = row.get("jpg_name", "").strip()
            jpg_path: Path | None = None
            if jpg_name:
                candidate = jpg_dir / jpg_name
                if candidate.exists():
                    jpg_path = candidate
            yield row["id"], obs, jpg_name, jpg_path
