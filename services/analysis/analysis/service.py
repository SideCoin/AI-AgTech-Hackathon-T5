"""Main analysis pipeline.

Public entry points:
    analyze(session_dir)         — iOS session folder (session.json + <uuid>.json files)
    analyze_csv(csv, jpg_dir, results_dir) — flat CSV + named JPG directory
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

from dotenv import load_dotenv

from .csv_loader import iter_rows, load_from_csv
from .gemini_client import GeminiAnalyzer
from .models import FieldReport, Observation, ObservationSummary, SessionLocation, SessionManifest

load_dotenv()

_SEVERITY_RANK = {"low": 0, "medium": 1, "high": 2}


def _load_manifest(session_dir: Path) -> SessionManifest:
    return SessionManifest.model_validate(
        json.loads((session_dir / "session.json").read_text())
    )


def _load_observations(session_dir: Path) -> list[Observation]:
    obs_list: list[Observation] = []
    for json_path in sorted(session_dir.glob("*.json")):
        if json_path.stem in ("session", "categories", "report", "session_output"):
            continue
        try:
            UUID(json_path.stem)
        except ValueError:
            continue
        obs_list.append(Observation.model_validate(json.loads(json_path.read_text())))
    return obs_list


def _load_categories(session_dir: Path) -> dict[str, list[str]]:
    """Load categories.json if it exists (written by categorization service)."""
    cat_path = session_dir / "categories.json"
    if cat_path.exists():
        return json.loads(cat_path.read_text())
    return {}


def _compute_importance(obs_summaries: list[dict]) -> str:
    best = 0
    for o in obs_summaries:
        sev = o.get("severity", "low")
        best = max(best, _SEVERITY_RANK.get(sev, 0))
    return ["low", "medium", "high"][best]


def analyze(
    session_dir: Path | str,
    output_path: Path | str | None = None,
    *,
    api_key: str | None = None,
    model: str | None = None,
) -> FieldReport:
    """Analyze a session folder and write the unified session_output.json.

    Args:
        session_dir: path to the session folder.
        output_path: where to write the output. Defaults to
            ``session_dir/session_output.json``.
        api_key: Gemini API key override.
        model: model ID override.

    Returns:
        The validated FieldReport written to disk.

    Raises:
        ValueError: if no observations are found.
        FileNotFoundError: if session.json is missing.
    """
    session_dir = Path(session_dir)
    output_path = Path(output_path) if output_path else session_dir / "session_output.json"

    manifest = _load_manifest(session_dir)
    observations = _load_observations(session_dir)

    if not observations:
        raise ValueError(f"No observations found in {session_dir}")

    analyzer = GeminiAnalyzer(api_key=api_key, model=model)
    raw = analyzer.analyze(observations, manifest, session_dir)

    report = _build_report(observations, manifest, raw, _load_categories(session_dir))
    output_path.write_text(report.model_dump_json(indent=2))
    return report


def _build_report(
    observations: list[Observation],
    manifest: SessionManifest,
    raw: dict,
    categories: dict[str, list[str]],
) -> FieldReport:
    """Shared helper: merge Gemini output + observation metadata into a FieldReport."""
    obs_by_id: dict[str, Observation] = {str(o.id): o for o in observations}

    merged_obs: list[ObservationSummary] = []
    for gemini_obs in raw.get("observations", []):
        uid = gemini_obs.get("observation_id", "")
        src = obs_by_id.get(uid)
        if src is None:
            continue
        merged_obs.append(
            ObservationSummary(
                id=uid,
                date=src.timestamp.strftime("%Y-%m-%d"),
                time=src.timestamp.strftime("%H:%M"),
                latitude=src.latitude,
                longitude=src.longitude,
                note=src.note or "",
                category=src.category,
                image_report=gemini_obs.get("image_report", "(no image)"),
                problem=gemini_obs.get("problem", ""),
                severity=gemini_obs.get("severity", "low"),
                recommendation=gemini_obs.get("recommendation", ""),
            )
        )

    lats = [o.latitude for o in observations]
    lons = [o.longitude for o in observations]
    start = manifest.start.strftime("%H:%M")
    end = manifest.end.strftime("%H:%M") if manifest.end else "?"
    date_str = manifest.start.strftime("%Y-%m-%d")
    time_range = f"{start}–{end} on {date_str}"

    importance = raw.get("importance") or _compute_importance(raw.get("observations", []))
    if importance not in _SEVERITY_RANK:
        importance = _compute_importance(raw.get("observations", []))

    return FieldReport(
        session_id=manifest.sessionID,
        generated_at=datetime.now(timezone.utc),
        date=date_str,
        time_range=time_range,
        location=SessionLocation(
            latitude_range=[min(lats), max(lats)],
            longitude_range=[min(lons), max(lons)],
            context=raw.get("location_summary", ""),
        ),
        importance=importance,
        keynotes=raw.get("keynotes", []),
        executive_summary=raw.get("executive_summary", ""),
        problems_found=raw.get("problems_found", []),
        action_items=raw.get("action_items", []),
        categories=categories,
        total_observations=len(observations),
        observations=merged_obs,
    )


def analyze_csv(
    csv_path: Path | str,
    jpg_dir: Path | str,
    results_dir: Path | str,
    *,
    api_key: str | None = None,
    model: str | None = None,
) -> list[dict]:
    """Analyze each CSV row individually and write a JSON list to results_dir.

    Each row gets its own Gemini call (note + photo). The output is a JSON array
    where every element has: id, date, time, location, importance, keynotes,
    image_name, image_report, note.

    Args:
        csv_path: path to the CSV (columns: id, time, gps_lat, gps_lng, note, jpg_name).
        jpg_dir: directory containing the JPG images referenced by jpg_name.
        results_dir: output directory; JSON written as <csv_stem>.json.
        api_key: Gemini API key override.
        model: model ID override.

    Returns:
        List of per-row result dicts (also written to disk).
    """
    csv_path = Path(csv_path)
    jpg_dir = Path(jpg_dir)
    results_dir = Path(results_dir)
    results_dir.mkdir(parents=True, exist_ok=True)
    output_path = results_dir / f"{csv_path.stem}.json"

    analyzer = GeminiAnalyzer(api_key=api_key, model=model)
    results: list[dict] = []

    for csv_id, obs, jpg_name, jpg_path in iter_rows(csv_path, jpg_dir):
        print(f"  [{csv_id}] {jpg_name} …")
        raw = analyzer.analyze_single(obs, jpg_path)
        results.append({
            "id": csv_id,
            "date": obs.timestamp.strftime("%Y-%m-%d"),
            "time": obs.timestamp.strftime("%H:%M"),
            "location": {
                "latitude": obs.latitude,
                "longitude": obs.longitude,
            },
            "importance": raw.get("importance", "low"),
            "keynotes": raw.get("keynotes", []),
            "image_name": jpg_name,
            "image_report": raw.get("image_report", "(no image)"),
            "note": obs.note,
        })

    output_path.write_text(json.dumps(results, indent=2, ensure_ascii=False))
    return results
