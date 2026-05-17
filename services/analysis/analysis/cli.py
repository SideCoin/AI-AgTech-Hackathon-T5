"""Command-line interface for the analysis service.

Commands:
    generate <session_dir>       Analyse a session and write session_output.json.
    generate-csv --csv --jpg-dir --results-dir   Analyse a CSV session with JPG images.
    show <session_dir>           Pretty-print an existing session_output.json.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()


def _cmd_generate(args: argparse.Namespace) -> int:
    from .service import analyze

    session_dir = Path(args.session_dir)
    if not session_dir.is_dir():
        print(f"error: '{session_dir}' is not a directory", file=sys.stderr)
        return 1

    print(f"Analysing {session_dir} …")
    try:
        report = analyze(session_dir)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(f"\n{'─'*60}")
    imp_icon = {"low": "🟢", "medium": "🟡", "high": "🔴"}.get(report.importance, "•")
    print(f"Session    : {report.session_id}")
    print(f"Date       : {report.date}  |  {report.time_range}")
    print(f"Location   : {report.location.context}")
    print(f"GPS        : lat {report.location.latitude_range}  lon {report.location.longitude_range}")
    print(f"Importance : {imp_icon} {report.importance.upper()}")
    print(f"\nSummary : {report.executive_summary}")
    print(f"\nKeynotes ({len(report.keynotes)}):")
    for k in report.keynotes:
        print(f"  • {k}")
    print(f"\nProblems found ({len(report.problems_found)}):")
    for p in report.problems_found:
        print(f"  • {p}")
    print(f"\nAction items ({len(report.action_items)}):")
    for i, a in enumerate(report.action_items, 1):
        print(f"  {i}. {a}")
    print(f"\nObservation details:")
    for obs in report.observations:
        sev_icon = {"low": "🟢", "medium": "🟡", "high": "🔴"}.get(obs.severity, "•")
        print(f"  {sev_icon} [{obs.date} {obs.time}] [{obs.severity.upper()}] {obs.problem}")
        if obs.image_report and obs.image_report != "(no image)":
            print(f"     📷 {obs.image_report}")
        print(f"     → {obs.recommendation}")
    print(f"{'─'*60}")
    print(f"\nOutput: {session_dir / 'session_output.json'}")
    return 0


def _cmd_generate_csv(args: argparse.Namespace) -> int:
    from .service import analyze_csv

    csv_path = Path(args.csv)
    jpg_dir = Path(args.jpg_dir)
    results_dir = Path(args.results_dir)

    if not csv_path.is_file():
        print(f"error: '{csv_path}' is not a file", file=sys.stderr)
        return 1
    if not jpg_dir.is_dir():
        print(f"error: '{jpg_dir}' is not a directory", file=sys.stderr)
        return 1

    print(f"Analysing {csv_path.name} with images from {jpg_dir} …")
    try:
        results = analyze_csv(csv_path, jpg_dir, results_dir)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    output = results_dir / f"{csv_path.stem}.json"
    print(f"\n{'─'*60}")
    print(f"Total observations: {len(results)}")
    for row in results:
        imp_icon = {"low": "🟢", "medium": "🟡", "high": "🔴"}.get(row["importance"], "•")
        print(f"\n  {imp_icon} [{row['id']}] {row['date']} {row['time']}  {row['image_name']}")
        print(f"     Importance : {row['importance'].upper()}")
        for k in row.get("keynotes", []):
            print(f"     • {k}")
        if row.get("image_report") and row["image_report"] != "(no image)":
            print(f"     📷 {row['image_report']}")
        print(f"     Note: {row['note']}")
    print(f"{'─'*60}")
    print(f"\nOutput: {output}")
    return 0


def _cmd_show(args: argparse.Namespace) -> int:
    report_path = Path(args.session_dir) / "session_output.json"
    if not report_path.exists():
        print(f"error: no session_output.json found in '{args.session_dir}'", file=sys.stderr)
        print("Run 'analysis generate <session_dir>' first.", file=sys.stderr)
        return 1

    data = json.loads(report_path.read_text())
    print(json.dumps(data, indent=2, ensure_ascii=False))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="analysis",
        description="FarmNote analysis service — generate unified field reports via Gemini.",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    gen_p = sub.add_parser("generate", help="analyse a session folder and write session_output.json")
    gen_p.add_argument("session_dir", help="path to the session folder")

    show_p = sub.add_parser("show", help="pretty-print an existing session_output.json")
    show_p.add_argument("session_dir", help="path to the session folder")

    csv_p = sub.add_parser("generate-csv", help="analyse a CSV session file with JPG images")
    csv_p.add_argument("--csv", required=True, help="path to the CSV file")
    csv_p.add_argument("--jpg-dir", required=True, help="directory containing JPG images")
    csv_p.add_argument(
        "--results-dir",
        default="results",
        help="output directory for JSON results (default: results/)",
    )

    args = parser.parse_args()

    return {
        "generate": _cmd_generate,
        "generate-csv": _cmd_generate_csv,
        "show": _cmd_show,
    }[args.command](args)
