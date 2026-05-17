"""Gemini-backed field report analyzer.

analyze()        — batch session call (all observations in one request)
analyze_single() — single-observation call; returns {importance, keynotes, image_report}
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional

from google import genai
from google.genai import types

from .models import Observation, SessionManifest

_SYSTEM_INSTRUCTION = (
    "You are an experienced agricultural field analyst reviewing a farm inspection. "
    "Analyze ALL observations — each includes a voice note and optionally a photo. "
    "Return a single comprehensive JSON field report. Be specific about problems, "
    "GPS locations, and actionable recommendations. "
    "For image_report: describe what you actually see in the photo. "
    "If no photo is provided for an observation, use '(no image)'. "
    "importance must be the highest severity level found across all observations. "
    "Severity and importance must be exactly 'low', 'medium', or 'high'."
)

_SCHEMA_FOOTER = """
Return ONLY valid JSON matching this exact schema — no markdown, no extra keys:
{
  "executive_summary": "<2-3 sentence overview of all findings>",
  "location_summary": "<text description of the field area based on GPS>",
  "importance": "low|medium|high",
  "keynotes": [
    "<short key finding 1>",
    "<short key finding 2>"
  ],
  "problems_found": ["<distinct problem type>", ...],
  "observations": [
    {
      "observation_id": "<uuid>",
      "image_report": "<describe what the photo shows, or '(no image)'>",
      "problem": "<one sentence — what was observed>",
      "severity": "low|medium|high",
      "recommendation": "<specific follow-up action>"
    }
  ],
  "action_items": ["<prioritised action>", ...]
}
"""


class GeminiAnalyzer:
    """Wraps the Gemini API for field report generation.

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

    def analyze(
        self,
        observations: list[Observation],
        manifest: SessionManifest,
        session_dir: Optional[Path] = None,
        image_map: Optional[dict[str, Path]] = None,
    ) -> dict:
        """Run analysis on a full session and return the raw report dict.

        Args:
            observations: all observations from the session.
            manifest: session metadata (ID, start/end times).
            session_dir: if provided, loads ``<uuid>.jpg`` for vision (legacy path).
            image_map: explicit str(obs.id) → Path mapping; takes priority over
                session_dir when provided.

        Returns:
            Raw dict with keys matching the FieldReport schema.
        """
        parts = self._build_parts(observations, manifest, session_dir, image_map)

        response = self._client.models.generate_content(
            model=self.model,
            contents=[types.Content(role="user", parts=parts)],
            config=types.GenerateContentConfig(
                system_instruction=_SYSTEM_INSTRUCTION,
                response_mime_type="application/json",
                temperature=0.3,
            ),
        )

        return json.loads(response.text.strip())

    def _build_parts(
        self,
        observations: list[Observation],
        manifest: SessionManifest,
        session_dir: Optional[Path],
        image_map: Optional[dict[str, Path]] = None,
    ) -> list[types.Part]:
        start_str = manifest.start.strftime("%Y-%m-%d %H:%M UTC")
        end_str = manifest.end.strftime("%H:%M UTC") if manifest.end else "ongoing"
        lats = [o.latitude for o in observations]
        lons = [o.longitude for o in observations]

        header = (
            f"Session ID: {manifest.sessionID}\n"
            f"Date/Time: {start_str} – {end_str}\n"
            f"GPS range: lat {min(lats):.4f}–{max(lats):.4f}, "
            f"lon {min(lons):.4f}–{max(lons):.4f}\n"
            f"Total observations: {len(observations)}\n\n"
            "Observations follow. Each block has JSON metadata; "
            "photos (if any) appear immediately after their metadata block."
        )

        parts: list[types.Part] = [types.Part(text=header)]

        for obs in observations:
            if image_map is not None:
                jpg_path: Optional[Path] = image_map.get(str(obs.id))
                has_image = jpg_path is not None
            else:
                jpg_path = session_dir / f"{obs.id}.jpg" if session_dir else None
                has_image = jpg_path is not None and jpg_path.exists()

            meta = {
                "id": str(obs.id),
                "timestamp": obs.timestamp.isoformat(),
                "latitude": obs.latitude,
                "longitude": obs.longitude,
                "note": obs.note or "(no voice note)",
                "category": obs.category or "(not yet categorised)",
                "has_image": has_image,
            }
            parts.append(types.Part(text=json.dumps(meta, ensure_ascii=False)))

            if has_image:
                parts.append(
                    types.Part(
                        inline_data=types.Blob(
                            mime_type="image/jpeg",
                            data=jpg_path.read_bytes(),
                        )
                    )
                )

        parts.append(types.Part(text=_SCHEMA_FOOTER))
        return parts

    def analyze_single(
        self,
        obs: Observation,
        jpg_path: Optional[Path] = None,
    ) -> dict:
        """Analyze one observation and return {importance, keynotes, image_report}.

        Args:
            obs: a single field observation (note + GPS + timestamp).
            jpg_path: path to the JPG for this observation, or None.

        Returns:
            dict with keys: importance, keynotes, image_report.
        """
        meta = {
            "timestamp": obs.timestamp.isoformat(),
            "latitude": obs.latitude,
            "longitude": obs.longitude,
            "note": obs.note or "(no voice note)",
            "has_image": jpg_path is not None,
        }
        schema = (
            "\nReturn ONLY valid JSON — no markdown, no extra keys:\n"
            '{\n'
            '  "importance": "low|medium|high",\n'
            '  "keynotes": ["<key finding 1>", "<key finding 2>"],\n'
            '  "image_report": "<describe exactly what the photo shows, or \'(no image)\'>"\n'
            '}'
        )
        system = (
            "You are an agricultural field analyst. Analyze one farm inspection observation "
            "which includes a voice note and optionally a photo. "
            "Return JSON with importance ('low', 'medium', or 'high'), keynotes (2-3 short "
            "key findings), and image_report (describe exactly what you see in the photo; "
            "use '(no image)' if no photo is provided)."
        )

        parts: list[types.Part] = [
            types.Part(text=json.dumps(meta, ensure_ascii=False)),
        ]
        if jpg_path is not None:
            parts.append(
                types.Part(
                    inline_data=types.Blob(
                        mime_type="image/jpeg",
                        data=jpg_path.read_bytes(),
                    )
                )
            )
        parts.append(types.Part(text=schema))

        response = self._client.models.generate_content(
            model=self.model,
            contents=[types.Content(role="user", parts=parts)],
            config=types.GenerateContentConfig(
                system_instruction=system,
                response_mime_type="application/json",
                temperature=0.3,
            ),
        )
        return json.loads(response.text.strip())
