"""SQLite-backed master taxonomy of agronomic categories.

The taxonomy is shared across every session. Each new canonical label minted
by the service appears as a row in ``categories``; observed aliases (raw
strings Gemini emitted that resolved to an existing canonical via fuzzy match)
are cached in ``aliases`` so identical inputs short-circuit the rapidfuzz pass
on later runs.

Schema:

    categories
        id INTEGER PK
        label TEXT UNIQUE          -- canonical, already cleaned
        first_seen TEXT            -- ISO-8601 UTC
        usage_count INTEGER        -- bumped on every reuse

    aliases
        alias TEXT PK              -- already cleaned
        category_id INTEGER FK -> categories.id

The DB grows monotonically; ``reset-db`` in the CLI is the only built-in path
to drop state, and it requires confirmation.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .normalize import canonicalize, clean

# DDL executed at construction time. ``IF NOT EXISTS`` keeps repeated opens cheap.
_SCHEMA = """
CREATE TABLE IF NOT EXISTS categories (
    id           INTEGER PRIMARY KEY,
    label        TEXT NOT NULL UNIQUE,
    first_seen   TEXT NOT NULL,
    usage_count  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS aliases (
    alias        TEXT PRIMARY KEY,
    category_id  INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_categories_usage
    ON categories (usage_count DESC, label ASC);
"""


class Taxonomy:
    """Thin wrapper around a SQLite file holding the canonical category list.

    Use as a context manager for automatic close:

        with Taxonomy("./taxonomy.db") as tax:
            tax.find_or_create("aphid damage")

    Pass ``":memory:"`` for a transient DB (tests).
    """

    def __init__(self, db_path: Path | str):
        # ``isolation_level=None`` enables implicit autocommit, which suits
        # this service's low write volume and avoids surprise lock-holds
        # when the CLI exits.
        self.conn = sqlite3.connect(str(db_path), isolation_level=None)
        self.conn.execute("PRAGMA foreign_keys = ON;")
        self.conn.executescript(_SCHEMA)

    # ----- context manager plumbing ----------------------------------------

    def __enter__(self) -> "Taxonomy":
        return self

    def __exit__(self, *_exc_info) -> None:
        self.close()

    def close(self) -> None:
        self.conn.close()

    # ----- public API ------------------------------------------------------

    def all_labels(self) -> list[str]:
        """Every canonical label, sorted by descending usage then alphabetically.

        Used by the prompt builder so that the most-used labels appear first
        in the "Known labels" block sent to Gemini.
        """
        rows = self.conn.execute(
            "SELECT label FROM categories ORDER BY usage_count DESC, label ASC"
        ).fetchall()
        return [r[0] for r in rows]

    def find_or_create(self, raw_label: str) -> str:
        """Resolve ``raw_label`` to a canonical label, creating one if needed.

        Resolution order:
            1. ``clean(raw_label)``.
            2. Direct alias hit (cached from a previous fuzzy match).
            3. Fuzzy match against existing canonicals (see ``normalize``).
            4. Mint a brand-new canonical.

        In all cases the canonical's ``usage_count`` is bumped by one.

        Returns:
            The canonical label callers should attach to the observation.
        """
        cleaned = clean(raw_label)

        # 2. Alias short-circuit — cheaper than running rapidfuzz again.
        row = self.conn.execute(
            "SELECT c.label "
            "FROM aliases a JOIN categories c ON c.id = a.category_id "
            "WHERE a.alias = ?",
            (cleaned,),
        ).fetchone()
        if row is not None:
            self._bump_usage(row[0])
            return row[0]

        # 3. Fuzzy match against the current taxonomy.
        existing = self.all_labels()
        canonical, matched = canonicalize(cleaned, existing)

        if matched is None:
            # 4. Brand-new label. Insert with usage_count=1 so we don't have to
            #    bump again right after.
            self.conn.execute(
                "INSERT INTO categories (label, first_seen, usage_count) "
                "VALUES (?, ?, 1)",
                (canonical, datetime.now(timezone.utc).isoformat()),
            )
        else:
            # Cache this exact alias for next time, then bump the canonical's count.
            self.add_alias(cleaned, matched)
            self._bump_usage(matched)

        return canonical

    def add_alias(self, alias: str, canonical: str) -> None:
        """Register ``alias`` as an explicit synonym for ``canonical``.

        No-op when alias and canonical match exactly (the canonical itself
        doesn't need an alias entry). Raises ``KeyError`` if ``canonical``
        isn't in the taxonomy yet.
        """
        if alias == canonical:
            return
        row = self.conn.execute(
            "SELECT id FROM categories WHERE label = ?", (canonical,)
        ).fetchone()
        if row is None:
            raise KeyError(f"unknown canonical label: {canonical!r}")
        # INSERT OR IGNORE handles the race where the same alias is added twice
        # within a single run.
        self.conn.execute(
            "INSERT OR IGNORE INTO aliases (alias, category_id) VALUES (?, ?)",
            (alias, row[0]),
        )

    def usage_count(self, label: str) -> int:
        """Return how many times ``label`` has been resolved to. Zero if unknown."""
        row = self.conn.execute(
            "SELECT usage_count FROM categories WHERE label = ?", (label,)
        ).fetchone()
        return 0 if row is None else int(row[0])

    def summary(self) -> list[tuple[str, int, str]]:
        """For the CLI ``list-categories`` command.

        Returns rows of ``(label, usage_count, first_seen)`` sorted by
        descending usage then alphabetical.
        """
        return list(
            self.conn.execute(
                "SELECT label, usage_count, first_seen FROM categories "
                "ORDER BY usage_count DESC, label ASC"
            ).fetchall()
        )

    # ----- internals -------------------------------------------------------

    def _bump_usage(self, label: str) -> None:
        """Increment ``usage_count`` for ``label`` by one. Silent if missing."""
        self.conn.execute(
            "UPDATE categories SET usage_count = usage_count + 1 WHERE label = ?",
            (label,),
        )
