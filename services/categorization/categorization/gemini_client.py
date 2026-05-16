"""Gemini-backed classifier for batched field observation notes.

Sends all observations in one API call and returns a raw
``{ str(uuid): raw_label }`` dict. The caller (service.py) is responsible
for resolving raw labels through the Taxonomy.

Vision support: when *session_dir* is supplied and a ``<uuid>.jpg`` exists
next to its JSON, the image bytes are included as an inline_data Part so the
model can use the photo alongside the transcribed note.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional

from google import genai
from google.genai import types

from .models import Observation

_SYSTEM_INSTRUCTION = (
    "You are a field scout assistant categorizing agricultural observations. "
    "For each observation assign a 2-4 word lowercase category label describing "
    "what was observed (e.g. 'aphid damage', 'powdery mildew', 'irrigation issue'). "
    "Prefer reusing an existing label when the phenomenon matches. "
    "Return ONLY valid JSON: { \"<uuid>\": \"<category>\", ... }"
)

_KNOWN_LABELS_HEADER = "Known labels (reuse when applicable):\n{known_block}\n\nObservations:"
_NO_LABELS_HEADER = "No known labels yet — mint new ones as needed.\n\nObservations:"
_FOOTER = '\nReturn JSON only: { "<uuid>": "<category>", ... }'


class GeminiClassifier:
    """Thin wrapper around google-genai for batch observation classification.

    Args:
        api_key: Gemini API key. Falls back to ``GEMINI_API_KEY`` env var.
        model: Model ID. Falls back to ``GEMINI_MODEL`` env var or
            ``"gemini-2.5-flash"``.
    """

    def __init__(
        self,
        api_key: Optional[str] = None,
        model: Optional[str] = None,
    ) -> None:
        self.api_key = api_key or os.environ["GEMINI_API_KEY"]
        self.model = model or os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
        self._client = genai.Client(api_key=self.api_key)

    # ------------------------------------------------------------------

    def classify(
        self,
        observations: list[Observation],
        existing_labels: list[str],
        session_dir: Optional[Path] = None,
    ) -> dict[str, str]:
        """Classify a batch of observations in a single Gemini call.

        Args:
            observations: observations to categorize.
            existing_labels: canonical labels already in the taxonomy
                (most-used first). The model is prompted to prefer these.
            session_dir: if given, load ``<uuid>.jpg`` thumbnails for vision.

        Returns:
            ``{ str(obs.id): raw_category_label }`` for every observation.
            Missing IDs default to ``"uncategorized"`` in the caller.
        """
        if not observations:
            return {}

        parts = self._build_parts(observations, existing_labels, session_dir)

        response = self._client.models.generate_content(
            model=self.model,
            contents=[types.Content(role="user", parts=parts)],
            config=types.GenerateContentConfig(
                system_instruction=_SYSTEM_INSTRUCTION,
                response_mime_type="application/json",
                temperature=0.2,
            ),
        )

        return json.loads(response.text.strip())

    # ------------------------------------------------------------------

    def _build_parts(
        self,
        observations: list[Observation],
        existing_labels: list[str],
        session_dir: Optional[Path],
    ) -> list[types.Part]:
        if existing_labels:
            known_block = "\n".join(f"- {lbl}" for lbl in existing_labels[:30])
            header = _KNOWN_LABELS_HEADER.format(known_block=known_block)
        else:
            header = _NO_LABELS_HEADER

        parts: list[types.Part] = [types.Part(text=header)]

        for obs in observations:
            entry_text = json.dumps(
                {"id": str(obs.id), "note": obs.note or "(no note)"},
                ensure_ascii=False,
            )
            parts.append(types.Part(text=entry_text))

            if session_dir is not None:
                jpg_path = session_dir / f"{obs.id}.jpg"
                if jpg_path.exists():
                    parts.append(
                        types.Part(
                            inline_data=types.Blob(
                                mime_type="image/jpeg",
                                data=jpg_path.read_bytes(),
                            )
                        )
                    )

        parts.append(types.Part(text=_FOOTER))
        return parts
