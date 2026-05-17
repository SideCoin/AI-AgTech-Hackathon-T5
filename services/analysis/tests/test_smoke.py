"""Offline smoke tests for the unified analysis pipeline.

Monkey-patches GeminiAnalyzer — no network, no API key required.
Run with:  pytest tests/test_smoke.py -v
"""

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

SAMPLE_SESSION = (
    Path(__file__).parent.parent.parent
    / "categorization"
    / "tests"
    / "fixtures"
    / "sample_session"
)

_UUIDS = [
    "11111111-0001-0001-0001-000000000001",
    "11111111-0002-0002-0002-000000000002",
    "11111111-0003-0003-0003-000000000003",
    "11111111-0004-0004-0004-000000000004",
    "11111111-0005-0005-0005-000000000005",
    "11111111-0006-0006-0006-000000000006",
    "11111111-0007-0007-0007-000000000007",
]

_FAKE_RAW = {
    "executive_summary": (
        "Seven observations were recorded across rows 3-7. "
        "The most critical issue is a high-severity aphid infestation requiring immediate action. "
        "A blocked drip emitter on row 3 is causing water pooling and must be cleared promptly."
    ),
    "location_summary": "Agricultural research field, rows 3-7, lat 38.54°N lon 121.76°W.",
    "importance": "high",
    "keynotes": [
        "Aphid infestation on new growth — HIGH severity, treat within 24 h",
        "Blocked drip emitter row 3 causing pooling — clear immediately",
        "Powdery mildew on lower leaves — schedule fungicide application",
    ],
    "problems_found": [
        "powdery mildew", "aphid infestation", "leaf spot disease",
        "plant wilting", "blocked drip emitter", "interveinal chlorosis",
    ],
    "observations": [
        {
            "observation_id": _UUIDS[0],
            "image_report": "White powdery fungal coating on ~30% of lower leaf surface.",
            "problem": "Powdery mildew on lower leaves of row 4.",
            "severity": "medium",
            "recommendation": "Apply fungicide and improve air circulation.",
        },
        {
            "observation_id": _UUIDS[1],
            "image_report": "(no image)",
            "problem": "Dense aphid clusters on new growth tips.",
            "severity": "high",
            "recommendation": "Apply insecticidal soap immediately.",
        },
        {
            "observation_id": _UUIDS[2],
            "image_report": "(no image)",
            "problem": "Leaf spot disease spreading on margins.",
            "severity": "medium",
            "recommendation": "Prune affected leaves and apply fungicide.",
        },
        {
            "observation_id": _UUIDS[3],
            "image_report": "(no image)",
            "problem": "Plant wilting despite moist soil.",
            "severity": "high",
            "recommendation": "Investigate root health for rot or vascular disease.",
        },
        {
            "observation_id": _UUIDS[4],
            "image_report": "(no image)",
            "problem": "Drip emitter blocked on row 3.",
            "severity": "medium",
            "recommendation": "Clear emitter and inspect neighbouring drippers.",
        },
        {
            "observation_id": _UUIDS[5],
            "image_report": "(no image)",
            "problem": "Interveinal chlorosis on several plants.",
            "severity": "medium",
            "recommendation": "Conduct soil test; apply iron or magnesium amendment.",
        },
        {
            "observation_id": _UUIDS[6],
            "image_report": "(no image)",
            "problem": "No voice note — potential issue not documented.",
            "severity": "low",
            "recommendation": "Revisit location to document the observation.",
        },
    ],
    "action_items": [
        "Apply insecticidal soap to aphid-infested plants within 24 hours.",
        "Clear blocked drip emitter on row 3 immediately.",
        "Schedule fungicide treatment for powdery mildew patches.",
        "Conduct soil nutrient test to address interveinal chlorosis.",
    ],
}


@pytest.fixture()
def session_dir(tmp_path):
    import shutil
    dest = tmp_path / "session"
    shutil.copytree(SAMPLE_SESSION, dest)
    return dest


def _mock_analyzer():
    mock = MagicMock()
    mock.analyze.return_value = dict(_FAKE_RAW)
    return mock


class TestPipeline:
    def test_writes_session_output_json(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            analyze(session_dir)
        assert (session_dir / "session_output.json").exists()

    def test_session_id_matches_manifest(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        assert report.session_id == "test-session-2026-05-16"

    def test_total_observations_correct(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        assert report.total_observations == 7

    def test_date_field_populated(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        assert report.date == "2026-05-16"

    def test_location_has_gps_ranges(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        assert len(report.location.latitude_range) == 2
        assert len(report.location.longitude_range) == 2
        assert report.location.latitude_range[0] <= report.location.latitude_range[1]

    def test_importance_is_valid(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        assert report.importance in ("low", "medium", "high")

    def test_keynotes_populated(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        assert len(report.keynotes) > 0

    def test_observations_have_date_time(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        for obs in report.observations:
            assert obs.date == "2026-05-16"
            assert ":" in obs.time

    def test_observations_have_note(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        # First obs has a non-empty note
        first = next(o for o in report.observations if o.id == _UUIDS[0])
        assert len(first.note) > 0

    def test_observations_have_image_report(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        for obs in report.observations:
            assert obs.image_report  # not empty

    def test_categories_merged_from_disk(self, session_dir):
        fake_cats = {"powdery mildew": [_UUIDS[0]], "aphid infestation": [_UUIDS[1]]}
        (session_dir / "categories.json").write_text(json.dumps(fake_cats))
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        assert report.categories == fake_cats

    def test_empty_categories_when_no_file(self, session_dir):
        (session_dir / "categories.json").unlink(missing_ok=True)
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            report = analyze(session_dir)
        assert report.categories == {}

    def test_empty_session_raises(self, tmp_path):
        empty = tmp_path / "empty"
        empty.mkdir()
        (empty / "session.json").write_text(
            '{"sessionID":"x","start":"2026-01-01T00:00:00Z"}'
        )
        with pytest.raises(ValueError, match="No observations"):
            from analysis.service import analyze
            analyze(empty)

    def test_output_json_is_valid(self, session_dir):
        with patch("analysis.service.GeminiAnalyzer", return_value=_mock_analyzer()):
            from analysis.service import analyze
            analyze(session_dir)
        data = json.loads((session_dir / "session_output.json").read_text())
        assert "importance" in data
        assert "keynotes" in data
        assert "categories" in data
        assert "date" in data
        assert "location" in data
        assert "latitude_range" in data["location"]
        obs0 = data["observations"][0]
        assert "image_report" in obs0
        assert "date" in obs0
        assert "time" in obs0
        assert "note" in obs0
