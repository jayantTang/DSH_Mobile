"""Frame codec / validation tests (spec §3)."""

from __future__ import annotations

import json

import pytest

import dlp


def test_parse_accepts_known_frames():
    frame = dlp.parse_frame('{"t":"req","id":"1","method":"session/list","args":{"_request":{}}}')
    assert frame["t"] == "req"
    assert frame["args"] == {"_request": {}}


def test_parse_accepts_unknown_type_for_forward_compatibility():
    assert dlp.parse_frame('{"t":"somethingNew","x":1}')["t"] == "somethingNew"


def test_parse_accepts_bytes_and_unicode():
    frame = dlp.parse_frame('{"t":"event","value":{"标题":"值"}}'.encode("utf-8"))
    assert frame["value"] == {"标题": "值"}


@pytest.mark.parametrize("raw", ["not json", "[]", "3", '{"id":"1"}', '{"t":""}', '{"t":5}'])
def test_parse_rejects_unusable_payloads(raw):
    with pytest.raises(dlp.FrameError):
        dlp.parse_frame(raw)


def test_parse_rejects_invalid_utf8():
    with pytest.raises(dlp.FrameError):
        dlp.parse_frame(b"\xff\xfe\x00")


def test_parse_rejects_oversized_frame():
    with pytest.raises(dlp.FrameError):
        dlp.parse_frame("{" + "x" * (dlp.MAX_FRAME_BYTES + 1) + "}")


def test_encode_is_compact_and_round_trips():
    text = dlp.encode_frame({"t": "pong", "ts": 12})
    assert text == '{"t":"pong","ts":12}'
    assert dlp.parse_frame(text) == {"t": "pong", "ts": 12}


def test_validate_from_device_requires_id_and_fields():
    assert dlp.validate_from_device({"t": "req", "id": "1", "method": "session/list"}) is None
    assert dlp.validate_from_device({"t": "req", "method": "session/list"}) == "req: missing `id`"
    assert dlp.validate_from_device({"t": "req", "id": "1"}) == "req: missing `method`"
    assert dlp.validate_from_device({"t": "open", "id": "1"}) == "open: missing `endpoint`"
    assert dlp.validate_from_device({"t": "cancel", "id": "1"}) is None
    assert dlp.validate_from_device({"t": "ping", "ts": 1}) is None


def test_validate_from_agent_requires_id_on_correlated_frames():
    assert dlp.validate_from_agent({"t": "res", "id": "1", "ok": True}) is None
    assert dlp.validate_from_agent({"t": "res", "ok": True}) == "res: missing `id`"
    assert dlp.validate_from_agent({"t": "hostStatus", "info": {"online": False}}) is None


def test_device_id_helpers_are_non_destructive():
    original = {"t": "res", "id": "9", "deviceId": "dev_1", "ok": True}
    stripped = dlp.strip_device_id(original)
    assert "deviceId" not in stripped
    assert original["deviceId"] == "dev_1"
    assert dlp.device_id_of(original) == "dev_1"
    assert dlp.device_id_of({"t": "res"}) is None
    assert dlp.strip_device_id({"t": "res"}) == {"t": "res"}


def test_control_frame_builders():
    assert dlp.host_status(online=False) == {"t": "hostStatus", "info": {"online": False}}
    assert dlp.host_status(online=True, agent_id="agt_1", name="mac") == {
        "t": "hostStatus", "info": {"online": True, "agentId": "agt_1", "name": "mac"}}
    attach = dlp.device_attach_frame("dev_1", name="iPhone", model="iPhone17,1", agent_id="agt_1")
    assert attach == {"t": "deviceAttach", "deviceId": "dev_1",
                      "device": {"name": "iPhone", "model": "iPhone17,1", "agentId": "agt_1"}}
    assert dlp.device_detach_frame("dev_1", reason="closed") == {
        "t": "deviceDetach", "deviceId": "dev_1", "reason": "closed"}
    error = dlp.error_frame("auth/x", "nope", fatal=True)
    assert error["fatal"] is True
    assert json.loads(json.dumps(error))["code"] == "auth/x"
