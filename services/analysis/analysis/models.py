"""Pydantic models for the unified session output.

Written to session_output.json by service.analyze().
Consumed by the iOS map view (Part 3) for rich annotation display.
"""

from __future__ import annotations

from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class Observation(BaseModel):
    """Minimal read-only mirror of the iOS Observation struct."""

    id: UUID
    note: str = Field(default="")
    latitude: float
    longitude: float
    timestamp: datetime
    category: Optional[str] = None


class SessionManifest(BaseModel):
    """Top-level session metadata. Written by Part 1; read-only here."""

    sessionID: str
    start: datetime
    end: Optional[datetime] = None


class SessionLocation(BaseModel):
    """GPS bounding box + text description of the field area."""

    latitude_range: list[float] = Field(..., description="[min_lat, max_lat]")
    longitude_range: list[float] = Field(..., description="[min_lon, max_lon]")
    context: str = Field(..., description="Human-readable field description.")


class ObservationSummary(BaseModel):
    """Per-observation analysis result — combines raw capture data with Gemini analysis."""

    id: str = Field(..., description="UUID of the source observation.")
    date: str = Field(..., description="Capture date: YYYY-MM-DD.")
    time: str = Field(..., description="Capture time: HH:MM.")
    latitude: float
    longitude: float
    note: str = Field(default="", description="Original voice-transcribed note.")
    category: Optional[str] = Field(default=None, description="Label from categorization service.")
    image_report: str = Field(
        default="(no image)",
        description="Gemini vision description of the photo, or '(no image)' if no jpg.",
    )
    problem: str = Field(..., description="One-sentence description of what was observed.")
    severity: str = Field(
        ...,
        description="Estimated severity: 'low', 'medium', or 'high'.",
        pattern="^(low|medium|high)$",
    )
    recommendation: str = Field(..., description="Suggested follow-up action.")


class FieldReport(BaseModel):
    """Unified session output combining categorization + analysis.

    Written to session_output.json by service.analyze().
    """

    session_id: str
    generated_at: datetime = Field(
        default_factory=lambda: datetime.utcnow(),
        description="UTC timestamp when this report was generated.",
    )
    date: str = Field(..., description="Session date: YYYY-MM-DD.")
    time_range: str = Field(..., description="Human-readable session time span.")
    location: SessionLocation
    importance: str = Field(
        ...,
        description="Overall session importance: highest severity across all observations.",
        pattern="^(low|medium|high)$",
    )
    keynotes: list[str] = Field(
        default_factory=list,
        description="3-5 short key findings for a quick briefing.",
    )
    executive_summary: str = Field(..., description="2-3 sentence overview for a manager.")
    problems_found: list[str] = Field(
        default_factory=list,
        description="Deduplicated list of distinct problem types found.",
    )
    action_items: list[str] = Field(
        default_factory=list,
        description="Prioritised list of recommended actions.",
    )
    categories: dict[str, list[str]] = Field(
        default_factory=dict,
        description="Category index from categorization service: { label: [uuid, ...] }.",
    )
    total_observations: int
    observations: list[ObservationSummary] = Field(default_factory=list)
