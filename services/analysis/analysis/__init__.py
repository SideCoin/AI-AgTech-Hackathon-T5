"""FarmNote field report generator backed by Google Gemini.

Public surface:
    analyze(session_dir)                          — iOS session folder pipeline
    analyze_csv(csv, jpg_dir, results_dir)        — flat CSV + JPG directory pipeline
    GeminiAnalyzer(...)                           — lower-level model wrapper
"""

from .gemini_client import GeminiAnalyzer
from .service import analyze, analyze_csv

__all__ = ["analyze", "analyze_csv", "GeminiAnalyzer"]
__version__ = "0.1.0"
