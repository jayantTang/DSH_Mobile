"""Shared fixtures: put the relay package on ``sys.path`` and build a test app."""

from __future__ import annotations

import pathlib
import sys
from typing import AsyncIterator

import pytest

RELAY_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
for entry in (str(RELAY_DIR), str(TESTS_DIR)):
    if entry not in sys.path:
        sys.path.insert(0, entry)

import relay as relay_module  # noqa: E402
from hub import Limits  # noqa: E402
from store import Store  # noqa: E402


@pytest.fixture
def store(tmp_path) -> AsyncIterator[Store]:
    instance = Store(str(tmp_path / "state.db"))
    try:
        yield instance
    finally:
        instance.close()


@pytest.fixture
def provisioned(store: Store) -> dict:
    """An account with one registered agent, plus a fresh pairing code."""
    account = store.create_account("test account")
    agent = store.register_agent(account["accountId"], "test mac")
    code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    return {"account": account, "agent": agent, "code": code}


@pytest.fixture
async def client(aiohttp_client, store: Store):
    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8), pair_ttl_ms=60_000)
    return await aiohttp_client(app)


def agent_headers(agent: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {agent['agentSecret']}"}


def device_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}
