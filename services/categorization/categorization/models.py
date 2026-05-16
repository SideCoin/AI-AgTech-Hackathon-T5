"""Pydantic models matching PLAN.md's on-disk schema.

The iOS capture pipeline writes each observation as a sibling pair on disk:

    Documents/sessions/<sessionID>/
        session.json          # SessionManifest
        <uuid>.json           # Observation (no `photoData` field on disk)
        <uuid>.jpg            # captured photo, untouched by this service
        categories.json       # produced here: { label: [uuid, ...] }

This Python prototype only needs the metadata to classify the `note` text,
so the JPEG side is left alone.
"""

from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class Observation(BaseModel):
    """One field observation captured by the user.

    Mirrors the Swift `Observation` struct defined in PLAN.md §"Shared Data
    Model". Field names match the Swift side exactly so JSON written by either
    runtime is mutually readable.
    """

    # `populate_by_name=True` lets us accept either field aliases or canonical
    # names; harmless safety for cross-language interop.
    model_config = ConfigDict(populate_by_name=True)

    id: UUID = Field(..., description="Stable unique id, also used as the JSON/JPEG filename.")
    note: str = Field(default="", description="Voice-transcribed note; empty string on silence.")
    latitude: float = Field(..., description="WGS-84 latitude at capture time.")
    longitude: float = Field(..., description="WGS-84 longitude at capture time.")
    timestamp: datetime = Field(..., description="Capture timestamp (ISO-8601).")
    category: Optional[str] = Field(
        default=None,
        description="Canonical category label. None until this service writes it back.",
    )


class SessionManifest(BaseModel):
    """Top-level metadata for the whole capture session.

    Written by Part 1 (capture). This service only reads it; never modifies it.
    """

    sessionID: str
    start: datetime
    end: Optional[datetime] = None


class CategorizedItem(BaseModel):
    """Bookkeeping record produced internally during one categorization run.

    Carries both the raw label Gemini returned and the canonical label we
    resolved it to — useful for logging and for debugging fuzzy-match misses.
    """

    observation_id: UUID
    raw_label: str
    canonical_label: str
