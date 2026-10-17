"""中转**这份代码**的版本标识。

为什么要单独一个模块：`/healthz` 里的 `version` 是**协议版本**（整数 `1`，见
``dlp.PROTOCOL_VERSION``），它回答的是"能不能对话"，不是"用户撞上的是哪一次部署"。
两者混用会让排障卡住：协议版本一年不动，而中转的代码一周改几次。

## 编号口径（owner 2026-10-17 定）

中转没有 npm 这类注册表，所以**不写语义化版本**，直接用部署构建号
``yyyyMMdd.HHmm``（北京时间）——与 iOS 的 `CFBundleVersion` 同一口径，一眼能看出
发布先后。构建号由 `deploy/deploy.sh` 在部署时生成并写进 `build.json`；
``build.json`` 同时记 commit（有 git 元数据的机器才有）与部署时刻。

读不到 ``build.json``（本机 pytest、手起进程）时不编造版本：``relayVersion`` 为
``0.0.0``，表示"这不是一次部署"。
"""

from __future__ import annotations

import json
from pathlib import Path

#: 没有部署构建号时的占位值。**不要**把它当成某个发行版。
UNVERSIONED = "0.0.0"

_BUILD_FILE = Path(__file__).with_name("build.json")


def _build() -> dict[str, str] | None:
    """部署指纹；没有 ``build.json``（例如本机 pytest）时返回 ``None``。"""
    try:
        payload = json.loads(_BUILD_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    kept = {
        key: payload[key]
        for key in ("commit", "deployedAt")
        if isinstance(payload.get(key), str) and payload[key].strip()
    }
    return kept or None


def deployed_version() -> str:
    """这次部署的构建号 ``yyyyMMdd.HHmm``；没部署过就是 `0.0.0`。

    只认 ``build.json`` 里的 ``version``：不从文件时间、进程启动时间推算——那会把
    "机器重启过"当成"重新发布过"。
    """
    try:
        payload = json.loads(_BUILD_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return UNVERSIONED
    if not isinstance(payload, dict):
        return UNVERSIONED
    value = payload.get("version")
    return value.strip() if isinstance(value, str) and value.strip() else UNVERSIONED


def describe() -> dict[str, object]:
    """`/healthz` 与启动日志共用的那段。

    键名只增不改：``relayVersion`` 一定有（部署构建号），``build`` 只在有指纹时出现。
    协议版本仍在 ``version`` 键里，两者不是一回事。
    """
    described: dict[str, object] = {"relayVersion": deployed_version()}
    build = _build()
    if build is not None:
        described["build"] = build
    return described
