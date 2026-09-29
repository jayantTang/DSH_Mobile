"""The app's push registration, as the app actually sends it.

The iOS side registers an APNs token by calling `POST /devices/push` from
`RelayDeviceAdmin.registerPush` (`ios/DSHMobile/DSHKit/Sources/RelayKit/
RelayDevices.swift`). The bodies below are the **exact** JSON that Swift method
builds — `JSONSerialization` over a `[String: Any]` — rather than a convenient
Python dict shaped like it, because the failure this guards against is a
mismatch between two languages that each look right on their own.

Why this file exists at all: the 2026-09-28 acceptance run found a device with
`hasPush=0` and no way to say which of the three links was missing — the app
never registered, never reported, or reported in a shape the relay rejected.
Only the first was true, but nothing in the test suite could have told them
apart. These tests pin the *contract* the app codes against, so the next such
run has one fewer suspect.
"""

from __future__ import annotations

import pytest


async def _paired_device(client, provisioned) -> str:
    """One paired phone, and its device token."""
    response = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"],
        "deviceName": "Example iPhone",
        "deviceModel": "iPhone17,1",
        "appVersion": "1.0",
    })
    assert response.status == 200
    return (await response.json())["deviceToken"]


def _swift_body(token: str, env: str | None, turn_end: bool = True, attention: bool = True) -> dict:
    """What `RelayDeviceAdmin.registerPush` puts on the wire.

    Mirrors the Swift construction exactly, including the one non-obvious rule:
    `env` is **omitted** when the token is empty. The relay requires `env` to be
    one of two literals when present, and ignores it when clearing, so an app
    that helpfully sends its environment alongside an empty token would be
    rejected by its own relay.
    """
    fields: dict[str, object] = {
        "apnsToken": token,
        "turnEnd": turn_end,
        "attention": attention,
    }
    if token and env is not None:
        fields["env"] = env
    return fields


async def test_a_sandbox_token_registers_and_lands_in_the_device_row(client, provisioned, store):
    """The acceptance target: after the app opens, the row says hasPush=1/sandbox."""
    token = await _paired_device(client, provisioned)
    # 32 bytes of token, hex-encoded: what `Data.map { %02x }` produces.
    apns = "9f" * 32

    response = await client.post(
        "/devices/push",
        headers={"Authorization": f"Bearer {token}"},
        json=_swift_body(apns, "sandbox"),
    )
    assert response.status == 200, await response.text()
    assert await response.json() == {"ok": True}

    listed = await client.get("/devices", headers={"Authorization": f"Bearer {token}"})
    current = (await listed.json())["currentDeviceId"]
    row = store.device_by_id(current)
    assert row["apnsToken"] == apns
    assert row["apnsEnv"] == "sandbox"
    assert row["pushTurnEnd"] == 1 and row["pushAttention"] == 1
    # What the acceptance run reads as "hasPush".
    assert store.push_targets(provisioned["agent"]["agentId"]), "该设备应进入推送目标集"


async def test_a_token_without_an_environment_is_still_accepted(client, provisioned, store):
    """An older app reports a token and nothing else; the relay must not refuse it.

    The app only omits `env` when it has no token, but the relay's tolerance is
    part of the contract an app codes against: `push_targets` filters rows whose
    environment is NULL, so a token sent alone is stored but never pushed to.
    """
    token = await _paired_device(client, provisioned)
    response = await client.post(
        "/devices/push",
        headers={"Authorization": f"Bearer {token}"},
        json={"apnsToken": "ab" * 32},
    )
    assert response.status == 200, await response.text()
    listed = await client.get("/devices", headers={"Authorization": f"Bearer {token}"})
    row = store.device_by_id((await listed.json())["currentDeviceId"])
    assert row["apnsToken"] == "ab" * 32
    assert row["apnsEnv"] is None
    assert store.push_targets(provisioned["agent"]["agentId"]) == []


async def test_clearing_a_registration_omits_the_environment(client, provisioned, store):
    """Permission turned off: the app sends an empty token with no `env`."""
    token = await _paired_device(client, provisioned)
    await client.post("/devices/push", headers={"Authorization": f"Bearer {token}"},
                      json=_swift_body("cd" * 32, "sandbox"))

    response = await client.post(
        "/devices/push",
        headers={"Authorization": f"Bearer {token}"},
        json=_swift_body("", None),
    )
    assert response.status == 200, await response.text()
    listed = await client.get("/devices", headers={"Authorization": f"Bearer {token}"})
    row = store.device_by_id((await listed.json())["currentDeviceId"])
    assert row["apnsToken"] is None and row["apnsEnv"] is None


async def test_a_switches_only_report_keeps_the_token(client, provisioned, store):
    """Flipping one of the two toggles re-sends the token, environment and both switches.

    The app has no partial-update frame: `registerPush` always sends all four
    fields, because the relay's defaults would otherwise silently re-enable a
    switch the user just turned off. This test is what says that shape is safe.
    """
    token = await _paired_device(client, provisioned)
    await client.post("/devices/push", headers={"Authorization": f"Bearer {token}"},
                      json=_swift_body("ef" * 32, "sandbox", turn_end=True, attention=True))

    response = await client.post(
        "/devices/push",
        headers={"Authorization": f"Bearer {token}"},
        json=_swift_body("ef" * 32, "sandbox", turn_end=True, attention=False),
    )
    assert response.status == 200, await response.text()
    listed = await client.get("/devices", headers={"Authorization": f"Bearer {token}"})
    row = store.device_by_id((await listed.json())["currentDeviceId"])
    assert row["pushTurnEnd"] == 1 and row["pushAttention"] == 0
    assert row["apnsToken"] == "ef" * 32


@pytest.mark.parametrize("env", ["Sandbox", "SANDBOX", "dev", "development", ""])
async def test_the_apps_two_environment_spellings_are_the_only_accepted_ones(
    client, provisioned, env
):
    """`RelayPushEnvironment` has exactly two cases; anything else must be refused.

    A build that sent `development` (the entitlements word) instead of `sandbox`
    would look correct in the app and be rejected here — which is the point:
    loud now, not a silently unreachable phone later.
    """
    token = await _paired_device(client, provisioned)
    response = await client.post(
        "/devices/push",
        headers={"Authorization": f"Bearer {token}"},
        json=_swift_body("ab" * 32, env),
    )
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "request/apns-env"


async def test_a_token_is_accepted_hex_lowercase_as_the_app_encodes_it(client, provisioned, store):
    """`%02x` is lowercase; a relay that normalized case would be storing a different token."""
    token = await _paired_device(client, provisioned)
    apns = "0a1b2c3d" * 8
    await client.post("/devices/push", headers={"Authorization": f"Bearer {token}"},
                      json=_swift_body(apns, "sandbox"))
    listed = await client.get("/devices", headers={"Authorization": f"Bearer {token}"})
    row = store.device_by_id((await listed.json())["currentDeviceId"])
    assert row["apnsToken"] == apns
