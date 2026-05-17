"""Main categorization pipeline.

Public entry point: ``categorize(session_dir, db_path=...)``.

Pipeline:
    1. Scan *session_dir* for ``<uuid>.json`` observation files.
    2. Send all observations to Gemini in one batched call.
    3. Resolve each raw label through the Taxonomy (fuzzy dedup + persistence).
    4. Write the ``category`` field back into every ``<uuid>.json``.
    5. Write ``categories.json`` mapping canonical labels to observation IDs.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from uuid import UUID

from dotenv import load_dotenv

from .gemini_client import GeminiClassifier
from .models import Observation
from .taxonomy import Taxonomy

load_dotenv()

_DEFAULT_DB = Path(os.environ.get("TAXONOMY_DB_PATH", "./taxonomy.db"))


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _load_observations(session_dir: Path) -> list[Observation]:
    """Read all ``<uuid>.json`` files from *session_dir*, skipping manifest files."""
    obs_list: list[Observation] = []
    for json_path in sorted(session_dir.glob("*.json")):
        if json_path.stem in ("session", "categories"):
            continue
        try:
            UUID(json_path.stem)
        except ValueError:
            continue
        obs_list.append(Observation.model_validate(json.loads(json_path.read_text())))
    return obs_list


def _write_observation_back(session_dir: Path, obs: Observation) -> None:
    """Patch the ``category`` field into the on-disk ``<uuid>.json``."""
    json_path = session_dir / f"{obs.id}.json"
    data = json.loads(json_path.read_text())
    data["category"] = obs.category
    json_path.write_text(json.dumps(data, indent=2, ensure_ascii=False))


def _write_categories_json(session_dir: Path, observations: list[Observation]) -> None:
    """Write ``categories.json``: ``{ label: [uuid, ...] }``."""
    index: dict[str, list[str]] = {}
    for obs in observations:
        if obs.category:
            index.setdefault(obs.category, []).append(str(obs.id))
    (session_dir / "categories.json").write_text(
        json.dumps(index, indent=2, ensure_ascii=False)
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def categorize(
    session_dir: Path | str,
    db_path: Path | str = _DEFAULT_DB,
    *,
    api_key: str | None = None,
    model: str | None = None,
) -> dict[str, list[str]]:
    """Categorize all observations in *session_dir* and write results back.

    Args:
        session_dir: path to the session folder.  Must contain at least one
            ``<uuid>.json`` observation file.
        db_path: SQLite taxonomy DB path.  Created automatically on first run.
        api_key: Gemini API key (overrides ``GEMINI_API_KEY`` env var).
        model: model ID override (overrides ``GEMINI_MODEL`` env var).

    Returns:
        The ``{ label: [uuid, ...] }`` mapping written to ``categories.json``.

    Raises:
        ValueError: if no observations are found in *session_dir*.
    """
    session_dir = Path(session_dir)
    db_path = Path(db_path)

    observations = _load_observations(session_dir)
    if not observations:
        raise ValueError(f"No observations found in {session_dir}")

    with Taxonomy(db_path) as taxonomy:
        classifier = GeminiClassifier(api_key=api_key, model=model)
        raw_map = classifier.classify(
            observations,
            existing_labels=taxonomy.all_labels(),
            session_dir=session_dir,
        )

        for obs in observations:
            raw_label = raw_map.get(str(obs.id), "uncategorized")
            obs.category = taxonomy.find_or_create(raw_label)

        for obs in observations:
            _write_observation_back(session_dir, obs)

        _write_categories_json(session_dir, observations)

    return _rebuild_index(observations)


def _rebuild_index(observations: list[Observation]) -> dict[str, list[str]]:
    index: dict[str, list[str]] = {}
    for obs in observations:
        if obs.category:
            index.setdefault(obs.category, []).append(str(obs.id))
    return index
