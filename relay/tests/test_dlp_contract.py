"""The DLP wire vectors, shared by all three ends (spec §3).

``test/contract/dlp-vectors.json`` is the single source of truth: the relay (this
file), the connector (``plugins/mobile-link/test/dlp-contract.test.js``) and iOS
(``DSHKit/Tests/DSHKitTests/DLPContractTests.swift``) all read the *same* file.
The contract itself is ``docs/relay-contract.json``.

These assertions pin today's behaviour, drift included: a row whose ``why`` names
a ``knownDrift`` entry is recording a real disagreement, not blessing it.
``scripts/dev/check-contracts.mjs`` (text-level) guards the wiring; this file
guards the behaviour.
"""

from __future__ import annotations

import json
import pathlib

import pytest

import dlp

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT = json.loads((REPO_ROOT / "docs" / "relay-contract.json").read_text("utf-8"))
VECTORS = json.loads(
    (REPO_ROOT / "test" / "contract" / "dlp-vectors.json").read_text("utf-8"))["vectors"]

DRIFT_IDS = sorted(entry["id"] for entry in CONTRACT["knownDrift"])


def frame_for(vector: dict) -> dict:
    """Build the frame the vector describes — including the fields it lacks."""
    frame: dict = {"t": vector["t"]}
    if vector["hasId"]:
        frame["id"] = "stream_1"
    if vector["t"] == "req" and vector["py"] != "error: req: missing `method`":
        frame["method"] = "session/list"
    if vector["t"] == "open" and vector["py"] != "error: open: missing `endpoint`":
        frame["endpoint"] = "$events"
    return frame


def test_the_frame_vocabularies_match_the_contract():
    assert set(dlp.DEVICE_TO_AGENT) == set(CONTRACT["deviceToAgent"])
    assert set(dlp.AGENT_TO_DEVICE) == set(CONTRACT["agentToDevice"])
    assert set(dlp.RELAY_TO_AGENT) == set(CONTRACT["relayControl"])
    # agent 侧控制帧单独一张表：加进 deviceToAgent/agentToDevice 会让 iOS 的
    # DLPContractTests 双向全等断言变红。
    assert set(dlp.AGENT_CONTROL) == set(CONTRACT["agentControl"])


def test_the_protocol_version_and_frame_ceiling_match_the_contract():
    assert dlp.PROTOCOL_VERSION == CONTRACT["protocolVersion"]
    assert dlp.MAX_FRAME_BYTES == CONTRACT["maxFrameBytes"]


def test_the_id_frame_set_matches_the_contract():
    assert set(dlp._ID_FRAMES) == set(CONTRACT["idFrames"])  # noqa: SLF001


@pytest.mark.parametrize("vector", VECTORS, ids=[v["name"] for v in VECTORS])
def test_every_vector_row_is_what_this_end_actually_does(vector):
    frame = frame_for(vector)
    if vector["direction"] == "deviceToAgent":
        actual = dlp.validate_from_device(frame)
    else:
        actual = dlp.validate_from_agent(frame)

    expected = vector["py"]
    if expected == "ok":
        assert actual is None, f"{vector['name']}: 应放行，实得 {actual}"
    else:
        assert expected.startswith("error: "), f"{vector['name']}: 向量里的 py 期望写法不对"
        assert actual == expected[len("error: "):], f"{vector['name']}: 错误文案不符"


def test_the_shared_vectors_cover_every_drift_the_contract_records():
    recorded = set()
    for vector in VECTORS:
        for drift in DRIFT_IDS:
            if drift in vector.get("why", ""):
                recorded.add(drift)
    assert sorted(recorded) == DRIFT_IDS, "每条 knownDrift 至少要有一条向量在记账"


def test_the_vectors_include_an_unknown_frame_for_forward_compatibility():
    unknown = [v for v in VECTORS if v["direction"] == "unknown"]
    assert unknown, "向量里必须有一条未知帧"
    for vector in unknown:
        assert dlp.validate_from_device({"t": vector["t"]}) is None
        assert dlp.validate_from_agent({"t": vector["t"]}) is None
