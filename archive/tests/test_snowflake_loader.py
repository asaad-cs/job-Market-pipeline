"""
Unit tests for pipeline/modeling/snowflake_loader.py

Regression coverage for the "nothing to load" return-type bug (README
Known Limitation #10): when every record is a duplicate or rejected,
load_to_snowflake() must return the same (loaded_count, failed) 2-tuple
as the normal path — NOT a bare int — so runner.py's
`loaded_count, failed = load_to_snowflake(...)` unpack never raises
TypeError.

These cases short-circuit before any Snowflake connection is opened
(to_load is empty), so no credentials or mocking are required.
"""

import pytest
from pipeline.modeling.snowflake_loader import load_to_snowflake


def _rec(**overrides):
    rec = {
        "raw_id": "r1",
        "source_name": "techmap",
        "title": "Software Engineer",
        "collected_at": "2026-09-13T00:00:00+00:00",
        "is_duplicate": False,
        "is_rejected": False,
    }
    rec.update(overrides)
    return rec


class TestNothingToLoadReturnShape:
    """The all-duplicate / all-rejected path returns (0, []), not a bare int."""

    def test_all_duplicates_returns_zero_tuple(self):
        # The exact scenario from Limitation #10: a techmap re-run where all
        # 100 records are prior duplicates.
        records = [_rec(raw_id=f"r{i}", is_duplicate=True) for i in range(100)]
        result = load_to_snowflake(records)
        assert result == (0, [])

    def test_all_rejected_returns_zero_tuple(self):
        records = [_rec(raw_id=f"r{i}", is_rejected=True) for i in range(5)]
        assert load_to_snowflake(records) == (0, [])

    def test_empty_input_returns_zero_tuple(self):
        assert load_to_snowflake([]) == (0, [])

    def test_result_is_unpackable_two_tuple(self):
        # This is the exact operation runner.py performs; it must not raise.
        loaded_count, failed = load_to_snowflake([_rec(is_duplicate=True)])
        assert loaded_count == 0
        assert failed == []

    def test_result_is_not_a_bare_int(self):
        result = load_to_snowflake([_rec(is_rejected=True)])
        assert not isinstance(result, int)
        assert isinstance(result, tuple)
        assert len(result) == 2
