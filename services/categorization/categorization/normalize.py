"""Label cleaning + fuzzy deduplication.

Gemini occasionally returns slight string variants of the same agronomic
concept ("Aphid Damage" vs "aphid  damage" vs "aphid damages"). We collapse
these to a single canonical form so the taxonomy stays tidy across sessions.

Two layers of defense:
  1. clean() — deterministic normalization (lowercase, trim, collapse spaces).
  2. canonicalize() — rapidfuzz string similarity against the existing
     canonical labels, returning the best match above a threshold.

Semantic deduplication ("aphid damage" vs "aphid infestation") is intentionally
NOT handled here — that's the prompt's job (the system instruction tells Gemini
to prefer existing labels). String-level fuzzy matching is a safety net for
typos, plurals, casing, and whitespace only.
"""

from __future__ import annotations

import re
from typing import Optional

from rapidfuzz import fuzz, process

# Default similarity threshold for treating two labels as synonyms.
# Calibration notes:
#   "aphid damage" vs "aphid damages"   -> ~96  (merged)
#   "aphid damage" vs "damage aphid"    -> 100  (token_sort handles reorder)
#   "powdery mildew" vs "downy mildew"  -> ~70  (kept distinct)
#   "leaf rust" vs "leaf rust"          -> 100
#   "leaf rust" vs "stem rust"          -> ~60  (kept distinct)
DEFAULT_THRESHOLD = 88


# Pattern used by clean() to squash runs of whitespace down to one space.
_WHITESPACE_RE = re.compile(r"\s+")


def clean(raw: str) -> str:
    """Lowercase, trim, and collapse internal whitespace.

    Idempotent: ``clean(clean(x)) == clean(x)`` for every ``x``.

    Args:
        raw: arbitrary label string, possibly with mixed case / extra spaces.

    Returns:
        A canonicalized lowercase string with single spaces between tokens.

    Examples:
        >>> clean("  Aphid   Damage  ")
        'aphid damage'
        >>> clean("LEAF RUST")
        'leaf rust'
    """
    return _WHITESPACE_RE.sub(" ", raw.strip().lower())


def canonicalize(
    raw: str,
    existing: list[str],
    threshold: int = DEFAULT_THRESHOLD,
) -> tuple[str, Optional[str]]:
    """Pick the canonical label for ``raw`` given the current taxonomy.

    The function first applies :func:`clean` defensively. If any existing
    canonical label scores at or above ``threshold`` using rapidfuzz's
    ``token_sort_ratio``, that existing label wins. Otherwise we mint a new
    canonical (the cleaned form of ``raw``).

    Args:
        raw: a label as returned by Gemini (or already cleaned).
        existing: every canonical label currently in the taxonomy DB.
        threshold: rapidfuzz score (0-100) above which we treat ``raw`` as
            a synonym of the closest existing label.

    Returns:
        Tuple ``(canonical, matched)`` where:
            * ``canonical`` is the label callers should use going forward.
            * ``matched`` is the existing label that ``raw`` was merged into,
              or ``None`` when a brand-new label was minted.
    """
    cleaned = clean(raw)

    # Fast path: empty taxonomy — nothing to match against.
    if not existing:
        return cleaned, None

    # token_sort_ratio normalizes word order before comparison, so
    # "spider mite" and "mite spider" score 100.
    match = process.extractOne(
        cleaned,
        existing,
        scorer=fuzz.token_sort_ratio,
        score_cutoff=threshold,
    )
    if match is None:
        return cleaned, None

    matched_label = match[0]
    return matched_label, matched_label
