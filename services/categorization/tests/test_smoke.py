"""Offline smoke tests for the categorization pipeline.

Monkey-patches GeminiClassifier so no network call is made.
Run with:  pytest tests/test_smoke.py -v
No GEMINI_API_KEY required.
"""

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

SAMPLE_SESSION = Path(__file__).parent / "fixtures" / "sample_session"

# Stable UUIDs that match gen_sample_session.py
_UUIDS = [
    "11111111-0001-0001-0001-000000000001",
    "11111111-0002-0002-0002-000000000002",
    "11111111-0003-0003-0003-000000000003",
    "11111111-0004-0004-0004-000000000004",
    "11111111-0005-0005-0005-000000000005",
    "11111111-0006-0006-0006-000000000006",
    "11111111-0007-0007-0007-000000000007",
]

# Fake Gemini response: one label per UUID
_FAKE_LABELS = {
    _UUIDS[0]: "powdery mildew",
    _UUIDS[1]: "aphid infestation",
    _UUIDS[2]: "leaf blight",
    _UUIDS[3]: "root rot",
    _UUIDS[4]: "irrigation issue",
    _UUIDS[5]: "nutrient deficiency",
    _UUIDS[6]: "uncategorized",
}


@pytest.fixture()
def clean_session(tmp_path):
    """Copy sample_session into a temp dir so each test gets a fresh copy."""
    import shutil
    session_copy = tmp_path / "session"
    shutil.copytree(SAMPLE_SESSION, session_copy)
    # Reset category fields to None
    for f in session_copy.glob("*.json"):
        if f.stem in ("session", "categories"):
            continue
        data = json.loads(f.read_text())
        data["category"] = None
        f.write_text(json.dumps(data, indent=2))
    return session_copy


def _make_mock_classifier():
    mock = MagicMock()
    mock.classify.return_value = _FAKE_LABELS
    return mock


class TestPipeline:
    def test_loads_all_observations(self, clean_session):
        from categorization.service import _load_observations
        obs = _load_observations(clean_session)
        assert len(obs) == 7

    def test_skips_manifest_files(self, clean_session):
        from categorization.service import _load_observations
        obs = _load_observations(clean_session)
        ids = {str(o.id) for o in obs}
        assert "session" not in ids
        assert "categories" not in ids

    def test_categorize_writes_categories_json(self, clean_session):
        mock_cls = _make_mock_classifier()
        with patch("categorization.service.GeminiClassifier", return_value=mock_cls):
            from categorization.service import categorize
            index = categorize(clean_session, db_path=":memory:")

        categories_path = clean_session / "categories.json"
        assert categories_path.exists(), "categories.json not written"
        on_disk = json.loads(categories_path.read_text())
        assert on_disk == index

    def test_categorize_patches_each_obs_json(self, clean_session):
        mock_cls = _make_mock_classifier()
        with patch("categorization.service.GeminiClassifier", return_value=mock_cls):
            from categorization.service import categorize
            categorize(clean_session, db_path=":memory:")

        for uid in _UUIDS:
            obs_path = clean_session / f"{uid}.json"
            data = json.loads(obs_path.read_text())
            assert data.get("category") is not None, f"{uid}.json missing category"

    def test_index_covers_all_observations(self, clean_session):
        mock_cls = _make_mock_classifier()
        with patch("categorization.service.GeminiClassifier", return_value=mock_cls):
            from categorization.service import categorize
            index = categorize(clean_session, db_path=":memory:")

        total = sum(len(ids) for ids in index.values())
        assert total == 7

    def test_empty_session_raises(self, tmp_path):
        from categorization.service import categorize
        empty = tmp_path / "empty"
        empty.mkdir()
        (empty / "session.json").write_text('{"sessionID":"x","start":"2026-01-01T00:00:00Z"}')
        with pytest.raises(ValueError, match="No observations"):
            categorize(empty, db_path=":memory:")


class TestNormalize:
    def test_clean_lowercases_and_trims(self):
        from categorization.normalize import clean
        assert clean("  Aphid   Damage  ") == "aphid damage"
        assert clean("LEAF RUST") == "leaf rust"

    def test_clean_is_idempotent(self):
        from categorization.normalize import clean
        s = "powdery mildew"
        assert clean(clean(s)) == clean(s)

    def test_canonicalize_merges_near_duplicate(self):
        from categorization.normalize import canonicalize
        canonical, matched = canonicalize("aphid damages", ["aphid damage"])
        assert canonical == "aphid damage"
        assert matched == "aphid damage"

    def test_canonicalize_mints_new_label(self):
        from categorization.normalize import canonicalize
        canonical, matched = canonicalize("stem rust", ["powdery mildew", "aphid damage"])
        assert canonical == "stem rust"
        assert matched is None


class TestTaxonomy:
    def test_find_or_create_new_label(self):
        from categorization.taxonomy import Taxonomy
        with Taxonomy(":memory:") as tax:
            label = tax.find_or_create("aphid damage")
            assert label == "aphid damage"
            assert tax.usage_count("aphid damage") == 1

    def test_find_or_create_reuses_existing(self):
        from categorization.taxonomy import Taxonomy
        with Taxonomy(":memory:") as tax:
            tax.find_or_create("aphid damage")
            label = tax.find_or_create("aphid damages")  # near-duplicate
            assert label == "aphid damage"
            assert tax.usage_count("aphid damage") == 2

    def test_all_labels_sorted_by_usage(self):
        from categorization.taxonomy import Taxonomy
        with Taxonomy(":memory:") as tax:
            tax.find_or_create("powdery mildew")
            tax.find_or_create("aphid damage")
            tax.find_or_create("aphid damage")
            labels = tax.all_labels()
            assert labels[0] == "aphid damage"  # higher usage first
