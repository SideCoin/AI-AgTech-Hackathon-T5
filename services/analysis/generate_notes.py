"""Generate categorized farm notes and overwrite the note column in the CSV.

Each row is assigned a target category; Gemini generates a realistic note
that naturally contains the category's trigger keywords.

Usage:
    cd services/analysis
    python generate_notes.py
"""

from __future__ import annotations

import csv
import os
from pathlib import Path

from dotenv import load_dotenv
from google import genai
from google.genai import types

load_dotenv()

CSV_PATH = Path(__file__).parent / "my_session/poultry_raw_notes_10_rows_llm_ready.csv"

# (csv_id, category_label, keywords_to_include)
ASSIGNMENTS: list[tuple[str, str, list[str]]] = [
    ("1",  "Livestock observation",     ["chicken", "sick"]),
    ("2",  "Livestock observation",     ["livestock", "sick"]),
    ("3",  "Irrigation issue",          ["water", "leak"]),
    ("4",  "Irrigation issue",          ["irrigation", "pressure"]),
    ("5",  "Crop disease / pest issue", ["disease", "infection"]),
    ("6",  "Crop disease / pest issue", ["pest", "mold"]),
    ("7",  "Equipment issue",           ["equipment", "broken"]),
    ("8",  "Equipment issue",           ["repair", "tractor"]),
    ("9",  "Pesticide observation",     ["pesticide", "spray"]),
    ("10", "Fertilizer observation",    ["fertilizer", "nitrogen"]),
]


def generate_note(
    client: genai.Client,
    model: str,
    category: str,
    keywords: list[str],
    original: str,
) -> str:
    prompt = (
        f"You are a farm worker writing a brief field observation note.\n"
        f"Target category: {category}\n"
        f"You MUST naturally include ALL of these words: {', '.join(keywords)}\n"
        f"Style: 1-2 sentences, first-person, specific and realistic farm language.\n"
        f"Original note for context only (do NOT copy it): {original}\n"
        f"Write only the note text — no quotes, no labels, no extra commentary."
    )
    response = client.models.generate_content(
        model=model,
        contents=prompt,
        config=types.GenerateContentConfig(temperature=0.7),
    )
    return response.text.strip()


def main() -> None:
    api_key = os.environ["GEMINI_API_KEY"]
    model = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
    client = genai.Client(api_key=api_key)

    with CSV_PATH.open(newline="") as f:
        rows = list(csv.DictReader(f))

    id_to_row = {r["id"]: r for r in rows}
    assignment_map = {csv_id: (cat, kw) for csv_id, cat, kw in ASSIGNMENTS}

    for csv_id, (category, keywords) in assignment_map.items():
        row = id_to_row.get(csv_id)
        if row is None:
            print(f"  [!] id={csv_id} not found in CSV, skipping")
            continue
        original = row["note"]
        print(f"  [{csv_id}] {category} — generating …")
        new_note = generate_note(client, model, category, keywords, original)
        row["note"] = new_note
        print(f"       → {new_note}")

    fieldnames = list(rows[0].keys())
    with CSV_PATH.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nDone — updated {CSV_PATH}")


if __name__ == "__main__":
    main()
