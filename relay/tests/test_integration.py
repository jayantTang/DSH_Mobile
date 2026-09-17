"""Pytest wrapper around the full middle-tier integration run.

The scenario itself lives in :mod:`integration_e2e` and needs a *real* local DSH
instance plus Node, so it is opt-in:

    DSH_E2E=1 relay/.venv/bin/python -m pytest relay/tests/test_integration.py -q

The direct one-command form is:

    relay/.venv/bin/python relay/tests/integration_e2e.py
"""

from __future__ import annotations

import os

import pytest

from integration_e2e import run_integration

pytestmark = pytest.mark.skipif(
    os.environ.get("DSH_E2E") != "1",
    reason="set DSH_E2E=1 to run the end-to-end test against the local DSH instance on 127.0.0.1:54499",
)


async def test_middle_tier_end_to_end():
    result = await run_integration()
    assert result["sessions"] > 0
    assert result["deviceId"].startswith("dev_")
    assert len(set(result["clientIds"])) == 2
