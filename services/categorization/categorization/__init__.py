"""Agriculture-aware categorization service backed by Google Gemini.

Public surface:
    categorize(session_dir, db_path=...) — full pipeline entry point
    Taxonomy(db_path)                    — direct access to the master taxonomy
    GeminiClassifier(...)                — lower-level model wrapper

See README.md for usage examples and PLAN.md §Part 2 for the data contract.
"""

from .gemini_client import GeminiClassifier
from .service import categorize
from .taxonomy import Taxonomy

__all__ = ["categorize", "GeminiClassifier", "Taxonomy"]
__version__ = "0.1.0"
