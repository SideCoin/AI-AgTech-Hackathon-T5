"""Group per-row analysis results into categories using keyword rules.

Reads:  results/poultry_raw_notes_10_rows_llm_ready.json  (flat list)
Writes: results/poultry_raw_notes_10_rows_categorized.json (grouped by category)

Usage:
    cd services/analysis
    python categorize_results.py
"""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

INPUT_PATH = Path(__file__).parent / "results/poultry_raw_notes_10_rows_llm_ready.json"
OUTPUT_PATH = Path(__file__).parent / "results/poultry_raw_notes_10_rows_categorized.json"

# Rules applied in order; first match wins. Keywords checked against note.lower().
RULES: list[tuple[str, str, list[str]]] = [
    ("Crop disease / pest issue",  "High",   ["fungal", "disease", "infection", "mold", "pest"]),
    ("Pesticide observation",      "High",   ["pesticide", "herbicide", "insecticide", "spray"]),
    ("Fertilizer observation",     "Medium", ["fertilizer", "nitrogen", "phosphorus", "potassium", "npk"]),
    ("Irrigation issue",           "High",   ["irrigation", "water", "leak", "pressure"]),
    ("Livestock observation",      "High",   ["cow", "chicken", "pig", "goat", "sheep", "livestock", "sick"]),
    ("Equipment issue",            "Medium", ["broken", "repair", "equipment", "tractor"]),
    ("General farm note",          "Low",    []),
]


def categorize(note: str) -> tuple[str, str]:
    lower = note.lower()
    for label, priority, keywords in RULES:
        if not keywords or any(w in lower for w in keywords):
            return label, priority
    return "General farm note", "Low"


def main() -> None:
    records: list[dict] = json.loads(INPUT_PATH.read_text())

    # Group records; preserve rule order in output
    groups: dict[str, list[dict]] = defaultdict(list)
    priority_of: dict[str, str] = {}

    for rec in records:
        label, priority = categorize(rec.get("note", ""))
        groups[label].append(rec)
        priority_of[label] = priority

    # Build output in rule order, skip empty categories
    rule_order = [label for label, _, _ in RULES]
    output = [
        {
            "category": label,
            "priority": priority_of[label],
            "items": groups[label],
        }
        for label in rule_order
        if label in groups
    ]

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(output, indent=2, ensure_ascii=False))

    print(f"Categorized {len(records)} records into {len(output)} groups:")
    for group in output:
        print(f"  [{group['priority']:6}] {group['category']}: {len(group['items'])} item(s)")
    print(f"\nOutput: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
