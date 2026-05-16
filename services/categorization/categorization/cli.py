"""Command-line interface for the categorization service.

Commands:
    run <session_dir>    Categorize all observations in a session folder.
    list-categories      Print all canonical labels with usage counts.
    reset-db             Drop the taxonomy DB (asks for confirmation).

Usage:
    python -m categorization run ./path/to/session
    python -m categorization list-categories
    python -m categorization reset-db --db ./taxonomy.db
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

_DEFAULT_DB = Path(os.environ.get("TAXONOMY_DB_PATH", "./taxonomy.db"))


def _cmd_run(args: argparse.Namespace) -> int:
    from .service import categorize

    session_dir = Path(args.session_dir)
    if not session_dir.is_dir():
        print(f"error: '{session_dir}' is not a directory", file=sys.stderr)
        return 1

    print(f"Categorizing {session_dir} …")
    try:
        index = categorize(session_dir, db_path=args.db)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    total = sum(len(ids) for ids in index.values())
    print(f"Done. {len(index)} categories across {total} observations.\n")
    for label, ids in sorted(index.items()):
        print(f"  {label} ({len(ids)})")
    return 0


def _cmd_list(args: argparse.Namespace) -> int:
    from .taxonomy import Taxonomy

    with Taxonomy(args.db) as tax:
        rows = tax.summary()

    if not rows:
        print("(taxonomy is empty)")
        return 0

    print(f"{'Label':<40} {'Uses':>5}  First seen")
    print("-" * 62)
    for label, count, first_seen in rows:
        print(f"{label:<40} {count:>5}  {first_seen[:10]}")
    return 0


def _cmd_reset(args: argparse.Namespace) -> int:
    db = Path(args.db)
    if not db.exists():
        print(f"Taxonomy DB not found: {db}")
        return 0

    answer = input(f"Delete '{db}' and reset all taxonomy? [y/N] ").strip().lower()
    if answer != "y":
        print("Aborted.")
        return 0

    db.unlink()
    print(f"Deleted {db}.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="categorization",
        description="FarmNote categorization service — classify session observations via Gemini.",
    )
    parser.add_argument(
        "--db",
        default=str(_DEFAULT_DB),
        metavar="PATH",
        help="taxonomy SQLite DB path (default: %(default)s)",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    run_p = sub.add_parser("run", help="categorize a session folder")
    run_p.add_argument("session_dir", help="path to the session folder")

    sub.add_parser("list-categories", help="show all canonical labels and usage counts")
    sub.add_parser("reset-db", help="drop the taxonomy DB (prompts for confirmation)")

    args = parser.parse_args()

    dispatch = {
        "run": _cmd_run,
        "list-categories": _cmd_list,
        "reset-db": _cmd_reset,
    }
    return dispatch[args.command](args)
